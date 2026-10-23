defmodule DeepEvalEx.TestRun.CacheParityTest do
  @moduledoc """
  Checks DeepEvalEx's test-run cache against what deepeval 4.3.1 did, from
  the fixtures of `test/fixtures/deepeval/cache/` (written by
  `scripts/parity/generate_runner_fixtures.py`, see the fixtures' README):

  - `keys/keys.json` - the key of each test case, byte for byte
  - `configurations/configurations.json` - every scripted and System One
    scenario's metric configuration before and after measuring, byte for
    byte, and whether each fresh metric reuses each stored configuration
    of its kind
  - every other directory - runs of `evaluate()` one after the other in
    one cache folder: each run starts from deepeval's cache file of the run
    before, and must write deepeval's cache file and test run, measure the
    same metrics (none that it read from the cache), ask System One the
    same questions and classify alike
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{Classifier, ConversationalTestCase, Evaluator, MetricError, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.{JSONDiff, ScriptedParity, SystemOneParity}
  alias DeepEvalEx.Test.ParityMetrics.{CacheStub, ConversationalStub, Failing}
  alias DeepEvalEx.TestRun.{Cache, JSON}

  @moduletag :parity
  @moduletag :tmp_dir

  @fixtures Path.expand("../../fixtures/deepeval/cache", __DIR__)

  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
             |> Enum.sort()

  @external_resource Path.join([@fixtures, "keys", "keys.json"])
  @external_resource Path.join([@fixtures, "configurations", "configurations.json"])

  for scenario <- @scenarios do
    @external_resource Path.join([@fixtures, scenario, "input.json"])
  end

  @judge "scripted-judge"

  test "covers the scenarios of the fixture script" do
    assert length(@scenarios) == 12
  end

  describe "keys" do
    test "are deepeval's serialize() of the test case and hyperparameters" do
      for case <- load("keys/keys.json") do
        test_case = test_case(case["test_case"])
        assert Cache.key(test_case, case["hyperparameters"]) == case["key"], case["description"]
      end
    end
  end

  describe "metric configurations" do
    setup do
      %{configurations: load("configurations/configurations.json")}
    end

    test "are deepeval's before and after measuring, for every scripted metric",
         %{configurations: configurations} do
      for entry <- configurations["metrics"] do
        {test_case, metric, opts} = ScriptedParity.build(entry["scenario"])

        assert encode(Evaluator.metric_configuration(metric, opts)) == entry["before"],
               "#{entry["scenario"]} before measuring"

        if after_measuring = entry["after"] do
          result = measured(test_case, metric, opts)

          assert encode(Evaluator.metric_configuration(metric, opts, result)) == after_measuring,
                 "#{entry["scenario"]} after measuring"
        end
      end
    end

    test "are deepeval's for the System One scenarios' metrics",
         %{configurations: configurations} do
      for entry <- configurations["system_one"] do
        {_test_case, metric, opts} = SystemOneParity.build(entry["scenario"])

        assert encode(Evaluator.metric_configuration(metric, opts)) == entry["before"],
               entry["scenario"]
      end
    end

    test "match stored configurations as deepeval's same_metric_configs",
         %{configurations: configurations} do
      stored =
        Map.new(configurations["metrics"], fn entry ->
          {entry["scenario"], entry["after"] && Jason.decode!(entry["after"])}
        end)

      for %{"metric" => metric, "cached" => cached, "same" => same} <- configurations["same"] do
        {_test_case, built, opts} = ScriptedParity.build(metric)
        current = Evaluator.metric_configuration(built, opts)
        configuration = Cache.configuration_from_map(Map.fetch!(stored, cached))

        assert Cache.same_metric_config?(current, configuration) == same,
               "#{metric} against #{cached}'s stored configuration"
      end
    end
  end

  for scenario <- @scenarios do
    describe scenario do
      @describetag scenario: scenario

      test "writes and reads the cache as deepeval", %{scenario: scenario, tmp_dir: dir} do
        input = load(Path.join(scenario, "input.json"), ordered: true)
        folder = Path.join(dir, "cache")

        input["runs"]
        |> Enum.with_index()
        |> Enum.each(fn {run, i} ->
          seed(folder, scenario, i)
          assert_run(scenario, i, run, folder, Path.join(dir, "results#{i}"))
        end)
      end
    end
  end

  # The cache folder holds deepeval's cache file of the run before run `i`.
  defp seed(folder, scenario, i) do
    File.mkdir_p!(folder)
    File.rm(Path.join(folder, Cache.cache_file()))
    previous = Path.join([@fixtures, scenario, "run#{i - 1}", "cache.json"])

    if i > 0 and File.regular?(previous),
      do: File.cp!(previous, Path.join(folder, Cache.cache_file()))
  end

  defp assert_run(scenario, i, run, folder, results_folder) do
    expected = load(Path.join([scenario, "run#{i}", "run.json"]), ordered: true)
    label = "#{scenario} run #{i}"
    {metrics, opts, calls} = build_run(run)

    outcome =
      ExUnit.CaptureLog.with_log(fn ->
        DeepEvalEx.run(
          Enum.map(run["test_cases"], &test_case/1),
          metrics,
          [
            cache_folder: folder,
            results_folder: results_folder,
            ignore_errors: true,
            use_cache: run["use_cache"] || false,
            write_cache: run["write_cache"] != false,
            max_concurrent: run["max_concurrent"] || 20
          ] ++ opts
        )
      end)
      |> elem(0)

    assert measured_names() == expected["measured"], "#{label}: metrics measured"

    files =
      Enum.filter(
        [Cache.cache_file(), Cache.temp_cache_file()],
        &File.regular?(Path.join(folder, &1))
      )

    assert files == expected["files"], "#{label}: cache files"

    cache_fixture = Path.join([@fixtures, scenario, "run#{i}", "cache.json"])

    if expected["raised"] do
      # deepeval 4.3.1 raises reading a cached expectation evaluator back;
      # DeepEvalEx reuses it (see the fixtures' README, "Known divergences").
      {[results], _classifications, _test_run, _path} = outcome
      assert List.last(results).metric == "Expectations"
      assert List.last(results).evaluation_cost == 0.0
      assert LLMMock.scripted_prompts() == []
    else
      if File.regular?(cache_fixture) do
        ours = File.read!(Path.join(folder, Cache.cache_file()))
        theirs = File.read!(cache_fixture)
        assert JSONDiff.diff(Jason.decode!(ours), Jason.decode!(theirs)) == []
        assert ours == theirs, "#{label}: cache bytes"
      end

      assert_test_run(scenario, i, results_folder, label)
      assert_classifications(outcome, expected, label)
    end

    if decide = expected["decide"] do
      assert encode_pretty(calls.()) == encode_pretty(decide), "#{label}: System One calls"
    end
  end

  defp assert_test_run(scenario, i, results_folder, label) do
    fixture = Path.join([@fixtures, scenario, "run#{i}", "test_run.json"])

    if File.regular?(fixture) do
      [path] = Path.wildcard(Path.join(results_folder, "test_run_*.json"))
      ours = path |> File.read!() |> normalise()
      theirs = fixture |> File.read!() |> normalise()
      assert JSONDiff.diff(Jason.decode!(ours), Jason.decode!(theirs)) == []
      assert ours == theirs, "#{label}: test run bytes"
    end
  end

  defp assert_classifications({_results, classifications, _test_run, _path}, expected, label) do
    theirs = Enum.map(expected["test_results"], & &1["classifications"])

    ours =
      Enum.map(classifications, fn per_case ->
        Enum.map(per_case, &DeepEvalEx.Classification.to_map/1)
      end)

    assert encode_pretty(ours) == encode_pretty(theirs), "#{label}: classifications"
  end

  # The run's metrics and options, its judge scripted and its System One
  # fake (with a function returning the fake's calls) built.
  defp build_run(run) do
    LLMMock.script(plain(run["responses"] || %{}), model: @judge)

    {mock, calls} =
      case run["system_one"] do
        nil ->
          {nil, fn -> [] end}

        spec ->
          mock = Mock.from_fixture(spec)
          {mock, fn -> Mock.dump_calls(mock) end}
      end

    built = Enum.map(run["metrics"] || [], &metric(&1["kind"], &1, mock))
    {metrics, metric_opts} = Enum.unzip(built)
    # A System One scenario's metrics share their options.
    opts = metric_opts |> Enum.uniq() |> List.first([])

    classifiers =
      Enum.map(run["classifiers"] || [], fn spec ->
        params = plain(spec["params"])
        Classifier.new!(name: params["name"], labels: params["labels"])
      end)

    classifier_opts = if classifiers == [], do: [], else: [classifiers: classifiers]
    {metrics, Keyword.merge([adapter: :mock, eval_mode: :llm], opts) ++ classifier_opts, calls}
  end

  defp metric("cache_stub", spec, _mock) do
    {%CacheStub{
       name: spec["name"],
       score: spec["score"],
       reason: spec["reason"],
       threshold: spec["threshold"],
       evaluation_model: spec["evaluation_model"],
       evaluation_cost: spec["evaluation_cost"],
       input_tokens: spec["input_tokens"],
       output_tokens: spec["output_tokens"]
     }, []}
  end

  defp metric("conversational_stub", spec, _mock) do
    {%ConversationalStub{
       name: spec["name"],
       score: spec["score"],
       reason: spec["reason"],
       threshold: spec["threshold"],
       evaluation_model: spec["evaluation_model"],
       evaluation_cost: spec["evaluation_cost"],
       input_tokens: spec["input_tokens"],
       output_tokens: spec["output_tokens"]
     }, []}
  end

  defp metric("error", spec, _mock) do
    {%Failing{
       name: spec["name"],
       threshold: spec["threshold"],
       exception: spec["exception"],
       message: spec["message"]
     }, []}
  end

  defp metric("exact_match", _spec, _mock), do: {ExactMatch, []}

  # A System One scenario's metric, with its eval mode and fake.
  defp metric(_kind, spec, mock), do: SystemOneParity.metric(spec, mock)

  # Measured as deepeval's measure() leaves the metric: the error's result
  # when it raises.
  defp measured(test_case, metric, opts) do
    {result, _printed} =
      ExUnit.CaptureIO.with_io(fn ->
        Evaluator.evaluate_metric(test_case, metric, [ignore_errors: false] ++ opts)
      end)

    result
  rescue
    error in [MetricError] -> error.result
  end

  defp measured_names(names \\ []) do
    receive do
      {:measured, name} -> measured_names([name | names])
    after
      0 -> Enum.sort(names)
    end
  end

  defp test_case(%Jason.OrderedObject{} = spec), do: test_case(plain(spec))
  defp test_case(%{"turns" => _} = spec), do: ConversationalTestCase.new!(spec)
  defp test_case(spec), do: TestCase.new!(spec)

  defp encode(configuration),
    do: configuration |> Cache.configuration_to_map() |> JSON.encode!()

  defp encode_pretty(term), do: JSON.encode!(term, indent: 2, ensure_ascii: false)

  defp load(file, opts \\ []) do
    objects = if opts[:ordered], do: :ordered_objects, else: :maps
    [@fixtures, file] |> Path.join() |> File.read!() |> Jason.decode!(objects: objects)
  end

  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(term), do: term

  # Wall-clock times: the run's runDuration and a conversation's.
  defp normalise(json) do
    json
    |> String.replace(~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
    |> String.replace(
      ~r/("runDuration": )\d+(\.\d+)?(e-?\d+)?(?=, "evaluationCost"|, "turns")/,
      "\\1\"<normalised>\""
    )
  end
end
