defmodule DeepEvalEx.Result do
  @moduledoc """
  Represents the result of evaluating a test case against a metric.

  ## Fields

  - `:metric` - Name of the metric that produced this result
  - `:score` - Numeric score from 0.0 to 1.0, or `nil` when the metric errored
    or was skipped
  - `:success` - Whether the score meets the threshold: `nil` without a
    threshold, `false` when errored (see "Score-only results")
  - `:reason` - Explanation for the score (from LLM-based metrics)
  - `:threshold` - The threshold used for pass/fail determination; `nil` for a
    score-only metric (or when unknown). The integer `1` in strict mode
  - `:error` - Error message when the metric could not produce a score, else `nil`
  - `:strict_mode` - Whether the metric ran in strict mode (default: `false`)
  - `:flaky` - Whether the metric is flaky: its result is reported but never
    decides a test case's success (default: `false`)
  - `:score_breakdown` - Per-component scores of a composite metric, as
    deepeval's `score_breakdown` (default: `nil`). Not exported
  - `:skipped` - Whether the metric was skipped instead of measured
    (default: `false`); skipped results are left out of the test run export
  - `:metadata` - Additional metric-specific data
  - `:verbose_logs` - The metric's intermediate steps (claims, verdicts,
    evaluation steps, ...) as deepeval's `verbose_logs` text, exported as
    `verboseLogs` (see `DeepEvalEx.Metrics.Utils.Verbose`); `nil` when the
    metric logs none
  - `:evaluation_model` - The judge model, for metrics that call an LLM
  - `:evaluation_cost` - USD cost of the LLM calls for this evaluation; `nil`
    when no LLM was called or a call's model is not priced
    (see `DeepEvalEx.LLM.Pricing`)
  - `:input_tokens` - Prompt tokens used by the LLM calls (`nil` if unknown)
  - `:output_tokens` - Completion tokens used by the LLM calls (`nil` if unknown)
  - `:latency_ms` - Time taken for the evaluation in milliseconds

  ## Examples

      %DeepEvalEx.Result{
        metric: "Faithfulness",
        score: 0.85,
        success: true,
        reason: "4 out of 5 claims are supported by the retrieval context.",
        threshold: 0.5,
        metadata: %{
          claims: ["claim1", "claim2", "claim3", "claim4", "claim5"],
          verdicts: [:yes, :yes, :yes, :yes, :no]
        },
        evaluation_model: "gpt-4o-mini",
        evaluation_cost: 0.002,
        input_tokens: 9_200,
        output_tokens: 1_040,
        latency_ms: 1250
      }

  ## Model, tokens and cost

  Like deepeval's `MetricData` (`evaluationModel`, `evaluationCost`,
  `inputTokenCount`, `outputTokenCount`), these are filled in by
  `DeepEvalEx.Metrics.BaseMetric` from the usage of every LLM call made while
  measuring (see `DeepEvalEx.LLM.Usage`). They stay `nil` for metrics that
  make no LLM call, such as `DeepEvalEx.Metrics.ExactMatch`. LLM metrics
  report their configured judge as `:evaluation_model` even without a call,
  and errored results keep the usage of the calls made before the error, as
  deepeval's `MetricData` does.

  ## Score-only results

  As in deepeval, a metric with a `nil` threshold only scores: its `:success`
  is `nil` (deepeval's `is_successful()` returns `None`), it neither passes
  nor fails its test case, and the export leaves out its `threshold` and
  `success`. In strict mode the threshold is forced to the integer `1` and a
  score below it becomes the integer `0` (see
  `DeepEvalEx.Metrics.BaseMetric`).

  ## Errored vs failed

  A *failed* result has a score below the threshold. An *errored* result
  means the metric never produced a score at all (an LLM call failed, the
  test case was missing parameters, the evaluation timed out, ...). Errored
  results have `score: nil`, `success: false` (`nil` for a score-only
  metric) and the message in `:error`, mirroring deepeval's `MetricData`.
  Build them with `error/3` and detect them with `errored?/1`. A *skipped*
  result (`skipped/2`) has neither a score nor an error.
  """

  @type t :: %__MODULE__{
          metric: String.t(),
          score: number() | nil,
          success: boolean() | nil,
          reason: String.t() | nil,
          threshold: number() | nil,
          error: String.t() | nil,
          strict_mode: boolean(),
          flaky: boolean(),
          score_breakdown: map() | nil,
          skipped: boolean(),
          metadata: map() | nil,
          verbose_logs: String.t() | nil,
          evaluation_model: String.t() | nil,
          evaluation_cost: float() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          latency_ms: non_neg_integer() | nil
        }

  @enforce_keys [:metric, :score, :success]
  defstruct [
    :metric,
    :score,
    :success,
    :reason,
    :threshold,
    :error,
    :metadata,
    :verbose_logs,
    :evaluation_model,
    :evaluation_cost,
    :input_tokens,
    :output_tokens,
    :latency_ms,
    :score_breakdown,
    strict_mode: false,
    flaky: false,
    skipped: false
  ]

  @doc """
  Creates a new result struct.

  ## Options

  - `:metric` - Name of the metric (required)
  - `:score` - Numeric score 0.0-1.0 (required)
  - `:threshold` - Pass/fail threshold (default: 0.5); `nil` for a
    score-only result, whose `:success` is then `nil`
  - `:success` - Overrides `score >= threshold`
  - `:reason` - Explanation for the score
  - `:strict_mode` / `:flaky` - See the module documentation
    (default: `false`)
  - `:score_breakdown` - Per-component scores
  - `:metadata` - Additional data
  - `:verbose_logs` - The metric's verbose logs
  - `:evaluation_model` - The judge model
  - `:evaluation_cost` - LLM API cost
  - `:input_tokens` / `:output_tokens` - LLM token counts
  - `:latency_ms` - Evaluation time

  ## Examples

      DeepEvalEx.Result.new(
        metric: "Helpfulness [GEval]",
        score: 0.8,
        threshold: 0.5,
        reason: "The response is accurate and relevant."
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    metric = Keyword.fetch!(opts, :metric)
    score = Keyword.fetch!(opts, :score)
    threshold = Keyword.get(opts, :threshold, 0.5)

    # Allow explicit success override (for metrics where lower is better)
    success = Keyword.get_lazy(opts, :success, fn -> successful?(score, threshold) end)

    %__MODULE__{
      metric: metric,
      score: score,
      success: success,
      threshold: threshold,
      reason: Keyword.get(opts, :reason),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      score_breakdown: Keyword.get(opts, :score_breakdown),
      metadata: Keyword.get(opts, :metadata),
      verbose_logs: Keyword.get(opts, :verbose_logs),
      evaluation_model: Keyword.get(opts, :evaluation_model),
      evaluation_cost: Keyword.get(opts, :evaluation_cost),
      input_tokens: Keyword.get(opts, :input_tokens),
      output_tokens: Keyword.get(opts, :output_tokens),
      latency_ms: Keyword.get(opts, :latency_ms)
    }
  end

  @doc """
  Creates an errored result for a metric that could not produce a score.

  The result has `score: nil` and `success: false`, or `success: nil` when
  `:threshold` is given as `nil` (a score-only metric), as deepeval's
  `is_successful()` checks the threshold before the error; `error` is
  stored as a message string. Strings are kept as-is, an exception becomes its message
  (as deepeval records `str(exception)`) and any other term is inspected,
  but for the errors of `DeepEvalEx.TestCase.validate_params/2`, which get
  the message of deepeval's `MissingTestCaseParamsError` for `metric`:

  - `{:missing_params, params}` - `"'actual_output' and 'expected_output'
    cannot be None for the 'Exact Match' metric"` (params joined as
    `'a'`, `'a' and 'b'` or `'a', 'b', and 'c'`)
  - `{:empty_param, :actual_output}` - `"'actual_output' cannot be empty for
    the 'Exact Match' metric"`

  ## Options

  - `:threshold` - The metric's threshold, when known (default: `nil`,
    unknown); an explicit `nil` marks a score-only metric
  - `:strict_mode` / `:flaky` - See the module documentation
    (default: `false`)
  - `:metadata` - Additional data
  - `:evaluation_model` - The judge model
  - `:evaluation_cost` - LLM API cost incurred before the error
  - `:input_tokens` / `:output_tokens` - LLM token counts before the error
  - `:latency_ms` - Evaluation time

  ## Examples

      DeepEvalEx.Result.error("Faithfulness", "Evaluation timed out", threshold: 0.5)
  """
  @spec error(String.t(), term(), keyword()) :: t()
  def error(metric, error, opts \\ []) do
    # An explicit nil threshold is a score-only metric; a missing one unknown.
    success = if Keyword.fetch(opts, :threshold) == {:ok, nil}, do: nil, else: false

    %__MODULE__{
      metric: metric,
      score: nil,
      success: success,
      threshold: Keyword.get(opts, :threshold),
      error: format_error(error, metric),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      metadata: Keyword.get(opts, :metadata),
      evaluation_model: Keyword.get(opts, :evaluation_model),
      evaluation_cost: Keyword.get(opts, :evaluation_cost),
      input_tokens: Keyword.get(opts, :input_tokens),
      output_tokens: Keyword.get(opts, :output_tokens),
      latency_ms: Keyword.get(opts, :latency_ms)
    }
  end

  @doc """
  Formats an exception as deepeval's `format_error_text`:
  `"<type>: <message>"`, the exception's unqualified module name (Python's
  `type(exc).__name__`) and its message, e.g. `"RuntimeError: boom"`.

  deepeval's synchronous executor (`AsyncConfig(run_async=False)`) records
  this text as an ignored metric error. Its default asynchronous executor,
  which `DeepEvalEx.Evaluator` matches, records only the message
  (`str(exception)`), as `error/3` does.

  ## Options

  - `:with_stack` - Append a newline and the formatted exception with its
    stack trace (default: `false`). deepeval appends its traceback when its
    `deepeval` logger is at `DEBUG` (its `LOG_LEVEL` setting), which has no
    DeepEvalEx counterpart
  - `:stacktrace` - The stack trace to format (default: `[]`)
  - `:verbose_mode` - Without `:with_stack`, append
    `" (Run with LOG_LEVEL=DEBUG for stack trace.)"` (default: the
    `:verbose_mode` setting, see `DeepEvalEx.Config`)

  ## Examples

      iex> DeepEvalEx.Result.format_error_text(%RuntimeError{message: "boom"}, verbose_mode: false)
      "RuntimeError: boom"
  """
  @spec format_error_text(Exception.t(), keyword()) :: String.t()
  def format_error_text(exception, opts \\ []) when is_exception(exception) do
    text = "#{type_name(exception)}: #{Exception.message(exception)}"

    cond do
      Keyword.get(opts, :with_stack, false) ->
        text <> "\n" <> Exception.format(:error, exception, Keyword.get(opts, :stacktrace, []))

      Keyword.get_lazy(opts, :verbose_mode, fn -> DeepEvalEx.Config.get(:verbose_mode) end) ->
        text <> " (Run with LOG_LEVEL=DEBUG for stack trace.)"

      true ->
        text
    end
  end

  defp type_name(%module{}), do: module |> Module.split() |> List.last()

  @doc """
  Creates a skipped result, for a metric that was not measured.

  deepeval skips a metric whose test case lacks its required parameters
  when `skip_on_missing_params` is set; the metric then has no score,
  success or error, and is left out of the test case's `metricsData`.
  `DeepEvalEx.TestRun.from_results/3` leaves skipped results out the same
  way.

  ## Options

  - `:threshold` - The metric's threshold, when known
  - `:strict_mode` / `:flaky` - See the module documentation
    (default: `false`)
  """
  @spec skipped(String.t(), keyword()) :: t()
  def skipped(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      score: nil,
      success: nil,
      threshold: Keyword.get(opts, :threshold),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      skipped: true
    }
  end

  @doc """
  Whether `score` meets `threshold`, as deepeval's `is_successful()`.

  Returns `nil` without a threshold (score-only), `false` without a numeric
  score and `score >= threshold` otherwise.

  ## Examples

      iex> DeepEvalEx.Result.successful?(0.7, 0.5)
      true

      iex> DeepEvalEx.Result.successful?(0.7, nil)
      nil
  """
  @spec successful?(number() | nil, number() | nil) :: boolean() | nil
  def successful?(_score, nil), do: nil
  def successful?(score, threshold) when is_number(score), do: score >= threshold
  def successful?(_score, _threshold), do: false

  @doc """
  Checks if the result is successful (score >= threshold).

  Errored results are never successful; score-only and skipped results
  return `nil`.
  """
  @spec success?(t()) :: boolean() | nil
  def success?(%__MODULE__{success: success}), do: success

  @doc """
  Checks if the metric errored instead of producing a score.
  """
  @spec errored?(t()) :: boolean()
  def errored?(%__MODULE__{error: error}), do: not is_nil(error)

  @doc """
  Returns a human-readable summary of the result.

  Errored results are summarised as `"Metric: ERROR - message"`, skipped
  ones as `"Metric: SKIPPED"` and score-only ones with the status `SCORED`.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{error: error} = result) when is_binary(error) do
    "#{result.metric}: ERROR - #{error}"
  end

  def summary(%__MODULE__{skipped: true} = result), do: "#{result.metric}: SKIPPED"

  def summary(%__MODULE__{} = result) do
    status = status(result)
    score_pct = Float.round(result.score * 100 / 1, 1)

    base = "#{result.metric}: #{status} (#{score_pct}%)"

    if result.reason do
      "#{base} - #{result.reason}"
    else
      base
    end
  end

  @doc false
  # "PASS", "FAIL", "SCORED" (no threshold), "SKIPPED" or "ERROR".
  @spec status(t()) :: String.t()
  def status(%__MODULE__{error: error}) when is_binary(error), do: "ERROR"
  def status(%__MODULE__{skipped: true}), do: "SKIPPED"
  def status(%__MODULE__{success: true}), do: "PASS"
  def status(%__MODULE__{success: false}), do: "FAIL"
  def status(%__MODULE__{success: nil}), do: "SCORED"

  # deepeval's check_llm_test_case_params messages (no trailing period)
  defp format_error({:missing_params, params}, metric) when is_list(params) and params != [] do
    "#{join_params(Enum.map(params, &"'#{&1}'"))} cannot be None for the '#{metric}' metric"
  end

  defp format_error({:empty_param, param}, metric) when is_atom(param) do
    "'#{param}' cannot be empty for the '#{metric}' metric"
  end

  defp format_error(error, _metric) when is_binary(error), do: error
  defp format_error(error, _metric) when is_exception(error), do: Exception.message(error)
  defp format_error(error, _metric), do: inspect(error)

  defp join_params([param]), do: param
  defp join_params([first, second]), do: "#{first} and #{second}"

  defp join_params(params) do
    {init, [last]} = Enum.split(params, -1)
    Enum.join(init, ", ") <> ", and " <> last
  end
end

defimpl String.Chars, for: DeepEvalEx.Result do
  def to_string(result) do
    DeepEvalEx.Result.summary(result)
  end
end

defimpl Inspect, for: DeepEvalEx.Result do
  import Inspect.Algebra

  def inspect(result, opts) do
    status = DeepEvalEx.Result.status(result)

    fields =
      [
        metric: result.metric,
        score: result.score,
        status: status,
        threshold: result.threshold
      ]
      |> maybe_add(:error, result.error)
      |> maybe_add(:reason, result.reason)
      |> maybe_add(:evaluation_model, result.evaluation_model)
      |> maybe_add(:evaluation_cost, result.evaluation_cost)
      |> maybe_add(:latency_ms, result.latency_ms)

    concat(["#DeepEvalEx.Result<", to_doc(fields, opts), ">"])
  end

  defp maybe_add(fields, _key, nil), do: fields
  defp maybe_add(fields, key, value), do: fields ++ [{key, value}]
end
