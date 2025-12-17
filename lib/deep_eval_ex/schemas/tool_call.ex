defmodule DeepEvalEx.Schemas.ToolCall do
  @moduledoc """
  Represents a tool call made by an LLM.

  Used for evaluating agentic LLM behaviors where the model
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

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          reasoning: String.t() | nil,
          input_parameters: map() | nil,
          output: any()
        }

  @primary_key false
  embedded_schema do
    field :name, :string
    field :description, :string
    field :reasoning, :string
    field :input_parameters, :map
    field :output, :string
  end

  @doc false
  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:name, :description, :reasoning, :input_parameters, :output])
    |> validate_required([:name])
  end
end
