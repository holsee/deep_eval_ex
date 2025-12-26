defmodule DeepEvalEx.TestCase do
  @moduledoc """
  Represents a test case for LLM evaluation.

  A test case contains the input, actual output, and optional context
  for evaluating LLM responses.

  ## Fields

  - `:input` - The input prompt sent to the LLM (required)
  - `:actual_output` - The LLM's response to evaluate (required for most metrics)
  - `:expected_output` - The expected/ground truth output (optional)
  - `:retrieval_context` - List of retrieved context chunks for RAG evaluation
  - `:context` - Alias for retrieval_context (for compatibility)
  - `:tools_called` - List of tool calls made by the LLM
  - `:expected_tools` - Expected tool calls for tool use evaluation
  - `:metadata` - Additional metadata for the test case

  ## Examples

      # Basic test case
      test_case = %DeepEvalEx.TestCase{
        input: "What is the capital of France?",
        actual_output: "The capital of France is Paris."
      }

      # RAG evaluation test case
      test_case = %DeepEvalEx.TestCase{
        input: "What are the benefits of exercise?",
        actual_output: "Exercise improves cardiovascular health and mood.",
        retrieval_context: [
          "Regular exercise strengthens the heart and improves circulation.",
          "Physical activity releases endorphins, improving mental well-being."
        ]
      }

      # With expected output
      test_case = %DeepEvalEx.TestCase{
        input: "Summarize: The quick brown fox jumps over the lazy dog.",
        actual_output: "A fox jumped over a dog.",
        expected_output: "A fox leaps over a resting dog."
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DeepEvalEx.Schemas.ToolCall

  @type t :: %__MODULE__{
          input: String.t(),
          actual_output: String.t() | nil,
          expected_output: String.t() | nil,
          retrieval_context: [String.t()] | nil,
          context: [String.t()] | nil,
          tools_called: [ToolCall.t()] | nil,
          expected_tools: [ToolCall.t()] | nil,
          metadata: map() | nil,
          name: String.t() | nil,
          tags: [String.t()] | nil
        }

  @primary_key false
  embedded_schema do
    field(:input, :string)
    field(:actual_output, :string)
    field(:expected_output, :string)
    field(:retrieval_context, {:array, :string})
    field(:context, {:array, :string})
    field(:metadata, :map)
    field(:name, :string)
    field(:tags, {:array, :string})

    embeds_many(:tools_called, ToolCall, on_replace: :delete)
    embeds_many(:expected_tools, ToolCall, on_replace: :delete)
  end

  @doc """
  Creates a new test case struct.

  ## Options

  - `:input` - The input prompt (required)
  - `:actual_output` - The LLM's response
  - `:expected_output` - Expected output for comparison
  - `:retrieval_context` - List of retrieved context strings
  - `:context` - Alias for retrieval_context
  - `:tools_called` - List of tool calls made
  - `:expected_tools` - Expected tool calls
  - `:metadata` - Additional metadata map
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Creates a new test case struct, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, test_case} -> test_case
      {:error, changeset} -> raise "Invalid test case: #{inspect(changeset.errors)}"
    end
  end

  @doc false
  def changeset(test_case, attrs) do
    attrs = normalize_attrs(attrs)

    test_case
    |> cast(attrs, [
      :input,
      :actual_output,
      :expected_output,
      :retrieval_context,
      :context,
      :metadata,
      :name,
      :tags
    ])
    |> cast_embed(:tools_called)
    |> cast_embed(:expected_tools)
    |> validate_required([:input])
    |> normalize_context()
  end

  # Normalize string keys to atoms and handle aliases
  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  rescue
    ArgumentError -> attrs
  end

  # If context is provided but retrieval_context is not, use context as retrieval_context
  defp normalize_context(changeset) do
    case {get_field(changeset, :retrieval_context), get_field(changeset, :context)} do
      {nil, context} when not is_nil(context) ->
        put_change(changeset, :retrieval_context, context)

      _ ->
        changeset
    end
  end

  @doc """
  Returns the effective retrieval context, preferring :retrieval_context over :context.
  """
  @spec get_retrieval_context(t()) :: [String.t()] | nil
  def get_retrieval_context(%__MODULE__{retrieval_context: ctx}) when not is_nil(ctx), do: ctx
  def get_retrieval_context(%__MODULE__{context: ctx}), do: ctx

  @doc """
  Validates that the test case has the required parameters for a given metric.

  Handles aliases:
  - `:context` and `:retrieval_context` are interchangeable
  """
  @spec validate_params(t(), [atom()]) :: :ok | {:error, {:missing_params, [atom()]}}
  def validate_params(test_case, required_params) do
    missing =
      required_params
      |> Enum.filter(fn param ->
        not has_param?(test_case, param)
      end)

    case missing do
      [] -> :ok
      params -> {:error, {:missing_params, params}}
    end
  end

  # Check if param is present, handling aliases
  defp has_param?(test_case, :context) do
    has_value?(test_case, :context) or has_value?(test_case, :retrieval_context)
  end

  defp has_param?(test_case, :retrieval_context) do
    has_value?(test_case, :retrieval_context) or has_value?(test_case, :context)
  end

  defp has_param?(test_case, param) do
    has_value?(test_case, param)
  end

  defp has_value?(test_case, param) do
    value = Map.get(test_case, param)
    not (is_nil(value) or value == "" or value == [])
  end
end
