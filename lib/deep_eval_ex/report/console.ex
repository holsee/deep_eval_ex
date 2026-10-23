# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/evaluate/console_report.py (EvaluationConsoleReport)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Report.Console do
  @moduledoc """
  The evaluation report deepeval's `evaluate()` prints, as data: a port of
  deepeval 4.3.1's `EvaluationConsoleReport`.

  `build/2` returns the panels `_build_display_elements` hands to Rich, each
  string exactly deepeval's (see `DeepEvalEx.Report`):

  1. a `🚀 DeepEval Evaluation Results` header;
  2. a panel per shown test case, sorted by index, then naturally by name
     (`"case 2"` before `"case 10"`): a passing test case on one line when
     truncated (`✅ name (Passed 2 metrics, 1 classifications)`), else a
     tree of its input and outputs (or conversation turns), its `Metrics`
     table and its `Classifiers` table. Statuses are PASS, FAIL, ERROR and
     NONE (no verdict: a score-only metric or a classification without an
     expected label); scores and thresholds have two decimals; a passing
     row's reason over 50 characters is cut to 47 plus `"..."` when
     truncated;
  3. with `display: :failing` or `:passing` hiding every test case, a panel
     saying so (`✅ All 2 test cases passed — no failing test cases to
     display.`);
  4. `Aggregate Metrics` (average score, pass rate with flaky sub-counts,
     total) and `Aggregate Classifiers` (label distribution, pass rate over
     verdicts, errors, total) over every test case, shown or not.

  Draw it with `DeepEvalEx.Report.Terminal.render/2`.
  `DeepEvalEx.evaluate_run/3` prints it when `:print_results` is on.
  """

  alias DeepEvalEx.{Classification, Report, Result, TestResult}
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Report.{Panel, Table, Tree}
  alias DeepEvalEx.TestRun.MetricData

  @purple "rgb(106,0,255)"
  @green "rgb(25,227,160)"
  @red "red"

  # Shown when a classifier with `allow_none` declined to classify.
  @no_classification "none"

  @typedoc "Which test cases to show, deepeval's `TestRunResultDisplay`."
  @type display :: :all | :failing | :passing

  @doc """
  Builds the report of `test_results`.

  ## Options

  - `:display` - `:all` (default), `:failing` or `:passing`: the test cases
    shown; the aggregates always cover all of them
  - `:truncate_passing_cases` - Show passing test cases on one line and cut
    their passing rows' reasons (default: `true`)
  """
  @spec build([TestResult.t()], keyword()) :: [Panel.t()]
  def build(test_results, opts \\ []) do
    display = display!(Keyword.get(opts, :display, :all))
    truncate? = Keyword.get(opts, :truncate_passing_cases, true)
    results = sort(test_results)
    shown = Enum.reject(results, &skip?(&1, display))

    [%Panel{content: {:style, "#{@purple} bold", "🚀 DeepEval Evaluation Results"}}] ++
      Enum.map(shown, &case_panel(&1, truncate?)) ++
      nothing_shown(shown, results, display) ++
      metric_aggregates_panel(results) ++
      classifier_aggregates_panel(results)
  end

  @doc false
  @spec display!(term()) :: display()
  def display!(display) when display in [:all, :failing, :passing], do: display

  def display!(display) do
    raise ArgumentError,
          "display must be :all, :failing or :passing, got: #{inspect(display)}"
  end

  @doc false
  # EvaluationConsoleReport's sort: by index (none last), then naturally by
  # name.
  @spec sort([TestResult.t()]) :: [TestResult.t()]
  def sort(test_results) do
    Enum.sort_by(test_results, fn result ->
      {if(is_nil(result.index), do: {1, 0}, else: {0, result.index}), natural_key(result.name)}
    end)
  end

  defp natural_key(name) do
    ~r/(\d+)/
    |> Regex.split(name, include_captures: true)
    |> Enum.map(fn part ->
      if part =~ ~r/\A\d+\z/, do: String.to_integer(part), else: String.downcase(part)
    end)
  end

  @doc false
  # _should_skip_case: a test case without a verdict is neither passing nor
  # failing, so only :all and :failing show it.
  @spec skip?(%{:success => boolean() | nil, optional(atom()) => term()}, display()) ::
          boolean()
  def skip?(%{success: success}, :passing), do: success != true
  def skip?(%{success: success}, :failing), do: success == true
  def skip?(_case, :all), do: false

  defp case_panel(result, truncate?) do
    metrics = metrics_data(result)
    classifications = result.classifications
    {color, icon} = case_status(result.success)

    if truncate? and result.success == true do
      parts =
        if(metrics == [], do: [], else: ["Passed #{length(metrics)} metrics"]) ++
          if classifications == [],
            do: [],
            else: ["#{length(classifications)} classifications"]

      %Panel{
        content: {:style, "#{color} bold", "#{icon} #{result.name} (#{Enum.join(parts, ", ")})"},
        border_style: color
      }
    else
      children =
        [case_data(result)] ++
          metrics_tree(metrics, truncate?) ++ classifiers_tree(classifications, truncate?)

      %Panel{
        content: %Tree{
          label: {:style, "#{color} bold", "#{icon} #{result.name}"},
          children: children
        },
        border_style: color,
        padding: {1, 2}
      }
    end
  end

  defp case_status(nil), do: {"dim", "➖"}
  defp case_status(true), do: {@green, "✅"}
  defp case_status(false), do: {@red, "❌"}

  defp case_data(%TestResult{conversational: true} = result) do
    %Tree{
      label: {:style, "bold cyan", "Conversation Turns"},
      children:
        Enum.map(result.turns || [], fn turn ->
          %Tree{label: [{:style, "bold", "#{capitalize(turn.role)}:"}, " ", turn.content]}
        end)
    }
  end

  defp case_data(result) do
    rows =
      [
        ["Input:", Report.py_str(result.input)],
        ["Actual Output:", Report.py_str(result.actual_output)]
      ] ++
        if(show_expected?(result.expected_output),
          do: [["Expected Output:", Report.py_str(result.expected_output)]],
          else: []
        )

    %Tree{
      label: %Table{
        columns: [%{header: "Key", style: "bold cyan"}, %{header: "Value"}],
        rows: rows,
        show_header: false,
        box: :none,
        padding: 2
      }
    }
  end

  @doc false
  # `if case.expected_output and case.expected_output != "N/A"`
  @spec show_expected?(String.t() | nil) :: boolean()
  def show_expected?(expected), do: Report.presence(expected) not in [nil, "N/A"]

  @doc false
  # Python's str.capitalize().
  @spec capitalize(String.t()) :: String.t()
  def capitalize(string) do
    case String.next_codepoint(string) do
      {first, rest} -> String.upcase(first) <> String.downcase(rest)
      nil -> ""
    end
  end

  defp metrics_tree([], _truncate?), do: []

  defp metrics_tree(metrics, truncate?) do
    rows =
      Enum.map(metrics, fn m ->
        [
          metric_status(m),
          m.name,
          fixed_or_na(m.score),
          fixed_or_na(m.threshold),
          reason(m, truncate?)
        ]
      end)

    [%Tree{label: verdict_table("Metrics", ~w(Status Metric Score Threshold Reason), rows)}]
  end

  defp classifiers_tree([], _truncate?), do: []

  defp classifiers_tree(classifications, truncate?) do
    rows =
      Enum.map(classifications, fn c ->
        [
          classification_status(c),
          c.name,
          classification_label(c),
          expected_label(c),
          reason(c, truncate?)
        ]
      end)

    [
      %Tree{
        label: verdict_table("Classifiers", ~w(Status Classifier Label Expected Reason), rows)
      }
    ]
  end

  defp verdict_table(title, [status | headers], rows) do
    %Table{
      title: title,
      title_justify: :left,
      show_edge: false,
      header_style: "bold #{@purple}",
      expand: true,
      columns: [%{header: status, justify: :center} | Enum.map(headers, &%{header: &1})],
      rows: rows
    }
  end

  defp metric_status(%{error: error, success: success}) do
    cond do
      Report.presence(error) -> {:style, "bold red", "ERROR"}
      is_nil(success) -> {:style, "bold dim", "NONE"}
      success -> {:style, "bold green", "PASS"}
      true -> {:style, "bold red", "FAIL"}
    end
  end

  defp classification_status(%{error: error, success: success}) do
    cond do
      Report.presence(error) -> {:style, "bold red", "ERROR"}
      is_nil(success) -> {:style, "bold dim", "NONE"}
      success -> {:style, "bold green", "PASS"}
      true -> {:style, "bold red", "FAIL"}
    end
  end

  @doc false
  # _classification_status(c, rich=False), the Markdown export's.
  @spec classification_icon(Classification.t()) :: String.t()
  def classification_icon(classification) do
    classification |> classification_status() |> markdown_icon("✅", "❌")
  end

  @doc false
  # The Markdown export's metric status.
  @spec metric_icon(MetricData.t()) :: String.t()
  def metric_icon(metric), do: metric |> metric_status() |> markdown_icon("✅", "❌")

  defp markdown_icon({:style, _, "ERROR"}, _pass, _fail), do: "⚠️ ERROR"
  defp markdown_icon({:style, _, "NONE"}, _pass, _fail), do: "➖ NONE"
  defp markdown_icon({:style, _, "PASS"}, pass, _fail), do: pass
  defp markdown_icon({:style, _, "FAIL"}, _pass, fail), do: fail

  @doc false
  # _classification_label
  @spec classification_label(Classification.t()) :: String.t()
  def classification_label(%{label: label}) when is_binary(label), do: label

  def classification_label(%{error: error}) do
    if Report.presence(error), do: "N/A", else: @no_classification
  end

  @doc false
  @spec expected_label(Classification.t()) :: String.t()
  def expected_label(%{expected_label: nil}), do: "N/A"
  def expected_label(%{expected_label: label}), do: label

  # `str(m.reason or m.error or "N/A")`, cut to 47 characters plus "..." for
  # a passing row over 50 when truncating.
  defp reason(row, truncate?) do
    reason = reason_text(row)

    if truncate? and row.success == true and Report.py_len(reason) > 50,
      do: Report.py_take(reason, 47) <> "...",
      else: reason
  end

  @doc false
  @spec reason_text(MetricData.t() | Classification.t()) :: String.t()
  def reason_text(row), do: Report.presence(row.reason) || Report.presence(row.error) || "N/A"

  @doc false
  # f"{x:.2f}", or "N/A" for None.
  @spec fixed_or_na(number() | nil) :: String.t()
  def fixed_or_na(nil), do: "N/A"
  def fixed_or_na(number), do: Python.format_fixed(number, 2)

  @doc false
  # A test result's metric data as deepeval's MetricData: an errored result
  # has neither score nor reason.
  @spec metrics_data(TestResult.t()) :: [MetricData.t()]
  def metrics_data(%TestResult{metrics_data: metrics_data}) do
    Enum.map(metrics_data, fn
      %Result{} = result -> MetricData.from_result(result)
      %MetricData{} = data -> data
    end)
  end

  defp nothing_shown([], [_ | _] = results, :failing) do
    total = length(results)

    [
      %Panel{
        content:
          {:style, "#{@green} bold",
           "✅ All #{total} test case#{plural(total)} passed — no failing test cases to display."},
        border_style: @green
      }
    ]
  end

  defp nothing_shown([], [_ | _] = results, :passing) do
    total = length(results)

    [
      %Panel{
        content:
          {:style, "#{@red} bold",
           "❌ All #{total} test case#{plural(total)} failed — no passing test cases to display."},
        border_style: @red
      }
    ]
  end

  defp nothing_shown(_shown, _results, _display), do: []

  defp plural(1), do: ""
  defp plural(_total), do: "s"

  defp metric_aggregates_panel(results) do
    case metric_aggregates(results) do
      [] ->
        []

      aggregates ->
        rows =
          Enum.map(aggregates, fn {name, agg} ->
            [name, average_score(agg), pass_rate(agg), Integer.to_string(agg.total)]
          end)

        [
          %Panel{
            content:
              aggregate_table(
                "Aggregate Metrics",
                ["Metric", "Average Score", "Pass Rate", "Total"],
                rows
              ),
            border_style: @purple
          }
        ]
    end
  end

  defp classifier_aggregates_panel(results) do
    case classifier_aggregates(results) do
      [] ->
        []

      aggregates ->
        rows =
          Enum.map(aggregates, fn {name, agg} ->
            [
              name,
              label_distribution(agg.labels),
              classifier_pass_rate(agg),
              Integer.to_string(agg.errors),
              Integer.to_string(agg.total)
            ]
          end)

        [
          %Panel{
            content:
              aggregate_table(
                "Aggregate Classifiers",
                ["Classifier", "Labels", "Pass Rate", "Errors", "Total"],
                rows
              ),
            border_style: @purple
          }
        ]
    end
  end

  defp aggregate_table(title, headers, rows) do
    %Table{
      title: [{:style, "bold", title}, "\n"],
      title_justify: :left,
      show_edge: false,
      header_style: "bold #{@purple}",
      expand: true,
      columns: Enum.map(headers, &%{header: &1}),
      rows: rows
    }
  end

  @doc false
  # The metric aggregates, in order of first appearance: a metric without a
  # verdict counts towards the total only, a flaky one towards its verdict
  # and its flaky sub-count.
  @spec metric_aggregates([TestResult.t()]) :: [{String.t(), map()}]
  def metric_aggregates(results) do
    empty = %{
      total: 0,
      passes: 0,
      fails: 0,
      flaky_passes: 0,
      flaky_fails: 0,
      score_sum: 0,
      score_count: 0
    }

    results
    |> Enum.flat_map(&metrics_data/1)
    |> aggregate_by_name(empty, fn agg, m ->
      agg = %{agg | total: agg.total + 1}

      agg =
        case m.success do
          nil -> agg
          true -> %{agg | passes: agg.passes + 1, flaky_passes: agg.flaky_passes + flaky(m)}
          false -> %{agg | fails: agg.fails + 1, flaky_fails: agg.flaky_fails + flaky(m)}
        end

      if is_nil(m.score),
        do: agg,
        else: %{agg | score_sum: agg.score_sum + m.score, score_count: agg.score_count + 1}
    end)
  end

  defp flaky(%{flaky: true}), do: 1
  defp flaky(_metric), do: 0

  @doc false
  # _aggregate_classifications
  @spec classifier_aggregates([TestResult.t()]) :: [{String.t(), map()}]
  def classifier_aggregates(results) do
    empty = %{total: 0, passes: 0, fails: 0, errors: 0, labels: %{}}

    results
    |> Enum.flat_map(& &1.classifications)
    |> aggregate_by_name(empty, fn agg, c ->
      agg = %{agg | total: agg.total + 1}

      agg =
        if Report.presence(c.error),
          do: %{agg | errors: agg.errors + 1},
          else: %{agg | labels: Map.update(agg.labels, classification_label(c), 1, &(&1 + 1))}

      case c.success do
        true -> %{agg | passes: agg.passes + 1}
        false -> %{agg | fails: agg.fails + 1}
        nil -> agg
      end
    end)
  end

  defp aggregate_by_name(items, empty, fun) do
    {names, aggregates} =
      Enum.reduce(items, {[], %{}}, fn item, {names, aggregates} ->
        names = if Map.has_key?(aggregates, item.name), do: names, else: [item.name | names]
        {names, Map.put(aggregates, item.name, fun.(Map.get(aggregates, item.name, empty), item))}
      end)

    names |> Enum.reverse() |> Enum.map(&{&1, Map.fetch!(aggregates, &1)})
  end

  @doc false
  @spec average_score(map()) :: String.t()
  def average_score(%{score_count: 0}), do: "N/A"
  def average_score(agg), do: Python.format_fixed(agg.score_sum / agg.score_count, 2)

  @doc false
  # _format_pass_rate
  @spec pass_rate(map()) :: String.t()
  def pass_rate(agg) do
    verdicts = agg.passes + agg.fails
    rate = if verdicts > 0, do: percent(agg.passes, verdicts), else: "N/A"
    passed = "passed=#{agg.passes}" <> flaky_count(agg.flaky_passes)
    failed = "failed=#{agg.fails}" <> flaky_count(agg.flaky_fails)
    "#{rate} | #{passed} | #{failed}"
  end

  defp flaky_count(0), do: ""
  defp flaky_count(count), do: " (flaky=#{count})"

  defp percent(passes, verdicts), do: Python.format_fixed(passes / verdicts * 100, 2) <> "%"

  @doc false
  # _format_classifier_pass_rate
  @spec classifier_pass_rate(map()) :: String.t()
  def classifier_pass_rate(%{passes: 0, fails: 0}), do: "N/A"

  def classifier_pass_rate(agg) do
    "#{percent(agg.passes, agg.passes + agg.fails)} | passed=#{agg.passes} | failed=#{agg.fails}"
  end

  @doc false
  # _format_label_distribution: by count, most first, then by label.
  @spec label_distribution(%{String.t() => pos_integer()}) :: String.t()
  def label_distribution(labels) when map_size(labels) == 0, do: "N/A"

  def label_distribution(labels) do
    labels
    |> Enum.sort_by(fn {label, count} -> {-count, label} end)
    |> Enum.map_join(", ", fn {label, count} -> "#{label}=#{count}" end)
  end
end
