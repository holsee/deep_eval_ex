defmodule DeepEvalEx.TestRun.LocalStoreTest do
  # Not async: some tests set DEEPEVAL_* environment variables, change the
  # working directory or override application config.
  use ExUnit.Case, async: false

  alias DeepEvalEx.{Result, TestCase, TestRun}
  alias DeepEvalEx.TestRun.{JSON, LocalStore}

  @moduletag :tmp_dir

  @now ~N[2026-10-22 09:23:59]

  setup do
    previous_cache = Application.fetch_env(:deep_eval_ex, :cache_folder)
    previous_fs = System.get_env("DEEPEVAL_FILE_SYSTEM")
    previous_cache_env = System.get_env("DEEPEVAL_CACHE_FOLDER")
    System.delete_env("DEEPEVAL_FILE_SYSTEM")
    System.delete_env("DEEPEVAL_CACHE_FOLDER")

    on_exit(fn ->
      restore_env("DEEPEVAL_FILE_SYSTEM", previous_fs)
      restore_env("DEEPEVAL_CACHE_FOLDER", previous_cache_env)

      case previous_cache do
        {:ok, value} -> Application.put_env(:deep_eval_ex, :cache_folder, value)
        :error -> Application.delete_env(:deep_eval_ex, :cache_folder)
      end
    end)

    previous = System.get_env("DEEPEVAL_RESULTS_FOLDER")
    previous_config = Application.fetch_env(:deep_eval_ex, :results_folder)
    System.delete_env("DEEPEVAL_RESULTS_FOLDER")
    Application.delete_env(:deep_eval_ex, :results_folder)

    on_exit(fn ->
      if previous,
        do: System.put_env("DEEPEVAL_RESULTS_FOLDER", previous),
        else: System.delete_env("DEEPEVAL_RESULTS_FOLDER")

      case previous_config do
        {:ok, value} -> Application.put_env(:deep_eval_ex, :results_folder, value)
        :error -> Application.delete_env(:deep_eval_ex, :results_folder)
      end
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

    test "prefers config :deep_eval_ex, :results_folder over DEEPEVAL_RESULTS_FOLDER" do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", "env-out")
      Application.put_env(:deep_eval_ex, :results_folder, "config-out")

      assert LocalStore.resolve_target_dir(nil, nil) == "config-out"
      assert LocalStore.resolve_target_dir("explicit", nil) == "explicit"
    end

    test "treats a blank DEEPEVAL_RESULTS_FOLDER as unset" do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", "  ")

      assert LocalStore.resolve_target_dir(nil, nil) == nil
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

  describe "write_rolling/2" do
    test "overwrites .deepeval/.latest_run_full.json in the working directory with the run",
         %{tmp_dir: dir, test_run: test_run} do
      Application.delete_env(:deep_eval_ex, :cache_folder)

      other =
        TestRun.from_results([%TestCase{input: "b"}], [[Result.new(metric: "M", score: 0.0)]])

      File.cd!(dir, fn ->
        assert {:ok, ".deepeval/.latest_run_full.json"} = LocalStore.write_rolling(other)
        assert {:ok, path} = LocalStore.write_rolling(test_run)

        assert File.read!(path) == test_run |> TestRun.to_map() |> JSON.encode!()
        assert File.ls!(".deepeval") == [".latest_run_full.json"]
      end)
    end

    test "writes to the cache folder: option, config, then DEEPEVAL_CACHE_FOLDER",
         %{tmp_dir: dir, test_run: test_run} do
      System.put_env("DEEPEVAL_CACHE_FOLDER", Path.join(dir, "env"))
      Application.delete_env(:deep_eval_ex, :cache_folder)
      assert {:ok, env_path} = LocalStore.write_rolling(test_run)
      assert env_path == Path.join([dir, "env", ".latest_run_full.json"])

      Application.put_env(:deep_eval_ex, :cache_folder, Path.join(dir, "config"))
      assert {:ok, config_path} = LocalStore.write_rolling(test_run)
      assert config_path == Path.join([dir, "config", ".latest_run_full.json"])

      assert {:ok, opt_path} = LocalStore.write_rolling(test_run, cache_folder: dir)
      assert opt_path == Path.join(dir, ".latest_run_full.json")
      assert File.exists?(opt_path)
    end

    test "writes nothing when DEEPEVAL_FILE_SYSTEM is READ_ONLY",
         %{tmp_dir: dir, test_run: test_run} do
      System.put_env("DEEPEVAL_FILE_SYSTEM", "READ_ONLY")

      assert LocalStore.write_rolling(test_run, cache_folder: dir) == :skip
      assert LocalStore.write_rolling(test_run, cache_folder: dir, read_only: true) == :skip
      assert File.ls!(dir) == []

      assert {:ok, _path} =
               LocalStore.write_rolling(test_run, cache_folder: dir, read_only: false)
    end

    test "returns an error when the cache folder is a file", %{tmp_dir: dir, test_run: test_run} do
      file = Path.join(dir, "taken")
      File.write!(file, "")

      path = Path.join(file, ".latest_run_full.json")
      assert {:error, {^path, _reason}} = LocalStore.write_rolling(test_run, cache_folder: file)
    end
  end

  describe "write_latest/2" do
    test "writes the run under testRunData in .deepeval/.latest_test_run.json",
         %{tmp_dir: dir, test_run: test_run} do
      Application.delete_env(:deep_eval_ex, :cache_folder)

      File.cd!(dir, fn ->
        assert {:ok, ".deepeval/.latest_test_run.json" = path} = LocalStore.write_latest(test_run)

        body = test_run |> TestRun.to_map() |> JSON.encode!()
        assert File.read!(path) == ~s({"testRunData": ) <> body <> "}"
        assert {:ok, %{"testRunData" => _}} = Jason.decode(File.read!(path))
      end)
    end

    test "overwrites the previous run", %{tmp_dir: dir, test_run: test_run} do
      other =
        TestRun.from_results([%TestCase{input: "b"}], [[Result.new(metric: "M", score: 0.0)]])

      assert {:ok, path} = LocalStore.write_latest(other, cache_folder: dir)
      assert {:ok, ^path} = LocalStore.write_latest(test_run, cache_folder: dir)
      assert File.read!(path) =~ ~s("input": "a")
      assert File.ls!(dir) == [".latest_test_run.json"]
    end

    test "writes nothing when read-only", %{tmp_dir: dir, test_run: test_run} do
      System.put_env("DEEPEVAL_FILE_SYSTEM", "ro")

      assert LocalStore.write_latest(test_run, cache_folder: dir) == :skip
      assert File.ls!(dir) == []
    end
  end

  defp restore_env(var, nil), do: System.delete_env(var)
  defp restore_env(var, value), do: System.put_env(var, value)
end
