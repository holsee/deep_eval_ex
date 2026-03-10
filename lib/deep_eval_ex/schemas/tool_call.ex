defmodule DeepEvalEx.Schemas.ToolCall do
  @moduledoc """
  Represents a tool call made by an LLM.

  Used for evaluating agentic LLM behaviours where the model
  invokes external tools or functions.

  ## Fields

  - `:name` - The name of the tool called (required)
  - `:description` - Description of the tool
  - `:reasoning` - The LLM's reasoning for calling this tool
  - `:input_parameters` - Parameters passed to the tool
  - `:output` - The result returned by the tool

  ## Examples

      tool_call = %DeepEvalEx.Schemas.ToolCall{
        name: "search_web",
        input_parameters: %{"query" => "weather in Paris"},
        output: "Current weather in Paris: 18°C, partly cloudy"
      }
  """

  import Peri

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          reasoning: String.t() | nil,
          input_parameters: map() | nil,
          output: any()
        }

  defstruct [:name, :description, :reasoning, :input_parameters, :output]

  defschema(:tool_call_schema, %{
    name: {:required, :string},
    description: :string,
    reasoning: :string,
    input_parameters: :map,
    output: :string
  })

  @doc false
  def new(attrs) do
    case tool_call_schema(to_map(attrs)) do
      {:ok, validated} -> {:ok, struct(__MODULE__, validated)}
      {:error, _} = err -> err
    end
  end

  @doc false
  def changeset(attrs), do: tool_call_schema(to_map(attrs))

  @doc """
  Returns the JSON schema representation for structured output requests.
  """
  def json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "reasoning" => %{"type" => "string"},
        "input_parameters" => %{"type" => "object"},
        "output" => %{"type" => "string"}
      },
      "required" => ["name", "description", "reasoning", "input_parameters", "output"],
      "additionalProperties" => false
    }
  end

  defp to_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp to_map(attrs) when is_map(attrs), do: attrs
end
