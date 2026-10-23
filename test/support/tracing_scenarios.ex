defmodule DeepEvalEx.Test.TracingScenarios do
  @moduledoc """
  Interprets the agent scripts of the traced fixtures (`input.json`, see
  `scripts/parity/generate_fixtures.py traced`) as `deftraced` functions,
  the Elixir side of the generator's `@observe`'d interpreter.

  `compile/1` defines a module with one `deftraced` function per script
  function: its parameters (with their defaults) in order, its span type,
  its `observe` keyword arguments as options. Each body runs the script's
  steps with `run/3`, and `run_app/2` runs the app's steps for each golden,
  one `DeepEvalEx.Tracing.capture/2` per golden.

  The steps are the generator's: `call` (with `args`, `kwargs`, `as` and
  `catch`), `raise`, the `update_*` functions, `with` a `next_*` function
  around a body, and `drop_current_span`. A value is resolved as the
  generator does: `"$name"` is a bound value, and a string with `{name}`
  is formatted with the bound values.

  Keyword arguments become options as the generator's `tracing_kwargs`
  builds them: a `test_case` and tool calls from their fields, a `prompt`
  as a map, `token_intervals` keys (`perf_counter` seconds) as
  microseconds. Staged `metrics` are left out: the span metrics run with
  the evaluator.
  """

  alias DeepEvalEx.Test.TracedFixtures
  alias DeepEvalEx.Tracing
  alias Jason.OrderedObject

  @updates %{
    "update_current_span" => :update_current_span,
    "update_current_trace" => :update_current_trace,
    "update_llm_span" => :update_llm_span,
    "update_agent_span" => :update_agent_span,
    "update_tool_span" => :update_tool_span,
    "update_retriever_span" => :update_retriever_span
  }

  @next ~w(next_span next_agent_span next_llm_span next_tool_span next_retriever_span)

  @supported_steps ["call", "raise", "with", "drop_current_span" | Map.keys(@updates)]

  @doc """
  The module of a scenario's functions, compiled on first use.
  """
  @spec compile(String.t()) :: module()
  def compile(scenario) do
    module = Module.concat(__MODULE__, Macro.camelize(scenario))

    unless Code.ensure_loaded?(module) do
      functions = TracedFixtures.load!(scenario, "input.json")["functions"]
      definitions = Enum.map(functions.values, &definition/1)

      body =
        quote do
          use DeepEvalEx.Tracing

          @doc false
          def __functions__, do: unquote(Macro.escape(functions))

          unquote_splicing(definitions)
        end

      Module.create(module, body, Macro.Env.location(__ENV__))
    end

    module
  end

  defp definition({name, spec}) do
    params = spec["params"] || []

    args =
      Enum.map(params, fn
        [param] -> var(param)
        [param, default] -> {:\\, [], [var(param), Macro.escape(default)]}
      end)

    env = {:%{}, [], Enum.map(params, fn [param | _] -> {param, var(param)} end)}
    head = {String.to_atom(name), [], args}

    observe = options(spec["observe"] || OrderedObject.new([]))
    opts = [type: span_type(spec["type"])] ++ observe

    quote do
      deftraced unquote(head), unquote(Macro.escape(opts)) do
        unquote(__MODULE__).run(
          __MODULE__,
          unquote(Macro.escape(spec)),
          unquote(env)
        )
      end
    end
  end

  defp var(name), do: Macro.var(String.to_atom(name), nil)

  defp span_type(nil), do: :base
  defp span_type(type), do: String.to_existing_atom(type)

  @doc """
  Runs a function's body with its bound arguments and returns its
  resolved `returns`.
  """
  @spec run(module(), OrderedObject.t(), map()) :: term()
  def run(module, spec, env) do
    env = run_steps(module, spec["body"] || [], env)
    resolve(spec["returns"], env)
  end

  @doc """
  Runs the scenario's app for every golden and returns, per golden, the
  traces it captured.
  """
  @spec run_app(String.t(), OrderedObject.t()) :: [[Tracing.Trace.t()]]
  def run_app(scenario, input) do
    module = compile(scenario)

    for golden <- input["goldens"] do
      {_, traces} =
        Tracing.capture([], fn ->
          run_steps(module, input["app"], %{"input" => golden["input"]}, input["uncaught"])
        end)

      traces
    end
  end

  defp run_steps(module, steps, env, uncaught \\ false) do
    Enum.reduce(steps, env, fn step, env -> run_step(module, step, env, uncaught) end)
  end

  defp run_step(module, %OrderedObject{} = step, env, uncaught) do
    case Enum.find(@supported_steps, &step[&1]) do
      "raise" ->
        raise step["raise"]["message"]

      "call" ->
        result =
          try do
            call(module, step, env)
          rescue
            error -> if step["catch"] || uncaught, do: nil, else: reraise(error, __STACKTRACE__)
          end

        if step["as"], do: Map.put(env, step["as"], result), else: env

      nil ->
        raise ArgumentError, "unsupported step #{inspect(step)}"

      tracing ->
        run_tracing_step(module, tracing, step, env, uncaught)
    end
  end

  # The steps that call the update, next and drop functions.
  defp run_tracing_step(_module, "drop_current_span", _step, env, _uncaught) do
    Tracing.drop_current_span()
    env
  end

  defp run_tracing_step(module, "with", step, env, uncaught) do
    true = step["with"] in @next
    opts = step["kwargs"] |> resolve(env) |> options()
    fun = String.to_existing_atom(step["with"])
    apply(Tracing, fun, [opts, fn -> run_steps(module, step["body"], env, uncaught) end])
  end

  defp run_tracing_step(_module, update, step, env, _uncaught) do
    apply(Tracing, Map.fetch!(@updates, update), [step[update] |> resolve(env) |> options()])
    env
  end

  # Python binds keyword arguments by name; Elixir calls by position, so
  # the keyword arguments become positions, leaving trailing defaults out.
  defp call(module, step, env) do
    name = step["call"]
    params = module.__functions__()[name]["params"] || []
    args = resolve(step["args"] || [], env)
    kwargs = resolve(step["kwargs"] || OrderedObject.new([]), env)

    rest =
      params
      |> Enum.drop(length(args))
      |> Enum.map(fn [param | default] ->
        case List.keyfind(kwargs.values, param, 0) do
          {_, value} -> {:given, value}
          nil -> {:default, List.first(default)}
        end
      end)
      |> Enum.reverse()
      |> Enum.drop_while(&match?({:default, _}, &1))
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 1))

    apply(module, String.to_atom(name), args ++ rest)
  end

  # tracing_kwargs: the script's keyword arguments as options.
  defp options(%OrderedObject{values: values}) do
    for {key, value} <- values, key != "metrics" do
      key = String.to_existing_atom(key)
      {key, option(key, plain(value))}
    end
  end

  defp option(:test_case, fields), do: DeepEvalEx.TestCase.new!(fields)

  defp option(:prompt, fields),
    do: Map.new(fields, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp option(:token_intervals, intervals) do
    Map.new(intervals, fn {seconds, text} ->
      {seconds, ""} = Float.parse(seconds)
      {round(seconds * 1_000_000), text}
    end)
  end

  defp option(_key, value), do: value

  defp plain(%OrderedObject{values: values}), do: Map.new(values, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  @doc """
  Resolves a script value against bound values, as the generator's
  `resolve`.
  """
  @spec resolve(term(), map()) :: term()
  def resolve("$" <> name = value, env), do: Map.get(env, name, value)

  def resolve(value, env) when is_binary(value) do
    Regex.replace(~r/\{(\w+)\}/, value, fn _, name -> Map.fetch!(env, name) end)
  end

  def resolve(list, env) when is_list(list), do: Enum.map(list, &resolve(&1, env))

  def resolve(%OrderedObject{values: values}, env),
    do: OrderedObject.new(for {key, value} <- values, do: {key, resolve(value, env)})

  def resolve(value, _env), do: value
end
