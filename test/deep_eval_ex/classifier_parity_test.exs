defmodule DeepEvalEx.ClassifierParityTest do
  @moduledoc """
  Runs the classifier scenarios of `test/fixtures/deepeval/classifiers/`
  (written by `scripts/parity/generate_runner_fixtures.py`, see the
  fixtures' README) through `DeepEvalEx.Classifier` and compares each with
  what deepeval 4.3.1 did, in these facets:

  - `prompts` - every prompt the scripted LLM judge got, byte for byte
  - `decide` - every System One request (state and questions), byte for byte
  - `classify` - the classification `classify()` produced, or the error it
    raised
  - `evaluate` - the test result's success and classifications that
    `evaluate(..., classifiers=[...])` returned, and, with a metric, the
    test run it wrote (which holds no classification)
  - `assert_test` - what `assert_test(..., classifiers=[...])` raised

  The System One scenario `refusal_classifier_system_one` of
  `test/fixtures/deepeval/system_one/` is run the same way. The built-in
  classifiers' labels and the label and run validation errors are
  compared too.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.{
    Classification,
    Classifier,
    Classifiers,
    ConversationalTestCase,
    TestCase,
    TestResult
  }

  alias DeepEvalEx.Classifier.Utils
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.{JSONDiff, ScriptedParity}
  alias DeepEvalEx.Test.ParityMetrics.Stub
  alias DeepEvalEx.TestRun.JSON

  @moduletag :parity
  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/deepeval/classifiers", __DIR__)
  @system_one Path.expand("../fixtures/deepeval/system_one", __DIR__)

  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
             |> Enum.sort()

  for scenario <- @scenarios,
      file <- ~w(input.json measure.json prompts.json decide.json evaluate.json
                 test_run.json assert_test.json) do
    @external_resource Path.join([@fixtures, scenario, file])
  end

  @external_resource Path.join([@fixtures, "builtins", "builtins.json"])
  @external_resource Path.join([@fixtures, "validation", "cases.json"])

  test "covers the scenarios of the fixture script" do
    assert length(@scenarios) == 16
  end

  for scenario <- @scenarios do
    describe scenario do
      @describetag scenario: scenario

      test "prompts the LLM judge as deepeval did", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "prompts.json")) do
          {_outcome, prompts, _calls} = classify(dir)
          ScriptedParity.assert_prompts(prompts, load(dir, "prompts.json"))
        end
      end

      test "asks System One what deepeval asked", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "decide.json")) do
          {_outcome, prompts, calls} = classify(dir)
          assert prompts == []
          assert encode(calls) == encode(load(dir, "decide.json", ordered: true)["classify"])
        end
      end

      test "classifies as deepeval did", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)
        assert_classified(classify(dir), load(dir, "measure.json"))
      end

      test "evaluates as deepeval did", %{scenario: scenario, tmp_dir: tmp_dir} do
        dir = Path.join(@fixtures, scenario)
        input = load(dir, "input.json")
        {test_case, metrics, classifier, calls} = build(dir)

        {results, classifications, test_run, path} =
          DeepEvalEx.run([test_case], metrics,
            classifiers: [classifier],
            ignore_errors: true,
            results_folder: tmp_dir
          )

        [test_result] =
          DeepEvalEx.EvaluationResult.from_results([test_case], results, classifications).test_results

        assert_evaluated(test_result, dir)

        if File.regular?(Path.join(dir, "decide.json")) do
          assert encode(calls.()) == encode(load(dir, "decide.json", ordered: true)["evaluate"])
        end

        if input["metric"] do
          assert normalise(File.read!(path)) ==
                   normalise(File.read!(Path.join(dir, "test_run.json")))
        else
          # A classifiers-only run has no test run.
          assert {test_run, path} == {nil, nil}
          assert File.ls!(tmp_dir) == []
        end
      end

      test "assert_test raises what deepeval's raised", %{scenario: scenario} do
        dir = Path.join(@fixtures, scenario)

        if File.regular?(Path.join(dir, "assert_test.json")) do
          {test_case, metrics, classifier, _calls} = build(dir)

          raised =
            try do
              DeepEvalEx.ExUnit.__assert_evaluation__(test_case, metrics,
                classifiers: [classifier]
              )

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

  describe "refusal_classifier_system_one (system_one fixtures)" do
    setup do
      %{dir: Path.join(@system_one, "refusal_classifier_system_one")}
    end

    test "asks System One what deepeval asked", %{dir: dir} do
      {_outcome, [], calls} = classify(dir)
      assert encode(calls) == encode(hd(load(dir, "decide.json", ordered: true)["measure"]))
    end

    test "classifies and evaluates as deepeval did", %{dir: dir} do
      {outcome, _prompts, _calls} = classify(dir)
      assert_classified({outcome, [], []}, hd(load(dir, "measure.json")))

      {test_case, [], classifier, calls} = build(dir)
      {:ok, evaluation} = DeepEvalEx.evaluate([test_case], [], classifiers: [classifier])
      [%TestResult{classifications: classifications}] = evaluation.test_results

      assert roundtrip(Enum.map(classifications, &Classification.to_map/1)) ==
               load(dir, "classifications.json")

      assert encode(calls.()) == encode(load(dir, "decide.json", ordered: true)["evaluate"])
    end
  end

  test "builds deepeval's built-in classifiers" do
    Code.ensure_loaded!(Classifiers)

    for builtin <- load(@fixtures, "builtins/builtins.json") do
      params =
        Enum.map(builtin["params"], fn {key, value} -> {String.to_existing_atom(key), value} end)

      classifier = apply(Classifiers, String.to_existing_atom(builtin["kind"]), [params])

      assert classifier.name == builtin["name"]

      assert classifier.labels ==
               Enum.map(builtin["labels"], &{&1["name"], &1["description"]})
    end

    # Every built-in is covered.
    kinds = load(@fixtures, "builtins/builtins.json") |> Enum.map(& &1["kind"]) |> Enum.uniq()
    assert length(kinds) == 13
  end

  test "validates labels and runs as deepeval does" do
    for %{"description" => description} = case <- load(@fixtures, "validation/cases.json") do
      {raised, log} =
        with_log(fn ->
          try do
            validate(case)
            nil
          rescue
            error in ArgumentError -> %{"type" => "ValueError", "message" => error.message}
          end
        end)

      assert raised == case["raised"], description

      warnings = Regex.scan(~r/\[warning\] (.*)/, log, capture: :all_but_first) |> List.flatten()
      assert warnings == case["warnings"], description
    end
  end

  defp validate(%{"kind" => "classifier"} = case),
    do: Classifier.new!(name: case["name"], labels: case["labels"])

  defp validate(%{"kind" => "validate"} = case) do
    classifiers =
      Enum.map(case["classifiers"], &Classifier.new!(name: &1["name"], labels: &1["labels"]))

    test_cases =
      Enum.map(
        case["expected_labels"],
        &TestCase.new!(input: "Q", actual_output: "A", expected_labels: &1)
      )

    Utils.validate!(test_cases, classifiers)
  end

  # Classifies the scenario's test case alone: {{:ok, classification} |
  # {:raised, exception}, prompts, System One calls}.
  defp classify(dir) do
    {test_case, _metrics, classifier, calls} = build(dir)

    outcome =
      try do
        {:ok, Classifier.classify(classifier, test_case)}
      rescue
        error -> {:raised, error}
      end

    {outcome, LLMMock.scripted_prompts(), calls.()}
  end

  defp assert_classified({{:raised, error}, _prompts, _calls}, measured) do
    assert measured["raised"]["message"] == Exception.message(error)
  end

  defp assert_classified({{:ok, classification}, _prompts, _calls}, measured) do
    assert measured["raised"] == nil

    ours =
      %{
        "label" => classification.label,
        "error" => classification.error,
        "evaluation_model" => classification.evaluation_model,
        "evaluation_cost" => classification.evaluation_cost,
        "input_tokens" => classification.input_tokens,
        "output_tokens" => classification.output_tokens
      }

    theirs =
      Map.take(
        measured,
        ~w(label error evaluation_model evaluation_cost input_tokens output_tokens)
      )

    # deepeval seeds the cost with the int 0, DeepEvalEx with 0.0.
    theirs = Map.update!(theirs, "evaluation_cost", &if(&1 === 0, do: 0.0, else: &1))
    assert ours == theirs

    # An errored classification drops the reason classify() kept.
    if measured["error"] == nil, do: assert(classification.reason == measured["reason"])
  end

  defp assert_evaluated(%TestResult{} = test_result, dir) do
    ours =
      Jason.OrderedObject.new([
        {"success", test_result.success},
        {"classifications", Enum.map(test_result.classifications, &Classification.to_map/1)}
      ])

    assert JSONDiff.diff(roundtrip_ordered(ours), load(dir, "evaluate.json", ordered: true)) ==
             []
  end

  # The scenario's test case, metrics and classifier, with a fresh scripted
  # judge or System One fake, and a function returning the fake's calls.
  defp build(dir) do
    input = load(dir, "input.json")
    spec = input["classifier"]

    {opts, calls} =
      case spec["eval_mode"] do
        "system_one" ->
          mock = Mock.from_fixture(load(dir, "input.json", ordered: true)["system_one"])
          {[eval_mode: :system_one, system_one_model: mock], fn -> Mock.dump_calls(mock) end}

        "llm" ->
          LLMMock.script(input["responses"], model: input["judge_model"])
          {[eval_mode: :llm, adapter: :mock], fn -> [] end}
      end

    {test_case(input["test_case"]), metrics(input["metric"]), classifier(spec, opts), calls}
  end

  defp classifier(%{"kind" => "classifier", "params" => params}, opts) do
    params
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Kernel.++(opts)
    |> Classifier.new!()
  end

  defp classifier(%{"kind" => kind} = spec, opts) do
    # Its constructors' names exist as atoms once it is loaded.
    Code.ensure_loaded!(Classifiers)

    params =
      Enum.map(spec["params"] || %{}, fn {key, value} -> {String.to_existing_atom(key), value} end)

    apply(Classifiers, String.to_existing_atom(kind), [params ++ opts])
  end

  defp metrics(nil), do: []

  defp metrics(spec) do
    [
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
    ]
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

  # The run-level runDuration is wall-clock time.
  defp normalise(json),
    do:
      String.replace(json, ~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
end
