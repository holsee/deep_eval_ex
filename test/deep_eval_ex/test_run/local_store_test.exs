defmodule DeepEvalEx.TestRun.LocalStoreTest do
  # Not async: some tests set the DEEPEVAL_RESULTS_FOLDER environment variable.
  use ExUnit.Case, async: false

  alias DeepEvalEx.{Result, TestCase, TestRun}
  alias DeepEvalEx.TestRun.{JSON, LocalStore}

  @moduletag :tmp_dir

  @now ~N[2026-10-22 09:23:59]

  setup do
    previous = System.get_env("DEEPEVAL_RESULTS_FOLDER")
    System.delete_env("DEEPEVAL_RESULTS_FOLDER")

    on_exit(fn ->
      if previous,
        do: System.put_env("DEEPEVAL_RESULTS_FOLDER", previous),
        else: System.delete_env("DEEPEVAL_RESULTS_FOLDER")
    end)

    test_run =
      TestRun.from_results(
        [%TestCase{input: "a"}],
        [[Result.new(metric: "M", score: 1.0)]],
        run_duration: 1.5
      )

    %{test_run: test_run}
  end

  describe "resolve_target_dir/2" do
    test "returns nil when no folder is configured" do
      assert LocalStore.resolve_target_dir(nil, nil) == nil
      assert LocalStore.resolve_target_dir("", "sub") == nil
    end

    test "uses the results folder, joined with the subfolder when given" do
      assert LocalStore.resolve_target_dir("out", nil) == "out"
      assert LocalStore.resolve_target_dir("out", "") == "out"
      assert LocalStore.resolve_target_dir("out", "run-a") == Path.join("out", "run-a")
    end

    test "falls back to DEEPEVAL_RESULTS_FOLDER" do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", "env-out")

      assert LocalStore.resolve_target_dir(nil, nil) == "env-out"
      assert LocalStore.resolve_target_dir(nil, "sub") == Path.join("env-out", "sub")
      assert LocalStore.resolve_target_dir("explicit", nil) == "explicit"
    end
  end

  describe "write/2" do
    test "writes test_run_<YYYYMMDD_HHMMSS>.json with the deepeval JSON encoding",
         %{tmp_dir: dir, test_run: test_run} do
      assert {:ok, path} = LocalStore.write(test_run, results_folder: dir, now: @now)

      assert path == Path.join(dir, "test_run_20261022_092359.json")
      assert File.read!(path) == test_run |> TestRun.to_map() |> JSON.encode!()
    end

    test "appends _2, _3, ... on a same-second collision", %{tmp_dir: dir, test_run: test_run} do
      paths =
        for _ <- 1..3 do
          {:ok, path} = LocalStore.write(test_run, results_folder: dir, now: @now)
          Path.basename(path)
        end

      assert paths == [
               "test_run_20261022_092359.json",
               "test_run_20261022_092359_2.json",
               "test_run_20261022_092359_3.json"
             ]
    end

    test "gives concurrent writers distinct files", %{tmp_dir: dir, test_run: test_run} do
      paths =
        1..10
        |> Task.async_stream(fn _ ->
          LocalStore.write(test_run, results_folder: dir, now: @now)
        end)
        |> Enum.map(fn {:ok, {:ok, path}} -> path end)

      assert paths |> Enum.uniq() |> length() == 10
    end

    test "creates the results subfolder", %{tmp_dir: dir, test_run: test_run} do
      assert {:ok, path} =
               LocalStore.write(test_run,
                 results_folder: dir,
                 results_subfolder: "nested/run",
                 now: @now
               )

      assert Path.dirname(path) == Path.join([dir, "nested", "run"])
      assert File.exists?(path)
    end

    test "falls back to DEEPEVAL_RESULTS_FOLDER", %{tmp_dir: dir, test_run: test_run} do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", dir)

      assert {:ok, path} = LocalStore.write(test_run, now: @now)
      assert Path.dirname(path) == dir
    end

    test "is skipped when no folder is configured", %{test_run: test_run} do
      assert LocalStore.write(test_run, now: @now) == :skip
    end

    test "returns an error when the target is a file", %{tmp_dir: dir, test_run: test_run} do
      file = Path.join(dir, "taken")
      File.write!(file, "")

      assert {:error, {:not_a_directory, ^file}} =
               LocalStore.write(test_run, results_folder: file)
    end

    test "defaults the timestamp to local time", %{tmp_dir: dir, test_run: test_run} do
      assert {:ok, path} = LocalStore.write(test_run, results_folder: dir)
      assert Path.basename(path) =~ ~r/\Atest_run_\d{8}_\d{6}\.json\z/
    end
  end
end
