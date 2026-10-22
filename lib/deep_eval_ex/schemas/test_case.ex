defmodule DeepEvalEx.TestCase do
  @moduledoc """
  Represents a test case for LLM evaluation.

  A test case contains the input, actual output, and optional context
  for evaluating LLM responses.

  ## Fields

  - `:input` - The input prompt sent to the LLM (required)
  - `:actual_output` - The LLM's response to evaluate (required for most metrics)
  - `:expected_output` - The expected/ground truth output (optional)
  - `:retrieval_context` - List of context chunks your retriever returned at
    run time, for RAG metrics (Faithfulness, ContextualPrecision,
    ContextualRecall, ContextualRelevancy): strings, or
    `DeepEvalEx.Schemas.RetrievedContextData` structs naming each chunk's
    source, in any mix
  - `:context` - List of ideal, ground-truth context for the input, for
    Hallucination
  - `:tools_called` - List of tool calls made by the LLM. `nil` (deepeval's
    `None`) when not given, which a metric requiring it reports as missing;
    an empty list is a test case that called no tools
  - `:expected_tools` - Expected tool calls for tool use evaluation, `nil`
    when not given
  - `:metadata` - Additional metadata for the test case
  - `:name` - Optional name identifying the test case
  - `:tags` - Optional list of tags
  - `:comments` - Free-text comments about the test case
  - `:token_cost` - Cost of the LLM call that produced `:actual_output` (float)
  - `:input_token_count` - Number of input tokens consumed (integer)
  - `:output_token_count` - Number of output tokens produced (integer)
  - `:completion_time` - Time the LLM took to respond, in seconds (float)
  - `:flaky` - Whether the test case is known to be flaky (default: `false`)
  - `:custom_column_key_values` - Custom columns for the test case, a map of
    string keys to string values
  - `:expected_labels` - The label each classifier should give the test
    case, a map of classifier name to label (both strings)

  `:comments` through `:flaky` mirror deepeval's `LLMTestCase` and are
  carried through to results and exports unchanged; no metric reads them.
  `:custom_column_key_values` and `:expected_labels` are deepeval's too and
  are kept on the struct; deepeval does not export them in a test run, and
  neither does DeepEvalEx.

  ## deepeval keys

  `new/1` accepts the keys deepeval's `LLMTestCase` accepts, as atoms or
  strings: each field name, and deepeval's camelCase aliases
  (`actualOutput`, `expectedOutput`, `retrievalContext`, `toolsCalled`,
  `expectedTools`, `tokenCost`, `inputTokenCount`, `outputTokenCount`,
  `completionTime`, `customColumnKeyValues`, `expectedLabels`), plus
  `additionalMetadata` and `additional_metadata` for `:metadata`. When
  several keys name one field, the one deepeval lists first wins (the
  camelCase alias, or `metadata`). As deepeval's `extra="ignore"`, any other
  key is dropped, so a test case exported by deepeval loads as it is.

  As in deepeval 4.3.1, `:context` and `:retrieval_context` are separate
  fields: neither stands in for the other, and each is exported only when
  set (`context` and `retrievalContext`). `:context` holds strings only;
  `:retrieval_context` also takes `DeepEvalEx.Schemas.RetrievedContextData`,
  of which the export keeps only the `:context`, as deepeval's does.

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

  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}

  @type t :: %__MODULE__{
          input: String.t(),
          actual_output: String.t() | nil,
          expected_output: String.t() | nil,
          retrieval_context: [String.t() | RetrievedContextData.t()] | nil,
          context: [String.t()] | nil,
          tools_called: [ToolCall.t()] | nil,
          expected_tools: [ToolCall.t()] | nil,
          metadata: map() | nil,
          name: String.t() | nil,
          tags: [String.t()] | nil,
          comments: String.t() | nil,
          token_cost: float() | nil,
          input_token_count: non_neg_integer() | nil,
          output_token_count: non_neg_integer() | nil,
          completion_time: float() | nil,
          flaky: boolean(),
          custom_column_key_values: %{optional(String.t()) => String.t()} | nil,
          expected_labels: %{optional(String.t()) => String.t()} | nil
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
    :custom_column_key_values,
    :expected_labels,
    :tools_called,
    :expected_tools,
    flaky: false
  ]

  @tool_call_schema ToolCall.schema()

  @tool_call_keys [:tools_called, :expected_tools]
  @float_keys [:token_cost, :completion_time]

  # deepeval 4.3.1's LLMTestCase validation aliases, in deepeval's order of
  # precedence. Keys not listed here are dropped, as deepeval's
  # extra="ignore".
  @key_aliases [
    input: ["input"],
    actual_output: ["actualOutput", "actual_output"],
    expected_output: ["expectedOutput", "expected_output"],
    context: ["context"],
    retrieval_context: ["retrievalContext", "retrieval_context"],
    metadata: ["metadata", "additionalMetadata", "additional_metadata"],
    tools_called: ["toolsCalled", "tools_called"],
    comments: ["comments"],
    expected_tools: ["expectedTools", "expected_tools"],
    token_cost: ["tokenCost", "token_cost"],
    input_token_count: ["inputTokenCount", "input_token_count"],
    output_token_count: ["outputTokenCount", "output_token_count"],
    completion_time: ["completionTime", "completion_time"],
    flaky: ["flaky"],
    name: ["name"],
    tags: ["tags"],
    custom_column_key_values: ["customColumnKeyValues", "custom_column_key_values"],
    expected_labels: ["expectedLabels", "expected_labels"]
  ]

  defschema(:test_case_schema, %{
    input: {:required, :string},
    actual_output: :string,
    expected_output: :string,
    retrieval_context: {:list, {:custom, {RetrievedContextData, :cast_item}}},
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
    flaky: {:boolean, {:default, false}},
    custom_column_key_values: {:map, :string, :string},
    expected_labels: {:map, :string, :string}
  })

  @doc """
  Creates a new test case struct.

  ## Options

  - `:input` - The input prompt (required)
  - `:actual_output` - The LLM's response
  - `:expected_output` - Expected output for comparison
  - `:retrieval_context` - List of retrieved context strings or
    `DeepEvalEx.Schemas.RetrievedContextData` structs (or maps with
    `context` and `source` keys, which are built into them)
  - `:context` - List of ground-truth context strings
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
  - `:custom_column_key_values` - Map of string column names to string values
  - `:expected_labels` - Map of string classifier names to string labels

  Keys may be atoms or strings, and may be deepeval's camelCase aliases;
  unknown keys are dropped (see "deepeval keys" above). Tool calls may be `DeepEvalEx.Schemas.ToolCall`
  structs or maps, and accept deepeval's `"inputParameters"` alias and
  `"FUNCTION"` / `"MCP"` type values.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    case test_case_schema(attrs) do
      {:ok, validated} ->
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
    string_map_schema = %{"type" => "object", "additionalProperties" => %{"type" => "string"}}

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
        "flaky" => %{"type" => "boolean"},
        "custom_column_key_values" => string_map_schema,
        "expected_labels" => string_map_schema
      },
      "required" => ["input"],
      "additionalProperties" => false
    }
  end

  @doc """
  Validates that the test case has the required parameters for a given metric,
  as deepeval 4.3.1's `check_llm_test_case_params`.

  - When `:actual_output` is required and is the empty string, returns
    `{:error, {:empty_param, :actual_output}}`, before looking for missing
    params
  - Otherwise returns `{:error, {:missing_params, params}}` with every
    required param that is `nil`, in the order given

  Only `nil` is missing: empty lists and other empty strings are present.
  Each param stands for itself, so `:context` does not satisfy
  `:retrieval_context` or the other way round.

  `DeepEvalEx.Result.error/3` renders both errors with deepeval's
  `MissingTestCaseParamsError` message.

  ## Examples

      iex> test_case = DeepEvalEx.TestCase.new!(input: "Q", actual_output: "A", context: ["c"])
      iex> DeepEvalEx.TestCase.validate_params(test_case, [:input, :actual_output, :retrieval_context])
      {:error, {:missing_params, [:retrieval_context]}}
  """
  @spec validate_params(t(), [atom()]) ::
          :ok | {:error, {:missing_params, [atom()]} | {:empty_param, :actual_output}}
  def validate_params(test_case, required_params) do
    missing = Enum.filter(required_params, &is_nil(Map.get(test_case, &1)))

    cond do
      :actual_output in required_params and Map.get(test_case, :actual_output) == "" ->
        {:error, {:empty_param, :actual_output}}

      missing != [] ->
        {:error, {:missing_params, missing}}

      true ->
        :ok
    end
  end

  # Maps deepeval's keys (atoms or strings, field names or aliases) to
  # fields, dropping the rest
  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {key_string(k), v} end)

    @key_aliases
    |> Enum.flat_map(fn {field, aliases} ->
      case Enum.find(aliases, &Map.has_key?(attrs, &1)) do
        nil -> []
        key -> [{field, Map.fetch!(attrs, key)}]
      end
    end)
    |> Map.new()
    |> normalize_tool_calls()
    |> normalize_floats()
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key

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
end
