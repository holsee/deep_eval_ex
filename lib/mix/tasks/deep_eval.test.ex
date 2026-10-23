# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/cli/test/command.py (run) and
# deepeval/plugins/plugin.py (pytest_terminal_summary)
# Original: https://github.com/confident-ai/deepeval

defmodule Mix.Tasks.DeepEval.Test do
  @shortdoc "Runs tests as one deepeval test run (deepeval test run)"

  @moduledoc """
  Runs ExUnit tests as one test run, deepeval 4.3.1's `deepeval test run`.

      mix deep_eval.test PATH[::TEST NAME | :LINE] [options] [-- mix test options]

  Every `assert_test/3` (and `assert_evaluation/3`, `assert_passes/3`) of
  the run's tests, and every `DeepEvalEx.evaluate_run/3` they call, adds its
  test case to the run (see "`mix deep_eval.test`" in `DeepEvalEx.ExUnit`).
  Once `mix test` is done, the task wraps the run up as `deepeval test run`
  does: the skipped tests, the `Test Results` table, the warnings and the
  summary are printed, and the run is saved (`.deepeval/.latest_test_run.json`,
  `.deepeval/.latest_run_full.json` and, with a results folder,
  `test_run_<timestamp>.json`) along with the test-run cache
  (`.deepeval/.deepeval-cache.json`). See `DeepEvalEx.TestRun.Manager.wrap_up/2`.

  The test modules must `use DeepEvalEx.ExUnit` after `use ExUnit.Case`.
  Hyperparameters are logged from `test/test_helper.exs` with
  `DeepEvalEx.ExUnit.log_hyperparameters/1`.

  The task runs in the test environment; add it to your project's preferred
  environments:

      def cli, do: [preferred_envs: ["deep_eval.test": :test]]

  ## Options

  `deepeval test run`'s, with the same meaning (see
  `DeepEvalEx.CLI.TestArgs`):

  - `-c`, `--use-cache` - Reuse cached results (not with `--repeat`)
  - `-i`, `--ignore-errors` - Record metric errors instead of raising them
  - `-s`, `--skip-on-missing-params` - Skip metrics whose test case lacks
    their params
  - `-v`, `--verbose` - Print each metric's verbose logs
  - `-d`, `--display all|failing|passing` - The test cases the table shows
  - `-id`, `--identifier NAME` - Name the run
  - `-r`, `--repeat N` - Run each test N times, as `<name>[i-N]`
  - `-n`, `--num-processes N` - Run up to N test modules at once
    (`--max-cases`)
  - `-x`, `--exit-on-first-failure` (`-X` to undo) - Stop at the first
    failure (`--max-failures 1`)
  - `-w`, `--show-warnings` (`-W` to undo) - Print the warnings of failing
    flaky test cases
  - `-m`, `--mark EXPR` - Run tests tagged `tag`, not tagged (`not tag`),
    or tagged with any of `a or b`
  - `--durations N` - Print the N slowest tests (default: 10; 0 for none)
  - `--color yes|no|auto` - Colour (default: `yes`)
  - `-o`, `--official` - Prints that it needs a Confident AI key, which
    DeepEvalEx never has
  - `--eval-mode llm|hybrid|system_one` - The run's eval mode (DeepEvalEx
    only; see `DeepEvalEx.SystemOne.Mode`)

  Other options, and everything after `--`, are passed to `mix test`.
  `--pdb` is not supported: run `iex -S mix deep_eval.test PATH -- --breakpoints`.

  The run's settings win over `config :deep_eval_ex` and the environment
  while it runs, as `deepeval test run`'s do (see "Run overrides" in
  `DeepEvalEx.Config`). Each run emits `[:deep_eval_ex, :test_run, :stop]`
  with `source: :cli` once wrapped up, deepeval's `on_test_run_end` hook
  (see `DeepEvalEx.Telemetry`).

  The exit status is `mix test`'s: non-zero when a test failed.

  ## Examples

      mix deep_eval.test test/evals -c -i -d failing --identifier nightly -n 8 -m rag
      mix deep_eval.test 'test/evals/refund_eval_test.exs::test refund policy answer' -r 3
      DEEPEVAL_EVAL_MODE=system_one mix deep_eval.test test/evals -c
      mix deep_eval.test test/evals -- --seed 0
  """

  use Mix.Task

  alias DeepEvalEx.CLI.TestArgs
  alias DeepEvalEx.Config
  alias DeepEvalEx.ExUnit.{Collector, Formatter}
  alias DeepEvalEx.TestRun.Cache
  alias DeepEvalEx.TestRun.Cache.Store
  alias DeepEvalEx.TestRun.Manager

  # deepeval's TEMP_FILE_PATH, deleted at the start of a run.
  @temp_test_run_file ".temp_test_run_data.json"

  @impl Mix.Task
  def run(argv) do
    unless Mix.env() == :test do
      Mix.raise(
        "mix deep_eval.test must run in the test environment: run it with MIX_ENV=test, " <>
          ~s(or add `def cli, do: [preferred_envs: ["deep_eval.test": :test]]` to mix.exs)
      )
    end

    args =
      try do
        TestArgs.parse!(argv)
      rescue
        error in ArgumentError -> Mix.raise(Exception.message(error))
      end

    delete_temp_files()
    check_if_valid_file!(args.path)
    Config.put_run_overrides(args.overrides)
    Enum.each(args.messages, &IO.puts/1)

    try do
      run_tests(args)
    after
      Config.clear_run_overrides()
    end
  end

  defp run_tests(args) do
    {:ok, cache} = Store.start_link(write_cache: true)

    {:ok, _collector} =
      Collector.start_link(
        identifier: Keyword.get(args.overrides, :identifier),
        test_file: args.path,
        cache: cache
      )

    try do
      started = System.monotonic_time()
      Mix.Task.run("test", with_formatter(args.mix_test_args))
      elapsed = System.monotonic_time() - started
      run_duration = System.convert_time_unit(elapsed, :native, :microsecond) / 1_000_000

      wrap_up(args, cache, elapsed, run_duration)
    after
      Collector.stop()
      Store.stop(cache)
    end
  end

  defp wrap_up(args, cache, elapsed, run_duration) do
    drained = Collector.drain()
    print_warnings(drained.warnings)
    print_skipped(drained.skipped)

    {test_run, path} =
      Manager.wrap_up(
        Map.drop(drained, [:skipped, :warnings]),
        [run_duration: run_duration, display_table: true, display: Config.get(:display)] ++
          [cache: cache] ++ color(args.color)
      )

    :telemetry.execute(
      [:deep_eval_ex, :test_run, :stop],
      %{duration: elapsed, test_passed: test_run.test_passed, test_failed: test_run.test_failed},
      %{test_run: test_run, path: path, identifier: test_run.identifier, source: :cli}
    )
  end

  defp color(nil), do: []
  defp color(color), do: [color: color]

  # pytest's warnings summary, shown with --show-warnings.
  defp print_warnings(warnings) do
    if Config.get(:show_warnings) and warnings != [] do
      IO.puts("\nWarnings:")
      Enum.each(warnings, &print_warning/1)
    end
  end

  defp print_warning({nil, message}), do: IO.puts("  #{message}")
  defp print_warning({id, message}), do: IO.puts("#{id}\n  #{message}")

  # deepeval's pytest_terminal_summary.
  defp print_skipped(skipped) do
    Enum.each(skipped, fn {id, reason} ->
      IO.puts("Test #{id} was skipped. Reason: #{reason}")
    end)
  end

  @doc false
  # ExUnit's own formatter, or the ones given, then ours.
  @spec with_formatter([String.t()]) :: [String.t()]
  def with_formatter(mix_test_args) do
    ours = ["--formatter", inspect(Formatter)]

    if "--formatter" in mix_test_args,
      do: mix_test_args ++ ours,
      else: mix_test_args ++ ["--formatter", inspect(ExUnit.CLIFormatter)] ++ ours
  end

  @doc false
  # command.py's check_if_valid_file, raised as a Mix error.
  @spec check_if_valid_file!(String.t()) :: :ok
  def check_if_valid_file!(path) do
    file = TestArgs.file_part(path)

    if File.regular?(file) or File.dir?(file),
      do: :ok,
      else: Mix.raise("Provided path is neither a valid file nor a directory.")
  end

  # deepeval deletes TEMP_FILE_PATH and TEMP_CACHE_FILE_NAME before a run.
  defp delete_temp_files do
    unless Config.read_only?() do
      folder = Config.get(:cache_folder)
      File.rm(Path.join(folder, @temp_test_run_file))
      File.rm(Path.join(folder, Cache.temp_cache_file()))
    end

    :ok
  end
end
