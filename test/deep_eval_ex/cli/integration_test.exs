# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.CLI.IntegrationTest do
  # Not async: each test runs `mix` in the fixture project, which builds into
  # one folder.
  use ExUnit.Case, async: false

  @moduletag :cli
  @moduletag :tmp_dir
  # The first run compiles the fixture project and its dependencies.
  @moduletag timeout: 600_000

  # `deepeval test run` over test/fixtures/deepeval/cli/test_runner.py, per
  # scenario and run: argv, exit code, skipped-test lines, the saved run and
  # the cache file.
  @fixtures "test/fixtures/deepeval/cli"
  @project Path.expand("../../fixtures/projects/runner", __DIR__)
  @test_file "test/runner_eval.exs"

  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&File.exists?(Path.join([@fixtures, &1, "input.json"])))
             |> Enum.sort()

  setup_all do
    {output, status} = mix(["compile"], [])
    assert status == 0, output
    :ok
  end

  for scenario <- @scenarios do
    @scenario scenario
    test "mix deep_eval.test runs as deepeval test run: #{scenario}", %{tmp_dir: dir} do
      %{"runs" => runs} = read_json(Path.join([@fixtures, @scenario, "input.json"]), [])

      for {_args, index} <- Enum.with_index(runs) do
        deepeval = Path.join([@fixtures, @scenario, "run#{index}"])

        %{"argv" => [_py_file | args], "exit_code" => exit_code, "skipped" => skipped} =
          read_json(Path.join(deepeval, "run.json"), [])

        {output, status} =
          mix(
            ["deep_eval.test", @test_file | args] ++ ["--color", "no", "--", "--seed", "0"],
            [{"DEEPEVAL_CACHE_FOLDER", dir}]
          )

        assert status != 0 == (exit_code != 0), output

        assert normalize(read_json(Path.join(dir, ".latest_test_run.json"))) ==
                 deepeval |> Path.join("latest_test_run.json") |> read_json() |> normalize()

        assert File.read!(Path.join(dir, ".deepeval-cache.json")) ==
                 File.read!(Path.join(deepeval, "cache.json"))

        for line <- skipped do
          [_line, test] = Regex.run(~r/^Test test_runner\.py::(\S+) was skipped/, line)

          assert output =~
                   "Test #{@test_file}::#{exunit_name(test)} was skipped. Reason: not ready"
        end

        assert output =~ "Test Results"
        refute output =~ "Running teardown with pytest sessionfinish"

        if "-w" in args,
          do:
            assert(output =~ "Flaky test case failed (no assertion raised): Metrics: Exact Match")
      end
    end
  end

  # deepeval passes --color=yes to pytest, but its report is Rich's, which
  # draws 80 columns wide and without colour when no terminal is attached
  # and COLUMNS is unset (System.cmd's output is a pipe).
  test "mix deep_eval.test prints the report without colour when no terminal is attached",
       %{tmp_dir: dir} do
    {output, _status} =
      mix(
        ["deep_eval.test", @test_file, "--", "--seed", "0"],
        [{"DEEPEVAL_CACHE_FOLDER", dir}] ++
          Enum.map(~w(COLUMNS LINES FORCE_COLOR TTY_COMPATIBLE NO_COLOR), &{&1, nil})
      )

    [_exunit, report] = String.split(output, "Test Results", parts: 2)
    refute report =~ "\e["
    assert [top | _] = report |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "┏"))
    assert String.length(top) == 80
  end

  test "mix deep_eval.test rejects a path that does not exist", %{tmp_dir: dir} do
    {output, status} =
      mix(["deep_eval.test", "test/missing_test.exs"], [{"DEEPEVAL_CACHE_FOLDER", dir}])

    assert status != 0
    assert output =~ "Provided path is neither a valid file nor a directory."
  end

  defp mix(args, env) do
    System.cmd("mix", args,
      cd: @project,
      env: [{"MIX_ENV", "test"} | env],
      stderr_to_stdout: true
    )
  end

  defp read_json(path, opts \\ [objects: :ordered_objects]),
    do: path |> File.read!() |> Jason.decode!(opts)

  # Only the times differ; the test path is each runner's own, and an
  # unnamed test case is named after its test (`test_unnamed`, `test unnamed`).
  defp normalize(%Jason.OrderedObject{values: values}) do
    values
    |> Enum.map(fn
      {"runDuration", _seconds} -> {"runDuration", 0}
      {"testFile", _path} -> {"testFile", @test_file}
      {"name", "test_" <> _ = name} -> {"name", exunit_name(name)}
      {"name", name} -> {"name", name}
      {key, value} -> {key, normalize(value)}
    end)
    |> then(&%Jason.OrderedObject{values: &1})
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  # pytest's `test_unnamed[1-2]` is ExUnit's `test unnamed[1-2]`.
  defp exunit_name("test_" <> rest) do
    [name | repeat] = String.split(rest, "[", parts: 2)
    Enum.join(["test " <> String.replace(name, "_", " ") | repeat], "[")
  end
end
