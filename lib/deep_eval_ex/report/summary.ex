# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/test_run.py (TestRunManager.wrap_up_test_run)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Report.Summary do
  @moduledoc """
  What deepeval 4.3.1's `wrap_up_test_run` prints around a finished run, as
  `t:DeepEvalEx.Report.text/0`, byte for byte:

  - `all_errored_warning/0`, when no metric recorded a score with a
    verdict (`DeepEvalEx.TestRun.Manager.valid_scores/1` is `0`);
  - `hyperparameters_warning/1`: `No hyperparameters logged.`, or `No
    prompts logged.` when hyperparameters but no prompts were logged, each
    with its 80-character `=` rule. The documentation links deepeval adds
    are Rich link markup, which a terminal shows as plain text, so they are
    left out;
  - `completed/3`: `✓ Evaluation completed 🎉! (time taken: 1.23s | token
    cost: 0.0012 USD)`, the number of tests and the pass rate.

  `wrap_up/3` returns them in deepeval's order. Each is one
  `console.print()`: print it followed by a newline.
  """

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.{Report, TestRun}
  alias DeepEvalEx.TestRun.Manager

  @rule String.duplicate("=", 80)

  @doc """
  The texts `wrap_up_test_run` prints for `test_run`, which took
  `run_duration` seconds, in order (without the `Test Results` table).

  ## Options

  - `:confident_ai` - Keep the closing lines advertising Confident AI's
    `deepeval view` (default: `false`, ADR-0010 decision 6)
  """
  @spec wrap_up(TestRun.t(), number(), keyword()) :: [Report.text()]
  def wrap_up(%TestRun{} = test_run, run_duration, opts \\ []) do
    errored = if Manager.valid_scores(test_run) == 0, do: [all_errored_warning()], else: []
    errored ++ [hyperparameters_warning(test_run), completed(test_run, run_duration, opts)]
  end

  @doc """
  The warning printed when every metric errored (or had no verdict).

  Its last sentence points at Confident AI's dashboard, and is kept for
  parity.
  """
  @spec all_errored_warning() :: Report.text()
  def all_errored_warning do
    [
      "\n",
      warning(),
      " All metrics errored across every test case — no metric scores were recorded. " <>
        "Posting the run anyway so you can inspect the trace + span errors on the " <>
        "Confident AI dashboard.\n"
    ]
  end

  @doc """
  The warning about the run's hyperparameters and prompts.
  """
  @spec hyperparameters_warning(TestRun.t()) :: Report.text()
  def hyperparameters_warning(%TestRun{hyperparameters: nil}) do
    [
      "\n",
      warning(),
      " No hyperparameters logged.\n» ",
      {:style, "bold blue", "Log hyperparameters"},
      " to attribute prompts and models to your test runs.\n\n" <> @rule
    ]
  end

  def hyperparameters_warning(%TestRun{prompts: prompts}) when prompts in [nil, []] do
    [
      "\n",
      warning(),
      " No prompts logged.\n» ",
      {:style, "bold blue", "Log prompts"},
      " to evaluate and optimize your prompt templates and models.\n\n" <> @rule
    ]
  end

  def hyperparameters_warning(%TestRun{}) do
    ["\n", {:style, "bold green", "✓ Prompts Logged"}, "\n"]
  end

  defp warning, do: {:style, "bold yellow", "⚠ WARNING:"}

  @doc """
  The summary closing the run: the time taken, the token cost, the number
  of tests and the pass rate.

  As in deepeval, a run without a cost (or a cost of 0) shows `None`. A run
  where no test case has a verdict, where deepeval divides by zero, shows a
  pass rate of `N/A`.

  ## Options

  - `:confident_ai` - Keep the closing lines advertising Confident AI's
    `deepeval view` (default: `false`)
  """
  @spec completed(TestRun.t(), number(), keyword()) :: Report.text()
  def completed(%TestRun{} = test_run, run_duration, opts \\ []) do
    passed = test_run.test_passed
    failed = test_run.test_failed
    total = passed + failed

    cost =
      if test_run.evaluation_cost in [nil, 0, +0.0],
        do: "None",
        else: "#{Report.float_str(test_run.evaluation_cost)} USD"

    rate = if total > 0, do: Report.float_str(Python.round(passed / total * 100, 2)), else: "N/A"
    time = Report.float_str(Python.round(run_duration / 1, 2))

    parts = [
      [
        "\n\n",
        {:style, "rgb(5,245,141)", "✓"},
        " Evaluation completed 🎉! (time taken: #{time}s | token cost: #{cost})\n" <>
          "» Test Results (#{total} total tests):\n"
      ],
      [
        "  » Pass Rate: #{rate}% | Passed: ",
        {:style, "bold green", Integer.to_string(passed)},
        " | Failed: ",
        {:style, "bold red", Integer.to_string(failed)},
        "\n\n"
      ],
      @rule
    ]

    confident_ai =
      if Keyword.get(opts, :confident_ai, false) do
        [
          [
            "\n\n» Want to share evals with your team, or a place for your test cases to live? " <>
              "❤️ 🏡\n  » Run ",
            {:style, "bold", "'deepeval view'"},
            " to analyze and save testing results on ",
            {:style, "rgb(106,0,255)", "Confident AI"},
            ".\n\n"
          ]
        ]
      else
        []
      end

    # console.print(*parts) joins its arguments with a space.
    Enum.intersperse(parts ++ confident_ai, " ")
  end
end
