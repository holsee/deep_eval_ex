defmodule DeepEvalEx.Result do
  @moduledoc """
  Represents the result of evaluating a test case against a metric.

  ## Fields

  - `:metric` - Name of the metric that produced this result
  - `:score` - Numeric score from 0.0 to 1.0
  - `:success` - Whether the score meets the threshold
  - `:reason` - Explanation for the score (from LLM-based metrics)
  - `:threshold` - The threshold used for pass/fail determination
  - `:metadata` - Additional metric-specific data
  - `:evaluation_cost` - Cost of the LLM calls for this evaluation
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
        evaluation_cost: 0.002,
        latency_ms: 1250
      }
  """

  @type t :: %__MODULE__{
          metric: String.t(),
          score: float(),
          success: boolean(),
          reason: String.t() | nil,
          threshold: float(),
          metadata: map() | nil,
          evaluation_cost: float() | nil,
          latency_ms: non_neg_integer() | nil
        }

  @enforce_keys [:metric, :score, :success]
  defstruct [
    :metric,
    :score,
    :success,
    :reason,
    :threshold,
    :metadata,
    :evaluation_cost,
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
  - `:evaluation_cost` - LLM API cost
  - `:latency_ms` - Evaluation time

  ## Examples

      DeepEvalEx.Result.new(
        metric: "GEval",
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
    success = score >= threshold

    %__MODULE__{
      metric: metric,
      score: score,
      success: success,
      threshold: threshold,
      reason: Keyword.get(opts, :reason),
      metadata: Keyword.get(opts, :metadata),
      evaluation_cost: Keyword.get(opts, :evaluation_cost),
      latency_ms: Keyword.get(opts, :latency_ms)
    }
  end

  @doc """
  Checks if the result is successful (score >= threshold).
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{success: success}), do: success

  @doc """
  Returns a human-readable summary of the result.
  """
  @spec summary(t()) :: String.t()
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
end

defimpl String.Chars, for: DeepEvalEx.Result do
  def to_string(result) do
    DeepEvalEx.Result.summary(result)
  end
end

defimpl Inspect, for: DeepEvalEx.Result do
  import Inspect.Algebra

  def inspect(result, opts) do
    status = if result.success, do: "PASS", else: "FAIL"

    fields =
      [
        metric: result.metric,
        score: result.score,
        status: status,
        threshold: result.threshold
      ]
      |> maybe_add(:reason, result.reason)
      |> maybe_add(:evaluation_cost, result.evaluation_cost)
      |> maybe_add(:latency_ms, result.latency_ms)

    concat(["#DeepEvalEx.Result<", to_doc(fields, opts), ">"])
  end

  defp maybe_add(fields, _key, nil), do: fields
  defp maybe_add(fields, key, value), do: fields ++ [{key, value}]
end
