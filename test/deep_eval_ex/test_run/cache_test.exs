defmodule DeepEvalEx.TestRun.CacheTest do
  use ExUnit.Case, async: true

  doctest DeepEvalEx.TestRun.Cache

  alias DeepEvalEx.{Classification, Classifier, Result, TestCase}
  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.Metrics.{ExactMatch, GEval}
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.TestRun.Cache

  alias DeepEvalEx.TestRun.Cache.{
    CachedClassification,
    CachedMetricData,
    CachedTestCase,
    CachedTestRun,
    ClassifierConfiguration,
    MetricConfiguration
  }

  alias DeepEvalEx.TestRun.{ExpectationsData, MetricData}

  @fixtures Path.expand("../../fixtures/deepeval/cache", __DIR__)

  describe "key/2" do
    test "sorts lists by their items' JSON, so context order does not matter" do
      a = %TestCase{input: "Q", actual_output: "A", context: ["b", "a"]}
      b = %TestCase{input: "Q", actual_output: "A", context: ["a", "b"]}
      assert Cache.key(a, nil) == Cache.key(b, nil)
    end

    test "keys a RetrievedContextData by its context, and an empty retrieval context as null" do
      with_data = %TestCase{
        input: "Q",
        actual_output: "A",
        retrieval_context: [%RetrievedContextData{context: "C", source: "s.md"}]
      }

      assert Cache.key(with_data, nil) =~ ~s("retrieval_context": ["C"])

      assert Cache.key(%TestCase{input: "Q", actual_output: "A", retrieval_context: []}, nil) =~
               ~s("retrieval_context": null)
    end

    test "keys the hyperparameters, sorted" do
      key = Cache.key(%TestCase{input: "Q", actual_output: "A"}, %{"model" => "x", "k" => "5"})
      assert key =~ ~s("hyperparameters": {"k": "5", "model": "x"})
    end

    test "leaves out other fields and empty expectations" do
      test_case = %TestCase{
        input: "Q",
        actual_output: "A",
        name: "named",
        tags: ["t"],
        expectations: %{model: nil, eval_mode: nil, must: [], must_not: []}
      }

      assert Cache.key(test_case, nil) ==
               Cache.key(%TestCase{input: "Q", actual_output: "A"}, nil)
    end
  end

  describe "encode!/1 and decode/1" do
    test "read deepeval's file back to its bytes, but for the costs pydantic loads as floats" do
      bytes = File.read!(Path.join([@fixtures, "classification", "run0", "cache.json"]))

      assert bytes |> Cache.decode() |> Cache.encode!() ==
               String.replace(bytes, ~s("evaluationCost": 0), ~s("evaluationCost": 0.0))
    end

    test "write a row this run cached with the integer cost 0, as deepeval" do
      result = %Result{
        metric: "M",
        score: 1,
        threshold: 0.5,
        success: true,
        evaluation_cost: 0.25
      }

      run = %CachedTestRun{
        test_cases_lookup_map: [
          {"k",
           %CachedTestCase{
             cached_metrics_data: [
               Cache.cached_metric_data(result, %MetricConfiguration{threshold: 0.5})
             ]
           }}
        ]
      }

      assert Cache.encode!(run) ==
               ~s({"test_cases_lookup_map": {"k": {"cached_metrics_data": [{"metric_data": ) <>
                 ~s({"name": "M", "threshold": 0.5, "success": true, "score": 1.0, ) <>
                 ~s("strictMode": false, "flaky": false, "evaluationCost": 0}, ) <>
                 ~s("metric_configuration": {"threshold": 0.5, "strict_mode": false}}], ) <>
                 ~s("cached_classifications": []}}})
    end

    test "read anything but a cache file as an empty cache" do
      for contents <- ["", "not json", "[]", ~s({"test_cases_lookup_map": {"k": 1}})] do
        assert Cache.decode(contents) == %CachedTestRun{}
      end
    end
  end

  describe "same_metric_config?/2" do
    @configuration %MetricConfiguration{
      threshold: 0.5,
      evaluation_model: "gpt-4o",
      strict_mode: false,
      include_reason: true
    }

    test "matches equal settings, an integer threshold equal to a float one included" do
      assert Cache.same_metric_config?(%{@configuration | threshold: 1}, %{
               @configuration
               | threshold: 1.0
             })
    end

    test "misses on another judge, so a System One result never serves the LLM" do
      refute Cache.same_metric_config?(@configuration, %{
               @configuration
               | evaluation_model: "jev"
             })
    end

    test "compares evaluation steps when the metric has some, else its criteria" do
      cached = %{@configuration | criteria: "C", evaluation_steps: ["generated"]}

      assert Cache.same_metric_config?(%{@configuration | criteria: "C"}, cached)
      refute Cache.same_metric_config?(%{@configuration | criteria: "D"}, cached)
      refute Cache.same_metric_config?(%{@configuration | evaluation_steps: ["mine"]}, cached)

      assert Cache.same_metric_config?(
               %{@configuration | evaluation_steps: ["generated"]},
               cached
             )
    end

    test "compares assessment questions even when the metric has none yet" do
      refute Cache.same_metric_config?(@configuration, %{
               @configuration
               | assessment_questions: ["Q?"]
             })
    end
  end

  describe "metric_data/3" do
    test "finds the first row of the metric's name whose configuration matches" do
      row = row("M", @configuration)
      entry = %CachedTestCase{cached_metrics_data: [row("N", @configuration), row]}

      assert Cache.metric_data("M", @configuration, entry) == row
      assert Cache.metric_data("M", %{@configuration | threshold: 0.6}, entry) == nil
      assert Cache.metric_data("M", @configuration, nil) == nil
    end
  end

  describe "metric_configuration/3" do
    test "has the threshold, strict mode and include_reason of the options" do
      assert %MetricConfiguration{threshold: 1.0, strict_mode: true, include_reason: false} =
               Cache.metric_configuration(ExactMatch, strict_mode: true)
    end

    test "stores GEval's criteria and, once measured, its generated steps" do
      opts = [criteria: "C", evaluation_params: [:input], adapter: :mock, model: "judge"]

      result = %Result{
        metric: "G",
        score: 1,
        success: true,
        metadata: %{evaluation_steps: ["one"]}
      }

      assert %MetricConfiguration{
               criteria: "C",
               evaluation_steps: nil,
               evaluation_params: ["input"]
             } =
               Cache.metric_configuration(GEval, opts)

      assert %MetricConfiguration{evaluation_steps: ["one"]} =
               Cache.metric_configuration(GEval, opts, result)
    end
  end

  describe "cached_result/2" do
    test "reuses the row at cost 0.0, without token counts, with the metric's flakiness" do
      data = %MetricData{
        name: "M",
        threshold: 0.5,
        success: true,
        score: 0.8,
        reason: "R",
        evaluation_model: "gpt-4o",
        evaluation_cost: 0.0,
        input_tokens: 3,
        output_tokens: 4,
        expectations_data: %{"success" => true, "verdicts" => [], "evaluationCost" => 0.5}
      }

      result =
        Cache.cached_result(
          %CachedMetricData{metric_data: data, metric_configuration: @configuration},
          true
        )

      assert %Result{
               metric: "M",
               score: 0.8,
               success: true,
               evaluation_cost: +0.0,
               input_tokens: nil,
               output_tokens: nil,
               flaky: true,
               expectations_data: %ExpectationsData{success: true, evaluation_cost: +0.0}
             } = result
    end
  end

  describe "classifications" do
    setup do
      classifier = Classifier.new!(name: "Topic", labels: ["a", {"b", "B."}])

      configuration = %ClassifierConfiguration{
        labels: [{"a", nil}, {"b", "B."}],
        evaluation_model: "judge"
      }

      %{classifier: classifier, configuration: configuration}
    end

    test "configure a classifier by its labels, judge, include_reason and allow_none", ctx do
      opts = [adapter: :mock, model: "judge"]

      assert Cache.classifier_configuration(ctx.classifier, opts) ==
               %{ctx.configuration | evaluation_model: Adapter.model_name(opts)}
    end

    test "are reused only error-free, under the same name and configuration", ctx do
      ok = %Classification{name: "Topic", label: "a"}

      entry = %CachedTestCase{
        cached_classifications: [
          %CachedClassification{
            classification: %{ok | error: "boom"},
            classifier_configuration: ctx.configuration
          },
          %CachedClassification{classification: ok, classifier_configuration: ctx.configuration}
        ]
      }

      assert %CachedClassification{classification: ^ok} =
               Cache.classification("Topic", ctx.configuration, entry)

      refute Cache.classification("Topic", %{ctx.configuration | allow_none: true}, entry)
      refute Cache.classification("Other", ctx.configuration, entry)
    end

    test "take the test case's expected label and verdict when reused", ctx do
      cached =
        Cache.cached_classification(
          %Classification{name: "Topic", label: "a", expected_label: "a", success: true},
          ctx.configuration
        )

      assert cached.classification.evaluation_cost == 0

      test_case = %TestCase{input: "Q", actual_output: "A", expected_labels: %{"Topic" => "b"}}

      assert %Classification{label: "a", expected_label: "b", success: false} =
               Cache.cached_classification_result(cached, test_case)
    end
  end

  defp row(name, configuration) do
    %CachedMetricData{
      metric_data: %MetricData{name: name, score: 1.0},
      metric_configuration: configuration
    }
  end
end
