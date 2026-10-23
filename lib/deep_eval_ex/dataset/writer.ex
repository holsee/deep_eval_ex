defmodule DeepEvalEx.Dataset.Writer do
  @moduledoc false
  # Writes goldens to CSV, JSON and JSONL files as deepeval 4.3.1's
  # EvaluationDataset.save_as (dataset/dataset.py), byte for byte but for
  # the order of map keys. DeepEvalEx.Dataset.EvaluationDataset validates the
  # arguments, picks the goldens and documents the behaviour.

  alias DeepEvalEx.Dataset.{Golden, Utils}
  alias DeepEvalEx.TestRun.JSON

  # save_as's keys and CSV columns, in its order
  @columns ~w(input actual_output expected_output retrieval_context context name comments
              source_file tools_called expected_tools token_cost input_token_count
              output_token_count additional_metadata custom_column_key_values expectations)

  @spec write!([Golden.t()], :csv | :json | :jsonl, Path.t()) :: :ok
  def write!(goldens, :json, path) do
    # json.dump(json_data, file, indent=4, ensure_ascii=False): no final newline
    records = Enum.map(goldens, &record(&1, :json))
    File.write!(path, JSON.encode!(records, indent: 4, ensure_ascii: false))
  end

  def write!(goldens, :jsonl, path) do
    lines = Enum.map(goldens, &[JSON.encode!(record(&1, :jsonl), ensure_ascii: false), ?\n])
    File.write!(path, lines)
  end

  def write!(goldens, :csv, path) do
    File.write!(path, [csv_row(@columns) | Enum.map(goldens, &csv_row(csv_cells(&1)))])
  end

  # The JSON and JSONL objects differ only in the context fields: JSON keeps
  # lists, JSONL joins them into one string as a CSV cell
  defp record(%Golden{} = golden, format) do
    {retrieval_context, context} =
      case format do
        :json ->
          {Utils.serialize_retrieval_context(golden.retrieval_context), golden.context}

        :jsonl ->
          {Utils.join_retrieval_context(golden.retrieval_context),
           Utils.join_context(golden.context)}
      end

    Jason.OrderedObject.new(
      Enum.zip(@columns, [
        golden.input,
        golden.actual_output,
        golden.expected_output,
        retrieval_context,
        context,
        golden.name,
        golden.comments,
        golden.source_file,
        Utils.dump_tool_calls(golden.tools_called),
        Utils.dump_tool_calls(golden.expected_tools),
        golden.token_cost,
        golden.input_token_count,
        golden.output_token_count,
        golden.additional_metadata,
        golden.custom_column_key_values,
        dump_expectations(golden.expectations)
      ])
    )
  end

  defp csv_cells(%Golden{} = golden) do
    [
      golden.input,
      golden.actual_output,
      golden.expected_output,
      Utils.join_retrieval_context(golden.retrieval_context),
      Utils.join_context(golden.context),
      golden.name,
      golden.comments,
      golden.source_file,
      golden.tools_called |> Utils.dump_tool_calls() |> json_cell(),
      golden.expected_tools |> Utils.dump_tool_calls() |> json_cell(),
      golden.token_cost,
      golden.input_token_count,
      golden.output_token_count,
      json_cell(golden.additional_metadata),
      # deepeval tests the custom columns for truthiness, metadata for None
      if(golden.custom_column_key_values == %{},
        do: nil,
        else: json_cell(golden.custom_column_key_values)
      ),
      # pydantic's model_dump_json(): compact, non-ASCII kept
      golden.expectations |> dump_expectations() |> compact_json()
    ]
  end

  defp json_cell(nil), do: nil
  defp json_cell(term), do: JSON.encode!(term, ensure_ascii: false)

  defp compact_json(nil), do: nil
  defp compact_json(term), do: Jason.encode!(term)

  # Expectations.model_dump(), in its field order
  defp dump_expectations(nil), do: nil

  defp dump_expectations(expectations) do
    Jason.OrderedObject.new([
      {"model", expectations.model},
      {"eval_mode", expectations.eval_mode && Atom.to_string(expectations.eval_mode)},
      {"must", expectations.must},
      {"must_not", expectations.must_not}
    ])
  end

  # Python's csv.writer (excel dialect, QUOTE_MINIMAL): str() of each cell,
  # None empty, quoted when it holds the delimiter, a quote, CR or LF, rows
  # ended with CRLF
  defp csv_row(cells), do: [Enum.map_intersperse(cells, ?,, &csv_field/1), "\r\n"]

  defp csv_field(nil), do: ""
  defp csv_field(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp csv_field(float) when is_float(float), do: JSON.float_repr(float)

  defp csv_field(text) when is_binary(text) do
    if String.contains?(text, [",", "\"", "\r", "\n"]),
      do: [?", String.replace(text, "\"", "\"\""), ?"],
      else: text
  end
end
