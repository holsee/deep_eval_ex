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

  The conversational helpers (`format_turns`, `parse_turns`, personas) wait
  for multi-turn goldens; `coerce_to_task` has no Elixir counterpart.

  ## Examples

      iex> alias DeepEvalEx.Dataset.Utils
      iex> alias DeepEvalEx.Schemas.RetrievedContextData
      iex> cell = Utils.join_retrieval_context(["chunk", %RetrievedContextData{source: "faq.md", context: "Yes."}])
      "chunk|deepeval_source=faq.md,deepeval_context=Yes."
      iex> cell |> String.split(Utils.delimiter()) |> Utils.reconstruct_retrieval_context()
      ["chunk", %RetrievedContextData{source: "faq.md", context: "Yes."}]
  """

  alias DeepEvalEx.Schemas.RetrievedContextData

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
end
