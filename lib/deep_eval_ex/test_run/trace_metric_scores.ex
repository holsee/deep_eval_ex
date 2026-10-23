defmodule DeepEvalEx.TestRun.TraceMetricScores do
  @moduledoc """
  A test run's `traceMetricsScores`: deepeval 4.3.1's `TraceMetricScores`
  (`test_run/test_run.py`), computed as `TestRun.calculate_metrics_scores`
  does from the spans of each test case's `trace` (`DeepEvalEx.Tracing.Api`).

  Spans are read type by type, agent, tool, retriever, llm then base, and
  each span's `metricsData` rows are counted under the span's type, its
  name and the metric's name, in the order they first appear: every score,
  and pass, fail and error counts. A row without a score or a success
  counts as an error, as in `metricsScores`.

  The same rows count in the run's `metricsScores` too, after the test
  case's own (`span_metrics_data/1`), as deepeval folds them in.

  `DeepEvalEx.TestRun.from_test_cases/2` computes it; a test run loaded
  from a file keeps the value it was saved with.
  """

  alias DeepEvalEx.TestRun.MetricData
  alias Jason.OrderedObject

  # deepeval's processing order, which is also TraceMetricScores'
  # declaration order.
  @types [
    {"agent", "agentSpans"},
    {"tool", "toolSpans"},
    {"retriever", "retrieverSpans"},
    {"llm", "llmSpans"},
    {"base", "baseSpans"}
  ]

  @doc """
  Computes `traceMetricsScores` over the test cases' traces, in order.

  Returns a `Jason.OrderedObject` with all five span types, as deepeval's
  `TraceMetricScores` dumps them, or `nil` when no span has metric data.
  Test cases without a `trace` (conversational ones included) are
  skipped. A trace may be a `Jason.OrderedObject` or a plain decoded map.
  """
  @spec compute([struct()]) :: OrderedObject.t() | nil
  def compute(test_cases) do
    rows = Enum.flat_map(test_cases, &span_rows/1)

    if rows == [] do
      nil
    else
      OrderedObject.new(
        for {type, _bucket} <- @types do
          {type, rows |> Enum.filter(&(elem(&1, 0) == type)) |> by_span()}
        end
      )
    end
  end

  @doc """
  The metric data of a test case's traced spans, in the order deepeval
  counts them in `metricsScores`: span type by span type (agent, tool,
  retriever, llm, base), each span's rows in order. Only the name, score
  and success are read.
  """
  @spec span_metrics_data(struct()) :: [MetricData.t()]
  def span_metrics_data(test_case) do
    for {_type, _span, row} <- span_rows(test_case) do
      %MetricData{name: row["name"], score: row["score"], success: row["success"]}
    end
  end

  # {type, span name, metric data row} for each row of each span, in order.
  defp span_rows(test_case) do
    case Map.get(test_case, :trace) do
      nil ->
        []

      trace ->
        for {type, bucket} <- @types,
            span <- trace[bucket] || [],
            row <- span["metricsData"] || [],
            do: {type, span["name"], row}
    end
  end

  defp by_span(rows) do
    rows
    |> group_in_order(&elem(&1, 1))
    |> Enum.map(fn {span, span_rows} ->
      metrics =
        span_rows
        |> group_in_order(fn {_type, _span, row} -> row["name"] end)
        |> Enum.map(fn {metric, metric_rows} -> {metric, scores(metric, metric_rows)} end)

      {span, OrderedObject.new(metrics)}
    end)
    |> OrderedObject.new()
  end

  # [{key, items}] by first appearance of each key.
  defp group_in_order(items, key_fun) do
    items
    |> Enum.group_by(key_fun)
    |> Enum.sort_by(fn {key, _} -> Enum.find_index(items, &(key_fun.(&1) == key)) end)
  end

  defp scores(metric, rows) do
    {scores, passes, fails, errors} =
      Enum.reduce(rows, {[], 0, 0, 0}, fn {_type, _span, row}, {scores, passes, fails, errors} ->
        case {row["score"], row["success"]} do
          {score, success} when is_nil(score) or is_nil(success) ->
            {scores, passes, fails, errors + 1}

          {score, true} ->
            {[score / 1 | scores], passes + 1, fails, errors}

          {score, _false} ->
            {[score / 1 | scores], passes, fails + 1, errors}
        end
      end)

    OrderedObject.new([
      {"metric", metric},
      {"scores", Enum.reverse(scores)},
      {"passes", passes},
      {"fails", fails},
      {"errors", errors}
    ])
  end
end
