defmodule DeepEvalEx.TestRun.ManagerTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.Cache.Store
  alias DeepEvalEx.TestRun.{ConversationalTestCase, Manager, MetricData}
  alias DeepEvalEx.TestRun.TestCase, as: ApiTestCase

  @moduletag :tmp_dir

  defp metric(name, score, opts \\ []) do
    struct!(
      %MetricData{name: name, score: score, threshold: 0.5, success: score && score >= 0.5},
      opts
    )
  end

  defp api_case(name, order, metrics) do
    %ApiTestCase{
      name: name,
      input: "#{name}?",
      order: order,
      metrics_data: metrics,
      success: not Enum.any?(metrics, &(&1.success == false))
    }
  end

  defp test_run(cases, opts \\ []), do: TestRun.from_test_cases(cases, opts)

  defp wrap_up(run, dir, opts \\ []) do
    {:ok, device} = StringIO.open("")

    result =
      Manager.wrap_up(
        run,
        [device: device, cache_folder: Path.join(dir, ".deepeval"), color: false, width: 100] ++
          opts
      )

    {:ok, {_input, output}} = StringIO.close(device)
    {result, output}
  end

  describe "new/1, add/2 and to_test_run/1 (deepeval's update_test_run)" do
    test "collect evaluated test cases in order into a sorted, counted run" do
      run =
        Manager.new(identifier: "nightly", test_file: "test/evals", hyperparameters: [k: 1])
        |> Manager.add(api_case("b", 1, [metric("M", 0.2)]))
        |> Manager.add(api_case("a", 0, [metric("M", 0.9)]))
        |> Manager.to_test_run()

      assert [%{name: "a"}, %{name: "b"}] = run.test_cases
      assert {run.test_passed, run.test_failed} == {1, 1}
      assert [%{metric: "M", scores: [0.2, 0.9]}] = run.metrics_scores
      assert run.identifier == "nightly"
      assert run.test_file == "test/evals"
      assert run.hyperparameters == [{"k", "1"}]
    end

    test "give test cases without an order (assert_test's) the next one, as deepeval" do
      run =
        Manager.new()
        |> Manager.add(api_case("first", nil, [metric("M", 0.9)]))
        |> Manager.add(api_case("ranked", 5, [metric("M", 0.9)]))
        |> Manager.add(api_case("second", nil, [metric("M", 0.2)]))
        |> Manager.to_test_run()

      assert Enum.map(run.test_cases, &{&1.name, &1.order}) ==
               [{"ranked", 5}, {"first", 6}, {"second", 7}]

      run =
        Manager.new()
        |> Manager.add(api_case("first", nil, [metric("M", 0.9)]))
        |> Manager.add(api_case("second", nil, [metric("M", 0.2)]))
        |> Manager.to_test_run()

      assert Enum.map(run.test_cases, &{&1.name, &1.order}) == [{"first", 0}, {"second", 1}]
    end

    test "leave out test cases without metric data, as classifier-only results" do
      collected =
        Manager.new()
        |> Manager.add(api_case("classified", 0, []))
        |> Manager.add(%ConversationalTestCase{name: "c", metrics_data: [], order: 0})

      assert collected.cases == []
    end
  end

  describe "valid_scores/1 (construct_metrics_scores)" do
    test "counts results with a score and a verdict, and the expectations' row" do
      run =
        test_run([
          %{
            api_case("a", 0, [metric("M", 0.9), metric("E", nil, error: "boom")])
            | expectations_data: %{"score" => 1.0, "success" => true}
          },
          api_case("b", 1, [metric("S", 0.3, threshold: nil, success: nil)])
        ])

      assert Manager.valid_scores(run) == 2
    end

    test "is 0 for score-only and errored runs" do
      run = test_run([api_case("a", 0, [metric("S", 0.3, threshold: nil, success: nil)])])
      assert Manager.valid_scores(run) == 0
    end
  end

  describe "wrap_up/2" do
    test "says so and saves nothing for a run without test cases", %{tmp_dir: dir} do
      {{run, nil}, output} = wrap_up(Manager.new(), dir)

      assert output == "No test cases found, please try again.\n"
      assert run.test_cases == []
      refute File.exists?(Path.join(dir, ".deepeval"))
    end

    test "prints deepeval's wrap-up in order and saves the run", %{tmp_dir: dir} do
      run = test_run([api_case("a", 0, [metric("M", 0.9)]), api_case("b", 1, [metric("M", 0.1)])])

      {{wrapped, path}, output} =
        wrap_up(run, dir, run_duration: 2.345, results_folder: Path.join(dir, "results"))

      assert wrapped.run_duration == 2.345
      assert path =~ ~r/test_run_\d{8}_\d{6}\.json\z/
      assert File.exists?(Path.join([dir, ".deepeval", ".latest_run_full.json"]))
      assert File.exists?(Path.join([dir, ".deepeval", ".latest_test_run.json"]))

      positions =
        Enum.map(
          [
            "┃ Test case",
            "⚠ WARNING: No hyperparameters logged.",
            "✓ Evaluation completed 🎉! (time taken: 2.35s"
          ],
          fn text ->
            assert {position, _length} = :binary.match(output, text)
            position
          end
        )

      assert positions == Enum.sort(positions)

      assert output =~ "» Pass Rate: 50.0% | Passed: 1 | Failed: 1"
      refute output =~ "Confident AI"
    end

    test "warns when every metric errored", %{tmp_dir: dir} do
      run = test_run([api_case("a", 0, [metric("M", nil, error: "boom", success: false)])])
      {_result, output} = wrap_up(run, dir, display_table: false)

      assert output =~ "⚠ WARNING: All metrics errored across every test case"
      refute output =~ "┃ Test case"
    end

    test "shows the table's :display selection", %{tmp_dir: dir} do
      run =
        test_run([
          api_case("kept", 0, [metric("M", 0.1)]),
          api_case("hidden", 1, [metric("M", 0.9)])
        ])

      {_result, output} = wrap_up(run, dir, display: :failing)

      assert output =~ "kept"
      refute output =~ "hidden"
    end

    test "prints nothing with print: false", %{tmp_dir: dir} do
      run = test_run([api_case("a", 0, [metric("M", 0.9)])])
      assert {{%TestRun{}, nil}, ""} = wrap_up(run, dir, print: false)
    end

    test "wraps up the run's cache store", %{tmp_dir: dir} do
      folder = Path.join(dir, ".deepeval")
      {:ok, store} = Store.start_link(write_cache: false, folder: folder)
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, ".deepeval-cache.json"), "{}")

      run = test_run([api_case("a", 0, [metric("M", 0.9)])])
      wrap_up(run, dir, cache: store, print: false)

      refute File.exists?(Path.join(folder, ".deepeval-cache.json"))
      Store.stop(store)
    end
  end
end
