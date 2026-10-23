defmodule DeepEvalEx.Tracing.Fields do
  @moduledoc false
  # Validation shared by `DeepEvalEx.Tracing.Span` and
  # `DeepEvalEx.Tracing.Trace`: their common Peri field types, metric specs,
  # tool calls and pydantic's float coercion.

  alias DeepEvalEx.Schemas.ToolCall

  @statuses [:in_progress, :success, :errored]

  @tool_call_schema ToolCall.schema()

  @tool_call_keys [:tools_called, :expected_tools]

  @doc false
  def statuses, do: @statuses

  @doc false
  # deepeval's TraceSpanStatus values.
  def status_value(:in_progress), do: "IN_PROGRESS"
  def status_value(:success), do: "SUCCESS"
  def status_value(:errored), do: "ERRORED"

  @doc false
  # The five test-case parameters Span and Trace share, with Peri types.
  def test_case_params do
    %{
      retrieval_context: {:list, :string},
      context: {:list, :string},
      expected_output: :string,
      tools_called: {:list, @tool_call_schema},
      expected_tools: {:list, @tool_call_schema}
    }
  end

  @doc false
  # A metric spec: a metric module, `{module, keyword}` or a metric struct.
  def cast_metric(metric) when is_atom(metric) and metric not in [nil, true, false], do: :ok
  def cast_metric({module, opts}) when is_atom(module) and is_list(opts), do: cast_opts(opts)
  def cast_metric(metric) when is_struct(metric), do: :ok

  def cast_metric(metric),
    do:
      {:error, "expected a metric module, {module, keyword} or metric struct, got %{value}",
       [value: inspect(metric)]}

  defp cast_opts(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, "expected keyword options, got %{value}", [value: inspect(opts)]}
  end

  @doc false
  # pydantic's lax float: an integer becomes a float, as `Optional[float]`.
  def to_floats(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        int when is_integer(int) -> Map.put(acc, key, int * 1.0)
        _ -> acc
      end
    end)
  end

  @doc false
  # Tool calls as the maps `ToolCall.schema/0` validates, from maps or structs.
  def normalize_tool_calls(attrs) do
    Enum.reduce(@tool_call_keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        tools when is_list(tools) -> Map.put(acc, key, Enum.map(tools, &normalize_tool_call/1))
        _ -> acc
      end
    end)
  end

  defp normalize_tool_call(tool) when is_map(tool) or is_list(tool), do: ToolCall.normalize(tool)
  defp normalize_tool_call(tool), do: tool

  @doc false
  # Validated tool-call maps back into `ToolCall` structs.
  def convert_tool_calls(validated) do
    Enum.reduce(@tool_call_keys, validated, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        tools -> Map.put(acc, key, Enum.map(tools, &struct(ToolCall, &1)))
      end
    end)
  end

  @doc false
  # Python truthiness: None, False, zero, and empty strings, lists and dicts
  # are false.
  def truthy?(value) when value in [nil, false, "", []], do: false
  def truthy?(value) when is_number(value) and value == 0, do: false
  def truthy?(%Jason.OrderedObject{values: []}), do: false
  def truthy?(%MapSet{} = set), do: MapSet.size(set) > 0
  def truthy?(value) when is_map(value) and not is_struct(value), do: map_size(value) > 0
  def truthy?(_value), do: true

  @doc false
  # A keyword list or map as an atom-keyed map.
  def to_map(attrs) when is_list(attrs), do: Map.new(attrs)
  def to_map(attrs) when is_map(attrs), do: attrs
end
