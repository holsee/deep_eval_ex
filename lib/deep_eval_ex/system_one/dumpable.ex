defprotocol DeepEvalEx.SystemOne.Dumpable do
  @moduledoc """
  How a struct is sent in a System One state, pydantic's
  `model_dump(mode="json", exclude_none=True)` as deepeval 4.3.1 dumps a
  test case field (`_field` in `deepeval/metrics/jev_eval/utils.py`): its
  fields by name, in declaration order, with `nil` fields left out, so a
  System One model reads a `ToolCall`'s `output` as data rather than as
  its `repr()`.

  `dump/1` returns a JSON-ready term or one `DeepEvalEx.SystemOne.State.dump/1`
  finishes, such as a `Jason.OrderedObject` whose values are other structs.
  `DeepEvalEx.Schemas.ToolCall` and the MCP calls
  (`DeepEvalEx.MCPToolCall`, `DeepEvalEx.MCPResourceCall`,
  `DeepEvalEx.MCPPromptCall`) implement it, and `DeepEvalEx.MCPServer`,
  a dataclass deepeval sends as its `str()`, as its Python `repr()`. A
  struct without an
  implementation is sent as text, deepeval's `str(value)` fallback: its
  `to_string/1` when it implements `String.Chars` (a `Date`), else its
  `inspect/1`.

  ## Examples

      defimpl DeepEvalEx.SystemOne.Dumpable, for: MyApp.Document do
        def dump(document),
          do: Jason.OrderedObject.new([{"title", document.title}, {"body", document.body}])
      end
  """

  @fallback_to_any true

  @doc "The struct as a System One state sends it, see the moduledoc."
  @spec dump(t()) :: term()
  def dump(value)
end

defimpl DeepEvalEx.SystemOne.Dumpable, for: DeepEvalEx.Schemas.ToolCall do
  # deepeval's ToolCall field order; `type` serialises as its enum value.
  def dump(tool_call) do
    [
      {"name", tool_call.name},
      {"type", tool_call.type && tool_call.type |> Atom.to_string() |> String.upcase()},
      {"description", tool_call.description},
      {"reasoning", tool_call.reasoning},
      {"output", tool_call.output},
      {"input_parameters", tool_call.input_parameters}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
  end
end

defimpl DeepEvalEx.SystemOne.Dumpable,
  for: [DeepEvalEx.MCPToolCall, DeepEvalEx.MCPResourceCall, DeepEvalEx.MCPPromptCall] do
  # model_dump(mode="json", exclude_none=True): every field is set.
  def dump(call), do: @for.model_dump(call)
end

defimpl DeepEvalEx.SystemOne.Dumpable, for: DeepEvalEx.MCPServer do
  # deepeval's _jsonable sends a dataclass as str(), its repr().
  def dump(server), do: DeepEvalEx.Prompts.Python.repr(server)
end

defimpl DeepEvalEx.SystemOne.Dumpable, for: Any do
  def dump(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end
end
