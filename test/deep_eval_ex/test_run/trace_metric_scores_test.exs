defmodule DeepEvalEx.TestRun.TraceMetricScoresTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.TracedFixtures
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.{JSON, MetricData, TraceMetricScores}
  alias Jason.OrderedObject

  @fixtures Path.expand("../../fixtures/deepeval", __DIR__)

  # Every test run deepeval wrote with traces: the traced scenarios' runs
  # in both iterator modes, and round_trip/traced_dataset.
  @files Path.wildcard(Path.join(@fixtures, "traced/*/test_run_*.json")) ++
           [Path.join(@fixtures, "round_trip/traced_dataset/test_run.json")]

  for file <- @files, do: @external_resource(file)

  defp ordered(pairs), do: OrderedObject.new(pairs)

  defp row(name, score, success),
    do: ordered([{"name", name}, {"score", score}, {"success", success}])

  defp api_span(name, rows), do: ordered([{"name", name}, {"metricsData", rows}])

  defp test_case(trace, metrics_data \\ []),
    do: %TestRun.TestCase{name: "tc", trace: trace, metrics_data: metrics_data}

  describe "compute/1" do
    test "is nil without span metric data" do
      no_rows = ordered([{"agentSpans", [ordered([{"name", "a"}])]}, {"toolSpans", []}])

      assert TraceMetricScores.compute([]) == nil
      assert TraceMetricScores.compute([test_case(nil), test_case(no_rows)]) == nil

      assert TraceMetricScores.compute([test_case(ordered([{"llmSpans", [api_span("l", [])]}]))]) ==
               nil
    end

    test "keys spans by type, name and metric, every type present, in pydantic order" do
      trace =
        ordered([
          {"baseSpans", [api_span("b", [row("M", 1, true)])]},
          {"llmSpans",
           [
             api_span("gen", [row("Strict", 0.5, false), row("M", nil, nil)]),
             api_span("gen", [row("Strict", 0.25, true)])
           ]},
          {"toolSpans", [api_span("t", [row("M", 0.5, nil)])]}
        ])

      json =
        [test_case(trace), %TestRun.ConversationalTestCase{name: "c"}]
        |> TraceMetricScores.compute()
        |> JSON.encode!()

      assert json ==
               ~s({"agent": {}, ) <>
                 ~s("tool": {"t": {"M": {"metric": "M", "scores": [], "passes": 0, "fails": 0, "errors": 1}}}, ) <>
                 ~s("retriever": {}, ) <>
                 ~s("llm": {"gen": {) <>
                 ~s("Strict": {"metric": "Strict", "scores": [0.5, 0.25], "passes": 1, "fails": 1, "errors": 0}, ) <>
                 ~s("M": {"metric": "M", "scores": [], "passes": 0, "fails": 0, "errors": 1}}}, ) <>
                 ~s("base": {"b": {"M": {"metric": "M", "scores": [1.0], "passes": 1, "fails": 0, "errors": 0}}}})
    end

    test "reads plain decoded maps as well as ordered objects" do
      trace = %{
        "agentSpans" => [
          %{"name" => "a", "metricsData" => [%{"name" => "M", "score" => 1.0, "success" => true}]}
        ]
      }

      assert %OrderedObject{} = scores = TraceMetricScores.compute([test_case(trace)])
      assert scores["agent"]["a"]["M"]["passes"] == 1
    end
  end

  describe "span_metrics_data/1" do
    test "lists span rows in agent, tool, retriever, llm, base order" do
      trace =
        ordered([
          {"baseSpans", [api_span("b", [row("B", 1.0, true)])]},
          {"agentSpans", [api_span("a", [row("A", 1.0, true)])]},
          {"retrieverSpans", [api_span("r", [row("R", 1.0, true)])]}
        ])

      assert [%MetricData{name: "A"}, %MetricData{name: "R"}, %MetricData{name: "B"}] =
               TraceMetricScores.span_metrics_data(test_case(trace))

      assert TraceMetricScores.span_metrics_data(test_case(nil)) == []
    end
  end

  describe "TestRun.from_test_cases/2" do
    test "computes traceMetricsScores and folds span rows into metricsScores" do
      trace = ordered([{"retrieverSpans", [api_span("retrieve", [row("Span", 0.75, true)])]}])
      own = [%MetricData{name: "Own", score: 1.0, success: true}]

      test_run = TestRun.from_test_cases([test_case(trace, own), test_case(trace, own)])

      assert Enum.map(test_run.metrics_scores, &{&1.metric, &1.scores}) ==
               [{"Own", [1.0, 1.0]}, {"Span", [0.75, 0.75]}]

      assert test_run.trace_metrics_scores["retriever"]["retrieve"]["Span"]["passes"] == 2
      assert TestRun.to_map(test_run)["traceMetricsScores"] == test_run.trace_metrics_scores
    end

    test "leaves traceMetricsScores out without traced spans" do
      test_run = TestRun.from_test_cases([test_case(nil)])
      assert test_run.trace_metrics_scores == nil
      refute "traceMetricsScores" in Enum.map(TestRun.to_map(test_run).values, &elem(&1, 0))
    end
  end

  describe "deepeval's traced test runs" do
    for file <- @files do
      name = Path.relative_to(file, @fixtures)

      test "recomputes #{name}'s metricsScores and traceMetricsScores" do
        {:ok, loaded} = TestRun.load(unquote(file))

        computed =
          TestRun.from_test_cases(loaded.test_cases ++ loaded.conversational_test_cases)

        stored = TestRun.to_map(loaded)
        recomputed = TestRun.to_map(computed)

        for key <- ["metricsScores", "traceMetricsScores"] do
          assert JSON.encode!(recomputed[key]) == JSON.encode!(stored[key]), key
        end
      end
    end

    test "keeps a loaded run's traceMetricsScores as it is" do
      raw = ordered([{"agent", ordered([])}, {"future", 1}])

      {:ok, test_run} =
        TestRun.from_map(ordered([{"testCases", []}, {"traceMetricsScores", raw}]))

      assert test_run.trace_metrics_scores == raw
    end

    test "finds the traced fixtures" do
      assert length(@files) > length(TracedFixtures.scenarios())
    end
  end
end
