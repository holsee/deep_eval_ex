defmodule DeepEvalEx.Schemas.ToolCall do
  @moduledoc """
  Represents a tool call made by an LLM.

  Used for evaluating agentic LLM behaviours where the model
  invokes external tools or functions. Mirrors deepeval's `ToolCall`.

  ## Fields

  - `:name` - The name of the tool called (required)
  - `:type` - The kind of tool: `:function` (default) or `:mcp`
  - `:description` - Description of the tool
  - `:reasoning` - The LLM's reasoning for calling this tool
  - `:input_parameters` - Parameters passed to the tool (a map)
  - `:output` - The result returned by the tool; any JSON term
    (string, number, boolean, list, map or `nil`)

  `new/1` accepts atom or string keys, deepeval's camelCase
  `"inputParameters"` alias, and deepeval's `"FUNCTION"` / `"MCP"`
  type values in any case.

  ## Examples

      tool_call = %DeepEvalEx.Schemas.ToolCall{
        name: "search_web",
        input_parameters: %{"query" => "weather in Paris"},
        output: %{"temp_c" => 18, "conditions" => "partly cloudy"}
      }
  """

  import Peri

  @types [:function, :mcp]

  @type tool_type :: :function | :mcp

  @type t :: %__MODULE__{
          name: String.t(),
          type: tool_type(),
          description: String.t() | nil,
          reasoning: String.t() | nil,
          input_parameters: map() | nil,
          output: any()
        }

  defstruct [:name, :description, :reasoning, :input_parameters, :output, type: :function]

  @schema %{
    name: {:required, :string},
    type: {{:enum, @types}, {:default, :function}},
    description: :string,
    reasoning: :string,
    input_parameters: :map,
    output: :any
  }

  @key_aliases %{
    "name" => :name,
    "type" => :type,
    "description" => :description,
    "reasoning" => :reasoning,
    "input_parameters" => :input_parameters,
    "inputParameters" => :input_parameters,
    "output" => :output
  }

  defschema(:tool_call_schema, @schema)

  @doc false
  # The Peri schema definition, shared with `DeepEvalEx.TestCase` for
  # validating nested tool calls.
  def schema, do: @schema

  @doc false
  def new(attrs) do
    case tool_call_schema(normalize(attrs)) do
      {:ok, validated} -> {:ok, struct(__MODULE__, validated)}
      {:error, _} = err -> err
    end
  end

  @doc false
  def changeset(attrs), do: tool_call_schema(normalize(attrs))

  @doc false
  # Converts a struct, keyword list or map (atom or string keys, deepeval
  # camelCase aliases, deepeval type strings) into the atom-keyed map the
  # schema validates. Unknown string keys are dropped.
  @spec normalize(t() | keyword() | map()) :: map()
  def normalize(%__MODULE__{} = tool_call), do: Map.from_struct(tool_call)
  def normalize(attrs) when is_list(attrs), do: normalize(Map.new(attrs))

  def normalize(attrs) when is_map(attrs) do
    attrs
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) ->
        case Map.fetch(@key_aliases, k) do
          {:ok, key} -> [{key, v}]
          :error -> []
        end

      {k, v} ->
        [{k, v}]
    end)
    |> Map.new()
    |> normalize_type()
  end

  defp normalize_type(%{type: type} = attrs) when is_binary(type) do
    case Enum.find(@types, &(Atom.to_string(&1) == String.downcase(type))) do
      nil -> attrs
      atom -> %{attrs | type: atom}
    end
  end

  defp normalize_type(attrs), do: attrs

  @doc """
  Returns the JSON schema representation for structured output requests.
  """
  def json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "type" => %{"type" => "string", "enum" => Enum.map(@types, &Atom.to_string/1)},
        "description" => %{"type" => "string"},
        "reasoning" => %{"type" => "string"},
        "input_parameters" => %{"type" => "object"},
        "output" => %{}
      },
      "required" => ["name", "type", "description", "reasoning", "input_parameters", "output"],
      "additionalProperties" => false
    }
  end
end
