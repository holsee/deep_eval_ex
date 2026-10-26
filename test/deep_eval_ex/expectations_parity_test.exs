defmodule DeepEvalEx.ExpectationsParityTest do
  @moduledoc """
  Runs the expectation scenarios of `test/fixtures/deepeval/expectations/`
  (written by `scripts/parity/generate_runner_fixtures.py`, see the
  fixtures' README) through DeepEvalEx and compares each with what
  deepeval 4.3.1's `_ExpectationEvaluator` did, in these facets:

  - `prompts` - every prompt the scripted LLM judge got, byte for byte
  - `decide` - every System One request (state and questions), byte for
    byte, of the evaluator alone and of `evaluate()`
  - `measure` - the evaluator's result, or the error it raised
  - `evaluate` - the test result's success and metric data (the
    Expectations row with its `expectationsData`), and the test run, which
    carries `expectationsData` and no Expectations row
  - `assert_test` - what `assert_test()` raised

  The `validation/cases.json` inputs check that evaluating without metrics
  or classifiers requires expectations, as deepeval's
  `validate_expectation_coverage` does.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, Result, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock
  alias DeepEvalEx.Metrics.{Expectations, Faithfulness}
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.{JSONDiff, ScriptedParity}
  alias DeepEvalEx.Test.ParityMetrics.Stub
  alias DeepEvalEx.TestRun.{ExpectationsData, JSON}

  @moduletag :parity
  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/deepeval/expectations", __DIR__)

  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
             |> Enum.sort()

  for scenario <- @scenarios,
      file <- ~w(input.json measure.json prompts.json decide.json evaluate.json
                 test_run.json assert_test.json) do
    @external_resource Path.join([@fixtures, scenario, file])
  end

  @external_resource Path.join([@fixtures, "validation", "cases.json"])

  test "covers the scenarios of the fixture script" do
    assert length(@scenarios) == 12
  end

  for scenario <- @scenarios do
    describe scenario do
      @describetag scenario: scenario

      test "prompts the LLM judge as deepeval did", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "prompts.json")) do
          {_outcome, prompts, _calls, _criteria} = measure(dir)
          ScriptedParity.assert_prompts(prompts, load(dir, "prompts.json"))
        end
      end

      test "asks System One what deepeval asked", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "decide.json")) do
          {_outcome, prompts, calls, _criteria} = measure(dir)
          assert prompts == []
          assert encode(calls) == encode(load(dir, "decide.json", ordered: true)["measure"])
        end
      end

      test "measures as deepeval did", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)
        assert_measured(measure(dir), load(dir, "measure.json"))
      end

      test "evaluates as deepeval did", %{scenario: scenario, tmp_dir: tmp_dir} do
        dir = Path.join(@fixtures, scenario)
        {test_case, metrics, opts, calls} = build(dir)

        {results, classifications, _test_run, path} =
          DeepEvalEx.run(
            [test_case],
            metrics,
            [ignore_errors: true, results_folder: tmp_dir] ++ opts
          )

        [test_result] =
          DeepEvalEx.EvaluationResult.from_results([test_case], results, classifications).test_results

        ours =
          Jason.OrderedObject.new([
            {"success", test_result.success},
            {"metrics_data", Enum.map(test_result.metrics_data, &metric_data/1)}
          ])

        assert JSONDiff.diff(roundtrip_ordered(ours), load(dir, "evaluate.json", ordered: true)) ==
                 []

        if File.regular?(Path.join(dir, "decide.json")) do
          assert encode(calls.()) == encode(load(dir, "decide.json", ordered: true)["evaluate"])
        end

        assert normalise(File.read!(path)) ==
                 normalise(File.read!(Path.join(dir, "test_run.json")))
      end

      test "assert_test raises what deepeval's raised", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "assert_test.json")) do
          {test_case, metrics, opts, _calls} = build(dir)

          raised =
            try do
              DeepEvalEx.ExUnit.__assert_evaluation__(test_case, metrics, opts)
              nil
            rescue
              error in ExUnit.AssertionError ->
                %{"type" => "AssertionError", "message" => error.message}

              error ->
                %{"message" => Exception.message(error)}
            end

          expected = load(dir, "assert_test.json")["raised"]

          assert raised ==
                   (expected &&
                      Map.take(
                        expected,
                        if(raised["type"], do: ~w(type message), else: ~w(message))
                      ))
        end
      end
    end
  end

  test "requires expectations without metrics or classifiers, as deepeval does" do
    for %{"description" => description} = case <- load(@fixtures, "validation/cases.json") do
      test_cases = Enum.map(case["test_cases"], &TestCase.new!/1)

      raised =
        try do
          case case["kind"] do
            "evaluate" -> DeepEvalEx.evaluate(test_cases, [])
            "assert_test" -> DeepEvalEx.ExUnit.__assert_evaluation__(hd(test_cases), [], [])
          end

          nil
        rescue
          error in ArgumentError -> %{"type" => "ValueError", "message" => error.message}
        end

      assert raised == case["raised"], description
    end
  end

  # The evaluator alone, as deepeval's measure(): {{:ok, result} |
  # {:raised, exception}, prompts, System One calls, its criteria}.
  defp measure(dir) do
    input = load(dir, "input.json")
    # In evaluate() the evaluator follows the metrics, so a batched
    # scenario's fake answers its m<j>. keys.
    prefix = if input["batched"], do: "m#{length(input["metrics"] || [])}.", else: ""
    {test_case, _metrics, opts, calls} = build(dir, prefix)
    evaluator = Expectations.new(test_case.expectations, opts)

    outcome =
      try do
        {:ok, Evaluator.evaluate_metric(test_case, evaluator, opts)}
      rescue
        error -> {:raised, error}
      end

    {outcome, LLMMock.scripted_prompts(), calls.(), Expectations.criteria(evaluator, opts)}
  end

  defp assert_measured({{:raised, error}, _prompts, _calls, _criteria}, measured) do
    assert measured["raised"]["message"] == Exception.message(error)
  end

  defp assert_measured({{:ok, result}, _prompts, _calls, criteria}, measured) do
    assert measured["raised"] == nil

    ours = %{
      "score" => result.score,
      "success" => result.success,
      "reason" => result.reason,
      "threshold" => result.threshold * 1.0,
      "strict_mode" => result.strict_mode,
      "error" => result.error,
      "evaluation_model" => result.evaluation_model,
      "evaluation_cost" => result.evaluation_cost,
      "input_tokens" => result.input_tokens,
      "output_tokens" => result.output_tokens,
      "verbose_logs" => result.verbose_logs,
      "verdicts" => verdicts(result),
      "criteria" => criteria,
      "confidence" => result.confidence
    }

    theirs = Map.drop(measured, ["raised"])
    # deepeval seeds the cost with the int 0, DeepEvalEx with 0.0.
    theirs = Map.update!(theirs, "evaluation_cost", &if(&1 === 0, do: 0.0, else: &1))
    assert JSONDiff.diff(roundtrip(ours), theirs) == []
  end

  # The verdicts as deepeval's evaluator keeps them, in the order of the
  # conditions (None under System One).
  defp verdicts(%Result{metadata: %{verdicts: verdicts}}) do
    Enum.map(verdicts, fn verdict ->
      Jason.OrderedObject.new([
        {"id", verdict.id},
        {"status", verdict.status},
        {"reason", verdict.reason},
        {"evidence", verdict.evidence}
      ])
    end)
  end

  defp verdicts(%Result{}), do: nil

  # A result as deepeval's MetricData.model_dump(by_alias=True,
  # exclude_none=True), its expectationsData included.
  defp metric_data(%Result{} = result) do
    errored? = Result.errored?(result)

    [
      {"name", result.metric},
      {"threshold", result.threshold && result.threshold * 1.0},
      {"success", result.success},
      {"score", if(errored?, do: nil, else: result.score && result.score * 1.0)},
      {"reason", if(errored?, do: nil, else: result.reason)},
      {"strictMode", result.strict_mode},
      {"flaky", result.flaky},
      {"evaluationModel", result.evaluation_model},
      {"error", result.error},
      {"evaluationCost", result.evaluation_cost},
      {"inputTokenCount", result.input_tokens},
      {"outputTokenCount", result.output_tokens},
      {"verboseLogs", result.verbose_logs},
      {"expectationsData",
       result.expectations_data &&
         ExpectationsData.to_map(result.expectations_data)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
  end

  # The scenario's test case, metrics and run options, with a fresh scripted
  # judge or System One fake, and a function returning the fake's calls.
  defp build(dir, prefix \\ "") do
    input = load(dir, "input.json")

    {opts, calls} =
      case input do
        %{"system_one" => _} ->
          mock =
            Mock.from_fixture(load(dir, "input.json", ordered: true)["system_one"],
              prefix: prefix
            )

          # A System One metric runs under :system_one as its own option.
          eval_mode =
            if input["metrics"] && input["batched"], do: [eval_mode: :system_one], else: []

          {[adapter: :mock, system_one_model: mock] ++ eval_mode, fn -> Mock.dump_calls(mock) end}

        %{"responses" => responses} ->
          LLMMock.script(responses, model: input["judge_model"])
          {[adapter: :mock], fn -> [] end}
      end

    {test_case(input["test_case"]), metrics(input["metrics"]), opts, calls}
  end

  defp metrics(nil), do: []

  defp metrics(specs) do
    Enum.map(specs, fn
      %{"kind" => "stub"} = spec ->
        %Stub{
          name: spec["name"],
          score: spec["score"],
          reason: spec["reason"],
          threshold: spec["threshold"],
          evaluation_model: spec["evaluation_model"],
          evaluation_cost: spec["evaluation_cost"],
          input_tokens: spec["input_tokens"],
          output_tokens: spec["output_tokens"]
        }

      # Under the run's eval_mode: :system_one.
      %{"kind" => "faithfulness", "eval_mode" => "system_one"} ->
        Faithfulness
    end)
  end

  defp test_case(%{"turns" => _} = spec), do: ConversationalTestCase.new!(spec)
  defp test_case(spec), do: TestCase.new!(spec)

  defp load(dir, file, opts \\ []) do
    objects = if opts[:ordered], do: :ordered_objects, else: :maps
    [dir, file] |> Path.join() |> File.read!() |> Jason.decode!(objects: objects)
  end

  defp encode(term), do: JSON.encode!(term, indent: 2, ensure_ascii: false)

  defp roundtrip(term), do: term |> JSON.encode!() |> Jason.decode!()

  defp roundtrip_ordered(term),
    do: term |> JSON.encode!() |> Jason.decode!(objects: :ordered_objects)

  # Wall-clock times: the run's runDuration and a conversation's (a
  # single-turn test case's is the integer 0).
  defp normalise(json) do
    json
    |> String.replace(~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
    |> String.replace(
      ~r/("runDuration": )\d+(\.\d+)?(e-?\d+)?(?=, "evaluationCost"|, "turns")/,
      "\\1\"<normalised>\""
    )
  end
end
