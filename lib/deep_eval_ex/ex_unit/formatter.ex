# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/plugins/plugin.py (pytest_terminal_summary)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ExUnit.Formatter do
  @moduledoc """
  An ExUnit formatter that reports skipped tests to the run's
  `DeepEvalEx.ExUnit.Collector`, for the `Test <file>::<test> was skipped.
  Reason: <reason>` lines deepeval's pytest plugin prints after a
  `deepeval test run`.

  `mix deep_eval.test` adds it next to ExUnit's own formatter. It prints
  nothing and ignores every other event; tests excluded by `--only` or
  `--exclude` are not skipped tests, as pytest's deselected tests are not.
  """

  use GenServer

  alias DeepEvalEx.ExUnit.Collector

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:test_finished, %{state: {:skipped, reason}, name: name, tags: tags}}, state) do
    Collector.note_skipped(id(tags[:file], name), reason)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # pytest's node id: the file relative to the root, then the test.
  defp id(file, name) when is_binary(file), do: "#{Path.relative_to_cwd(file)}::#{name}"
  defp id(_file, name), do: to_string(name)
end
