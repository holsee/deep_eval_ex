defmodule DeepEvalEx.MCPServer do
  @moduledoc """
  An MCP server a test case's application could use, deepeval 4.3.1's
  `MCPServer` (`test_case/mcp.py`).

  A `DeepEvalEx.TestCase` or `DeepEvalEx.ConversationalTestCase` lists its
  servers as `:mcp_servers`, and `DeepEvalEx.evaluate/3` takes servers for
  every test case as its `:mcp_servers` option. A tool call named after one
  of a server's available tools is an MCP tool call (see
  `DeepEvalEx.MCP.process_servers/2`).

  ## Fields

  - `:server_name` - The server's name (required)
  - `:transport` - How the application reaches it: `:stdio`, `:sse` or
    `:streamable_http` (deepeval's `"stdio"`, `"sse"` and
    `"streamable-http"`), or `nil`
  - `:available_tools` - The tools it offers, as the MCP spec's tool
    objects (maps with at least a `"name"`), or `nil`
  - `:available_resources` - The resources it offers, as maps, or `nil`
  - `:available_prompts` - The prompts it offers, as maps, or `nil`

  As deepeval's `validate_mcp_servers` with no `mcp` package installed,
  the available tools, resources and prompts must each be `nil` or a list
  of maps (a map with atom or string keys, or a `Jason.OrderedObject`);
  they are kept as given.

  ## Examples

      iex> {:ok, server} =
      ...>   DeepEvalEx.MCPServer.new(%{
      ...>     "server_name" => "weather",
      ...>     "transport" => "streamable-http",
      ...>     "available_tools" => [%{"name" => "get_weather"}]
      ...>   })
      iex> {server.server_name, server.transport}
      {"weather", :streamable_http}
  """

  alias DeepEvalEx.MCP

  @type transport :: :stdio | :sse | :streamable_http

  @type t :: %__MODULE__{
          server_name: String.t(),
          transport: transport() | nil,
          available_tools: [map()] | nil,
          available_resources: [map()] | nil,
          available_prompts: [map()] | nil
        }

  @enforce_keys [:server_name]
  defstruct [
    :server_name,
    :transport,
    :available_tools,
    :available_resources,
    :available_prompts
  ]

  @transports %{"stdio" => :stdio, "sse" => :sse, "streamable-http" => :streamable_http}
  @transport_names Map.new(@transports, fn {name, atom} -> {atom, name} end)

  @keys ~w(server_name transport available_tools available_resources available_prompts)
  @lists ~w(available_tools available_resources available_prompts)

  @doc """
  Builds a server from a keyword list or a map with atom or string keys;
  other keys are dropped. `:transport` may be an atom or deepeval's string.

  Returns `{:error, message}` when `:server_name` is not a string, the
  transport is not one of the three, or an available list is not a list of
  maps (deepeval's `validate_mcp_servers` messages).
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = server), do: {:ok, server}

  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         :ok <- check_name(attrs["server_name"]),
         {:ok, transport} <- cast_transport(attrs["transport"]),
         :ok <- check_lists(attrs) do
      {:ok,
       %__MODULE__{
         server_name: attrs["server_name"],
         transport: transport,
         available_tools: attrs["available_tools"],
         available_resources: attrs["available_resources"],
         available_prompts: attrs["available_prompts"]
       }}
    end
  end

  @doc """
  Builds a server like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, server} -> server
      {:error, message} -> raise ArgumentError, "Invalid MCP server: " <> message
    end
  end

  @doc """
  deepeval's name for a transport: `"stdio"`, `"sse"`, `"streamable-http"`,
  or `nil`.

  ## Examples

      iex> DeepEvalEx.MCPServer.transport_name(:streamable_http)
      "streamable-http"
  """
  @spec transport_name(transport() | nil) :: String.t() | nil
  def transport_name(nil), do: nil
  def transport_name(transport), do: Map.fetch!(@transport_names, transport)

  @doc false
  # Peri custom validator for one of a test case's :mcp_servers.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t(), keyword()}
  def cast(value) do
    case new(value) do
      {:ok, server} -> {:ok, server}
      {:error, message} -> {:error, "%{message}", [message: message]}
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, @keys) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error,
         "'mcp_servers' must be a list of MCPServer, or of the attributes " <>
           "MCPServer.new/1 takes, got " <> inspect(attrs)}
    end
  end

  defp check_name(name) when is_binary(name), do: :ok
  defp check_name(name), do: {:error, "'server_name' must be a string, got #{inspect(name)}"}

  defp cast_transport(nil), do: {:ok, nil}
  defp cast_transport(atom) when is_map_key(@transport_names, atom), do: {:ok, atom}
  defp cast_transport(name) when is_map_key(@transports, name), do: {:ok, @transports[name]}

  defp cast_transport(other) do
    {:error, "'transport' must be 'stdio', 'sse' or 'streamable-http', got #{inspect(other)}"}
  end

  defp check_lists(attrs) do
    Enum.find_value(@lists, :ok, &check_list(&1, attrs[&1]))
  end

  defp check_list(_field, nil), do: nil
  defp check_list(field, items) when not is_list(items), do: {:error, "'#{field}' must be a list"}

  defp check_list(field, items) do
    unless Enum.all?(items, &MCP.object?/1),
      do: {:error, "'#{field}' must be a list of dicts"}
  end
end
