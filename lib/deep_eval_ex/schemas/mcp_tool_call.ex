defmodule DeepEvalEx.MCPToolCall do
  @moduledoc """
  A call to an MCP server's tool, deepeval 4.3.1's `MCPToolCall`
  (`test_case/mcp.py`), as a test case's or turn's `:mcp_tools_called`.

  ## Fields

  - `:name` - The tool's name (required)
  - `:args` - The arguments it was called with, a map (required)
  - `:result` - What it returned, shaped as the MCP spec's
    `CallToolResult`: a map holding a `"content"` list, and optionally
    `"structuredContent"` and `"isError"` (required, see "Results" in
    `DeepEvalEx.MCP`)

  ## Examples

      iex> {:ok, call} =
      ...>   DeepEvalEx.MCPToolCall.new(
      ...>     name: "get_weather",
      ...>     args: %{"city" => "Paris"},
      ...>     result: %{"content" => [%{"type" => "text", "text" => "18°C"}], "isError" => false}
      ...>   )
      iex> call.name
      "get_weather"
  """

  alias DeepEvalEx.MCP
  alias Jason.OrderedObject

  @type t :: %__MODULE__{name: String.t(), args: map(), result: MCP.result()}

  @enforce_keys [:name, :args, :result]
  defstruct [:name, :args, :result]

  @doc """
  Builds a tool call from a keyword list or a map with atom or string keys;
  other keys are dropped. Returns `{:error, message}` when `:name` is not a
  string, `:args` not a map, or `:result` not a `CallToolResult`-shaped map.
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = call), do: {:ok, call}

  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         :ok <- check_name(attrs["name"]),
         :ok <- check_args(attrs["args"]),
         :ok <- MCP.check_result(attrs["result"], :content, "CallToolResult") do
      {:ok, %__MODULE__{name: attrs["name"], args: attrs["args"], result: attrs["result"]}}
    end
  end

  @doc """
  Builds a tool call like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, call} -> call
      {:error, message} -> raise ArgumentError, "Invalid MCP tool call: " <> message
    end
  end

  @doc """
  The call as deepeval's `model_dump()` gives it: `name`, `args` and
  `result`, the args and result as given.
  """
  @spec model_dump(t()) :: OrderedObject.t()
  def model_dump(%__MODULE__{} = call) do
    OrderedObject.new([{"name", call.name}, {"args", call.args}, {"result", call.result}])
  end

  @doc false
  # Peri custom validator for one of a test case's or turn's
  # :mcp_tools_called.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t(), keyword()}
  def cast(value) do
    case new(value) do
      {:ok, call} -> {:ok, call}
      {:error, message} -> {:error, "%{message}", [message: message]}
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, ~w(name args result)) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error,
         "'mcp_tools_called' must be a list of MCPToolCall, or of the attributes " <>
           "MCPToolCall.new/1 takes, got " <> inspect(attrs)}
    end
  end

  defp check_name(name) when is_binary(name), do: :ok
  defp check_name(name), do: {:error, "'name' must be a string, got #{inspect(name)}"}

  defp check_args(args) do
    if MCP.object?(args), do: :ok, else: {:error, "'args' must be a map, got #{inspect(args)}"}
  end
end
