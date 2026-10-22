defmodule DeepEvalEx.Dataset.Golden do
  @moduledoc """
  A single-turn golden: the input of a test case and what it should produce,
  before the LLM application under test has run. deepeval 4.3.1's `Golden`
  (`dataset/golden.py`).

  A dataset holds goldens; running the application over each golden's
  `:input` fills in the `:actual_output` and turns it into a
  `DeepEvalEx.TestCase` (`to_test_case/1`).

  ## Fields

  - `:input` - The input to the application (required)
  - `:actual_output` - The application's output, when already known
  - `:expected_output` - The ideal output
  - `:context` - Ideal, ground-truth context for the input (strings)
  - `:retrieval_context` - Retrieved context, strings or
    `DeepEvalEx.Schemas.RetrievedContextData` structs, in any mix
  - `:additional_metadata` - A map of metadata; the test case's `:metadata`
  - `:comments` - Free-text comments
  - `:tools_called` - Tool calls made (`DeepEvalEx.Schemas.ToolCall`)
  - `:expected_tools` - Tool calls expected
  - `:token_cost` - Cost of producing `:actual_output` (float)
  - `:input_token_count` - Input tokens consumed (integer)
  - `:output_token_count` - Output tokens produced (integer)
  - `:source_file` - The file the golden was generated from
  - `:name` - A name identifying the golden
  - `:custom_column_key_values` - Custom columns, a map of string keys to
    string values
  - `:expectations` - Required and prohibited behaviour, plain data as
    `DeepEvalEx.Dataset.Expectations` describes
  - `:expected_labels` - The label each classifier should give, a map of
    classifier name to label (both strings)

  deepeval's Confident AI `id`, its multimodal image fields and its private
  dataset attributes are not ported.

  ## deepeval keys

  `new/1` accepts the keys deepeval's `Golden` validates, as atoms or
  strings: each field name, and the camelCase aliases `tokenCost`,
  `inputTokenCount`, `outputTokenCount` and `expectedLabels`, which win
  over the field name when both are given. deepeval declares the other
  camelCase names (`actualOutput`, `expectedOutput`, `retrievalContext`,
  `additionalMetadata`, `toolsCalled`, `expectedTools`, `sourceFile`,
  `customColumnKeyValues`) for serialisation only, so `Golden(actualOutput=...)`
  ignores them; so does `new/1`, which drops every key it does not know, as
  deepeval's `extra="ignore"`.

  ## Examples

      iex> alias DeepEvalEx.Dataset.Golden
      iex> golden = Golden.new!(input: "What is the capital of France?", expected_output: "Paris")
      iex> test_case = Golden.to_test_case(%{golden | actual_output: "Paris."})
      iex> {test_case.input, test_case.actual_output, test_case.expected_output}
      {"What is the capital of France?", "Paris.", "Paris"}
  """

  import Peri

  alias DeepEvalEx.Dataset.Expectations
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestCase

  @type t :: %__MODULE__{
          input: String.t(),
          actual_output: String.t() | nil,
          expected_output: String.t() | nil,
          context: [String.t()] | nil,
          retrieval_context: [String.t() | RetrievedContextData.t()] | nil,
          additional_metadata: map() | nil,
          comments: String.t() | nil,
          tools_called: [ToolCall.t()] | nil,
          expected_tools: [ToolCall.t()] | nil,
          token_cost: float() | nil,
          input_token_count: integer() | nil,
          output_token_count: integer() | nil,
          source_file: String.t() | nil,
          name: String.t() | nil,
          custom_column_key_values: %{optional(String.t()) => String.t()} | nil,
          expectations: Expectations.t() | nil,
          expected_labels: %{optional(String.t()) => String.t()} | nil
        }

  defstruct [
    :input,
    :actual_output,
    :expected_output,
    :context,
    :retrieval_context,
    :additional_metadata,
    :comments,
    :tools_called,
    :expected_tools,
    :token_cost,
    :input_token_count,
    :output_token_count,
    :source_file,
    :name,
    :custom_column_key_values,
    :expectations,
    :expected_labels
  ]

  @tool_call_schema ToolCall.schema()

  @tool_call_keys [:tools_called, :expected_tools]

  # deepeval 4.3.1's Golden validation keys, in its order of precedence.
  # Keys not listed here are dropped, as deepeval's extra="ignore".
  @key_aliases [
    input: ["input"],
    actual_output: ["actual_output"],
    expected_output: ["expected_output"],
    context: ["context"],
    retrieval_context: ["retrieval_context"],
    additional_metadata: ["additional_metadata"],
    comments: ["comments"],
    tools_called: ["tools_called"],
    expected_tools: ["expected_tools"],
    token_cost: ["tokenCost", "token_cost"],
    input_token_count: ["inputTokenCount", "input_token_count"],
    output_token_count: ["outputTokenCount", "output_token_count"],
    source_file: ["source_file"],
    name: ["name"],
    custom_column_key_values: ["custom_column_key_values"],
    expectations: ["expectations"],
    expected_labels: ["expectedLabels", "expected_labels"]
  ]

  defschema(:golden_schema, %{
    input: {:required, :string},
    actual_output: :string,
    expected_output: :string,
    context: {:list, :string},
    retrieval_context: {:list, {:custom, {RetrievedContextData, :cast_item}}},
    additional_metadata: :map,
    comments: :string,
    tools_called: {:list, @tool_call_schema},
    expected_tools: {:list, @tool_call_schema},
    token_cost: :float,
    input_token_count: :integer,
    output_token_count: :integer,
    source_file: :string,
    name: :string,
    custom_column_key_values: {:map, :string, :string},
    expectations: {:custom, {Expectations, :cast}},
    expected_labels: {:map, :string, :string}
  })

  @doc """
  Creates a golden from a keyword list or map.

  Keys may be atoms or strings, and may be the camelCase aliases deepeval
  validates (see "deepeval keys" above). `:token_cost` takes an integer
  and casts it to a float. Tool calls may be `DeepEvalEx.Schemas.ToolCall`
  structs or maps, which accept deepeval's `"inputParameters"` alias and
  `"FUNCTION"` / `"MCP"` type values. Retrieval context items may be maps
  with `context` and `source` keys, which are built into
  `DeepEvalEx.Schemas.RetrievedContextData`. `:expectations` is validated
  by `DeepEvalEx.Dataset.Expectations.cast/1`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    case attrs |> normalize_attrs() |> golden_schema() do
      {:ok, validated} -> {:ok, struct(__MODULE__, convert_tool_calls(validated))}
      {:error, _} = err -> err
    end
  end

  @doc """
  Creates a golden, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, golden} -> golden
      {:error, errors} -> raise "Invalid golden: #{inspect(errors)}"
    end
  end

  @doc """
  Converts a golden into a test case, as one golden of deepeval's
  `convert_goldens_to_test_cases`.

  `:additional_metadata` becomes the test case's `:metadata`; the other
  fields keep their names. `:source_file` and `:custom_column_key_values`
  are left out, as deepeval leaves them out.
  """
  @spec to_test_case(t()) :: TestCase.t()
  def to_test_case(%__MODULE__{} = golden) do
    %TestCase{
      input: golden.input,
      actual_output: golden.actual_output,
      expected_output: golden.expected_output,
      context: golden.context,
      retrieval_context: golden.retrieval_context,
      tools_called: golden.tools_called,
      expected_tools: golden.expected_tools,
      token_cost: golden.token_cost,
      input_token_count: golden.input_token_count,
      output_token_count: golden.output_token_count,
      name: golden.name,
      comments: golden.comments,
      metadata: golden.additional_metadata,
      expected_labels: golden.expected_labels,
      expectations: golden.expectations
    }
  end

  @doc """
  Converts a test case into a golden, as one test case of deepeval's
  `convert_test_cases_to_goldens`.

  The test case's `:metadata` becomes `:additional_metadata`, and the
  retrieval context is kept as it is, `DeepEvalEx.Schemas.RetrievedContextData`
  included. As deepeval, the golden does not keep the test case's `:name`,
  `:comments`, `:tags`, `:completion_time`, `:flaky`, `:expected_labels` or
  `:custom_column_key_values`.
  """
  @spec from_test_case(TestCase.t()) :: t()
  def from_test_case(%TestCase{} = test_case) do
    %__MODULE__{
      input: test_case.input,
      actual_output: test_case.actual_output,
      expected_output: test_case.expected_output,
      context: test_case.context,
      retrieval_context: test_case.retrieval_context,
      tools_called: test_case.tools_called,
      expected_tools: test_case.expected_tools,
      token_cost: test_case.token_cost,
      input_token_count: test_case.input_token_count,
      output_token_count: test_case.output_token_count,
      additional_metadata: test_case.metadata,
      expectations: test_case.expectations
    }
  end

  @doc """
  Converts goldens into test cases, in order, as deepeval's
  `convert_goldens_to_test_cases` (see `to_test_case/1`).
  """
  @spec convert_goldens_to_test_cases([t()]) :: [TestCase.t()]
  def convert_goldens_to_test_cases(goldens), do: Enum.map(goldens, &to_test_case/1)

  @doc """
  Converts test cases into goldens, in order, as deepeval's
  `convert_test_cases_to_goldens` (see `from_test_case/1`).
  """
  @spec convert_test_cases_to_goldens([TestCase.t()]) :: [t()]
  def convert_test_cases_to_goldens(test_cases), do: Enum.map(test_cases, &from_test_case/1)

  # Maps deepeval's keys (atoms or strings, field names or aliases) to
  # fields, dropping the rest
  defp normalize_attrs(attrs) do
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
    |> normalize_token_cost()
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key

  defp normalize_tool_calls(attrs) do
    Enum.reduce(@tool_call_keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        tools when is_list(tools) -> Map.put(acc, key, Enum.map(tools, &normalize_tool_call/1))
        _ -> acc
      end
    end)
  end

  defp normalize_tool_call(tool) when is_map(tool) or is_list(tool), do: ToolCall.normalize(tool)
  defp normalize_tool_call(tool), do: tool

  # deepeval (pydantic) accepts an int for the float token_cost
  defp normalize_token_cost(%{token_cost: cost} = attrs) when is_integer(cost),
    do: %{attrs | token_cost: cost / 1}

  defp normalize_token_cost(attrs), do: attrs

  defp convert_tool_calls(validated) do
    Enum.reduce(@tool_call_keys, validated, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        tools -> Map.put(acc, key, Enum.map(tools, &struct(ToolCall, &1)))
      end
    end)
  end
end
