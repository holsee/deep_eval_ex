defmodule DeepEvalEx.MCP do
  @moduledoc """
  Model Context Protocol (MCP) helpers, ports of deepeval 4.3.1's
  `get_available_mcp_tool_names` (`test_case/mcp.py`) and of
  `classify_tool_call_types` and `process_mcp_servers`
  (`test_case/utils.py`).

  A test case records the MCP servers its application could use
  (`DeepEvalEx.MCPServer`) and the MCP calls it made
  (`DeepEvalEx.MCPToolCall`, `DeepEvalEx.MCPResourceCall`,
  `DeepEvalEx.MCPPromptCall`). `DeepEvalEx.evaluate/3` (and
  `DeepEvalEx.evaluate_run/3`) runs `process_servers/2` over its test cases
  before evaluating them, as deepeval's `evaluate()` does: a tool call
  whose name a server lists among its available tools becomes an `:mcp`
  tool call, which the test run exports as `"type": "MCP"`.

  ## Results

  deepeval types a call's result as the `mcp` package's pydantic models
  (`CallToolResult`, `ReadResourceResult`, `GetPromptResult`). DeepEvalEx
  takes the result as plain data shaped as the MCP spec's: a map (atom or
  string keys) or a `Jason.OrderedObject`, holding a `"content"`,
  `"contents"` or `"messages"` list. It is kept, and dumped, as it is
  given; pass a `Jason.OrderedObject` to keep its keys in order.

  deepeval's `normalize_mcp_servers`, which reads the tools, resources and
  prompts of a server from the official `mcp` SDK, has no counterpart:
  list them on a `DeepEvalEx.MCPServer` instead.
  """

  alias DeepEvalEx.{ConversationalTestCase, MCPServer, TestCase, Turn}
  alias DeepEvalEx.Schemas.ToolCall

  @typedoc """
  An MCP call's result, plain data shaped as the MCP spec's result (see
  "Results" above).
  """
  @type result :: map()

  @doc """
  The names of the tools the servers make available, deepeval's
  `get_available_mcp_tool_names`: each `:available_tools` map's `"name"`
  (or `:name`), when set.

  ## Examples

      iex> server = DeepEvalEx.MCPServer.new!(server_name: "weather", available_tools: [%{"name" => "get_weather"}])
      iex> DeepEvalEx.MCP.available_tool_names([server])
      MapSet.new(["get_weather"])
  """
  @spec available_tool_names([MCPServer.t()]) :: MapSet.t(String.t())
  def available_tool_names(servers) when is_list(servers) do
    for %MCPServer{available_tools: tools} <- servers,
        tool <- tools || [],
        name = tool_name(tool),
        name not in [nil, ""],
        into: MapSet.new(),
        do: name
  end

  defp tool_name(tool), do: get(tool, :name)

  @doc """
  Marks the tool calls named in `mcp_tool_names` as `:mcp`, deepeval's
  `classify_tool_call_types`; the others are left as they are. `nil` stays
  `nil`.

  ## Examples

      iex> alias DeepEvalEx.Schemas.ToolCall
      iex> [add, search] = [%ToolCall{name: "add"}, %ToolCall{name: "search"}]
      iex> DeepEvalEx.MCP.classify_tool_call_types([add, search], MapSet.new(["add"]))
      [%ToolCall{name: "add", type: :mcp}, %ToolCall{name: "search", type: :function}]
  """
  @spec classify_tool_call_types([ToolCall.t()] | nil, MapSet.t(String.t())) ::
          [ToolCall.t()] | nil
  def classify_tool_call_types(nil, _mcp_tool_names), do: nil

  def classify_tool_call_types(tools_called, mcp_tool_names) when is_list(tools_called) do
    Enum.map(tools_called, fn %ToolCall{} = tool_call ->
      if MapSet.member?(mcp_tool_names, tool_call.name),
        do: %{tool_call | type: :mcp},
        else: tool_call
    end)
  end

  @doc """
  The test cases with their MCP tool calls marked, deepeval's
  `process_mcp_servers`.

  Each test case uses its own `:mcp_servers`, or `servers` when it has none
  (`nil` or `[]`), and keeps them as its `:mcp_servers`. When they list any
  tools, `classify_tool_call_types/2` marks the `:tools_called` and
  `:expected_tools` of a `DeepEvalEx.TestCase`, and each turn's
  `:tools_called` of a `DeepEvalEx.ConversationalTestCase`. A test case
  with no servers is returned as it is.

  `servers` may be `DeepEvalEx.MCPServer`s or the attributes
  `DeepEvalEx.MCPServer.new/1` takes; invalid ones raise `ArgumentError`,
  as deepeval's `validate_mcp_servers` raises `TypeError`.

  ## Examples

      iex> alias DeepEvalEx.{MCP, TestCase}
      iex> test_case = TestCase.new!(input: "2 + 3?", tools_called: [%{name: "add"}])
      iex> [processed] = MCP.process_servers([test_case], [%{server_name: "calc", available_tools: [%{name: "add"}]}])
      iex> hd(processed.tools_called).type
      :mcp
  """
  @spec process_servers([test_case], [MCPServer.t() | map() | keyword()] | nil) :: [test_case]
        when test_case: TestCase.t() | ConversationalTestCase.t()
  def process_servers(test_cases, servers \\ nil) when is_list(test_cases) do
    servers = servers && Enum.map(servers, &MCPServer.new!/1)
    Enum.map(test_cases, &process_test_case(&1, servers))
  end

  defp process_test_case(test_case, servers) do
    case test_case.mcp_servers || [] do
      [] when servers in [nil, []] -> test_case
      [] -> classify(%{test_case | mcp_servers: servers})
      _own -> classify(test_case)
    end
  end

  defp classify(test_case) do
    names = available_tool_names(test_case.mcp_servers)

    if MapSet.size(names) == 0,
      do: test_case,
      else: classify(test_case, names)
  end

  defp classify(%TestCase{} = test_case, names) do
    %{
      test_case
      | tools_called: classify_tool_call_types(test_case.tools_called, names),
        expected_tools: classify_tool_call_types(test_case.expected_tools, names)
    }
  end

  defp classify(%ConversationalTestCase{} = test_case, names) do
    turns =
      Enum.map(test_case.turns, fn %Turn{} = turn ->
        %{turn | tools_called: classify_tool_call_types(turn.tools_called, names)}
      end)

    %{test_case | turns: turns}
  end

  @doc false
  # The value of `key` in a map with string or atom keys (the string key
  # first), or in a Jason.OrderedObject.
  @spec get(term(), atom()) :: term()
  def get(%Jason.OrderedObject{} = object, key), do: object[Atom.to_string(key)]

  def get(map, key) when is_map(map) and not is_struct(map) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  def get(_other, _key), do: nil

  @doc false
  # Whether `value` is JSON object data: a plain map or a
  # Jason.OrderedObject.
  @spec object?(term()) :: boolean()
  def object?(%Jason.OrderedObject{}), do: true
  def object?(value), do: is_map(value) and not is_struct(value)

  @doc false
  # The given attributes (a keyword list or a map with atom or string keys)
  # as a map of the known string `keys`; any other key is dropped, as
  # pydantic's extra="ignore". Returns :error for anything else.
  @spec take_keys(term(), [String.t()]) :: {:ok, %{String.t() => term()}} | :error
  def take_keys(attrs, keys) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: take_keys(Map.new(attrs), keys), else: :error
  end

  def take_keys(attrs, keys) when is_map(attrs) and not is_struct(attrs) do
    taken =
      for {key, value} <- attrs,
          key = if(is_atom(key), do: Atom.to_string(key), else: key),
          key in keys,
          into: %{},
          do: {key, value}

    {:ok, taken}
  end

  def take_keys(_attrs, _keys), do: :error

  @doc false
  # Checks that `result` is a spec-shaped MCP result: object data holding
  # a `list_key` list.
  @spec check_result(term(), atom(), String.t()) :: :ok | {:error, String.t()}
  def check_result(result, list_key, result_type) do
    if object?(result) and is_list(get(result, list_key)) do
      :ok
    else
      {:error,
       "'result' must be a #{result_type}: a map holding a \"#{list_key}\" list, got " <>
         inspect(result)}
    end
  end
end
