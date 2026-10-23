defmodule DeepEvalEx.Report.ReportParityTest do
  @moduledoc """
  Checks DeepEvalEx's console report against what deepeval 4.3.1 printed,
  from the fixtures of `test/fixtures/deepeval/report/` (written by
  `scripts/parity/generate_runner_fixtures.py`, see the fixtures' README).
  For each scenario, the same test results and test run must give:

  - `sections.json` - the panels, trees and tables of
    `EvaluationConsoleReport`, every string as deepeval hands it to Rich
  - `report.md` - `export_to_markdown`, byte for byte
  - `tables.json` - what `display_results_table` printed
  - `summary.txt` - what `wrap_up_test_run` printed, byte for byte
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{Classification, Report, TestResult, TestRun}
  alias DeepEvalEx.Report.{Console, Markdown, Panel, ResultsTable, Summary, Table, Tree}
  alias DeepEvalEx.Schemas.ToolCall

  @moduletag :parity

  @fixtures Path.expand("../../fixtures/deepeval/report", __DIR__)
  @scenarios @fixtures |> File.ls!() |> Enum.sort()

  for scenario <- @scenarios,
      file <- ~w(input.json sections.json report.md tables.json summary.txt) do
    @external_resource Path.join([@fixtures, scenario, file])
  end

  test "covers every scenario" do
    assert length(@scenarios) >= 15
  end

  for scenario <- @scenarios do
    describe scenario do
      @describetag scenario: scenario

      test "Console.build/2 hands Rich deepeval's strings", %{scenario: scenario} do
        input = read_json(scenario, "input.json")

        sections =
          input
          |> test_results()
          |> Console.build(
            display: String.to_existing_atom(input["display"]),
            truncate_passing_cases: input["truncate"]
          )
          |> Enum.map(&to_fixture/1)

        assert sections == read_json(scenario, "sections.json")
      end

      test "Markdown.render/1 is export_to_markdown", %{scenario: scenario} do
        input = read_json(scenario, "input.json")

        assert Markdown.render(test_results(input)) ==
                 File.read!(Path.join([@fixtures, scenario, "report.md"]))
      end

      test "ResultsTable.build/2 prints display_results_table's tables", %{scenario: scenario} do
        input = read_json(scenario, "input.json")
        {:ok, test_run} = TestRun.load(Path.join([@fixtures, scenario, "test_run.json"]))

        printed =
          test_run
          |> ResultsTable.build(String.to_existing_atom(input["display"]))
          |> Enum.map(&to_fixture/1)

        assert printed == read_json(scenario, "tables.json")
      end

      test "Summary.wrap_up/3 is wrap_up_test_run's text", %{scenario: scenario} do
        input = read_json(scenario, "input.json")
        {:ok, test_run} = TestRun.load(Path.join([@fixtures, scenario, "test_run.json"]))

        summary =
          test_run
          |> Summary.wrap_up(input["run_duration"], confident_ai: true)
          |> Enum.map_join(&(Report.plain(&1) <> "\n"))

        assert summary == File.read!(Path.join([@fixtures, scenario, "summary.txt"]))
      end
    end
  end

  defp read_json(scenario, file) do
    [@fixtures, scenario, file] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  # The fixture's shape of a renderable: Rich's objects as maps, every text
  # as its markup.
  defp to_fixture(%Panel{border_style: border, content: content}) do
    %{"panel" => %{"border_style" => border || "none", "content" => to_fixture(content)}}
  end

  defp to_fixture(%Tree{label: label, children: children}) do
    %{"tree" => %{"label" => to_fixture(label), "children" => Enum.map(children, &to_fixture/1)}}
  end

  defp to_fixture(%Table{} = table) do
    %{
      "table" => %{
        "title" => table.title && Report.markup(table.title),
        "columns" => Enum.map(table.columns, & &1.header),
        "rows" =>
          Enum.map(table.rows, fn
            {:confident_ai, cells} -> Enum.map(cells, &Report.markup/1)
            cells -> Enum.map(cells, &Report.markup/1)
          end)
      }
    }
  end

  defp to_fixture(text), do: Report.markup(text)

  # deepeval's TestResults as DeepEvalEx's, from the scenario.
  defp test_results(input) do
    Enum.map(input["test_results"], fn spec ->
      %TestResult{
        name: spec["name"],
        success: spec["success"],
        conversational: spec["conversational"] || false,
        index: spec["index"],
        input: spec["input"],
        actual_output: spec["actual_output"],
        expected_output: spec["expected_output"],
        turns: spec["turns"] && Enum.map(spec["turns"], &turn/1),
        metrics_data: Enum.map(spec["metrics_data"] || [], &result/1),
        classifications: Enum.map(spec["classifications"] || [], &classification/1)
      }
    end)
  end

  defp result(map) do
    {:ok, data} = TestRun.metric_data_from_map(map)
    TestRun.MetricData.to_result(data)
  end

  defp turn(map) do
    %TestRun.Turn{
      role: map["role"],
      content: map["content"],
      order: map["order"],
      user_id: map["userId"],
      retrieval_context: map["retrievalContext"],
      tools_called:
        map["toolsCalled"] && Enum.map(map["toolsCalled"], &%ToolCall{name: &1["name"]}),
      comments: map["comments"]
    }
  end

  defp classification(map) do
    %Classification{
      name: map["name"],
      label: map["label"],
      expected_label: map["expectedLabel"],
      success: map["success"],
      reason: map["reason"],
      evaluation_model: map["evaluationModel"],
      error: map["error"],
      evaluation_cost: map["evaluationCost"]
    }
  end
end
