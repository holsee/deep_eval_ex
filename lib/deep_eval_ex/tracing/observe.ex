defmodule DeepEvalEx.Tracing.Observe do
  @moduledoc """
  `deftraced` and `defptraced`: functions whose every call is a span,
  deepeval 4.3.1's `@observe` decorator (`tracing/tracing.py`).

  `use DeepEvalEx.Tracing` imports them.

      defmodule MyApp.Support do
        use DeepEvalEx.Tracing

        @doc "Answers a support question."
        @spec answer(String.t()) :: String.t()
        deftraced answer(query), type: :agent, available_tools: ["retrieve"] do
          docs = retrieve(query)
          generate(query, docs)
        end

        deftraced retrieve(query, k \\\\ 2), type: :retriever, embedder: "text-embedding-3-small" do
          MyApp.Search.top_k(query, k)
        end
      end

  A call is wrapped in `DeepEvalEx.Tracing.span/3`:

  - the span is named after the function, unless the options give a
    `:name`;
  - its default input is the call's arguments as a `Jason.OrderedObject`
    with string keys, in the order of the head, defaults applied, as
    deepeval binds `inspect.signature(func)` with `apply_defaults()`
    (`retrieve("q")` records `{"query": "q", "k": 2}`, a zero-argument
    function `{}`);
  - its default output is the result.

  The options are those of `DeepEvalEx.Tracing.span/3` (`:type`,
  `:metrics`, `:drop_if_root`, ...), evaluated at each call.

  ## Argument names

  - a variable keeps its name: `query` is `"query"`;
  - `name = pattern` (or `pattern = name`) uses `name`;
  - an underscored variable loses its underscore: `_opts` is `"opts"`;
  - any other pattern, `_` included, is named after its position:
    `"arg1"`, `"arg2"`, ...

  ## Bodies

  Guards, defaults, `@doc` and `@spec` work as with `def`. A body may
  have `rescue`, `catch`, `else` and `after` clauses, which run inside the
  span. A function of several clauses keeps one head and lists the
  clauses in its body, so a call is one span whichever clause runs:

      deftraced classify(input), type: :tool do
        text when is_binary(text) -> {:text, text}
        _other -> :unknown
      end

  Stacktraces gain one frame, the anonymous function the body runs in.
  """

  alias DeepEvalEx.Tracing

  @body_keys [:do, :rescue, :catch, :else, :after]

  @doc """
  Defines a public function whose calls are spans; see the moduledoc.
  """
  defmacro deftraced(head, opts \\ [], body), do: define(:def, head, opts, body)

  @doc """
  Defines a private function whose calls are spans; see the moduledoc.
  """
  defmacro defptraced(head, opts \\ [], body), do: define(:defp, head, opts, body)

  @doc false
  # The runtime half of a traced function.
  @spec __span__(String.t(), keyword(), [{String.t(), term()}], (-> result)) :: result
        when result: term()
  def __span__(name, opts, arguments, fun) do
    {type, opts} = Keyword.pop(opts, :type)

    opts =
      opts
      |> Keyword.put_new(:name, name)
      |> Keyword.put(:input, Jason.OrderedObject.new(arguments))

    Tracing.span(type || :base, opts, fun)
  end

  defp define(kind, head, opts, body) do
    # `deftraced f(x), type: :tool, do: x` brings its options in the body.
    {body, extra} = if Keyword.keyword?(body), do: Keyword.split(body, @body_keys), else: {[], []}
    opts = if extra == [], do: opts, else: opts ++ extra

    unless Keyword.has_key?(body, :do) do
      raise ArgumentError, "#{kind}traced needs a do block, got: #{Macro.to_string(head)}"
    end

    name = head |> call() |> elem(0) |> Atom.to_string()
    {head, arguments} = bind_head(head)
    vars = Enum.map(arguments, &elem(&1, 1))

    traced =
      quote do
        unquote(__MODULE__).__span__(
          unquote(name),
          unquote(opts),
          unquote(arguments),
          fn -> unquote(inner(body, vars)) end
        )
      end

    case kind do
      :def -> quote(do: def(unquote(head), do: unquote(traced)))
      :defp -> quote(do: defp(unquote(head), do: unquote(traced)))
    end
  end

  defp call({:when, _meta, [call, _guards]}), do: call
  defp call(call), do: call

  # The head with its parameters bound, and each argument's name and
  # variable.
  defp bind_head({:when, meta, [call, guards]}) do
    {call, arguments} = bind_head(call)
    {{:when, meta, [call, guards]}, arguments}
  end

  defp bind_head({name, meta, args}) do
    args = if is_list(args), do: args, else: []

    {params, arguments} =
      args
      |> Enum.with_index(1)
      |> Enum.map(fn {arg, position} ->
        {param, key, var} = bind(arg, position)
        {param, {key, var}}
      end)
      |> Enum.unzip()

    {{name, meta, params}, arguments}
  end

  # Clauses in the body: one anonymous function applied to the arguments.
  defp inner([do: [{:->, _, _} | _] = clauses], vars) do
    function = {:fn, [], clauses}
    quote(do: unquote(function).(unquote_splicing(vars)))
  end

  defp inner([do: block], _vars), do: block
  defp inner(body, _vars), do: quote(do: try(unquote(body)))

  # Returns {parameter, argument name, variable holding the argument}.
  defp bind({:\\, meta, [pattern, default]}, position) do
    {param, key, var} = bind(pattern, position)
    {{:\\, meta, [param, default]}, key, var}
  end

  defp bind({name, _meta, context} = var, position) when is_atom(name) and is_atom(context) do
    case Atom.to_string(name) do
      "_" -> generated(var, position, "arg#{position}")
      "_" <> rest -> generated(var, position, rest)
      key -> {var, key, var}
    end
  end

  defp bind({:=, _meta, [left, right]} = pattern, position) do
    cond do
      named?(left) -> {pattern, var_name(left), left}
      named?(right) -> {pattern, var_name(right), right}
      true -> generated(pattern, position, "arg#{position}")
    end
  end

  defp bind(pattern, position), do: generated(pattern, position, "arg#{position}")

  defp generated(pattern, position, key) do
    var = Macro.var(:"arg#{position}", __MODULE__)
    {{:=, [], [pattern, var]}, key, var}
  end

  defp named?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: not String.starts_with?(Atom.to_string(name), "_")

  defp named?(_pattern), do: false

  defp var_name({name, _meta, _context}), do: Atom.to_string(name)
end
