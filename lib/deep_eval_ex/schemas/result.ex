defmodule DeepEvalEx.Result do
  @moduledoc """
  Represents the result of evaluating a test case against a metric.

  ## Fields

  - `:metric` - Name of the metric that produced this result
  - `:score` - Numeric score from 0.0 to 1.0, or `nil` when the metric errored
  - `:success` - Whether the score meets the threshold (always `false` when errored)
  - `:reason` - Explanation for the score (from LLM-based metrics)
  - `:threshold` - The threshold used for pass/fail determination (`nil` if unknown)
  - `:error` - Error message when the metric could not produce a score, else `nil`
  - `:metadata` - Additional metric-specific data
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

  ## Errored vs failed

  A *failed* result has a score below the threshold. An *errored* result
  means the metric never produced a score at all (an LLM call failed, the
  test case was missing parameters, the evaluation timed out, ...). Errored
  results have `score: nil`, `success: false` and the message in `:error`,
  mirroring deepeval's `MetricData`. Build them with `error/3` and detect
  them with `errored?/1`.
  """

  @type t :: %__MODULE__{
          metric: String.t(),
          score: float() | nil,
          success: boolean(),
          reason: String.t() | nil,
          threshold: float() | nil,
          error: String.t() | nil,
          metadata: map() | nil,
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
    :evaluation_model,
    :evaluation_cost,
    :input_tokens,
    :output_tokens,
    :latency_ms
  ]

  @doc """
  Creates a new result struct.

  ## Options

  - `:metric` - Name of the metric (required)
  - `:score` - Numeric score 0.0-1.0 (required)
  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:reason` - Explanation for the score
  - `:metadata` - Additional data
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
    success = Keyword.get_lazy(opts, :success, fn -> score >= threshold end)

    %__MODULE__{
      metric: metric,
      score: score,
      success: success,
      threshold: threshold,
      reason: Keyword.get(opts, :reason),
      metadata: Keyword.get(opts, :metadata),
      evaluation_model: Keyword.get(opts, :evaluation_model),
      evaluation_cost: Keyword.get(opts, :evaluation_cost),
      input_tokens: Keyword.get(opts, :input_tokens),
      output_tokens: Keyword.get(opts, :output_tokens),
      latency_ms: Keyword.get(opts, :latency_ms)
    }
  end

  @doc """
  Creates an errored result for a metric that could not produce a score.

  The result has `score: nil` and `success: false`; `error` is stored as a
  message string. Strings are kept as-is, an exception becomes its message
  (as deepeval records `str(exception)`), `{:missing_params, params}` is
  rendered as a readable message and any other term is inspected.

  ## Options

  - `:threshold` - The metric's threshold, when known (default: `nil`)
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
    %__MODULE__{
      metric: metric,
      score: nil,
      success: false,
      threshold: Keyword.get(opts, :threshold),
      error: format_error(error),
      metadata: Keyword.get(opts, :metadata),
      evaluation_model: Keyword.get(opts, :evaluation_model),
      evaluation_cost: Keyword.get(opts, :evaluation_cost),
      input_tokens: Keyword.get(opts, :input_tokens),
      output_tokens: Keyword.get(opts, :output_tokens),
      latency_ms: Keyword.get(opts, :latency_ms)
    }
  end

  @doc """
  Checks if the result is successful (score >= threshold).

  Errored results are never successful.
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{success: success}), do: success

  @doc """
  Checks if the metric errored instead of producing a score.
  """
  @spec errored?(t()) :: boolean()
  def errored?(%__MODULE__{error: error}), do: not is_nil(error)

  @doc """
  Returns a human-readable summary of the result.

  Errored results are summarised as `"Metric: ERROR - message"`.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{error: error} = result) when is_binary(error) do
    "#{result.metric}: ERROR - #{error}"
  end

  def summary(%__MODULE__{} = result) do
    status = if result.success, do: "PASS", else: "FAIL"
    score_pct = Float.round(result.score * 100, 1)

    base = "#{result.metric}: #{status} (#{score_pct}%)"

    if result.reason do
      "#{base} - #{result.reason}"
    else
      base
    end
  end

  defp format_error({:missing_params, params}) do
    "Missing required parameters: #{Enum.join(params, ", ")}"
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end

defimpl String.Chars, for: DeepEvalEx.Result do
  def to_string(result) do
    DeepEvalEx.Result.summary(result)
  end
end

defimpl Inspect, for: DeepEvalEx.Result do
  import Inspect.Algebra

  def inspect(result, opts) do
    status =
      cond do
        DeepEvalEx.Result.errored?(result) -> "ERROR"
        result.success -> "PASS"
        true -> "FAIL"
      end

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
