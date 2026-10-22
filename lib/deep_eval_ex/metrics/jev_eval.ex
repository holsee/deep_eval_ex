# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/jev_eval/jev_eval.py and utils.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.JevEval do
  @moduledoc """
  A score metric whose decision points are answered by a System One model
  (TypeSafe AI's Jev by default) with calibrated probabilities, never
  generated text. A port of deepeval 4.3.1's `JevEval`
  (`deepeval/metrics/jev_eval/jev_eval.py`).

  You write the decision points as `DeepEvalEx.SystemOne.Scored` questions:

  - `DeepEvalEx.SystemOne.Scored.Noul` - a proposition, valued P(true)
  - `DeepEvalEx.SystemOne.Scored.Score` - 2 to 10 ordered levels, worst
    first, valued by the expected level
  - `DeepEvalEx.SystemOne.Scored.Choice` - a closed set of options, each
    with a credit in `0..1`, or `nil` for "does not apply"

  One System One request (`DeepEvalEx.SystemOne.decide/3`) answers them
  all, about the test case fields named by `:evaluation_params`. Each
  answer maps onto `0..1` and the score is their weighted mean over the
  questions that applied (`DeepEvalEx.SystemOne.Scoring`); `1.0` when none
  did. No LLM is involved at any point: the reason is deterministic text
  built from the answers and their confidence.

  ## Usage

      alias DeepEvalEx.Metrics.JevEval
      alias DeepEvalEx.SystemOne.Scored

      metric =
        JevEval.new(
          name: "Tool Faithfulness",
          evaluation_params: [:input, :actual_output, :tools_called],
          questions: [
            Scored.Noul.new!(
              statement: "Every figure in actual_output appears in a tool output in tools_called.",
              weight: 2
            ),
            Scored.Score.new!(
              question: "How much of actual_output is grounded in tools_called?",
              levels: ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
            ),
            Scored.Choice.new!(
              question: "What did actual_output do with information the tools did not return?",
              options: [left_it_out: 1.0, hedged_it: 0.5, stated_it_as_fact: 0.0, nothing_missing: nil]
            )
          ]
        )

      {:ok, result} = JevEval.evaluate(metric, test_case)
      result.score            # => 0.46
      result.confidence       # => the least decisive answer's confidence
      result.score_breakdown  # => one outcome per question

  A metric struct can also be passed to `DeepEvalEx.evaluate/3` like any
  other metric. To ask about a conversation, use
  `DeepEvalEx.Metrics.ConversationalJevEval`.

  ## Eval modes

  JevEval is always decided by System One, whatever the `:eval_mode`
  option or setting (see `DeepEvalEx.SystemOne.Mode`), as deepeval's: it
  has no LLM to fall back to and needs no LLM key. Like a metric under the
  `:system_one` eval mode it is seeded with zero cost and token counts,
  which the request adds to; an unpriced request leaves the cost `nil`. A
  System One error is raised, never caught. JevEval is not batched with
  other metrics, as in deepeval.

  ## Strict mode

  `strict_mode: true` forces the threshold to `1` and the score to `1.0`
  when every applicable question is answered at its best (a Noul at
  P(true) >= 0.5, a Score's likeliest level the top one, a Choice's
  likeliest credited option worth `1.0`) and `0.0` otherwise. Each outcome
  of the breakdown then says whether it `passed`.

  ## The trace

  In deepeval, a JevEval without `:evaluation_params` asks about the
  agent's trace instead of test case fields. DeepEvalEx test cases carry no
  trace yet, so such a metric raises `DeepEvalEx.MissingTestCaseParamsError`
  for every test case, with deepeval's message.

  ## Options

  - `:name` - the metric's name (required); results are named
    `"<name> [JevEval]"`
  - `:questions` - the `DeepEvalEx.SystemOne.Scored` questions (required,
    at least one), asked as `"q_<index>"`
  - `:evaluation_params` - the test case fields the questions refer to,
    sent in this order (e.g. `[:input, :actual_output]`); unset and empty
    fields are left out. Omitted: the trace (see above)
  - `:system_one_model` - the System One model, anything
    `DeepEvalEx.SystemOne.Model.resolve/1` accepts (default: the
    `:system_one_model` application config, else Jev)
  - `:threshold` - pass/fail threshold (default: `0.5`); `nil` for
    score-only
  - `:strict_mode` - see above (default: `false`)
  - `:include_reason` - build the reason (default: `true`)
  - `:verbose_mode` - print the verbose logs (default: `false`)
  - `:flaky` - never decide the test case's success (default: `false`)
  - `:include_jev_eval_suffix` - append `" [JevEval]"` to the name
    (default: `true`)
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{DeepEvalError, MissingTestCaseParamsError, Result, SystemOne, TestCase}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.SystemOne.{Context, Model, Scored, Scoring, State}

  @enforce_keys [:name, :questions, :system_one_model]
  defstruct [
    :name,
    :evaluation_params,
    :questions,
    :system_one_model,
    :verbose_mode,
    threshold: 0.5,
    strict_mode: false,
    include_reason: true,
    flaky: false,
    include_jev_eval_suffix: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          evaluation_params: [atom()] | nil,
          questions: [Scored.t(), ...],
          system_one_model: Model.t(),
          verbose_mode: boolean() | nil,
          threshold: number() | nil,
          strict_mode: boolean(),
          include_reason: boolean(),
          flaky: boolean(),
          include_jev_eval_suffix: boolean()
        }

  # deepeval's LLMTestCase multimodal auto-detection.
  @multimodal ~r/\[DEEPEVAL:(?:IMAGE|PDF):(.*?)\]/

  @doc """
  Creates a JevEval metric. See the moduledoc for the options.

  The System One model is resolved and initialised here, as deepeval's
  constructor does (`initialize_jev_model`). Raises `ArgumentError`, as
  deepeval raises `ValueError` or `TypeError`, for an empty
  `:evaluation_params` list, no questions or a question that is not a
  Noul, Score or Choice, and `DeepEvalEx.DeepEvalError` when the System One
  model is not usable.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    evaluation_params = Keyword.get(opts, :evaluation_params)

    if evaluation_params == [] do
      raise ArgumentError,
            "evaluation_params cannot be an empty list; list the test case fields your " <>
              "questions refer to, or omit it to evaluate the trace."
    end

    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      evaluation_params: evaluation_params,
      questions: opts |> Keyword.get(:questions) |> validate_questions!(),
      system_one_model: opts |> Keyword.get(:system_one_model) |> jev_model!(),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      include_reason: Keyword.get(opts, :include_reason, true),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky, false),
      include_jev_eval_suffix: Keyword.get(opts, :include_jev_eval_suffix, true)
    }
  end

  @doc false
  # deepeval's validate_questions, shared with ConversationalJevEval.
  @spec validate_questions!(term()) :: [Scored.t(), ...]
  def validate_questions!(questions) when questions in [nil, []] do
    raise ArgumentError, "JevEval needs at least one question (Noul, Score or Choice)."
  end

  def validate_questions!(questions) when is_list(questions) do
    Enum.each(questions, fn
      %module{} when module in [Scored.Noul, Scored.Score, Scored.Choice] ->
        :ok

      other ->
        raise ArgumentError,
              "Questions must be Noul, Score or Choice; got #{inspect(other)}."
    end)

    questions
  end

  @doc false
  # deepeval's initialize_jev_model, shared with ConversationalJevEval:
  # there is no LLM to fall back to.
  @spec jev_model!(term()) :: Model.t()
  def jev_model!(spec) do
    case spec |> Model.resolve() |> Model.init() do
      {:ok, model} ->
        model

      {:error, error} ->
        raise DeepEvalError,
          message:
            "JevEval needs Jev to score, but it is not usable: #{Exception.message(error)} " <>
              "Pass a configured `TypeSafeModel` as `system_one_model`, or install " <>
              "`typesafe-sdk` and set TYPESAFE_API_KEY."
    end
  end

  @impl true
  def metric_name, do: "JevEval"

  @doc """
  The name results of this configured metric carry, deepeval's
  `JevEval.__name__`: `"<name> [JevEval]"`, or just `"<name>"` when
  `:include_jev_eval_suffix` is false.
  """
  @impl true
  @spec metric_name(t()) :: String.t()
  def metric_name(%__MODULE__{name: name, include_jev_eval_suffix: true}),
    do: "#{name} [JevEval]"

  def metric_name(%__MODULE__{name: name}), do: name

  @impl true
  def required_params, do: []

  @doc """
  The System One model's name, deepeval's `evaluation_model`, reported
  even on an errored result.
  """
  @impl true
  def evaluation_model(opts), do: Model.resolve(Keyword.get(opts, :system_one_model)).name

  @doc """
  Measures `test_case` with `metric`, plus `opts` (e.g. `:verbose_mode`).
  Same as `measure/2` with the metric's fields as options.
  """
  @spec evaluate(t(), TestCase.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = metric, %TestCase{} = test_case, opts \\ []) do
    measure(test_case, Keyword.merge(opts, to_opts(metric)))
  end

  defp to_opts(metric) do
    metric
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)
  end

  @doc """
  Measures `test_case` with the metric configured by `opts` (see the
  moduledoc), as `c:DeepEvalEx.Metrics.BaseMetric.measure/2` does, always
  on System One.

  The test case is checked first, as deepeval's `_check_params`: a
  multimodal one raises `ArgumentError`, one missing an evaluation param
  returns `{:error, {:missing_params, params}}`, and without
  `:evaluation_params` `DeepEvalEx.MissingTestCaseParamsError` is raised.
  """
  @impl true
  def measure(%TestCase{} = test_case, opts) when is_list(opts) do
    metric = new(opts)

    with :ok <- check_params(metric, test_case) do
      context = %Context{mode: :system_one, model: metric.system_one_model, llm?: false}

      super(
        test_case,
        Keyword.merge(opts,
          evaluation_params: metric.evaluation_params,
          questions: metric.questions,
          system_one_model: metric.system_one_model,
          system_one: context
        )
      )
    end
  end

  # deepeval's _check_params.
  defp check_params(metric, test_case) do
    if multimodal?(test_case) do
      raise ArgumentError,
            "#{metric_name(metric)} evaluates text only: Jev has no image input. " <>
              "Pass a text-only LLMTestCase."
    end

    case metric.evaluation_params do
      nil ->
        name = metric_name(metric)

        raise MissingTestCaseParamsError,
          metric: name,
          message:
            "The '#{name}' metric has no evaluation_params, so it evaluates the trace, but " <>
              "this test case has none. Run it on a traced component (`@observe` or " <>
              "`evals_iterator`), or pass evaluation_params to evaluate a plain LLMTestCase."

      params ->
        TestCase.validate_params(test_case, params)
    end
  end

  defp multimodal?(%TestCase{} = test_case) do
    texts =
      [test_case.input, test_case.actual_output, test_case.expected_output] ++
        Enum.map(List.wrap(test_case.retrieval_context), &RetrievedContextData.context/1) ++
        List.wrap(test_case.context)

    Enum.any?(texts, &(is_binary(&1) and Regex.match?(@multimodal, &1)))
  end

  @doc false
  def do_measure(%TestCase{} = test_case, opts) do
    state = State.single_turn(Keyword.fetch!(opts, :evaluation_params), test_case)
    decide(state, name(opts), opts)
  end

  @doc false
  # One System One request about `state`, then deepeval's _finalize: the
  # measure shared with ConversationalJevEval, which builds its own state
  # and result name.
  @spec decide(Jason.OrderedObject.t(), String.t(), keyword()) :: {:ok, Result.t()}
  def decide(state, name, opts) do
    %Context{model: %Model{name: model_name} = model} = Keyword.fetch!(opts, :system_one)
    questions = Keyword.fetch!(opts, :questions)

    case SystemOne.decide(state, Scoring.questions(questions),
           system_one_model: model,
           mode: :system_one,
           metrics: [name]
         ) do
      {:ok, answers, usage} ->
        # An unpriced request (nil) voids the summed cost, as _accrue_cost(None).
        Usage.record(usage || %Usage{source: :system_one})
        {:ok, finalize(name, model_name, questions, Scoring.outcomes(questions, answers), opts)}

      {:error, error} ->
        raise error
    end
  end

  # deepeval's _finalize.
  defp finalize(name, model_name, questions, outcomes, opts) do
    strict? = Keyword.get(opts, :strict_mode, false)

    {outcomes, score} =
      if strict? do
        outcomes = Scoring.mark_strict(questions, outcomes)
        {outcomes, Scoring.aggregate_strict(outcomes)}
      else
        {outcomes, Scoring.aggregate(outcomes)}
      end

    confidence = Scoring.min_confidence(outcomes)

    reason =
      if Keyword.get(opts, :include_reason, true),
        do: Scoring.reason(model_name, outcomes, score: score, strict_mode: strict?)

    verbose_logs =
      Verbose.construct_verbose_logs(
        name,
        [
          "Questions:\n" <> Scoring.format_for_logs(outcomes),
          "Score: #{Verbose.to_str(score)}\nConfidence: #{Verbose.to_str(confidence)}",
          "Reason: #{Verbose.to_str(reason)}"
        ],
        opts
      )

    Result.new(
      metric: name,
      score: score,
      threshold: Keyword.get(opts, :threshold, default_threshold()),
      reason: reason,
      score_breakdown: Enum.map(outcomes, &Scored.Outcome.to_dump/1),
      confidence: confidence,
      strict_applied: true,
      verbose_logs: verbose_logs,
      evaluation_model: model_name
    )
  end

  defp name(opts) do
    name = Keyword.fetch!(opts, :name)
    if Keyword.get(opts, :include_jev_eval_suffix, true), do: "#{name} [JevEval]", else: name
  end
end
