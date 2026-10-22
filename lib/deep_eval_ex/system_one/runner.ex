defmodule DeepEvalEx.SystemOne.Runner do
  @moduledoc """
  The whole-chain System One path of a metric under the `:system_one` eval
  mode, a port of deepeval 4.3.1's `run_system_one_eval`
  (`deepeval/metrics/utils/system_one.py`: `_prepare`, `_request_for`,
  `_decide` and `_populate`).

  A built-in LLM-as-a-judge metric normally runs a chain: the LLM extracts
  items, a judge decides about each, code turns the decisions into a score
  and the LLM writes a reason. Under `:system_one` a metric that implements
  `c:DeepEvalEx.Metrics.BaseMetric.system_one_eval_spec/2` instead describes
  itself as a `DeepEvalEx.SystemOne.EvalSpec`, and one System One request
  answers every question about the test case. The score is the weighted
  mean of the answers and the reason deterministic text built from them
  (`DeepEvalEx.SystemOne.Scoring`). No LLM call is made.

  A metric calls `run/3` first thing in its `do_measure/2`, as deepeval's
  `measure()` calls `run_system_one_eval`:

      @impl true
      def do_measure(test_case, opts) do
        case DeepEvalEx.SystemOne.Runner.run(__MODULE__, test_case, opts) do
          {:ok, result} -> {:ok, result}
          :continue -> llm_chain(test_case, opts)
        end
      end

  ## When the runner decides

  `run/3` returns `:continue`, and the metric runs its usual chain, unless
  the metric's effective eval mode (`opts[:system_one]`, see
  `DeepEvalEx.SystemOne.Context`) is `:system_one`. Under `:system_one`:

  - a `nil` spec is `:continue` when the metric has an LLM, and raises
    `DeepEvalEx.DeepEvalError` ("... which cannot judge this test case")
    when it has none, which is always the case under `:system_one`
  - the request's state is `DeepEvalEx.SystemOne.State.build/2` and its
    questions `DeepEvalEx.SystemOne.Scoring.questions/1`, keyed `"q_<i>"`
  - the request is checked against the model's context budget
    (`c:DeepEvalEx.SystemOne.Adapter.context_budget/1`) before it is sent

  Nothing falls back: the user asked for System One. A context overflow,
  found by the budget check or reported by the model, raises
  `DeepEvalEx.ContextWindowExceededError` telling the user to switch the
  metric back to the LLM (`DeepEvalEx.SystemOne.Decision.context_limit_error/2`),
  and any other error is raised unchanged. A low-confidence answer is kept,
  and the result's `:confidence` reports it.

  ## The result

  The request's usage is booked in the measure's usage scope and its
  confidence in the measure's `DeepEvalEx.SystemOne.Ledger`, then replaced
  by the minimum over the outcomes. The result has:

  - `:score` - the weighted mean (`DeepEvalEx.SystemOne.Scoring.aggregate/1`),
    or under `:strict_mode` `1.0` / `0.0`
    (`DeepEvalEx.SystemOne.Scoring.aggregate_strict/1`), and
    `:strict_applied` so the float score is kept
  - `:reason` - `DeepEvalEx.SystemOne.Scoring.reason/3`, or `nil` with
    `include_reason: false`
  - `:score_breakdown` - each outcome as `QuestionOutcome.model_dump()`
  - `:confidence`, `:evaluation_model` (the System One model's name) and
    `:verbose_logs` ("Decided by System One (<model>); no LLM call was
    made." and the outcomes)

  ## Options

  - `:system_one` - the metric's `DeepEvalEx.SystemOne.Context`, which
    `c:DeepEvalEx.Metrics.BaseMetric.measure/2` sets (resolved from the
    options when absent)
  - `:threshold`, `:strict_mode`, `:include_reason` and `:verbose_mode` -
    as for any metric
  - `:metric_name` - the metric's name in results and error messages
    (default: the metric's `metric_name/0`)
  """

  alias DeepEvalEx.{DeepEvalError, Result, SystemOne, TestCase}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.Utils.Verbose

  alias DeepEvalEx.SystemOne.{
    Answers,
    Context,
    Decision,
    Error,
    EvalSpec,
    Ledger,
    Limits,
    Model,
    Question,
    Scored,
    Scoring,
    State
  }

  @doc """
  Decides the whole measure of `metric` (a metric module) for `test_case`
  with its System One model, or returns `:continue` for the metric's own
  chain. See the moduledoc.
  """
  @spec run(module(), TestCase.t(), keyword()) :: {:ok, Result.t()} | :continue
  def run(metric, %TestCase{} = test_case, opts) when is_atom(metric) and is_list(opts) do
    case Context.resolve!(metric, opts) do
      %Context{mode: :system_one} = context -> prepare(metric, test_case, context, opts)
      %Context{} -> :continue
    end
  end

  @doc """
  The whole-chain request `metric` would send for `test_case`, deepeval's
  `_request_for`: `{spec, state, questions}`, the questions keyed
  `"q_<i>"`, or `nil` when the metric's spec declines the test case (or it
  has none). `DeepEvalEx.SystemOne.Batch` merges these requests.

  Raises `DeepEvalEx.DeepEvalError` when the metric has no System One
  model.
  """
  @spec request_for(module(), TestCase.t(), keyword()) ::
          {EvalSpec.t(), Jason.OrderedObject.t(), Question.questions()} | nil
  def request_for(metric, %TestCase{} = test_case, opts) when is_atom(metric) and is_list(opts) do
    case eval_spec(metric, test_case, opts) do
      %EvalSpec{} = spec ->
        %Context{model: model} = Context.resolve!(metric, opts)
        {spec, build_state(metric, spec, model, test_case), Scoring.questions(spec.questions)}

      nil ->
        nil
    end
  end

  # deepeval's _prepare.
  defp prepare(metric, test_case, %Context{} = context, opts) do
    case eval_spec(metric, test_case, opts) do
      %EvalSpec{} = spec ->
        decide(metric, test_case, spec, context, opts)

      nil ->
        if context.llm?,
          do: :continue,
          else: raise(DeepEvalError, message: cannot_judge(metric, opts))
    end
  end

  defp eval_spec(metric, test_case, opts) do
    if Code.ensure_loaded?(metric) and function_exported?(metric, :system_one_eval_spec, 2),
      do: metric.system_one_eval_spec(test_case, opts)
  end

  # deepeval's _request_for, _decide and _populate.
  defp decide(metric, test_case, spec, %Context{model: model}, opts) do
    state = build_state(metric, spec, model, test_case)
    questions = Scoring.questions(spec.questions)

    {answers, usage} =
      case Keyword.get(opts, :system_one_prefetched) do
        nil -> request(metric, model, state, questions, opts)
        prefetched -> prefetched(prefetched)
      end

    {:ok, populate(metric, spec, model, answers, usage, opts)}
  end

  defp build_state(metric, _spec, nil, _test_case),
    do: raise(DeepEvalError, message: not_configured(metric))

  defp build_state(_metric, spec, %Model{}, test_case), do: State.build(spec, test_case)

  # A batch prefetch (DeepEvalEx.SystemOne.Batch) already sent this
  # metric's questions: its answers and usage share, or the request's error.
  defp prefetched({:answers, %Answers{} = answers, usage}), do: {answers, usage}
  defp prefetched({:error, error}) when is_exception(error), do: raise(error)

  # The runner sends the whole test case, the largest state any metric
  # builds, so it checks the budget itself rather than relying on the
  # model to.
  defp request(metric, model, state, questions, opts) do
    name = name(metric, opts)

    with :ok <- Limits.check(state, questions, Model.context_budget(model)),
         {:ok, answers, usage} <-
           SystemOne.decide(state, questions,
             system_one_model: model,
             mode: :system_one,
             metrics: [name]
           ) do
      {answers, usage}
    else
      {:error, %Error{reason: :context_limit} = error} ->
        raise Decision.context_limit_error(name, error)

      {:error, error} ->
        raise error
    end
  end

  defp populate(metric, spec, %Model{name: model_name}, answers, usage, opts) do
    book(usage)
    Ledger.record_confidence(answers)

    outcomes = Scoring.outcomes(spec.questions, answers)
    confidence = Scoring.min_confidence(outcomes)
    strict? = Keyword.get(opts, :strict_mode, false)

    {outcomes, score} =
      if strict? do
        outcomes = Scoring.mark_strict(spec.questions, outcomes)
        {outcomes, Scoring.aggregate_strict(outcomes)}
      else
        {outcomes, Scoring.aggregate(outcomes)}
      end

    Ledger.put_confidence(confidence)

    reason =
      if Keyword.get(opts, :include_reason, true),
        do: Scoring.reason(model_name, outcomes, score: score, strict_mode: strict?)

    name = name(metric, opts)

    verbose_logs =
      Verbose.construct_verbose_logs(
        name,
        [
          "Decided by System One (#{model_name}); no LLM call was made.",
          "Questions:\n" <> Scoring.format_for_logs(outcomes),
          "Score: #{Verbose.to_str(score)}\nConfidence: #{Verbose.to_str(confidence)}\n" <>
            "Reason: #{Verbose.to_str(reason)}"
        ],
        opts
      )

    Result.new(
      metric: name,
      score: score,
      threshold: Keyword.get_lazy(opts, :threshold, fn -> default_threshold(metric) end),
      reason: reason,
      score_breakdown: Enum.map(outcomes, &Scored.Outcome.to_dump/1),
      confidence: confidence,
      strict_applied: true,
      verbose_logs: verbose_logs,
      evaluation_model: model_name
    )
  end

  # An unpriced request (nil) voids the measure's summed cost, as deepeval's
  # _accrue_cost(None).
  defp book(nil), do: Usage.record(%Usage{source: :system_one})
  defp book(%Usage{} = usage), do: Usage.record(usage)

  defp name(metric, opts), do: Keyword.get(opts, :metric_name) || metric.metric_name()

  defp default_threshold(metric) do
    if function_exported?(metric, :default_threshold, 0),
      do: metric.default_threshold(),
      else: 0.5
  end

  defp cannot_judge(metric, opts) do
    "DEEPEVAL_EVAL_MODE=system_one runs #{name(metric, opts)} on System One, which cannot " <>
      "judge this test case. Switch it back to the LLM with `eval_mode=\"llm\"` or " <>
      "`deepeval set-eval-mode llm`."
  end

  # deepeval names the metric's class here.
  defp not_configured(metric) do
    "DEEPEVAL_EVAL_MODE=system_one runs #{metric |> Module.split() |> List.last()} on a " <>
      "System One model, but none is configured. Set TYPESAFE_API_KEY or switch back with " <>
      "`deepeval set-eval-mode llm`."
  end
end
