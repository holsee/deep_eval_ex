defmodule DeepEvalEx.Dataset.SaveAsParityTest do
  @moduledoc """
  Builds the datasets scripts/parity/generate_dataset_fixtures.py saves
  with deepeval 4.3.1's `save_as` and compares what
  `DeepEvalEx.Dataset.EvaluationDataset.save_as/4` writes with deepeval's
  files under test/fixtures/deepeval/datasets.

  `save_as_edges` keeps every map's keys in sorted order, so the files must
  match byte for byte. `saved` has a tool call whose input parameters
  deepeval writes in insertion order (`query`, `limit`), which an Elixir map
  does not keep, so its files are compared once decoded; and each file
  DeepEvalEx writes must load back, with DeepEvalEx's loaders, as deepeval's
  own file does (loader_parity_test.exs checks those against deepeval's
  loaders).
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestCase

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fixtures Path.expand("../../fixtures/deepeval/datasets", __DIR__)

  @file_types [:csv, :json, :jsonl]

  @loaders %{
    csv: &EvaluationDataset.add_goldens_from_csv_file/2,
    json: &EvaluationDataset.add_goldens_from_json_file/2,
    jsonl: &EvaluationDataset.add_goldens_from_jsonl_file/2
  }

  describe "save_as_edges" do
    for file_type <- @file_types,
        {file_name, include_test_cases} <- [{"saved", true}, {"goldens", false}] do
      @file_type file_type
      @file_name file_name
      @include_test_cases include_test_cases

      test "#{file_name}.#{file_type} is deepeval's, byte for byte", %{tmp_dir: dir} do
        path =
          EvaluationDataset.save_as(edge_dataset(), @file_type, dir,
            file_name: @file_name,
            include_test_cases: @include_test_cases
          )

        assert path == Path.join(dir, "#{@file_name}.#{@file_type}")

        assert File.read!(path) ==
                 File.read!(Path.join([@fixtures, "save_as_edges", Path.basename(path)]))
      end
    end
  end

  describe "saved" do
    for file_type <- @file_types do
      @file_type file_type

      test "saved.#{file_type} decodes as deepeval's", %{tmp_dir: dir} do
        path =
          EvaluationDataset.save_as(saved_dataset(), @file_type, dir,
            file_name: "saved",
            include_test_cases: true
          )

        expected = Path.join([@fixtures, "saved", "saved.#{@file_type}"])
        assert decode(@file_type, File.read!(path)) == decode(@file_type, File.read!(expected))
      end

      test "saved.#{file_type} loads back as deepeval's", %{tmp_dir: dir} do
        path =
          EvaluationDataset.save_as(saved_dataset(), @file_type, dir,
            file_name: "saved",
            include_test_cases: true
          )

        load = Map.fetch!(@loaders, @file_type)
        expected = Path.join([@fixtures, "saved", "saved.#{@file_type}"])

        assert load.(EvaluationDataset.new(), path).goldens ==
                 load.(EvaluationDataset.new(), expected).goldens
      end
    end
  end

  # Rows of cells, JSON cells decoded; the CSV must also end each row with
  # CRLF, as Python's csv module does.
  defp decode(:csv, content) do
    assert String.ends_with?(content, "\r\n")

    content
    |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
    |> Enum.map(fn row -> Enum.map(row, &decode_cell/1) end)
  end

  defp decode(:json, content), do: Jason.decode!(content)

  defp decode(:jsonl, content) do
    assert String.ends_with?(content, "\n")
    content |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp decode_cell(cell) do
    case Jason.decode(cell) do
      {:ok, decoded} when is_list(decoded) or is_map(decoded) -> decoded
      _ -> cell
    end
  end

  # The generator's full_golden(), Golden(input="Minimal golden"),
  # csv_hostile_golden() and test_case_with_counts()
  defp saved_dataset do
    [
      Golden.new!(
        input: "What is the refund window, in days?",
        actual_output: "30 days, from delivery.",
        expected_output: "30 days",
        context: ["Refunds: 30 days from delivery.", "Exchanges: 60 days."],
        retrieval_context: [
          "Plain retrieved chunk",
          %RetrievedContextData{
            source: "policy.md#refunds",
            context: "Refunds are accepted within 30 days."
          }
        ],
        name: "refund-window",
        comments: "Checked against the 2026 policy.",
        source_file: "policy.md",
        tools_called: [
          %ToolCall{
            name: "search_policy",
            description: "Searches the policy",
            reasoning: "Needs the refund rule",
            input_parameters: %{"query" => "refund window", "limit" => 3},
            output: ["Refunds: 30 days"]
          }
        ],
        expected_tools: [%ToolCall{name: "search_policy", type: :mcp}],
        additional_metadata: %{
          "locale" => "en-GB",
          "priority" => 2,
          "tags" => ["refunds", "policy"]
        },
        custom_column_key_values: %{"team" => "support"},
        expectations: %{
          must: ["Cite the policy"],
          must_not: ["Promise exceptions"],
          model: "gpt-4o-mini",
          eval_mode: "llm"
        }
      ),
      Golden.new!(input: "Minimal golden"),
      Golden.new!(
        input: ~s(Say "hello", then\na new line),
        expected_output: "Grüße, “quoted”; done",
        context: ["one, with comma", ~s(two "quoted")],
        retrieval_context: [%RetrievedContextData{source: "a,b", context: "x|y"}]
      )
    ]
    |> EvaluationDataset.new()
    |> EvaluationDataset.add_test_case(
      TestCase.new!(
        input: "Summarise the order",
        actual_output: "Two items, shipped.",
        expected_output: "Two items",
        token_cost: 0.25,
        input_token_count: 120,
        output_token_count: 8,
        metadata: %{"order_id" => "A-1"},
        tools_called: [%ToolCall{name: "get_order", input_parameters: %{"id" => "A-1"}}]
      )
    )
  end

  # The generator's edge_dataset()
  defp edge_dataset do
    [
      Golden.new!(
        input: "Emoji \u{1F389}, bell \a, CR\rand CRLF\r\nend",
        actual_output: "",
        expected_output: " padded; semi ",
        context: [],
        retrieval_context: [],
        tools_called: [],
        expected_tools: [
          %ToolCall{
            name: "noop",
            input_parameters: %{},
            output: %{"a" => nil, "b" => [1, 2.5, true, -0.0], "c" => 1.0e16}
          }
        ],
        additional_metadata: %{},
        custom_column_key_values: %{},
        expectations: %{eval_mode: "system_one"},
        token_cost: 3.0,
        input_token_count: 4,
        output_token_count: 5,
        name: "edge"
      ),
      Golden.new!(
        input: "Tabs\tand ümläuts \u2028",
        context: ["only|piped"],
        retrieval_context: [%RetrievedContextData{source: "", context: ""}],
        tools_called: [%ToolCall{name: "t", type: :mcp, output: "plain"}],
        additional_metadata: %{"a" => [], "b" => %{}, "n" => 1.5e-7},
        custom_column_key_values: %{"k" => "vé"},
        expectations: %{model: "m", must: ["Be kind"], must_not: []}
      )
    ]
    |> EvaluationDataset.new()
    |> EvaluationDataset.add_test_case(
      TestCase.new!(
        input: "Tiny cost",
        actual_output: "ok",
        token_cost: 1.0e-5,
        input_token_count: 0,
        output_token_count: 1_000_000,
        retrieval_context: [%RetrievedContextData{source: "db", context: "row 1"}],
        metadata: %{"nested" => %{"a" => 1, "b" => "ü"}},
        expectations: %{must: ["Answer"]}
      )
    )
    |> EvaluationDataset.add_test_case(
      TestCase.new!(input: "Whole cost", actual_output: "ok", token_cost: 2.0)
    )
  end
end
