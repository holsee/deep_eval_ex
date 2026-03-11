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
        input: "Summarise: The quick brown fox jumps over the lazy dog.",
        actual_output: "A fox jumped over a dog.",
        expected_output: "A fox leaps over a resting dog."
      }
  """

  import Peri

  alias DeepEvalEx.Schemas.ToolCall

  @type t :: %__MODULE__{
          input: String.t(),
          actual_output: String.t() | nil,
          expected_output: String.t() | nil,
          retrieval_context: [String.t()] | nil,
          context: [String.t()] | nil,
          tools_called: [ToolCall.t()],
          expected_tools: [ToolCall.t()],
          metadata: map() | nil,
          name: String.t() | nil,
          tags: [String.t()] | nil
        }

  defstruct [
    :input,
    :actual_output,
    :expected_output,
    :retrieval_context,
    :context,
    :metadata,
    :name,
    :tags,
    tools_called: [],
    expected_tools: []
  ]

  @tool_call_schema %{
    name: {:required, :string},
    description: :string,
    reasoning: :string,
    input_parameters: :map,
    output: :string
  }

  defschema(:test_case_schema, %{
    input: {:required, :string},
    actual_output: :string,
    expected_output: :string,
    retrieval_context: {:list, :string},
    context: {:list, :string},
    tools_called: {:list, @tool_call_schema},
    expected_tools: {:list, @tool_call_schema},
    metadata: :map,
    name: :string,
    tags: {:list, :string}
  })

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
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    case test_case_schema(attrs) do
      {:ok, validated} ->
        validated = normalize_context(validated)
        validated = convert_tool_calls(validated)
        {:ok, struct(__MODULE__, validated)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates a new test case struct, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, test_case} -> test_case
      {:error, errors} -> raise "Invalid test case: #{inspect(errors)}"
    end
  end

  @doc """
  Returns the JSON schema representation for structured output requests.
  """
  def json_schema do
    tool_call_schema = ToolCall.json_schema()

    %{
      "type" => "object",
      "properties" => %{
        "input" => %{"type" => "string"},
        "actual_output" => %{"type" => "string"},
        "expected_output" => %{"type" => "string"},
        "retrieval_context" => %{"type" => "array", "items" => %{"type" => "string"}},
        "context" => %{"type" => "array", "items" => %{"type" => "string"}},
        "tools_called" => %{"type" => "array", "items" => tool_call_schema},
        "expected_tools" => %{"type" => "array", "items" => tool_call_schema},
        "metadata" => %{"type" => "object"},
        "name" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["input"],
      "additionalProperties" => false
    }
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
  defp normalize_context(validated) do
    case {Map.get(validated, :retrieval_context), Map.get(validated, :context)} do
      {nil, context} when not is_nil(context) ->
        Map.put(validated, :retrieval_context, context)

      _ ->
        validated
    end
  end

  # Convert nested tool call maps to ToolCall structs
  defp convert_tool_calls(validated) do
    validated
    |> maybe_convert_tools(:tools_called)
    |> maybe_convert_tools(:expected_tools)
  end

  defp maybe_convert_tools(validated, key) do
    case Map.get(validated, key) do
      nil -> validated
      tools -> Map.put(validated, key, Enum.map(tools, &struct(ToolCall, &1)))
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
