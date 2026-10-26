# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/utils/verbose.py and deepeval/utils.py
# (prettify_list)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.Verbose do
  @moduledoc """
  A metric's verbose logs, as deepeval 4.3.1 builds and prints them.

  After measuring, each built-in metric describes its intermediate steps
  (truths, claims, statements, verdicts, evaluation steps, tools, ...) as a
  list of text steps, the last of which is the score and reason.
  `construct_verbose_logs/3` joins every step but the last into the
  result's `:verbose_logs`, which the test run export writes as
  `verboseLogs`, and prints all of them when the metric is in verbose mode.

  As in deepeval, verbose mode only controls printing: the logs are
  computed either way, except by `DeepEvalEx.Metrics.ExactMatch`, which
  like deepeval's only computes them in verbose mode.

  ## Verbose mode

  A metric is in verbose mode when its options have `verbose_mode: true`
  (`verbose_mode?/1`), as deepeval's `verbose_mode` constructor argument.
  `DeepEvalEx.ExUnit`'s assertions default it from the `:verbose_mode`
  setting (`config :deep_eval_ex, verbose_mode: true` or the
  `DEEPEVAL_VERBOSE_MODE` environment variable, see `DeepEvalEx.Config`),
  as deepeval's `assert_test` does.
  """

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.TestRun.JSON
  alias Jason.OrderedObject

  # Python's str.splitlines() line boundaries.
  @line_boundaries ~r/\r\n|[\n\r\x0b\x0c\x1c\x1d\x1e\x{85}\x{2028}\x{2029}]/u

  @doc """
  Joins every step but the last into the metric's verbose logs, as
  deepeval's `construct_verbose_logs`, and prints all of the steps with
  `print_verbose_logs/2` when `opts` are in verbose mode.

  Steps are separated by `" \\n \\n"`. The last step, the score and reason,
  is only printed.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.Verbose.construct_verbose_logs(
      ...>   "Faithfulness",
      ...>   ["Claims:\\n[]", "Verdicts:\\n[]", "Score: 1\\nReason: None"],
      ...>   []
      ...> )
      "Claims:\\n[] \\n \\nVerdicts:\\n[]"
  """
  @spec construct_verbose_logs(String.t(), [String.t(), ...], keyword()) :: String.t()
  def construct_verbose_logs(metric_name, steps, opts) do
    logs = steps |> Enum.drop(-1) |> Enum.join(" \n \n")

    if verbose_mode?(opts) do
      print_verbose_logs(metric_name, logs <> "\n \n" <> List.last(steps))
    end

    logs
  end

  @doc """
  Prints `logs` to standard output under a banner naming the metric, as
  deepeval's `print_verbose_logs`.
  """
  @spec print_verbose_logs(String.t(), String.t()) :: :ok
  def print_verbose_logs(metric_name, logs) do
    stars = String.duplicate("*", 50)

    IO.write([
      [stars, "\n", metric_name, " Verbose Logs\n", stars, "\n\n"],
      [logs, "\n\n"],
      [String.duplicate("=", 70), "\n"]
    ])
  end

  @doc """
  Formats a list one item per line, as deepeval's `prettify_list`.

  Strings are wrapped in double quotes as they are, without escaping, as
  deepeval's f-string does. Maps and `Jason.OrderedObject`s stand for
  deepeval's pydantic models: they are dumped as JSON indented by four
  spaces, non-ASCII characters escaped, in their key order (use an ordered
  object to keep deepeval's field order). Anything else prints as Python's
  `repr()`.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.Verbose.prettify_list(["Paris is in France."])
      "[\\n    \\"Paris is in France.\\"\\n]"

      iex> DeepEvalEx.Metrics.Utils.Verbose.prettify_list([])
      "[]"
  """
  @spec prettify_list(list()) :: String.t()
  def prettify_list([]), do: "[]"

  def prettify_list(list) do
    "[\n    " <> Enum.map_join(list, ",\n    ", &prettify_item/1) <> "\n]"
  end

  defp prettify_item(item) when is_binary(item), do: ~s("#{item}")

  defp prettify_item(%OrderedObject{} = item), do: model_dump(item)
  defp prettify_item(item) when is_map(item) and not is_struct(item), do: model_dump(item)

  defp prettify_item(item), do: Python.repr(item)

  defp model_dump(item), do: item |> JSON.encode!(indent: 4) |> String.replace("\n", "\n    ")

  @doc """
  deepeval's verdict models for QAG verdicts parsed by
  `DeepEvalEx.Metrics.QAG.parse_verdicts/2`: `verdict` and `reason`, in that
  order, followed by `extra` fields (ContextualRecall's `expected_output`),
  for `prettify_list/1`.

  ## Examples

      iex> [verdict] = DeepEvalEx.Metrics.Utils.Verbose.verdict_models([%{verdict: :yes, reason: nil}])
      iex> DeepEvalEx.Metrics.Utils.Verbose.prettify_list([verdict])
      "[\\n    {\\n        \\"verdict\\": \\"yes\\",\\n        \\"reason\\": null\\n    }\\n]"
  """
  @spec verdict_models([map()], keyword()) :: [OrderedObject.t()]
  def verdict_models(verdicts, extra \\ []) do
    Enum.map(verdicts, &OrderedObject.new([verdict: &1.verdict, reason: &1.reason] ++ extra))
  end

  @doc """
  Formats tool calls under a title, as deepeval's ToolCorrectness verbose
  steps do: each call's `repr()` indented by four spaces, between brackets
  on their own lines.
  """
  @spec format_tools(String.t(), [DeepEvalEx.Schemas.ToolCall.t()]) :: String.t()
  def format_tools(title, tool_calls) do
    "#{title}:\n[\n" <>
      Enum.map_join(tool_calls, ",\n", &(&1 |> Python.repr() |> indent())) <> "\n]"
  end

  # deepeval's indent_multiline_string: every line of str.splitlines()
  # prefixed with four spaces.
  defp indent(text) do
    text
    |> String.split(@line_boundaries)
    |> drop_trailing_empty()
    |> Enum.map_join("\n", &("    " <> &1))
  end

  defp drop_trailing_empty(lines) do
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  @doc """
  Formats `value` as a Python f-string does: `nil` as `None`, strings as
  they are and numbers like Python's `str()`.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.Verbose.to_str(nil)
      "None"

      iex> DeepEvalEx.Metrics.Utils.Verbose.to_str(1.0)
      "1.0"
  """
  @spec to_str(term()) :: String.t()
  def to_str(value) when is_binary(value), do: value
  def to_str(value), do: Python.repr(value)

  @doc """
  Whether `opts` put the metric in verbose mode: `:verbose_mode` is `true`
  (default: `false`).
  """
  @spec verbose_mode?(keyword()) :: boolean()
  def verbose_mode?(opts), do: Keyword.get(opts, :verbose_mode) == true
end
