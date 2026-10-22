defmodule DeepEvalExTest do
  # Not async: some tests set the DEEPEVAL_RESULTS_FOLDER environment variable.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.{Result, TestCase, TestRun}

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
        hyperparameters: [k: 1]
      )

      assert_received {:opts, opts}
      assert opts[:test_pid] == self()

      for key <- [:results_folder, :results_subfolder, :identifier, :hyperparameters] do
        refute Keyword.has_key?(opts, key)
      end
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

  describe "evaluate_batch/3" do
    test "still returns the result lists and writes the test run", %{tmp_dir: dir} do
      capture_log(fn ->
        assert [[%Result{success: true}], [%Result{success: false}]] =
                 DeepEvalEx.evaluate_batch(test_cases(), [ExactMatch], results_folder: dir)
      end)

      assert [_path] = written(dir)
    end
  end

  describe "evaluate/3" do
    test "still returns {:ok, results} and writes the test run", %{tmp_dir: dir} do
      [test_case | _] = test_cases()

      capture_log(fn ->
        assert {:ok, [%Result{success: true}]} =
                 DeepEvalEx.evaluate(test_case, [ExactMatch], results_folder: dir)
      end)

      assert [path] = written(dir)
      assert File.read!(path) =~ ~s("testPassed": 1, "testFailed": 0)
    end

    test "raises like deepeval when no metric has a threshold" do
      [test_case | _] = test_cases()

      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate(test_case, [ScoreOnlyMetric])
      end

      assert_raise ArgumentError, @no_threshold_message, fn ->
        DeepEvalEx.evaluate_batch(test_cases(), [ScoreOnlyMetric])
      end
    end

    test "writes nothing without a results folder", %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        assert {:ok, [_]} = DeepEvalEx.evaluate(hd(test_cases()), [ExactMatch])
      end)

      assert File.ls!(dir) == []
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
