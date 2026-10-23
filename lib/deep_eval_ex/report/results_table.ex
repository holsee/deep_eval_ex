# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/test_run/test_run.py
# (TestRunManager.display_results_table and its helpers) and
# deepeval/utils.py (format_turn, shorten)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Report.ResultsTable do
  @moduledoc """
  The `Test Results` table deepeval's `deepeval test run` prints after a
  run, as data: a port of deepeval 4.3.1's
  `TestRunManager.display_results_table`.

  `build/2` returns what deepeval prints, in order: for each shown
  conversation, its turns table (`Conversation - <name>`, one row per turn
  with its details and tools, cut as deepeval's `format_turn` and
  `shorten` cut them) or a `No turns recorded for <name>.` line, then the
  `Test Results` table. Each shown test case has a header row with its
  success rate (`66.67% | passed=2 | failed=1`, with flaky sub-counts) and
  a row per metric with its rounded score, threshold, evaluation model,
  reason and error, and a PASSED, FAILED, ERRORED or NONE status. Empty
  rows separate test cases, with deepeval's quirks for conversations. The
  last row only advertises Confident AI, so it is tagged `:confident_ai`
  and not drawn (see `DeepEvalEx.Report.Table`).

  The expectation evaluator's row is not shown: deepeval's CLI reads the
  run back from disk, where it is `expectationsData`, not metric data.

  `DeepEvalEx.TestRun.Manager.wrap_up/2` prints it with `display_table:
  true`.
  """

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.{Report, TestRun}
  alias DeepEvalEx.Report.{Console, Table}

  # deepeval's len_tiny, len_short, len_medium and len_long defaults.
  @len_tiny 40
  @len_short 60
  @len_medium 120
  @len_long 240

  # Rich's console width in the turns table's column limits.
  @console_width 80

  @columns ["Test case", "Metric", "Score", "Status", "Overall Success Rate"]

  @doc """
  The tables and lines `display_results_table` prints for `test_run`,
  showing the test cases `display` selects (`:all`, `:failing` or
  `:passing`).
  """
  @spec build(TestRun.t(), Console.display()) :: [Table.t() | Report.text()]
  def build(%TestRun{} = test_run, display \\ :all) do
    display = Console.display!(display)
    last_case = length(test_run.test_cases) - 1
    last_conversation = length(test_run.conversational_test_cases) - 1

    case_rows =
      test_run.test_cases
      |> Enum.with_index()
      |> Enum.flat_map(fn {test_case, index} ->
        if Console.skip?(test_case, display),
          do: [],
          else: case_rows(test_case) ++ separator(index < last_case)
      end)

    {printed, conversation_rows} =
      test_run.conversational_test_cases
      |> Enum.with_index()
      |> Enum.reject(fn {test_case, _index} -> Console.skip?(test_case, display) end)
      |> Enum.map(fn {test_case, index} ->
        {turns_output(test_case),
         case_rows(test_case) ++
           separator(index < last_conversation) ++ separator(index < last_case)}
      end)
      |> Enum.unzip()

    note =
      {:confident_ai,
       [
         {:style, "bold red",
          "Note: Use Confident AI with DeepEval to analyze failed test cases for more details"},
         "",
         "",
         "",
         ""
       ]}

    table = %Table{
      title: "Test Results",
      columns: Enum.map(@columns, &%{header: &1}),
      rows: case_rows ++ Enum.concat(conversation_rows) ++ [note]
    }

    printed ++ [table]
  end

  @doc """
  The rows of the `Test Results` table `build/2` returns.
  """
  @spec rows(TestRun.t(), Console.display()) :: [Table.row()]
  def rows(%TestRun{} = test_run, display \\ :all) do
    %Table{rows: rows} = List.last(build(test_run, display))
    rows
  end

  defp separator(true), do: [["", "", "", "", ""]]
  defp separator(false), do: []

  defp case_rows(test_case) do
    {passes, fails, flaky_passes, flaky_fails} = count(test_case.metrics_data)

    rate =
      "#{success_rate(passes, fails)}% | passed=#{passes}#{flaky(flaky_passes)} | " <>
        "failed=#{fails}#{flaky(flaky_fails)}"

    [[test_case.name, "", "", "", rate] | Enum.map(test_case.metrics_data, &metric_row/1)]
  end

  defp flaky(0), do: ""
  defp flaky(count), do: " (flaky=#{count})"

  # _count_metric_results: metrics without a verdict are not counted.
  defp count(metrics_data) do
    Enum.reduce(metrics_data, {0, 0, 0, 0}, fn
      %{success: nil}, counts -> counts
      %{success: true, flaky: flaky}, {p, f, fp, ff} -> {p + 1, f, fp + bit(flaky), ff}
      %{success: false, flaky: flaky}, {p, f, fp, ff} -> {p, f + 1, fp, ff + bit(flaky)}
    end)
  end

  defp bit(true), do: 1
  defp bit(_flaky), do: 0

  # _calculate_success_rate
  defp success_rate(passes, fails) when passes + fails > 0,
    do: Report.float_str(Python.round(100 * passes / (passes + fails), 2))

  defp success_rate(_passes, _fails) do
    "Cannot display metrics for component-level evals, please run 'deepeval view' to see " <>
      "results on Confident AI."
  end

  defp metric_row(metric_data) do
    ["", metric_data.name, metric_score(metric_data), metric_status(metric_data), ""]
  end

  # _get_metric_status
  defp metric_status(metric_data) do
    cond do
      Report.presence(metric_data.error) -> {:style, "red", "ERRORED"}
      is_nil(metric_data.success) -> {:style, "dim", "NONE"}
      metric_data.success -> {:style, "green", "PASSED"}
      true -> {:style, "red", "FAILED"}
    end
  end

  # _format_metric_score
  defp metric_score(metric_data) do
    score =
      if is_nil(metric_data.score),
        do: "None",
        else: Report.float_str(Python.round(metric_data.score / 1, 2))

    threshold =
      if is_nil(metric_data.threshold), do: "None", else: Report.float_str(metric_data.threshold)

    "#{score} (threshold=#{threshold}, " <>
      "evaluation model=#{Report.presence(metric_data.evaluation_model) || "n/a"}, " <>
      "reason=#{Report.py_str(metric_data.reason)}, error=#{Report.py_str(metric_data.error)})"
  end

  defp turns_output(%{turns: [], name: name}),
    do: {:style, "dim", "No turns recorded for #{name}."}

  defp turns_output(%{turns: turns, name: name}) do
    rows =
      turns
      |> Enum.sort_by(& &1.order)
      |> Enum.map(fn turn ->
        tools = Enum.map_join(turn.tools_called || [], ", ", & &1.name)
        [Integer.to_string(turn.order), turn.role, format_turn(turn), shorten(tools, @len_short)]
      end)

    %Table{
      title: "Conversation - #{name}",
      header_style: "bold",
      columns: [
        %{header: "#", justify: :right, width: 3},
        %{header: "Role", width: 10},
        %{header: "Details", max_width: max(48, min(120, @console_width - 3 - 10 - 20))},
        %{
          header: "Tools",
          no_wrap: true,
          max_width: min(60, max(24, div(@console_width, 3)))
        }
      ],
      rows: rows
    }
  end

  @doc false
  # format_turn(turn, include_tools_in_header=False,
  # include_order_role_in_header=False) with deepeval's default lengths.
  @spec format_turn(TestRun.Turn.t()) :: String.t()
  def format_turn(turn) do
    indent = "      "
    first = shorten(turn.content, @len_long)

    first =
      case Report.presence(turn.user_id) do
        nil -> first
        user -> first <> "  | user: " <> shorten(user, @len_tiny)
      end

    contexts = turn.retrieval_context || []
    shown = Enum.take(contexts, 2)

    context_lines =
      shown
      |> Enum.with_index()
      |> Enum.map(fn {context, i} -> "#{indent}↳ ctx[#{i}]: #{shorten(context, @len_medium)}" end)

    hidden = length(contexts) - length(shown)
    hidden_lines = if hidden > 0, do: ["#{indent}↳ ctx: (+#{hidden} more)"], else: []

    comment_lines =
      case Report.presence(turn.comments) do
        nil -> []
        comments -> ["#{indent}↳ comment: #{shorten(comments, @len_medium)}"]
      end

    Enum.join([first | context_lines] ++ hidden_lines ++ comment_lines, "\n")
  end

  @doc false
  # deepeval's shorten(text, max_len) with its "..." suffix, by code point.
  @spec shorten(String.t() | nil, non_neg_integer()) :: String.t()
  def shorten(nil, _max_len), do: ""
  def shorten(_text, max_len) when max_len <= 0, do: ""

  def shorten(text, max_len) do
    if Report.py_len(text) <= max_len,
      do: text,
      else: Report.py_take(text, max_len - 3) <> "..."
  end
end
