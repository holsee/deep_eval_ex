defmodule DeepEvalEx.LLM.Usage do
  @moduledoc """
  Token usage and cost of a single LLM call, and the per-process scope that
  accumulates it while a metric is measured.

  Mirrors deepeval, where every judge call adds its token counts and cost to
  the metric (`evaluation_cost`, `input_tokens`, `output_tokens`), which are
  then reported on `MetricData` alongside `evaluation_model`.

  ## How usage is collected

  `DeepEvalEx.Metrics.BaseMetric` wraps each `measure/2` in `track/1`, which
  opens a scope in the calling process. Adapters report the usage of each
  call with `record/1`; `DeepEvalEx.LLM.Adapter.generate/2` and
  `generate_with_schema/3` additionally record the adapter's `model_name/1`
  when an adapter reports nothing, so the judge model is always known. When
  the measurement finishes the collected usages are summed into the
  `DeepEvalEx.Result` (see `summarize/1`).

  The scope lives in the process dictionary, so it follows the process that
  runs the metric. The evaluator runs each metric in its own task, which
  keeps concurrent metrics' usage apart. A metric that makes LLM calls from
  tasks of its own must start them with `async/1` and collect them with
  `await/2`, which carry the task's usage back into the caller's scope.
  They carry the caller's `DeepEvalEx.SystemOne.Ledger` the same way: the
  task sees it, and what the task records in it is folded back on `await/2`.

  ## Reporting usage from a custom adapter

      def generate(prompt, opts) do
        with {:ok, %{text: text, usage: usage}} <- call_api(prompt, opts) do
          DeepEvalEx.LLM.Usage.record(
            DeepEvalEx.LLM.Usage.new(model_name(opts), usage.input, usage.output)
          )

          {:ok, text}
        end
      end
  """

  alias DeepEvalEx.LLM.Pricing
  alias DeepEvalEx.SystemOne.Ledger

  @typedoc """
  Where a usage comes from: `:llm` for an LLM judge call (the default), or
  `:system_one` for a System One request (stamped by
  `DeepEvalEx.SystemOne.decide/3`).
  """
  @type source :: :llm | :system_one

  @type t :: %__MODULE__{
          model: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cost: float() | nil,
          source: source()
        }

  @type summary :: %{
          evaluation_model: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          evaluation_cost: float() | nil
        }

  defstruct [:model, :input_tokens, :output_tokens, :cost, source: :llm]

  @scope_key {__MODULE__, :scope}

  @doc """
  Builds the usage of one call, priced with `DeepEvalEx.LLM.Pricing.cost/3`.

  The cost is `nil` when the model is not priced or a token count is unknown.
  """
  @spec new(String.t() | nil, non_neg_integer() | nil, non_neg_integer() | nil) :: t()
  def new(model, input_tokens, output_tokens) do
    %__MODULE__{
      model: model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost: Pricing.cost(model, input_tokens, output_tokens)
    }
  end

  @doc """
  Records `usage` in the current process's scope.

  Does nothing when no scope is open, so adapters can always call it.
  """
  @spec record(t()) :: :ok
  def record(%__MODULE__{} = usage) do
    case Process.get(@scope_key) do
      nil -> :ok
      usages -> Process.put(@scope_key, [usage | usages])
    end

    :ok
  end

  @doc """
  Records each of `usages` in the current process's scope, in order.
  """
  @spec record_all([t()]) :: :ok
  def record_all(usages), do: Enum.each(usages, &record/1)

  @doc """
  Runs `fun` in a fresh scope and returns `{result, usages}`, the usages
  recorded while it ran in recording order.

  Scopes nest: an enclosing scope is set aside while `fun` runs and restored
  afterwards (also when `fun` raises), without the inner usages. Use
  `record_all/1` to pass them on.
  """
  @spec track((-> result)) :: {result, [t()]} when result: term()
  def track(fun) when is_function(fun, 0) do
    outer = Process.put(@scope_key, [])

    try do
      result = fun.()
      {result, Enum.reverse(Process.get(@scope_key))}
    after
      if outer, do: Process.put(@scope_key, outer), else: Process.delete(@scope_key)
    end
  end

  @doc """
  Starts `fun` in a `Task` whose usage is tracked; collect it with `await/2`.

  The task works on a copy of the caller's `DeepEvalEx.SystemOne.Ledger`,
  when one is open, so it sees the measure's System One state.
  """
  @spec async((-> term())) :: Task.t()
  def async(fun) when is_function(fun, 0) do
    ledger = Ledger.current()

    Task.async(fn ->
      {{result, usages}, ledger} = Ledger.run_forked(ledger, fn -> track(fun) end)
      {result, usages, ledger}
    end)
  end

  @doc """
  Awaits a task started with `async/1`, records its usage in the caller's
  scope, folds what it recorded in the System One ledger into the caller's
  and returns the task's result.
  """
  @spec await(Task.t(), timeout()) :: term()
  def await(task, timeout \\ 5_000) do
    {result, usages, ledger} = Task.await(task, timeout)
    record_all(usages)
    Ledger.join(ledger)
    result
  end

  @doc """
  Sums usages into the fields `DeepEvalEx.Result` reports, or returns `nil`
  when there are none (the metric made no LLM call).

  Token counts add up the calls that reported them and are `nil` when none
  did. As in deepeval, the cost is `nil` as soon as one call could not be
  priced. The evaluation model is the first model recorded.
  """
  @spec summarize([t()]) :: summary() | nil
  def summarize([]), do: nil

  def summarize(usages) do
    %{
      evaluation_model: Enum.find_value(usages, & &1.model),
      input_tokens: sum(usages, :input_tokens),
      output_tokens: sum(usages, :output_tokens),
      evaluation_cost: total_cost(usages)
    }
  end

  defp total_cost(usages) do
    costs = Enum.map(usages, & &1.cost)
    if Enum.any?(costs, &is_nil/1), do: nil, else: Enum.sum(costs)
  end

  defp sum(usages, key) do
    case usages |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end
end
