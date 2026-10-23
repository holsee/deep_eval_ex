# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ExUnit.CollectorTest do
  # Not async: a run is VM-wide (a named collector and run overrides).
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.{Config, TestCase}
  alias DeepEvalEx.ExUnit.{Collector, Formatter}
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.TestRun.Cache
  alias DeepEvalEx.TestRun.Cache.Store
  alias DeepEvalEx.TestRun.MetricData
  alias DeepEvalEx.TestRun.TestCase, as: ApiTestCase

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(&Config.clear_run_overrides/0)
    %{cache: start_supervised!({Store, folder: dir, read_only: false})}
  end

  # A run as mix deep_eval.test starts it, with the calling test registered.
  defp start_run(context, opts \\ []) do
    Config.put_run_overrides(Keyword.merge([running: true], Keyword.get(opts, :overrides, [])))

    start_supervised!(
      {Collector, identifier: "nightly", test_file: "test/evals", cache: context.cache}
    )

    :ok = Collector.register(context)
  end

  defp api_case(name, metrics_data \\ [%MetricData{name: "M", score: 1.0, success: true}]),
    do: %ApiTestCase{name: name, metrics_data: metrics_data}

  defp exact(input, output, expected, fields \\ []),
    do: TestCase.new!([input: input, actual_output: output, expected_output: expected] ++ fields)

  describe "active?/0 (get_is_running_deepeval)" do
    test "needs both the :running setting and a live collector", context do
      refute Collector.active?()

      start_supervised!(Collector)
      refute Collector.active?()

      Config.put_run_overrides(running: true)
      assert Collector.active?()

      :ok = stop_supervised(Collector)
      refute Collector.active?()
      assert :ok = Collector.register(context)
    end
  end

  describe "lookup/0" do
    test "finds the test of the calling process, or of the process that started it", context do
      start_run(context)

      assert %{
               test:
                 "test lookup/0 finds the test of the calling process, or of the process " <> _
             } =
               Collector.lookup()

      name = Collector.test_name()
      assert Task.await(Task.async(fn -> Collector.test_name() end)) == name

      assert Task.await(Task.async(fn -> Task.await(Task.async(&Collector.test_name/0)) end)) ==
               name

      parent = self()
      spawn(fn -> send(parent, {:unrelated, Collector.test_name()}) end)
      assert_receive {:unrelated, nil}
    end

    test "is nil without a collector" do
      assert Collector.lookup() == nil
      assert Collector.test_name() == nil
    end
  end

  describe "record/1 and drain/0 (update_test_run)" do
    test "collect test cases in arrival order, leaving out classifier-only ones", context do
      start_run(context)

      1..100
      |> Enum.map(fn i -> Task.async(fn -> Collector.record(api_case("c#{i}")) end) end)
      |> Task.await_many()

      :ok = Collector.record(api_case("classifiers only", []))
      :ok = Collector.record(api_case("last"))

      drained = Collector.drain()
      assert length(drained.cases) == 101
      assert hd(drained.cases).name == "last"
      refute Enum.any?(drained.cases, &(&1.name == "classifiers only"))
      assert drained.identifier == "nightly"
      assert drained.test_file == "test/evals"
      assert drained.skipped == []
      assert drained.warnings == []
    end

    test "log_hyperparameters/1 sets the run's, and does nothing without a run", context do
      assert DeepEvalEx.ExUnit.log_hyperparameters(model: "gpt-4.1") == :ok

      start_run(context)
      DeepEvalEx.ExUnit.log_hyperparameters(%{"model" => "gpt-4.1", "temperature" => 0.5})

      assert Collector.drain().hyperparameters == [{"model", "gpt-4.1"}, {"temperature", "0.5"}]
      assert Collector.cache_hyperparameters() == %{"model" => "gpt-4.1", "temperature" => "0.5"}
    end
  end

  describe "assert_test/3 in a run" do
    test "records the test case, named after the test", context do
      start_run(context)

      assert_test(exact("2 + 2?", "4", "4"), [ExactMatch])
      assert_test(exact("Named?", "yes", "yes", name: "named"), [ExactMatch])

      %{cases: [named, unnamed]} = Collector.drain()

      assert unnamed.name ==
               "test assert_test/3 in a run records the test case, named after the test"

      assert unnamed.order == nil
      assert [%MetricData{name: "Exact Match", success: true}] = unnamed.metrics_data
      assert named.name == "named"
    end

    test "names a test case asserted from a Task after the test", context do
      start_run(context)

      Task.await(Task.async(fn -> assert_evaluation(exact("2 + 2?", "4", "4"), [ExactMatch]) end))

      assert [%{name: "test assert_test/3 in a run names a test case asserted from a Task" <> _}] =
               Collector.drain().cases
    end

    test "records a failing test case before failing", context do
      start_run(context)

      assert_raise ExUnit.AssertionError, fn ->
        assert_passes(exact("2 + 3?", "6", "5", name: "failing"), ExactMatch)
      end

      assert [%{name: "failing", success: false}] = Collector.drain().cases
    end

    test "keeps a failing flaky test case's warning for the run instead of printing it",
         context do
      start_run(context)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert_test(exact("3 + 3?", "7", "6", flaky: true), [ExactMatch])
        end)

      assert output == ""

      assert [{id, "Flaky test case failed (no assertion raised): Metrics: Exact Match" <> _}] =
               Collector.drain().warnings

      assert id ==
               "test/deep_eval_ex/ex_unit/collector_test.exs::test assert_test/3 in a run " <>
                 "keeps a failing flaky test case's warning for the run instead of printing it"
    end

    test "assert_fails/3 and assert_score/4 never record", context do
      start_run(context)

      assert_fails(exact("2 + 3?", "6", "5"), ExactMatch)
      assert_score(exact("2 + 2?", "4", "4"), ExactMatch, exact: 1.0)

      assert Collector.drain().cases == []
    end

    test "writes the run's cache, keyed with its hyperparameters", %{tmp_dir: dir} = context do
      start_run(context)
      DeepEvalEx.ExUnit.log_hyperparameters(%{"model" => "gpt-4.1"})
      test_case = exact("2 + 2?", "4", "4")

      assert_test(test_case, [ExactMatch])
      :ok = Store.wrap_up(context.cache)

      cached = dir |> Path.join(Cache.cache_file()) |> File.read!() |> Cache.decode()
      assert %{} = Cache.get(cached, Cache.key(test_case, %{"model" => "gpt-4.1"}))
    end

    test "reads the cache with use_cache", context do
      test_case = exact("2 + 2?", "4", "4")
      start_run(context, overrides: [use_cache: true])
      assert_test(test_case, [ExactMatch])
      :ok = Store.wrap_up(context.cache)
      :ok = stop_supervised(Collector)
      :ok = stop_supervised(Store)

      cache = start_supervised!({Store, folder: context.tmp_dir, read_only: false})
      start_run(%{context | cache: cache}, overrides: [use_cache: true])
      handler = attach_cache_hits()
      assert_test(test_case, [ExactMatch])

      assert_received {[:deep_eval_ex, :metric, :cache_hit], %{metric: "Exact Match"}}
      :telemetry.detach(handler)
      assert [%{metrics_data: [%{evaluation_cost: +0.0}]}] = Collector.drain().cases
    end
  end

  test "evaluate_run/3 in a run adds its test cases to the run and wraps nothing up", context do
    start_run(context)
    parent = self()
    handler = "collector-test-run-stop-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:deep_eval_ex, :test_run, :stop], &__MODULE__.forward/4, parent)

    {[[%{success: true}], [%{success: false}]], test_run, path} =
      DeepEvalEx.evaluate_run(
        [exact("2 + 2?", "4", "4"), exact("2 + 3?", "6", "5", name: "named")],
        [ExactMatch],
        hyperparameters: [model: "gpt-4.1"]
      )

    :telemetry.detach(handler)
    refute_received {[:deep_eval_ex, :test_run, :stop], _metadata}
    assert path == nil
    assert length(test_run.test_cases) == 2

    drained = Collector.drain()
    assert drained.hyperparameters == [{"model", "gpt-4.1"}]

    assert Enum.map(drained.cases, &{&1.name, &1.order}) |> Enum.reverse() == [
             {"test evaluate_run/3 in a run adds its test cases to the run and wraps nothing up",
              0},
             {"named", 1}
           ]
  end

  test "assertions record nothing outside a run" do
    assert Collector.active?() == false
    assert_test(exact("2 + 2?", "4", "4"), [ExactMatch])
  end

  describe "Formatter" do
    test "reports skipped tests only, as <file>::<test>", context do
      start_run(context)
      {:ok, formatter} = GenServer.start_link(Formatter, [])
      file = Path.join(File.cwd!(), "test/evals/refund_test.exs")

      skipped = %ExUnit.Test{
        name: :"test refund",
        tags: %{file: file},
        state: {:skipped, "not ready"}
      }

      GenServer.cast(formatter, {:test_started, skipped})
      GenServer.cast(formatter, {:test_finished, skipped})
      GenServer.cast(formatter, {:test_finished, %{skipped | state: {:excluded, "due to tag"}}})
      GenServer.cast(formatter, {:test_finished, %{skipped | state: nil}})
      GenServer.cast(formatter, {:suite_finished, %{}})
      GenServer.stop(formatter)

      assert Collector.drain().skipped == [
               {"test/evals/refund_test.exs::test refund", "not ready"}
             ]
    end
  end

  defp attach_cache_hits do
    parent = self()
    handler = "collector-test-cache-hit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:deep_eval_ex, :metric, :cache_hit],
      &__MODULE__.forward/4,
      parent
    )

    handler
  end

  def forward(event, _measurements, metadata, parent), do: send(parent, {event, metadata})
end
