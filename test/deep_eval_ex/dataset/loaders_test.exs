defmodule DeepEvalEx.Dataset.LoadersTest do
  @moduledoc """
  Behaviour of `DeepEvalEx.Dataset.EvaluationDataset`'s file loaders beyond
  the deepeval fixtures (loader_parity_test.exs): appending, options, and
  the errors raised.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.Schemas.ToolCall

  @moduletag :tmp_dir

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "appending" do
    test "loaded goldens follow the dataset's own", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input\nloaded\n")
      dataset = EvaluationDataset.new([Golden.new!(input: "existing")])

      assert dataset |> EvaluationDataset.add_goldens_from_csv_file(path) |> Enum.map(& &1.input) ==
               ["existing", "loaded"]
    end

    test "loaded test cases are ranked after the dataset's own", %{tmp_dir: dir} do
      path = write!(dir, "t.json", ~s([{"i": "b", "o": "B"}]))

      dataset =
        EvaluationDataset.new()
        |> EvaluationDataset.add_test_case(DeepEvalEx.TestCase.new!(input: "a"))
        |> EvaluationDataset.add_test_cases_from_json_file(path, "i", "o")

      assert Enum.map(dataset.test_cases, &{&1.input, &1.dataset_rank}) == [{"a", 0}, {"b", 1}]
    end
  end

  describe "CSV" do
    test "a nil column name leaves the field unset, as a missing column", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input,context\nq,a|b\n")

      assert [%Golden{context: nil}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_goldens_from_csv_file(path, context_col_name: nil)
               |> Enum.to_list()
    end

    test "skips a UTF-8 byte order mark, as pandas", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "﻿input\nq\n")

      assert [%Golden{input: "q"}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_goldens_from_csv_file(path)
               |> Enum.to_list()
    end

    test "keeps numeric-looking text cells as strings", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input,expected_output,name\n1,2.5,3\n")

      assert [%Golden{input: "1", expected_output: "2.5", name: "3"}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_goldens_from_csv_file(path)
               |> Enum.to_list()
    end

    test "raises on a row with more cells than the header, as pandas", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input,name\na,b\nc,d,e\n")

      assert_raise ArgumentError, "Expected 2 fields in row 3 of #{path}, saw 3", fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path)
      end
    end

    test "raises on a golden deepeval's Golden rejects", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "question\nq\n")

      assert_raise ArgumentError, ~r/^Invalid golden: /, fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path)
      end
    end

    test "raises on tool calls that are not a JSON list of tool calls", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input,tools_called\nq,search;lookup\n")

      assert_raise ArgumentError, ~r/tools_called/, fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path)
      end

      assert_raise ArgumentError,
                   ~r/^Error processing tools_called: Invalid JSON: search;lookup/,
                   fn ->
                     EvaluationDataset.add_test_cases_from_csv_file(
                       EvaluationDataset.new(),
                       path,
                       "input",
                       "input"
                     )
                   end
    end

    test "raises on a metadata cell that is not JSON", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input,additional_metadata\nq,{'a': 1}\n")

      assert_raise ArgumentError, ~r/^Invalid JSON: /, fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path)
      end
    end

    test "reads tool calls into ToolCall structs for test cases", %{tmp_dir: dir} do
      path =
        write!(
          dir,
          "t.csv",
          ~s(in,out,tools_called\nq,a,"[{""name"": ""s"", ""type"": ""MCP""}]"\n)
        )

      assert [%{tools_called: [%ToolCall{name: "s", type: :mcp}], expected_tools: nil}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_test_cases_from_csv_file(path, "in", "out")
               |> Map.fetch!(:test_cases)
    end
  end

  describe "multi-turn goldens" do
    test "a scenario raises, as conversational goldens are not supported yet", %{tmp_dir: dir} do
      csv = write!(dir, "c.csv", "scenario,input\nA support call,\n")
      json = write!(dir, "c.json", ~s([{"scenario": "A support call"}]))
      jsonl = write!(dir, "c.jsonl", ~s({"scenario": "A support call"}\n))

      for {loader, path} <- [
            add_goldens_from_csv_file: csv,
            add_goldens_from_json_file: json,
            add_goldens_from_jsonl_file: jsonl
          ] do
        assert_raise ArgumentError, ~r/conversational goldens are not supported/, fn ->
          apply(EvaluationDataset, loader, [EvaluationDataset.new(), path])
        end
      end
    end

    test "an empty scenario is a single-turn golden, as deepeval", %{tmp_dir: dir} do
      path = write!(dir, "c.json", ~s([{"scenario": "", "input": "q"}]))

      assert [%Golden{input: "q"}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_goldens_from_json_file(path)
               |> Enum.to_list()
    end
  end

  describe "JSON and JSONL" do
    test "a JSON file must hold a list of objects", %{tmp_dir: dir} do
      path = write!(dir, "g.json", ~s({"input": "q"}))

      assert_raise ArgumentError, "The file #{path} must hold a list of JSON objects.", fn ->
        EvaluationDataset.add_goldens_from_json_file(EvaluationDataset.new(), path)
      end
    end

    test "a JSONL context must be a list, string or null", %{tmp_dir: dir} do
      path = write!(dir, "g.jsonl", ~s({"input": "q", "context": 3}\n))

      assert_raise ArgumentError,
                   "Expected context fields in JSONL goldens to be a list, string, or null.",
                   fn ->
                     EvaluationDataset.add_goldens_from_jsonl_file(EvaluationDataset.new(), path)
                   end
    end

    test "reads CRLF line endings", %{tmp_dir: dir} do
      path = write!(dir, "g.jsonl", ~s({"input": "a"}\r\n{"input": "b"}\r\n))

      assert EvaluationDataset.new()
             |> EvaluationDataset.add_goldens_from_jsonl_file(path)
             |> Enum.map(& &1.input) == ["a", "b"]
    end
  end

  describe "errors common to every loader" do
    test "a missing file raises File.Error", %{tmp_dir: dir} do
      path = Path.join(dir, "missing")

      assert_raise File.Error, fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path)
      end

      assert_raise File.Error, fn ->
        EvaluationDataset.add_goldens_from_json_file(EvaluationDataset.new(), path)
      end

      assert_raise File.Error, fn ->
        EvaluationDataset.add_goldens_from_jsonl_file(EvaluationDataset.new(), path)
      end

      assert_raise File.Error, fn ->
        EvaluationDataset.add_test_cases_from_csv_file(EvaluationDataset.new(), path, "i", "o")
      end

      assert_raise File.Error, fn ->
        EvaluationDataset.add_test_cases_from_json_file(EvaluationDataset.new(), path, "i", "o")
      end
    end

    test "an unknown option raises", %{tmp_dir: dir} do
      path = write!(dir, "g.csv", "input\nq\n")

      assert_raise NimbleOptions.ValidationError, fn ->
        EvaluationDataset.add_goldens_from_csv_file(EvaluationDataset.new(), path,
          input_key_name: "x"
        )
      end
    end
  end
end
