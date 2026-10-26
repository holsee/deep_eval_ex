defmodule DeepEvalEx.Dataset.Loader do
  @moduledoc false
  # Reads goldens and test cases from CSV, JSON and JSONL files, as deepeval
  # 4.3.1's EvaluationDataset.add_*_from_*_file methods (dataset/dataset.py).
  # DeepEvalEx.Dataset.EvaluationDataset validates the options and documents
  # the behaviour; this module returns the goldens or test cases to add.

  alias DeepEvalEx.Dataset.{Golden, Utils}
  alias DeepEvalEx.TestCase
  alias NimbleCSV.RFC4180, as: CSV

  # pandas.read_csv's default missing-value markers (STR_NA_VALUES): a cell
  # holding exactly one of these is deepeval's None.
  @na_values MapSet.new([
               "",
               "#N/A",
               "#N/A N/A",
               "#NA",
               "-1.#IND",
               "-1.#QNAN",
               "-NaN",
               "-nan",
               "1.#IND",
               "1.#QNAN",
               "<NA>",
               "N/A",
               "NA",
               "NULL",
               "NaN",
               "None",
               "n/a",
               "nan",
               "null"
             ])

  @unsupported_multi_turn "conversational goldens are not supported yet: a golden with a " <>
                            "scenario is a multi-turn ConversationalGolden in deepeval"

  ## CSV

  @spec goldens_from_csv!(Path.t(), keyword()) :: [Golden.t()]
  def goldens_from_csv!(path, opts) do
    {header, rows} = read_csv!(path)

    Enum.map(rows, fn row ->
      if truthy?(cell(row, opts[:scenario_col_name])),
        do: raise(ArgumentError, @unsupported_multi_turn)

      build_golden!(%{
        input: cell(row, opts[:input_col_name]),
        actual_output: cell(row, opts[:actual_output_col_name]),
        expected_output: cell(row, opts[:expected_output_col_name]),
        context:
          parse_column(
            header,
            row,
            opts[:context_col_name],
            &split_cell(&1, opts[:context_col_delimiter])
          ),
        retrieval_context:
          parse_column(
            header,
            row,
            opts[:retrieval_context_col_name],
            &split_retrieval_cell(&1, opts[:retrieval_context_col_delimiter])
          ),
        tools_called:
          parse_column(
            header,
            row,
            opts[:tools_called_col_name],
            &tools_cell!(&1, "tools_called")
          ),
        expected_tools:
          parse_column(
            header,
            row,
            opts[:expected_tools_col_name],
            &tools_cell!(&1, "expected_tools")
          ),
        token_cost: number(cell(row, opts[:token_cost_col_name])),
        input_token_count: count(number(cell(row, opts[:input_token_count_col_name]))),
        output_token_count: count(number(cell(row, opts[:output_token_count_col_name]))),
        comments: cell(row, opts[:comments_key_name]),
        name: cell(row, opts[:name_key_name]),
        source_file: cell(row, opts[:source_file_col_name]),
        additional_metadata:
          parse_column(header, row, opts[:additional_metadata_col_name], &json_cell!/1),
        custom_column_key_values:
          parse_column(header, row, opts[:custom_column_key_values_col_name], &json_cell!/1),
        expectations: parse_column(header, row, "expectations", &json_cell!/1)
      })
    end)
  end

  @spec test_cases_from_csv!(Path.t(), String.t(), String.t(), keyword()) :: [TestCase.t()]
  def test_cases_from_csv!(path, input_col_name, actual_output_col_name, opts) do
    {header, rows} = read_csv!(path)

    Enum.map(rows, fn row ->
      build_test_case!(%{
        input: cell(row, input_col_name),
        actual_output: cell(row, actual_output_col_name),
        expected_output: cell(row, opts[:expected_output_col_name]),
        context:
          parse_column(
            header,
            row,
            opts[:context_col_name],
            &split_cell(&1, opts[:context_col_delimiter])
          ),
        retrieval_context:
          parse_column(
            header,
            row,
            opts[:retrieval_context_col_name],
            &split_retrieval_cell(&1, opts[:retrieval_context_col_delimiter])
          ),
        tools_called:
          parse_column(
            header,
            row,
            opts[:tools_called_col_name],
            &tools_cell!(&1, "tools_called")
          ),
        expected_tools:
          parse_column(
            header,
            row,
            opts[:expected_tools_col_name],
            &tools_cell!(&1, "expected_tools")
          ),
        metadata: parse_column(header, row, opts[:additional_metadata_col_name], &json_cell!/1),
        expectations: parse_column(header, row, "expectations", &json_cell!/1)
      })
    end)
  end

  # Rows as maps of column name to cell (nil for pandas' missing values),
  # with blank lines skipped and short rows padded, as pandas.read_csv
  defp read_csv!(path) do
    rows =
      path
      |> File.read!()
      |> strip_bom()
      |> CSV.parse_string(skip_headers: false)
      |> Enum.reject(&(&1 == [""]))

    case rows do
      [] ->
        raise ArgumentError, "No columns to parse from file #{path}"

      [header | rows] ->
        rows =
          rows
          |> Enum.with_index(2)
          |> Enum.map(fn {cells, row_number} -> csv_row!(header, cells, row_number, path) end)

        {MapSet.new(header), rows}
    end
  end

  defp csv_row!(header, cells, row_number, path) do
    width = length(header)

    if length(cells) > width do
      raise ArgumentError,
            "Expected #{width} fields in row #{row_number} of #{path}, saw #{length(cells)}"
    end

    cells = cells ++ List.duplicate("", width - length(cells))

    # The first of duplicate column names wins
    header |> Enum.zip(Enum.map(cells, &na/1)) |> Enum.reverse() |> Map.new()
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp na(cell), do: if(MapSet.member?(@na_values, cell), do: nil, else: cell)

  defp cell(_row, nil), do: nil
  defp cell(row, column), do: Map.get(row, column)

  # deepeval's _parse_column: nil for every row when the column is absent
  # (or not named), the parsed cell otherwise
  defp parse_column(header, row, column, parse) do
    if column != nil and MapSet.member?(header, column), do: parse.(Map.get(row, column))
  end

  defp split_cell(nil, _delimiter), do: []
  defp split_cell(value, delimiter), do: String.split(value, delimiter)

  defp split_retrieval_cell(nil, _delimiter), do: []

  defp split_retrieval_cell(value, delimiter),
    do: value |> String.split(delimiter) |> Utils.reconstruct_retrieval_context()

  defp tools_cell!(nil, _field), do: []

  defp tools_cell!(value, field) do
    case Utils.trim_and_load_json(value) do
      {:ok, tools} when is_list(tools) ->
        if Enum.all?(tools, &is_map/1), do: tools, else: raise_tools!(field, value)

      {:ok, _} ->
        raise_tools!(field, value)

      {:error, message} ->
        raise ArgumentError, "Error processing #{field}: #{message}"
    end
  end

  defp raise_tools!(field, value) do
    raise ArgumentError,
          "Error processing #{field}: expected a JSON list of tool calls, got: #{value}"
  end

  defp json_cell!(nil), do: nil

  defp json_cell!(value) do
    case Utils.trim_and_load_json(value) do
      {:ok, decoded} -> decoded
      {:error, message} -> raise ArgumentError, message
    end
  end

  # pandas reads a column of numbers as numbers; only the token columns
  # are numbers in a golden
  defp number(nil), do: nil

  defp number(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  # pydantic takes a float with no fractional part for an int field, as
  # pandas gives a column of counts with missing values
  defp count(value) when is_float(value) and value == trunc(value), do: trunc(value)
  defp count(value), do: value

  ## JSON

  @spec goldens_from_json!(Path.t(), keyword()) :: [Golden.t()]
  def goldens_from_json!(path, opts) do
    path |> read_json_list!() |> Enum.map(&json_golden!(&1, opts, :json))
  end

  @spec goldens_from_jsonl!(Path.t(), keyword()) :: [Golden.t()]
  def goldens_from_jsonl!(path, opts) do
    path
    |> File.read!()
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> {String.trim(line), number} end)
    |> Enum.reject(fn {line, _number} -> line == "" end)
    |> Enum.map(fn {line, number} ->
      case Jason.decode(line) do
        {:ok, object} when is_map(object) ->
          json_golden!(object, opts, :jsonl)

        {:ok, _} ->
          raise ArgumentError, "The file #{path} holds no JSON object on line #{number}."

        {:error, _} ->
          raise ArgumentError, "The file #{path} contains invalid JSON on line #{number}."
      end
    end)
  end

  @spec test_cases_from_json!(Path.t(), String.t(), String.t(), keyword()) :: [TestCase.t()]
  def test_cases_from_json!(path, input_key_name, actual_output_key_name, opts) do
    path
    |> read_json_list!()
    |> Enum.map(fn object ->
      unless Map.has_key?(object, input_key_name) and Map.has_key?(object, actual_output_key_name) do
        raise ArgumentError, "Required fields are missing in one or more JSON objects"
      end

      get = &key(object, opts[&1])

      build_test_case!(%{
        input: Map.fetch!(object, input_key_name),
        actual_output: Map.fetch!(object, actual_output_key_name),
        expected_output: get.(:expected_output_key_name),
        context: get.(:context_key_name),
        retrieval_context: Utils.reconstruct_retrieval_context(get.(:retrieval_context_key_name)),
        tools_called: json_tools!(object, opts[:tools_called_key_name], "tools_called"),
        expected_tools: json_tools!(object, opts[:expected_tools_key_name], "expected_tools"),
        expectations: Map.get(object, "expectations")
      })
    end)
  end

  defp read_json_list!(path) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_map/1), do: list, else: raise_not_list!(path)

      {:ok, _} ->
        raise_not_list!(path)

      {:error, _} ->
        raise ArgumentError, "The file #{path} is not a valid JSON file."
    end
  end

  defp raise_not_list!(path),
    do: raise(ArgumentError, "The file #{path} must hold a list of JSON objects.")

  # One golden of add_goldens_from_json_file or add_goldens_from_jsonl_file,
  # which also splits string contexts and decodes string tool calls
  defp json_golden!(object, opts, format) do
    get = &key(object, opts[&1])

    if truthy?(get.(:scenario_key_name)), do: raise(ArgumentError, @unsupported_multi_turn)

    {context, retrieval_context, tools_called, expected_tools} =
      case format do
        :json ->
          {get.(:context_key_name), get.(:retrieval_context_key_name),
           get.(:tools_called_key_name), get.(:expected_tools_key_name)}

        :jsonl ->
          {jsonl_context!(get.(:context_key_name), opts[:context_col_delimiter]),
           jsonl_context!(
             get.(:retrieval_context_key_name),
             opts[:retrieval_context_col_delimiter]
           ), jsonl_tools!(get.(:tools_called_key_name), "tools_called"),
           jsonl_tools!(get.(:expected_tools_key_name), "expected_tools")}
      end

    build_golden!(%{
      input: get.(:input_key_name),
      actual_output: get.(:actual_output_key_name),
      expected_output: get.(:expected_output_key_name),
      context: context,
      retrieval_context: Utils.reconstruct_retrieval_context(retrieval_context),
      tools_called: tools_called,
      expected_tools: expected_tools,
      token_cost: get.(:token_cost_key_name),
      input_token_count: count(get.(:input_token_count_key_name)),
      output_token_count: count(get.(:output_token_count_key_name)),
      comments: get.(:comments_key_name),
      name: get.(:name_key_name),
      source_file: get.(:source_file_key_name),
      additional_metadata: get.(:additional_metadata_key_name),
      custom_column_key_values: get.(:custom_column_key_values_key_name),
      expectations: Map.get(object, "expectations")
    })
  end

  defp key(_object, nil), do: nil
  defp key(object, key), do: Map.get(object, key)

  defp jsonl_context!(nil, _delimiter), do: nil
  defp jsonl_context!(value, _delimiter) when is_list(value), do: value

  defp jsonl_context!(value, delimiter) when is_binary(value),
    do: split_cell(non_empty(value), delimiter)

  defp jsonl_context!(_value, _delimiter),
    do:
      raise(
        ArgumentError,
        "Expected context fields in JSONL goldens to be a list, string, or null."
      )

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp jsonl_tools!(value, field) do
    cond do
      not truthy?(value) -> nil
      is_binary(value) -> tools_cell!(value, field)
      true -> value
    end
  end

  # add_test_cases_from_json_file reads the tool calls as a list, [] when
  # the key is absent or not named
  defp json_tools!(_object, nil, _field), do: []

  defp json_tools!(object, key, field) do
    case Map.get(object, key, []) do
      nil -> raise ArgumentError, "#{field} must be a list of tool calls, got: nil"
      tools -> tools
    end
  end

  ## Building

  defp build_golden!(attrs) do
    case Golden.new(attrs) do
      {:ok, golden} -> golden
      {:error, errors} -> raise ArgumentError, "Invalid golden: #{inspect(errors)}"
    end
  end

  defp build_test_case!(attrs) do
    case TestCase.new(attrs) do
      {:ok, test_case} -> test_case
      {:error, errors} -> raise ArgumentError, "Invalid test case: #{inspect(errors)}"
    end
  end

  # Python's truthiness, for deepeval's `if value`
  defp truthy?(value), do: value not in [nil, false, "", [], %{}, 0, +0.0, -0.0]
end
