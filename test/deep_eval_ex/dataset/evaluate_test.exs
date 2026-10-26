defmodule DeepEvalEx.Dataset.EvaluateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.{EvaluationResult, Result, TestCase, TestResult, TestRun}
  alias DeepEvalEx.Metrics.ExactMatch

  @moduletag :tmp_dir

  defmodule CountingMetric do
    @moduledoc false

    def metric_name, do: "Counting"

    def measure(test_case, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:measured, test_case.input})
      {:ok, Result.new(metric: metric_name(), score: 1.0)}
    end
  end

  defp dataset(opts \\ []) do
    EvaluationDataset.new(
      [
        Golden.new!(input: "2 + 2?", expected_output: "4"),
        Golden.new!(input: "3 + 3?", expected_output: "6", name: "sixes")
      ],
      opts
    )
  end

  # The application under test: right about 2 + 2, wrong about 3 + 3.
  defp app(%Golden{input: "2 + 2?"}), do: "4"
  defp app(%Golden{input: "3 + 3?"}), do: "7"

  describe "evaluate/4" do
    test "runs the task over each golden and evaluates the test cases it builds" do
      assert {:ok, %EvaluationResult{test_results: [four, sixes]}} =
               EvaluationDataset.evaluate(dataset(), &app/1, [ExactMatch])

      assert %TestResult{
               name: "test_case_0",
               input: "2 + 2?",
               actual_output: "4",
               expected_output: "4",
               success: true
             } = four

      assert %TestResult{name: "sixes", actual_output: "7", success: false} = sixes
    end

    test "raises ArgumentError on a dataset without goldens, before running the task" do
      assert_raise ArgumentError, "Unable to evaluate dataset with no goldens.", fn ->
        EvaluationDataset.evaluate(EvaluationDataset.new(), fn _ -> flunk("ran") end, [
          ExactMatch
        ])
      end
    end
  end

  describe "evaluate_run/4" do
    test "returns the test cases, results, test run and path" do
      assert {[%TestCase{} = four, %TestCase{} = sixes],
              [[%Result{success: true}], [%Result{success: false}]], %TestRun{} = test_run, nil} =
               EvaluationDataset.evaluate_run(dataset(), &app/1, [ExactMatch])

      assert {four.input, four.actual_output, four.dataset_rank} == {"2 + 2?", "4", 0}
      assert {sixes.name, sixes.actual_output, sixes.dataset_rank} == {"sixes", "7", 1}
      assert {test_run.test_passed, test_run.test_failed} == {1, 1}
    end

    test "builds each test case from its golden" do
      golden =
        Golden.new!(
          input: "q",
          expected_output: "a",
          context: ["c"],
          retrieval_context: ["r"],
          additional_metadata: %{"k" => "v"},
          comments: "note",
          name: "named"
        )

      {[test_case], _results, _test_run, nil} =
        EvaluationDataset.evaluate_run(
          EvaluationDataset.new([golden]),
          fn given ->
            assert given == golden
            "a"
          end,
          [CountingMetric],
          test_pid: self()
        )

      assert test_case == %{Golden.to_test_case(golden) | actual_output: "a", dataset_rank: 0}
    end

    test "takes the task's string, nil, map, keyword list or test case" do
      dataset =
        EvaluationDataset.new(
          Enum.map(~w(string nil map keyword test_case), &Golden.new!(input: &1))
        )

      task = fn
        %Golden{input: "string"} -> "out"
        %Golden{input: "nil"} -> nil
        %Golden{input: "map"} -> %{actual_output: "out", retrieval_context: ["r"]}
        %Golden{input: "keyword"} -> [actual_output: "out", completion_time: 1.5]
        %Golden{input: "test_case"} -> TestCase.new!(input: "replaced", actual_output: "out")
      end

      {test_cases, _results, _test_run, nil} =
        EvaluationDataset.evaluate_run(dataset, task, [CountingMetric], test_pid: self())

      assert [
               %TestCase{input: "string", actual_output: "out", dataset_rank: 0},
               %TestCase{input: "nil", actual_output: nil, dataset_rank: 1},
               %TestCase{input: "map", actual_output: "out", retrieval_context: ["r"]},
               %TestCase{input: "keyword", actual_output: "out", completion_time: 1.5},
               %TestCase{input: "replaced", actual_output: "out", dataset_rank: 4}
             ] = test_cases
    end

    test "raises ArgumentError for any other task result" do
      assert_raise ArgumentError, ~r/must return/, fn ->
        EvaluationDataset.evaluate_run(dataset(), fn _ -> 42 end, [CountingMetric],
          test_pid: self()
        )
      end

      refute_received {:measured, _}
    end

    test "re-raises the task's exception for the first golden in order, evaluating nothing" do
      task = fn
        %Golden{input: "2 + 2?"} ->
          Process.sleep(50)
          raise "first"

        %Golden{} ->
          raise "second"
      end

      assert_raise RuntimeError, "first", fn ->
        EvaluationDataset.evaluate_run(dataset(), task, [CountingMetric], test_pid: self())
      end

      refute_received {:measured, _}
    end

    test "runs the task with up to :max_concurrent goldens at once" do
      goldens = Enum.map(1..6, &Golden.new!(input: "#{&1}"))
      dataset = EvaluationDataset.new(goldens)

      assert peak_concurrency(dataset, max_concurrent: 2) == 2
      assert peak_concurrency(dataset, max_concurrent: 6) == 6
      assert peak_concurrency(dataset, run_async: false) == 1
    end

    test "validates the run before running the task" do
      never = fn _ -> flunk("ran") end

      assert_raise ArgumentError, "'max_concurrent' must be at least 1", fn ->
        EvaluationDataset.evaluate_run(dataset(), never, [ExactMatch], max_concurrent: 0)
      end

      assert_raise ArgumentError, ~r/at least one non-flaky metric/, fn ->
        EvaluationDataset.evaluate_run(dataset(), never, [ExactMatch], threshold: nil)
      end

      assert_raise ArgumentError, fn ->
        EvaluationDataset.evaluate_run(dataset(), never, [ExactMatch],
          hyperparameters: [model: {:openai, "gpt-4o"}]
        )
      end
    end

    test "writes the run with the dataset's alias, id and version", %{tmp_dir: dir} do
      {{_test_cases, _results, test_run, path}, _log} =
        with_log(fn ->
          EvaluationDataset.evaluate_run(
            dataset(alias: "arithmetic", id: "ds-1", version: "v2"),
            &app/1,
            [ExactMatch],
            results_folder: dir,
            identifier: "nightly",
            hyperparameters: [model: "gpt-4o"]
          )
        end)

      assert {test_run.dataset_alias, test_run.dataset_id, test_run.dataset_version} ==
               {"arithmetic", "ds-1", "v2"}

      assert test_run.identifier == "nightly"
      assert test_run.hyperparameters == [{"model", "gpt-4o"}]

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order}) == [
               {"test_case_0", 0},
               {"sixes", 1}
             ]

      json = File.read!(path)
      assert json =~ ~s("datasetAlias": "arithmetic", "datasetId": "ds-1", "datasetVersion": "v2")
    end

    test "leaves the dataset keys null for a dataset without them" do
      {_test_cases, _results, test_run, nil} =
        EvaluationDataset.evaluate_run(dataset(), &app/1, [ExactMatch])

      assert {test_run.dataset_alias, test_run.dataset_id, test_run.dataset_version} ==
               {nil, nil, nil}
    end
  end

  # The most task calls seen running at once.
  defp peak_concurrency(dataset, opts) do
    counts = :atomics.new(2, [])

    task = fn _golden ->
      running = :atomics.add_get(counts, 1, 1)
      raise_peak(counts, running)
      Process.sleep(30)
      :atomics.sub(counts, 1, 1)
      "out"
    end

    EvaluationDataset.evaluate_run(dataset, task, [CountingMetric], [test_pid: self()] ++ opts)
    :atomics.get(counts, 2)
  end

  defp raise_peak(counts, running) do
    peak = :atomics.get(counts, 2)

    if running > peak and :atomics.compare_exchange(counts, 2, peak, running) != :ok,
      do: raise_peak(counts, running)
  end
end
