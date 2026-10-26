defmodule DeepEvalEx.Schemas.RetrievedContextData do
  @moduledoc """
  A retrieved chunk that knows where it came from, deepeval 4.3.1's
  `RetrievedContextData`.

  A test case's `:retrieval_context` may mix these with plain strings.
  deepeval treats them as follows, and so does DeepEvalEx:

  - the test run export and `DeepEvalEx.TestResult` keep only the
    `:context` (deepeval's `create_api_test_case`), so a loaded test run
    holds strings
  - a System One state sends one as deepeval's `model_serializer`,
    `"source: context"` (its `to_string/1`)
  - `DeepEvalEx.Metrics.ContextualPrecision` groups the chunks of each
    source into one document, `"Source: <source>\\n"` followed by their
    contexts joined with `"\\n---\\n"`, at the source's first position
  - `DeepEvalEx.Metrics.ContextualRecall` and `DeepEvalEx.Metrics.GEval`
    print the list as Python's `str(list)`, so one prints as its pydantic
    repr, `RetrievedContextData(context='...', source='...')`
    (`DeepEvalEx.Prompts.Python.repr/1`)

  deepeval 4.3.1's Faithfulness and ContextualRelevancy raise a `TypeError`
  on one (they join or split the retrieval context as strings);
  DeepEvalEx renders it as `"source: context"` there instead.

  ## Fields

  - `:context` - The retrieved text (required)
  - `:source` - Where it was retrieved from, e.g. a document name or URL
    (required)

  ## Examples

      iex> alias DeepEvalEx.Schemas.RetrievedContextData
      iex> data = %RetrievedContextData{context: "Paris is in France.", source: "wiki"}
      iex> to_string(data)
      "wiki: Paris is in France."
  """

  import Peri

  @enforce_keys [:context, :source]
  defstruct [:context, :source]

  @type t :: %__MODULE__{context: String.t(), source: String.t()}

  @key_aliases %{"context" => :context, "source" => :source}

  defschema(:retrieved_context_data_schema, %{
    context: {:required, :string},
    source: {:required, :string}
  })

  @doc """
  Builds a `RetrievedContextData` from a keyword list or a map with atom or
  string keys. Both `:context` and `:source` are required strings; other
  keys are dropped.

  ## Examples

      iex> DeepEvalEx.Schemas.RetrievedContextData.new(%{"context" => "c", "source" => "s"})
      {:ok, %DeepEvalEx.Schemas.RetrievedContextData{context: "c", source: "s"}}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    case attrs |> normalize() |> retrieved_context_data_schema() do
      {:ok, validated} -> {:ok, struct(__MODULE__, validated)}
      {:error, _} = err -> err
    end
  end

  @doc """
  The text of a retrieval context item: a `RetrievedContextData`'s
  `:context`, or a string as it is. deepeval's
  `c.context if isinstance(c, RetrievedContextData) else c`.

  ## Examples

      iex> alias DeepEvalEx.Schemas.RetrievedContextData
      iex> RetrievedContextData.context(%RetrievedContextData{context: "c", source: "s"})
      "c"
      iex> RetrievedContextData.context("chunk")
      "chunk"
  """
  @spec context(t() | String.t()) :: String.t()
  def context(%__MODULE__{context: context}), do: context
  def context(text) when is_binary(text), do: text

  @doc false
  # Peri custom validator for one item of a test case's retrieval context:
  # a string, a RetrievedContextData, or a map that builds one.
  @spec cast_item(term()) :: {:ok, String.t() | t()} | {:error, String.t(), keyword()}
  def cast_item(item) when is_binary(item), do: {:ok, item}

  def cast_item(%__MODULE__{context: context, source: source} = item)
      when is_binary(context) and is_binary(source),
      do: {:ok, item}

  def cast_item(item) when is_map(item) and not is_struct(item) do
    case new(item) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> invalid(item)
    end
  end

  def cast_item(item), do: invalid(item)

  defp invalid(item) do
    {:error, "must be a string or RetrievedContextData (context and source strings), got %{item}",
     [item: inspect(item)]}
  end

  defp normalize(attrs) do
    Enum.flat_map(attrs, fn
      {k, v} when is_binary(k) ->
        case Map.fetch(@key_aliases, k) do
          {:ok, key} -> [{key, v}]
          :error -> []
        end

      {k, v} when k in [:context, :source] ->
        [{k, v}]

      _ ->
        []
    end)
    |> Map.new()
  end
end

defimpl String.Chars, for: DeepEvalEx.Schemas.RetrievedContextData do
  # deepeval's @model_serializer: f"{self.source}: {self.context}"
  def to_string(%{source: source, context: context}), do: "#{source}: #{context}"
end
