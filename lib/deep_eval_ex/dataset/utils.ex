defmodule DeepEvalEx.Dataset.Utils do
  @moduledoc """
  How datasets flatten list-valued fields into single CSV or JSONL cells,
  and read them back: deepeval 4.3.1's `dataset/utils.py`.

  Context and retrieval context are joined on `delimiter/0` (`"|"`); a
  `DeepEvalEx.Schemas.RetrievedContextData` is written as the marker
  `"deepeval_source=<source>,deepeval_context=<context>"`, which
  `reconstruct_retrieval_context/1` turns back into one. `tools_delimiter/0`
  (`";"`) is the default delimiter of the loaders' tool call columns.

  As deepeval, a round trip is lossless only when no item contains the
  delimiter: an item containing `"|"` comes back split in two.

  Conversations are written as one JSON cell by `format_turns/1` and read
  back by `parse_turns/1`, and a `DeepEvalEx.Dataset.Persona` is dumped by
  `serialize_persona/1`. deepeval's `persona_kwargs` has no counterpart:
  `DeepEvalEx.Dataset.ConversationalGolden.new/1` takes a persona map, or
  the `user_description` of files written before personas, as it is.
  `coerce_to_task` has no Elixir counterpart.

  ## Examples

      iex> alias DeepEvalEx.Dataset.Utils
      iex> alias DeepEvalEx.Schemas.RetrievedContextData
      iex> cell = Utils.join_retrieval_context(["chunk", %RetrievedContextData{source: "faq.md", context: "Yes."}])
      "chunk|deepeval_source=faq.md,deepeval_context=Yes."
      iex> cell |> String.split(Utils.delimiter()) |> Utils.reconstruct_retrieval_context()
      ["chunk", %RetrievedContextData{source: "faq.md", context: "Yes."}]
  """

  alias DeepEvalEx.Dataset.Persona
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn
  alias Jason.OrderedObject

  @delimiter "|"
  @tools_delimiter ";"

  # deepeval's _RETRIEVED_CONTEXT_MARKER. Without the s flag `.` stops at a
  # newline and `$` also matches before a final one, as in Python's re.
  @marker ~r/^deepeval_source=(?<source>.*?),deepeval_context=(?<context>.*)$/u

  @doc """
  The delimiter list-valued cells (context, retrieval context) are joined
  on and split by, deepeval's `DELIMITER`: `"|"`.
  """
  @spec delimiter() :: String.t()
  def delimiter, do: @delimiter

  @doc """
  The default delimiter of the loaders' tool call columns, deepeval's
  `TOOLS_DELIMITER`: `";"`.
  """
  @spec tools_delimiter() :: String.t()
  def tools_delimiter, do: @tools_delimiter

  @doc """
  Serialises retrieval context items for a file: each
  `DeepEvalEx.Schemas.RetrievedContextData` becomes its
  `"deepeval_source=...,deepeval_context=..."` marker, strings are kept.
  deepeval's `serialize_retrieval_context`.
  """
  @spec serialize_retrieval_context([String.t() | RetrievedContextData.t()] | nil) ::
          [String.t()] | nil
  def serialize_retrieval_context(nil), do: nil

  def serialize_retrieval_context(items) when is_list(items) do
    Enum.map(items, fn
      %RetrievedContextData{source: source, context: context} ->
        "deepeval_source=#{source},deepeval_context=#{context}"

      item ->
        item
    end)
  end

  @doc """
  Joins serialised retrieval context items into one cell, deepeval's
  `join_retrieval_context`.
  """
  @spec join_retrieval_context([String.t() | RetrievedContextData.t()] | nil, String.t()) ::
          String.t() | nil
  def join_retrieval_context(items, delimiter \\ @delimiter)
  def join_retrieval_context(nil, _delimiter), do: nil

  def join_retrieval_context(items, delimiter),
    do: items |> serialize_retrieval_context() |> Enum.join(delimiter)

  @doc """
  Joins context items into one cell, deepeval's `join_context`.
  """
  @spec join_context([String.t()] | nil, String.t()) :: String.t() | nil
  def join_context(items, delimiter \\ @delimiter)
  def join_context(nil, _delimiter), do: nil
  def join_context(items, delimiter), do: Enum.join(items, delimiter)

  @doc """
  Rebuilds `DeepEvalEx.Schemas.RetrievedContextData` from the marker
  strings `serialize_retrieval_context/1` writes, leaving every other item
  as it is. deepeval's `reconstruct_retrieval_context`.

  The source ends at the first `",deepeval_context="`.
  """
  @spec reconstruct_retrieval_context([term()] | nil) :: [term()] | nil
  def reconstruct_retrieval_context(nil), do: nil

  def reconstruct_retrieval_context(items) when is_list(items) do
    Enum.map(items, fn
      item when is_binary(item) ->
        case Regex.named_captures(@marker, item) do
          %{"source" => source, "context" => context} ->
            %RetrievedContextData{source: source, context: context}

          nil ->
            item
        end

      item ->
        item
    end)
  end

  @doc """
  Decodes JSON, tolerating trailing commas before `]` or `}`. deepeval's
  `trimAndLoadJson`: the string is trimmed and decoded; only when that fails
  are trailing commas dropped and the decoding retried, so a JSON string
  value containing `", ]"` is never changed.

  Returns `{:error, message}` where deepeval raises `ValueError`, with its
  message (the decoder's own error text differs from Python's).

  ## Examples

      iex> DeepEvalEx.Dataset.Utils.trim_and_load_json(~s( [{"name": "search"},] ))
      {:ok, [%{"name" => "search"}]}
  """
  @spec trim_and_load_json(String.t()) :: {:ok, term()} | {:error, String.t()}
  def trim_and_load_json(input) when is_binary(input) do
    stripped = String.trim(input)

    with {:error, _} <- Jason.decode(stripped),
         {:error, error} <- Jason.decode(Regex.replace(~r/,\s*([\]}])/, stripped, "\\1")) do
      {:error, "Invalid JSON: #{input}. Error: #{Exception.message(error)}"}
    end
  end

  @doc """
  Writes turns as one JSON string, deepeval's `format_turns`: per turn an
  object of `role`, `content`, `user_id`, `retrieval_context` (serialised
  as `serialize_retrieval_context/1`), `tools_called` (each tool call
  without its `nil` fields, `input_parameters` as `inputParameters`), the
  unported MCP fields as `null`, and `metadata`. No tool calls and empty
  metadata are `null`.

  As deepeval's `json.dumps(..., ensure_ascii=False)`, items are separated
  by `", "` and non-ASCII characters are kept. The audio, latency,
  interruption and provider transcript are left out, as deepeval leaves
  them out.
  """
  @spec format_turns([Turn.t()]) :: String.t()
  def format_turns(turns) when is_list(turns) do
    turns
    |> Enum.map(fn %Turn{} = turn ->
      OrderedObject.new([
        {"role", Atom.to_string(turn.role)},
        {"content", turn.content},
        {"user_id", turn.user_id},
        {"retrieval_context", serialize_retrieval_context(turn.retrieval_context)},
        {"tools_called", dump_tool_calls(turn.tools_called)},
        {"mcp_tools_called", nil},
        {"mcp_resources_called", nil},
        {"mcp_prompts_called", nil},
        {"metadata", if(turn.metadata != %{}, do: turn.metadata)}
      ])
    end)
    |> JSON.encode!(ensure_ascii: false)
  end

  @doc """
  Reads turns from a JSON string or a list of maps, deepeval's
  `parse_turns`: the inverse of `format_turns/1`.

  Each turn must be a map whose `"role"` and `"content"` (string or atom
  keys) are strings; a `"retrieval_context"` is passed through
  `reconstruct_retrieval_context/1` before `DeepEvalEx.Turn.new/1` builds
  the turn. Returns `{:error, message}` where deepeval raises, with its
  message; a turn that `DeepEvalEx.Turn.new/1` rejects gives
  `"Turn at index <i> is invalid: ..."` where deepeval raises pydantic's
  `ValidationError`.

  ## Examples

      iex> {:ok, [turn]} = DeepEvalEx.Dataset.Utils.parse_turns(~s([{"role": "user", "content": "Hi"}]))
      iex> {turn.role, turn.content}
      {:user, "Hi"}
  """
  @spec parse_turns(term()) :: {:ok, [Turn.t()]} | {:error, String.t()}
  def parse_turns(turns) when is_binary(turns) do
    case Jason.decode(turns) do
      {:ok, parsed} -> parse_turn_list(parsed)
      {:error, error} -> {:error, "Invalid JSON: #{Exception.message(error)}"}
    end
  end

  def parse_turns(turns) when is_list(turns), do: parse_turn_list(turns)
  def parse_turns(_turns), do: {:error, "Expected a JSON string or a list of turns."}

  @doc """
  Reads turns as `parse_turns/1`, raising `ArgumentError` with its message
  on error.
  """
  @spec parse_turns!(term()) :: [Turn.t()]
  def parse_turns!(turns) do
    case parse_turns(turns) do
      {:ok, parsed} -> parsed
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Dumps a persona for a file, deepeval's `serialize_persona`: its fields
  in deepeval's order, leaving out those at their default (`nil`).
  """
  @spec serialize_persona(Persona.t() | nil) :: OrderedObject.t() | nil
  def serialize_persona(nil), do: nil

  def serialize_persona(%Persona{} = persona) do
    [
      {"name", persona.name},
      {"characteristics", persona.characteristics},
      {"metadata", persona.metadata}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> OrderedObject.new()
  end

  @doc false
  # ToolCall.model_dump(by_alias=True, exclude_none=True, mode="json"), in
  # its field order; nil or no tool calls are None
  @spec dump_tool_calls([ToolCall.t()] | nil) :: [OrderedObject.t()] | nil
  def dump_tool_calls(nil), do: nil
  def dump_tool_calls([]), do: nil
  def dump_tool_calls(tools), do: Enum.map(tools, &dump_tool_call/1)

  defp dump_tool_call(%ToolCall{} = tool) do
    [
      {"name", tool.name},
      {"type", tool.type |> Atom.to_string() |> String.upcase()},
      {"description", tool.description},
      {"reasoning", tool.reasoning},
      {"output", tool.output},
      {"inputParameters", tool.input_parameters}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> OrderedObject.new()
  end

  defp parse_turn_list(parsed) when is_list(parsed) do
    parsed
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {turn, index}, {:ok, acc} ->
      case parse_turn(turn, index) do
        {:ok, parsed_turn} -> {:cont, {:ok, [parsed_turn | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, turns} -> {:ok, Enum.reverse(turns)}
      error -> error
    end
  end

  defp parse_turn_list(_parsed), do: {:error, "Expected a list of turns."}

  defp parse_turn(turn, index) when is_map(turn) and not is_struct(turn) do
    turn = Map.new(turn, fn {k, v} -> {to_string(k), v} end)

    cond do
      not is_binary(turn["role"]) ->
        {:error, "Turn at index #{index} is missing a valid 'role'."}

      not is_binary(turn["content"]) ->
        {:error, "Turn at index #{index} is missing a valid 'content'."}

      true ->
        turn
        |> reconstruct_turn_context()
        |> Turn.new()
        |> case do
          {:ok, parsed} -> {:ok, parsed}
          {:error, errors} -> {:error, "Turn at index #{index} is invalid: #{inspect(errors)}"}
        end
    end
  end

  defp parse_turn(_turn, index), do: {:error, "Turn at index #{index} is not a dictionary."}

  defp reconstruct_turn_context(%{"retrieval_context" => context} = turn) when is_list(context),
    do: %{turn | "retrieval_context" => reconstruct_retrieval_context(context)}

  defp reconstruct_turn_context(turn), do: turn
end
