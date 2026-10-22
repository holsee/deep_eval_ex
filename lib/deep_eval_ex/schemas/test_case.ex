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
  - `:name` - Optional name identifying the test case
  - `:tags` - Optional list of tags
  - `:comments` - Free-text comments about the test case
  - `:token_cost` - Cost of the LLM call that produced `:actual_output` (float)
  - `:input_token_count` - Number of input tokens consumed (integer)
  - `:output_token_count` - Number of output tokens produced (integer)
  - `:completion_time` - Time the LLM took to respond, in seconds (float)
  - `:flaky` - Whether the test case is known to be flaky (default: `false`)

  The last six fields mirror deepeval's `LLMTestCase` and are carried through
  to results and exports unchanged; no metric reads them.

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
          tags: [String.t()] | nil,
          comments: String.t() | nil,
          token_cost: float() | nil,
          input_token_count: non_neg_integer() | nil,
          output_token_count: non_neg_integer() | nil,
          completion_time: float() | nil,
          flaky: boolean()
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
    :comments,
    :token_cost,
    :input_token_count,
    :output_token_count,
    :completion_time,
    tools_called: [],
    expected_tools: [],
    flaky: false
  ]

  @tool_call_schema ToolCall.schema()

  @tool_call_keys [:tools_called, :expected_tools]
  @float_keys [:token_cost, :completion_time]

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
    tags: {:list, :string},
    comments: :string,
    token_cost: :float,
    input_token_count: :integer,
    output_token_count: :integer,
    completion_time: :float,
    flaky: {:boolean, {:default, false}}
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
  - `:name` - Optional test case name
  - `:tags` - Optional list of tags
  - `:comments` - Free-text comments
  - `:token_cost` - Cost of producing the output (integers are cast to floats)
  - `:input_token_count` - Input tokens consumed
  - `:output_token_count` - Output tokens produced
  - `:completion_time` - Response time in seconds (integers are cast to floats)
  - `:flaky` - Whether the test case is flaky (default: `false`)

  Keys may be atoms or strings. Tool calls may be `DeepEvalEx.Schemas.ToolCall`
  structs or maps, and accept deepeval's `"inputParameters"` alias and
  `"FUNCTION"` / `"MCP"` type values.
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
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "comments" => %{"type" => "string"},
        "token_cost" => %{"type" => "number"},
        "input_token_count" => %{"type" => "integer"},
        "output_token_count" => %{"type" => "integer"},
        "completion_time" => %{"type" => "number"},
        "flaky" => %{"type" => "boolean"}
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
    |> normalize_tool_calls()
    |> normalize_floats()
  rescue
    ArgumentError -> attrs
  end

  defp normalize_tool_calls(attrs) do
    Enum.reduce(@tool_call_keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        tools when is_list(tools) ->
          Map.put(acc, key, Enum.map(tools, &normalize_tool_call/1))

        _ ->
          acc
      end
    end)
  end

  defp normalize_tool_call(tool) when is_map(tool) or is_list(tool), do: ToolCall.normalize(tool)
  defp normalize_tool_call(tool), do: tool

  # deepeval (pydantic) accepts ints for float fields; do the same
  defp normalize_floats(attrs) do
    Enum.reduce(@float_keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        value when is_integer(value) -> Map.put(acc, key, value / 1)
        _ -> acc
      end
    end)
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
