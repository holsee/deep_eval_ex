defmodule DeepEvalEx.MCPPromptCall do
  @moduledoc """
  A request for an MCP server's prompt, deepeval 4.3.1's `MCPPromptCall`
  (`test_case/mcp.py`), as a test case's or turn's `:mcp_prompts_called`.

  ## Fields

  - `:name` - The prompt's name (required)
  - `:result` - What the server returned, shaped as the MCP spec's
    `GetPromptResult`: a map holding a `"messages"` list, and optionally a
    `"description"` (required, see "Results" in `DeepEvalEx.MCP`)

  ## Examples

      iex> {:ok, call} =
      ...>   DeepEvalEx.MCPPromptCall.new(%{
      ...>     "name" => "forecast",
      ...>     "result" => %{"messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hi"}}]}
      ...>   })
      iex> call.name
      "forecast"
  """

  alias DeepEvalEx.MCP
  alias Jason.OrderedObject

  @type t :: %__MODULE__{name: String.t(), result: MCP.result()}

  @enforce_keys [:name, :result]
  defstruct [:name, :result]

  @doc """
  Builds a prompt call from a keyword list or a map with atom or string
  keys; other keys are dropped. Returns `{:error, message}` when `:name` is
  not a string or `:result` not a `GetPromptResult`-shaped map.
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = call), do: {:ok, call}

  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         :ok <- check_name(attrs["name"]),
         :ok <- MCP.check_result(attrs["result"], :messages, "GetPromptResult") do
      {:ok, %__MODULE__{name: attrs["name"], result: attrs["result"]}}
    end
  end

  @doc """
  Builds a prompt call like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, call} -> call
      {:error, message} -> raise ArgumentError, "Invalid MCP prompt call: " <> message
    end
  end

  @doc """
  The call as deepeval's `model_dump()` gives it: `name` and `result`, the
  result as given.
  """
  @spec model_dump(t()) :: OrderedObject.t()
  def model_dump(%__MODULE__{} = call),
    do: OrderedObject.new([{"name", call.name}, {"result", call.result}])

  @doc false
  # Peri custom validator for one of a test case's or turn's
  # :mcp_prompts_called.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t(), keyword()}
  def cast(value) do
    case new(value) do
      {:ok, call} -> {:ok, call}
      {:error, message} -> {:error, "%{message}", [message: message]}
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, ~w(name result)) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error,
         "'mcp_prompts_called' must be a list of MCPPromptCall, or of the attributes " <>
           "MCPPromptCall.new/1 takes, got " <> inspect(attrs)}
    end
  end

  defp check_name(name) when is_binary(name), do: :ok
  defp check_name(name), do: {:error, "'name' must be a string, got #{inspect(name)}"}
end
