# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/test_run.py (TestRunManager.update_test_run,
# wrap_up_test_run and TestRun.construct_metrics_scores's valid scores)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.TestRun.Manager do
  @moduledoc """
  Collects evaluated test cases into a test run and wraps the run up, as
  deepeval 4.3.1's `TestRunManager`.

  `new/1` and `add/2` are a pure fold over evaluated test cases (deepeval's
  `create_test_run` and `update_test_run`), so any runner can build a run;
  `to_test_run/1` finalizes it. `wrap_up/2` ports `wrap_up_test_run`
  without Confident AI, in deepeval's order:

  1. `No test cases found, please try again.` for a run without test
     cases, which is then neither saved nor wrapped up;
  2. the all-errored warning when no metric recorded a score with a
     verdict (`valid_scores/1`);
  3. the cache wrap-up (`DeepEvalEx.TestRun.Cache.Store.wrap_up/1`);
  4. with `display_table: true`, the `Test Results` table
     (`DeepEvalEx.Report.ResultsTable`);
  5. the hyperparameters or prompts warning;
  6. the local store: `.latest_run_full.json`, the results folder's
     `test_run_<timestamp>.json` and `.latest_test_run.json` (see
     `DeepEvalEx.TestRun.LocalStore`);
  7. the completion summary (`DeepEvalEx.Report.Summary`).

  `DeepEvalEx.evaluate_run/3` wraps up its runs with it, without the table.
  """

  require Logger

  alias DeepEvalEx.Report.{ResultsTable, Summary, Terminal}
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.Cache.Store
  alias DeepEvalEx.TestRun.{ConversationalTestCase, LocalStore}
  alias DeepEvalEx.TestRun.TestCase, as: ApiTestCase

  @typedoc """
  A test run being collected: its evaluated test cases (most recent first)
  and the run's settings.
  """
  @type collected :: %{
          optional(:prompts) => [TestRun.raw()] | nil,
          cases: [ApiTestCase.t() | ConversationalTestCase.t()],
          hyperparameters: keyword() | map() | [{String.t(), String.t()}] | nil,
          identifier: String.t() | nil,
          test_file: String.t() | nil
        }

  @doc """
  An empty run, deepeval's `create_test_run`.

  ## Options

  - `:identifier` - Name for the run
  - `:test_file` - The test file or folder the run came from
  - `:hyperparameters` - The run's hyperparameters, see
    `DeepEvalEx.TestRun.process_hyperparameters/1`
  - `:prompts` - The run's prompts: `[]` (the default) as `evaluate()`
    writes them, `nil` as `deepeval test run`, which never sets them
  """
  @spec new(keyword()) :: collected()
  def new(opts \\ []) do
    %{
      cases: [],
      hyperparameters: Keyword.get(opts, :hyperparameters),
      identifier: Keyword.get(opts, :identifier),
      test_file: Keyword.get(opts, :test_file),
      prompts: Keyword.get(opts, :prompts, [])
    }
  end

  @doc """
  Adds an evaluated test case to the run, deepeval's `update_test_run`.

  A test case without metric data or a trace (classifiers only) is left
  out, as deepeval leaves classifier-only results out of the run.
  """
  @spec add(collected(), ApiTestCase.t() | ConversationalTestCase.t()) :: collected()
  def add(collected, %ConversationalTestCase{metrics_data: []}), do: collected
  def add(collected, %ApiTestCase{metrics_data: [], trace: nil}), do: collected
  def add(collected, test_case), do: %{collected | cases: [test_case | collected.cases]}

  @doc """
  The collected run as a `DeepEvalEx.TestRun`, its test cases sorted and
  counted (see `DeepEvalEx.TestRun.from_test_cases/2`).
  """
  @spec to_test_run(collected()) :: TestRun.t()
  def to_test_run(collected) do
    collected.cases
    |> Enum.reverse()
    |> TestRun.from_test_cases(
      identifier: collected.identifier,
      test_file: collected.test_file,
      hyperparameters: collected.hyperparameters,
      prompts: Map.get(collected, :prompts, [])
    )
  end

  @doc """
  The number of metric results with both a score and a verdict, the count
  deepeval's `construct_metrics_scores` returns. The expectation
  evaluator's result, exported as a test case's `expectationsData`, counts
  too. Score-only results have no verdict, so a run of them counts `0`.
  """
  @spec valid_scores(TestRun.t()) :: non_neg_integer()
  def valid_scores(%TestRun{} = test_run) do
    for test_case <- test_run.test_cases ++ test_run.conversational_test_cases, reduce: 0 do
      count ->
        metrics =
          Enum.count(test_case.metrics_data, &(not is_nil(&1.score) and not is_nil(&1.success)))

        count + metrics + expectations_score(test_case.expectations_data)
    end
  end

  # The expectationsData is a map or a Jason.OrderedObject.
  defp expectations_score(nil), do: 0

  defp expectations_score(data) do
    if is_nil(data["score"]) or is_nil(data["success"]), do: 0, else: 1
  end

  @doc """
  Wraps up a run, as deepeval's `wrap_up_test_run` (see the module
  documentation), printing as it goes. Takes a collected run (see `new/1`)
  or a `DeepEvalEx.TestRun`.

  Returns `{test_run, path}`: the run and the `test_run_<timestamp>.json`
  file written to the results folder, or `nil`.

  ## Options

  - `:run_duration` - Seconds the run took, set as the run's
    `runDuration` (default: the run's)
  - `:display_table` - Print the `Test Results` table (default: `true`)
  - `:display` - The test cases the table shows: `:all` (default),
    `:failing` or `:passing`
  - `:cache` - The run's `DeepEvalEx.TestRun.Cache.Store`, wrapped up
  - `:print` - Print anything at all (default: `true`)
  - `:device` - Where to print (default: `:stdio`)
  - `:width`, `:color` - See `DeepEvalEx.Report.Terminal`
  - `:results_folder`, `:results_subfolder`, `:cache_folder`, `:read_only` -
    See `DeepEvalEx.TestRun.LocalStore`
  """
  @spec wrap_up(collected() | TestRun.t(), keyword()) :: {TestRun.t(), Path.t() | nil}
  def wrap_up(run, opts \\ [])

  def wrap_up(%TestRun{test_cases: [], conversational_test_cases: []} = test_run, opts) do
    say("No test cases found, please try again.", opts)
    {test_run, nil}
  end

  def wrap_up(%TestRun{} = test_run, opts) do
    if valid_scores(test_run) == 0, do: say(Summary.all_errored_warning(), opts)

    run_duration = Keyword.get(opts, :run_duration, test_run.run_duration)
    test_run = %{test_run | run_duration: run_duration / 1}

    if cache = opts[:cache], do: Store.wrap_up(cache)

    if Keyword.get(opts, :display_table, true) and print?(opts) do
      table = ResultsTable.build(test_run, Keyword.get(opts, :display, :all))
      IO.write(device(opts), Terminal.render(table, opts))
    end

    say(Summary.hyperparameters_warning(test_run), opts)

    warn_on_error(LocalStore.write_rolling(test_run, opts), "write rolling snapshot to")
    path = save_to_results_folder(test_run, opts)
    warn_on_error(LocalStore.write_latest(test_run, opts), "write")

    say(Summary.completed(test_run, run_duration, opts), opts)
    {test_run, path}
  end

  def wrap_up(%{cases: _} = collected, opts), do: collected |> to_test_run() |> wrap_up(opts)

  defp say(text, opts) do
    if print?(opts), do: IO.write(device(opts), [Terminal.render_text(text, opts), "\n"])
  end

  defp print?(opts), do: Keyword.get(opts, :print, true)
  defp device(opts), do: Keyword.get(opts, :device, :stdio)

  defp warn_on_error({:error, {path, reason}}, action) do
    Logger.warning("DeepEvalEx failed to #{action} #{path}: #{inspect(reason)}")
  end

  defp warn_on_error(_ok_or_skip, _action), do: :ok

  defp save_to_results_folder(test_run, opts) do
    case LocalStore.write(test_run, opts) do
      {:ok, path} ->
        Logger.info("Test run saved at #{path}")
        path

      :skip ->
        nil

      {:error, reason} ->
        Logger.warning("DeepEvalEx failed to save test run: #{inspect(reason)}")
        nil
    end
  end
end
