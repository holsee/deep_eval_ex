# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/evaluate/console_report.py
# (EvaluationConsoleReport.export_to_markdown)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Report.Markdown do
  @moduledoc """
  The evaluation report as Markdown, deepeval 4.3.1's
  `EvaluationConsoleReport.export_to_markdown`, byte for byte.

  Unlike the console report (`DeepEvalEx.Report.Console`), it shows every
  test case in full, sorted the same way: a `## ✅ PASS - name` heading
  (`❌ FAIL`, or `➖ NONE` without a verdict), the test case's data in a
  `<details>` block, its `Metrics` and `Classifiers` tables (statuses ✅,
  ❌, `⚠️ ERROR` and `➖ NONE`, line breaks in reasons as `<br>`), then the
  `Aggregate Metrics` and `Aggregate Classifiers` tables.

  `DeepEvalEx.evaluate_run/3` writes it with `:file_output_dir` (see
  `export/3`).
  """

  alias DeepEvalEx.{Report, TestResult}
  alias DeepEvalEx.Report.Console

  @doc """
  The Markdown report of `test_results`.
  """
  @spec render([TestResult.t()]) :: String.t()
  def render(test_results) do
    results = Console.sort(test_results)

    ["# 🚀 DeepEval Evaluation Results\n"]
    |> Kernel.++(Enum.flat_map(results, &case_lines/1))
    |> Kernel.++(metric_aggregates(results))
    |> Kernel.++(classifier_aggregates(results))
    |> Enum.join("\n")
  end

  @doc """
  Writes the Markdown report of `test_results` to
  `<output_dir>/<name>_<YYYYMMDD_HHMMSS>.md` (local time), creating
  `output_dir`, and returns the file's path.

  `<name>` is `evaluation_name` lowercased with spaces as underscores, or
  `evaluation` without one, as deepeval names it.
  """
  @spec export([TestResult.t()], Path.t(), String.t() | nil) :: Path.t()
  def export(test_results, output_dir, evaluation_name \\ nil) do
    File.mkdir_p!(output_dir)

    name =
      case Report.presence(evaluation_name) do
        nil -> "evaluation"
        name -> name |> String.replace(" ", "_") |> String.downcase()
      end

    {{year, month, day}, {hour, minute, second}} = :calendar.local_time()

    timestamp =
      :io_lib.format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B", [
        year,
        month,
        day,
        hour,
        minute,
        second
      ])

    path = Path.join(output_dir, "#{name}_#{timestamp}.md")
    File.write!(path, render(test_results))
    path
  end

  defp case_lines(result) do
    status =
      case result.success do
        nil -> "➖ NONE"
        true -> "✅ PASS"
        false -> "❌ FAIL"
      end

    [
      "## #{status} - #{result.name}\n",
      "<details><summary><b>View Test Case Data</b></summary>\n"
    ] ++
      case_data(result) ++
      ["\n</details>\n"] ++
      metrics_table(Console.metrics_data(result)) ++
      classifiers_table(result.classifications) ++
      ["\n---\n"]
  end

  defp case_data(%TestResult{conversational: true} = result) do
    Enum.map(result.turns || [], fn turn ->
      "- **#{Console.capitalize(turn.role)}**: #{turn.content}"
    end)
  end

  defp case_data(result) do
    [
      "- **Input:** #{Report.py_str(result.input)}",
      "- **Actual Output:** #{Report.py_str(result.actual_output)}"
    ] ++
      if Console.show_expected?(result.expected_output),
        do: ["- **Expected Output:** #{result.expected_output}"],
        else: []
  end

  defp metrics_table([]), do: []

  defp metrics_table(metrics) do
    [
      "\n### Metrics\n",
      "| Status | Metric | Score | Threshold | Reason |",
      "|:---:|:---|:---:|:---:|:---|"
    ] ++
      Enum.map(metrics, fn m ->
        "| #{Console.metric_icon(m)} | **#{m.name}** | #{Console.fixed_or_na(m.score)} | " <>
          "#{Console.fixed_or_na(m.threshold)} | #{reason(m)} |"
      end)
  end

  defp classifiers_table([]), do: []

  defp classifiers_table(classifications) do
    [
      "\n### Classifiers\n",
      "| Status | Classifier | Label | Expected | Reason |",
      "|:---:|:---|:---:|:---:|:---|"
    ] ++
      Enum.map(classifications, fn c ->
        "| #{Console.classification_icon(c)} | **#{c.name}** | #{Console.classification_label(c)} | " <>
          "#{Console.expected_label(c)} | #{reason(c)} |"
      end)
  end

  defp reason(row), do: row |> Console.reason_text() |> String.replace("\n", " <br> ")

  defp metric_aggregates(results) do
    case Console.metric_aggregates(results) do
      [] ->
        []

      aggregates ->
        [
          "## Aggregate Metrics\n",
          "| Metric | Average Score | Pass Rate | Total |",
          "|:---|:---:|:---:|:---:|"
        ] ++
          Enum.map(aggregates, fn {name, agg} ->
            "| **#{name}** | #{Console.average_score(agg)} | #{Console.pass_rate(agg)} | #{agg.total} |"
          end) ++ ["\n---\n"]
    end
  end

  defp classifier_aggregates(results) do
    case Console.classifier_aggregates(results) do
      [] ->
        []

      aggregates ->
        [
          "## Aggregate Classifiers\n",
          "| Classifier | Labels | Pass Rate | Errors | Total |",
          "|:---|:---|:---:|:---:|:---:|"
        ] ++
          Enum.map(aggregates, fn {name, agg} ->
            "| **#{name}** | #{Console.label_distribution(agg.labels)} | " <>
              "#{Console.classifier_pass_rate(agg)} | #{agg.errors} | #{agg.total} |"
          end) ++ ["\n---\n"]
    end
  end
end
