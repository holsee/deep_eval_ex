defmodule DeepEvalExTest do
  # Not async: some tests set the DEEPEVAL_RESULTS_FOLDER environment variable.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias DeepEvalEx.{EvaluationResult, Result, TestCase, TestResult, TestRun}
  alias DeepEvalEx.Metrics.ExactMatch

  @moduletag :tmp_dir

  defmodule OptsMetric do
    @moduledoc false

    def metric_name, do: "OptsMetric"

    def measure(_test_case, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:opts, opts})
      {:ok, Result.new(metric: metric_name(), score: 1.0, evaluation_cost: 0.25)}
    end
  end

  defmodule ScoreOnlyMetric do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric, default_threshold: nil

    @impl true
    def metric_name, do: "ScoreOnly"

    @impl true
    def required_params, do: [:input]

    def do_measure(_test_case, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: 0.25,
         threshold: Keyword.get(opts, :threshold, default_threshold())
       )}
    end
  end

  @no_threshold_message "You must provide at least one non-flaky metric with a 'threshold', " <>
                          "otherwise test cases can never pass or fail."

  setup do
    previous = System.get_env("DEEPEVAL_RESULTS_FOLDER")
    System.delete_env("DEEPEVAL_RESULTS_FOLDER")

    on_exit(fn ->
      if previous,
        do: System.put_env("DEEPEVAL_RESULTS_FOLDER", previous),
        else: System.delete_env("DEEPEVAL_RESULTS_FOLDER")
    end)
  end

  defp test_cases do
    [
      TestCase.new!(input: "2 + 2?", actual_output: "4", expected_output: "4"),
      TestCase.new!(input: "3 + 3?", actual_output: "7", expected_output: "6", name: "wrong")
    ]
  end

  defp written(dir), do: dir |> Path.join("*.json") |> Path.wildcard()

  describe "evaluate_run/3" do
    test "returns the results, the test run and no path without a results folder" do
      assert {[[%Result{success: true}], [%Result{success: false}]], %TestRun{} = test_run, nil} =
               DeepEvalEx.evaluate_run(test_cases(), [ExactMatch])

      assert test_run.test_passed == 1
      assert test_run.test_failed == 1
      assert [%{name: "test_case_0"}, %{name: "wrong"}] = test_run.test_cases
      assert is_float(test_run.run_duration) and test_run.run_duration > 0
    end

    test "writes the test run to the results folder", %{tmp_dir: dir} do
      {{_results, test_run, path}, log} =
        with_log(fn ->
          DeepEvalEx.evaluate_run(test_cases(), [ExactMatch],
            results_folder: dir,
            results_subfolder: "sub",
            identifier: "nightly",
            hyperparameters: [model: "gpt-4o", temperature: 0.7]
          )
        end)

      assert [^path] = written(Path.join(dir, "sub"))
      assert log =~ "Test run saved at #{path}"

      json = File.read!(path)
      assert json == test_run |> TestRun.to_map() |> TestRun.JSON.encode!()
      assert json =~ ~s("identifier": "nightly")
      assert json =~ ~s("hyperparameters": {"model": "gpt-4o", "temperature": "0.7"})
      assert json =~ ~s("testPassed": 1, "testFailed": 1)
    end

    test "does not pass export options to metrics", %{tmp_dir: dir} do
      DeepEvalEx.evaluate_run(test_cases(), [OptsMetric],
        test_pid: self(),
        results_folder: dir,
        identifier: "x",
        hyperparameters: [k: 1],
        dataset_alias: "qa",
        dataset_id: "ds-1",
        dataset_version: "v2"
      )

      assert_received {:opts, opts}
      assert opts[:test_pid] == self()

      for key <- [
            :results_folder,
            :results_subfolder,
            :identifier,
            :hyperparameters,
            :dataset_alias,
            :dataset_id,
            :dataset_version
          ] do
        refute Keyword.has_key?(opts, key)
      end
    end

    test "records the dataset the test cases came from" do
      {_results, test_run, nil} =
        DeepEvalEx.evaluate_run(test_cases(), [ExactMatch],
          dataset_alias: "qa",
          dataset_id: "ds-1",
          dataset_version: "v2"
        )

      assert {test_run.dataset_alias, test_run.dataset_id, test_run.dataset_version} ==
               {"qa", "ds-1", "v2"}
    end

    test "sums evaluation costs from the metrics" do
      {_results, test_run, nil} =
        DeepEvalEx.evaluate_run(test_cases(), [OptsMetric], test_pid: self())

      assert test_run.evaluation_cost == 0.5
    end

    test "rejects invalid hyperparameters before evaluating" do
      assert_raise ArgumentError, fn ->
        DeepEvalEx.evaluate_run(test_cases(), [OptsMetric],
          test_pid: self(),
          hyperparameters: [model: {:openai, "gpt-4o"}]
        )
      end

      refute_received {:opts, _}
    end

    test "raises like deepeval when no metric has a threshold, before evaluating" do
      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate_run(test_cases(), [OptsMetric], test_pid: self(), threshold: nil)
      end

      refute_received {:opts, _}

      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate_run(test_cases(), [ScoreOnlyMetric])
      end
    end

    test "raises like deepeval on a mix of single- and multi-turn test cases, before evaluating" do
      conversation =
        DeepEvalEx.ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}])

      assert_raise ArgumentError, ~r/cannot supply a mixture of `LLMTestCase`/, fn ->
        DeepEvalEx.evaluate_run(test_cases() ++ [conversation], [OptsMetric], test_pid: self())
      end

      refute_received {:opts, _}
    end

    test "raises like deepeval when every metric with a threshold is flaky" do
      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate_run(test_cases(), [ExactMatch, ScoreOnlyMetric], flaky: true)
      end
    end

    test "evaluates score-only metrics alongside a metric with a threshold" do
      {[[_, score_only] | _], test_run, nil} =
        DeepEvalEx.evaluate_run(test_cases(), [ExactMatch, ScoreOnlyMetric])

      assert %Result{score: 0.25, threshold: nil, success: nil} = score_only
      assert test_run.test_passed == 1
      assert test_run.test_failed == 1

      json = test_run |> TestRun.to_map() |> TestRun.JSON.encode!()
      assert json =~ ~s({"name": "ScoreOnly", "score": 0.25, "strictMode": false)
    end

    test "exports each metric's strict mode, with the threshold forced to 1" do
      {_results, test_run, nil} =
        DeepEvalEx.evaluate_run(test_cases(), [ExactMatch], strict_mode: true, threshold: 0.2)

      assert [%{metrics_data: [%{strict_mode: true, threshold: 1}]}, _] = test_run.test_cases
    end

    test "writes to DEEPEVAL_RESULTS_FOLDER when no folder is given", %{tmp_dir: dir} do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", dir)

      capture_log(fn ->
        assert {_results, _test_run, path} = DeepEvalEx.evaluate_run(test_cases(), [ExactMatch])
        assert [^path] = written(dir)
      end)
    end

    test "logs a warning and returns no path when the run cannot be written", %{tmp_dir: dir} do
      file = Path.join(dir, "taken")
      File.write!(file, "")

      log =
        capture_log(fn ->
          assert {_results, %TestRun{}, nil} =
                   DeepEvalEx.evaluate_run(test_cases(), [ExactMatch], results_folder: file)
        end)

      assert log =~ "failed to save test run"
    end
  end

  describe "evaluate/3" do
    test "returns {:ok, %EvaluationResult{}} with a TestResult per test case" do
      assert {:ok,
              %EvaluationResult{confident_link: nil, test_run_id: nil, test_results: results}} =
               DeepEvalEx.evaluate(test_cases(), [ExactMatch])

      assert [
               %TestResult{
                 name: "test_case_0",
                 index: 0,
                 success: true,
                 conversational: false,
                 input: "2 + 2?",
                 actual_output: "4",
                 expected_output: "4",
                 metrics_data: [%Result{metric: "Exact Match", success: true}],
                 classifications: []
               },
               %TestResult{name: "wrong", index: 1, success: false}
             ] = results
    end

    test "writes the test run", %{tmp_dir: dir} do
      capture_log(fn ->
        assert {:ok, %EvaluationResult{}} =
                 DeepEvalEx.evaluate(test_cases(), [ExactMatch], results_folder: dir)
      end)

      assert [path] = written(dir)
      assert File.read!(path) =~ ~s("testPassed": 1, "testFailed": 1)
    end

    test "returns no test results for no test cases" do
      assert {:ok, %EvaluationResult{test_results: []}} = DeepEvalEx.evaluate([], [ExactMatch])
    end

    test "raises like deepeval when no metric has a threshold" do
      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate(test_cases(), [ScoreOnlyMetric])
      end
    end

    test "writes only the .deepeval snapshots without a results folder", %{tmp_dir: dir} do
      without_cache_folder_config(fn ->
        File.cd!(dir, fn ->
          assert {:ok, %EvaluationResult{}} = DeepEvalEx.evaluate(test_cases(), [ExactMatch])
        end)
      end)

      assert File.ls!(dir) == [".deepeval"]

      assert dir |> Path.join(".deepeval") |> File.ls!() |> Enum.sort() ==
               [".latest_run_full.json", ".latest_test_run.json"]
    end
  end

  describe "latest-run snapshots" do
    setup %{tmp_dir: dir} do
      previous = Application.fetch_env(:deep_eval_ex, :cache_folder)
      previous_fs = System.get_env("DEEPEVAL_FILE_SYSTEM")
      cache = Path.join(dir, "cache")
      Application.put_env(:deep_eval_ex, :cache_folder, cache)

      on_exit(fn ->
        restore_cache_folder(previous)

        if previous_fs,
          do: System.put_env("DEEPEVAL_FILE_SYSTEM", previous_fs),
          else: System.delete_env("DEEPEVAL_FILE_SYSTEM")
      end)

      %{cache: cache}
    end

    test "overwrite .latest_run_full.json and .latest_test_run.json after every run",
         %{tmp_dir: dir, cache: cache} do
      {_results, _first, nil} = DeepEvalEx.evaluate_run(test_cases(), [ExactMatch])

      {{_results, test_run, path}, _log} =
        with_log(fn ->
          DeepEvalEx.evaluate_run(Enum.take(test_cases(), 1), [ExactMatch],
            results_folder: Path.join(dir, "out")
          )
        end)

      body = File.read!(path)
      assert body == test_run |> TestRun.to_map() |> TestRun.JSON.encode!()
      assert body =~ ~s("testPassed": 1, "testFailed": 0)
      assert File.read!(Path.join(cache, ".latest_run_full.json")) == body

      assert File.read!(Path.join(cache, ".latest_test_run.json")) ==
               ~s({"testRunData": ) <> body <> "}"
    end

    test "are not written with DEEPEVAL_FILE_SYSTEM=READ_ONLY; the results folder still is",
         %{tmp_dir: dir, cache: cache} do
      System.put_env("DEEPEVAL_FILE_SYSTEM", "READ_ONLY")
      out = Path.join(dir, "out")

      capture_log(fn ->
        assert {_results, _test_run, path} =
                 DeepEvalEx.evaluate_run(test_cases(), [ExactMatch], results_folder: out)

        assert [^path] = written(out)
      end)

      refute File.exists?(cache)
    end

    test "raise before evaluating on an invalid DEEPEVAL_FILE_SYSTEM" do
      System.put_env("DEEPEVAL_FILE_SYSTEM", "nope")

      assert_raise ArgumentError, ~r/DEEPEVAL_FILE_SYSTEM must be READ_ONLY/, fn ->
        DeepEvalEx.evaluate_run([TestCase.new!(input: "x")], [OptsMetric], test_pid: self())
      end

      refute_received {:opts, _}
    end

    test "are not written for a run without test cases", %{cache: cache} do
      assert {[], %TestRun{}, nil} = DeepEvalEx.evaluate_run([], [ExactMatch])
      refute File.exists?(cache)
    end

    test "log a warning, and the evaluation still succeeds, when they cannot be written",
         %{tmp_dir: dir, cache: cache} do
      File.write!(cache, "")

      {{results, _test_run, path}, log} =
        with_log(fn ->
          DeepEvalEx.evaluate_run(test_cases(), [ExactMatch],
            results_folder: Path.join(dir, "out")
          )
        end)

      assert [[%Result{success: true}], [%Result{success: false}]] = results
      assert [^path] = written(Path.join(dir, "out"))

      assert log =~
               "failed to write rolling snapshot to #{Path.join(cache, ".latest_run_full.json")}"

      assert log =~ "failed to write #{Path.join(cache, ".latest_test_run.json")}"
    end
  end

  defp without_cache_folder_config(fun) do
    previous = Application.fetch_env(:deep_eval_ex, :cache_folder)
    Application.delete_env(:deep_eval_ex, :cache_folder)

    try do
      fun.()
    after
      restore_cache_folder(previous)
    end
  end

  defp restore_cache_folder({:ok, value}),
    do: Application.put_env(:deep_eval_ex, :cache_folder, value)

  defp restore_cache_folder(:error), do: Application.delete_env(:deep_eval_ex, :cache_folder)

  describe "deprecated result shapes" do
    test "evaluate/3 with a single test case still returns {:ok, results}, with a warning",
         %{tmp_dir: dir} do
      [test_case | _] = test_cases()

      warning =
        capture_io(:stderr, fn ->
          capture_log(fn ->
            assert {:ok, [%Result{success: true}]} =
                     DeepEvalEx.evaluate(test_case, [ExactMatch], results_folder: dir)
          end)
        end)

      assert warning =~ "Passing a single test case to DeepEvalEx.evaluate/3 is deprecated"
      assert [path] = written(dir)
      assert File.read!(path) =~ ~s("testPassed": 1, "testFailed": 0)
    end

    test "evaluate_batch/3 still returns the result lists, with a warning", %{tmp_dir: dir} do
      warning =
        capture_io(:stderr, fn ->
          capture_log(fn ->
            assert [[%Result{success: true}], [%Result{success: false}]] =
                     DeepEvalEx.evaluate_batch(test_cases(), [ExactMatch], results_folder: dir)
          end)
        end)

      assert warning =~ "DeepEvalEx.evaluate_batch/3 is deprecated"
      assert [_path] = written(dir)
    end

    test "still raise like deepeval when no metric has a threshold" do
      capture_io(:stderr, fn ->
        assert_raise ArgumentError, @no_threshold_message, fn ->
          DeepEvalEx.evaluate(hd(test_cases()), [ScoreOnlyMetric])
        end

        assert_raise ArgumentError, @no_threshold_message, fn ->
          DeepEvalEx.evaluate_batch(test_cases(), [ScoreOnlyMetric])
        end
      end)
    end
  end

  describe "moduledoc" do
    setup do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(DeepEvalEx)
      {:ok, modules} = :application.get_key(:deep_eval_ex, :modules)
      %{moduledoc: moduledoc, modules: modules}
    end

    test "lists every shipped metric", %{moduledoc: moduledoc, modules: modules} do
      metrics =
        for module <- modules,
            match?(["DeepEvalEx", "Metrics", _], Module.split(module)),
            # Shared helpers such as DeepEvalEx.Metrics.QAG are not metrics
            DeepEvalEx.Metrics.BaseMetric in Keyword.get(
              module.module_info(:attributes),
              :behaviour,
              []
            ),
            # Nor is the private expectation evaluator, which users never build
            not match?({:docs_v1, _, _, _, :hidden, _, _}, Code.fetch_docs(module)),
            do: module

      assert DeepEvalEx.Metrics.ToolCorrectness in metrics

      for metric <- metrics do
        assert moduledoc =~ "`#{inspect(metric)}`", "#{inspect(metric)} missing from moduledoc"
      end
    end

    test "lists every bundled LLM adapter", %{moduledoc: moduledoc, modules: modules} do
      adapters =
        for module <- modules,
            match?(["DeepEvalEx", "LLM", "Adapters", _], Module.split(module)),
            do: module

      assert DeepEvalEx.LLM.Adapters.Mock in adapters

      for adapter <- adapters do
        assert moduledoc =~ "`#{inspect(adapter)}`", "#{inspect(adapter)} missing from moduledoc"
      end
    end

    test "configures default_model as a {provider, model} tuple", %{moduledoc: moduledoc} do
      refute moduledoc =~ "default_model: :openai,"
      assert moduledoc =~ ~s(default_model: {:openai, "gpt-4o-mini"})
    end
  end
end
