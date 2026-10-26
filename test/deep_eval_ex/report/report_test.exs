defmodule DeepEvalEx.ReportTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{Report, Result, TestResult}
  alias DeepEvalEx.Report.Console

  doctest Report

  describe "Console.build/2" do
    test "rejects a display deepeval does not have" do
      assert_raise ArgumentError, ~r/display must be :all, :failing or :passing/, fn ->
        Console.build([], display: "failing")
      end
    end

    test "shows a test case without a verdict under :failing, not :passing" do
      result = %TestResult{name: "classified", success: nil, index: 0}

      assert [_header, %Report.Panel{border_style: "dim"}] =
               Console.build([result], display: :failing)

      # deepeval's "nothing to show" panel calls it failed.
      assert [_header, %Report.Panel{content: content}] =
               Console.build([result], display: :passing)

      assert Report.plain(content) =~ "All 1 test case failed — no passing test cases to display."
    end

    test "shows an errored result's error as its reason, without a score" do
      result = %TestResult{
        name: "t",
        success: false,
        index: 0,
        input: "q",
        actual_output: "a",
        metrics_data: [Result.error("Faithfulness", "boom", threshold: 0.5)]
      }

      [_header, %Report.Panel{content: tree} | _aggregates] = Console.build([result])
      [_data, %Report.Tree{label: %Report.Table{rows: [row]}}] = tree.children

      assert Enum.map(row, &Report.markup/1) ==
               ["[bold red]ERROR[/bold red]", "Faithfulness", "N/A", "0.50", "boom"]
    end
  end
end
