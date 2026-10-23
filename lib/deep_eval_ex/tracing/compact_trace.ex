defmodule DeepEvalEx.Tracing.CompactTrace do
  @moduledoc """
  A nested trace dict as a System One model reads it: deepeval 4.3.1's
  `compact_trace` (`metrics/utils/system_one.py`), which the trace metrics
  send as the `trace` of their System One state.

  `compact/1` keeps each span's name, type, inputs, outputs and tool
  calls, and drops token counts, costs, prompts and integration details,
  which say nothing about whether the agent did its job:

  - only the keys of deepeval's `_TRACE_SPAN_KEYS` are kept, in its order:
    `name`, `type`, `description`, `input`, `output`, `error`, `model`,
    `retrieval_context`, `context`, `expected_output`, `tools_called`,
    `expected_tools`, `available_tools` and `agent_handoffs`;
  - a value that is `nil`, `[]` or `""` is left out, other falsy ones
    (`%{}`, `0`, `false`) kept;
  - `children` comes last, each child compacted, and is left out when
    there are none;
  - values are made JSON-ready as deepeval's `_jsonable`: strings,
    numbers, booleans and `nil` are kept, maps and `Jason.OrderedObject`s
    become `Jason.OrderedObject`s with keys as Python's `str()` prints
    them, lists and tuples become lists, and anything else becomes its
    Python `str()`: a `DeepEvalEx.Schemas.ToolCall` as
    `DeepEvalEx.Prompts.Python.str/1` prints it, other atoms by name, and
    another struct as its `to_string/1` when it implements `String.Chars`,
    else its `inspect/1`, as `DeepEvalEx.SystemOne.Dumpable` falls back.

  A term that is not a dict is returned as it is.

  ## Examples

      iex> alias DeepEvalEx.Tracing.{CompactTrace, NestedDict, Span}
      iex> llm = Span.new!(uuid: "s2", type: :llm, name: "draft", model: "gpt-4o", input_token_count: 42)
      iex> root = Span.new!(uuid: "s1", type: :agent, name: "answer", output: "ok", children: [llm])
      iex> root |> NestedDict.build() |> CompactTrace.compact() |> DeepEvalEx.TestRun.JSON.encode!()
      ~S({"name": "answer", "type": "agent", "output": "ok", "children": [{"name": "draft", "type": "llm", "model": "gpt-4o"}]})
  """

  alias DeepEvalEx.Prompts.Python
  alias Jason.OrderedObject

  @trace_span_keys ~w(name type description input output error model retrieval_context context
                      expected_output tools_called expected_tools available_tools agent_handoffs)

  @doc """
  Compacts a nested trace dict (`DeepEvalEx.Tracing.NestedDict.build/1`),
  as deepeval's `compact_trace` (see the moduledoc).
  """
  @spec compact(term()) :: term()
  def compact(%OrderedObject{} = trace), do: compact_dict(trace)
  def compact(trace) when is_map(trace) and not is_struct(trace), do: compact_dict(trace)
  def compact(trace), do: trace

  defp compact_dict(trace) do
    span =
      @trace_span_keys
      |> Enum.map(&{&1, Access.get(trace, &1)})
      |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)

    children =
      case Access.get(trace, "children") do
        children when is_list(children) -> Enum.map(children, &compact/1)
        _ -> []
      end

    pairs = if children == [], do: span, else: span ++ [{"children", children}]
    jsonable(OrderedObject.new(pairs))
  end

  # deepeval's `_jsonable`.
  defp jsonable(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp jsonable(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, do: {key_str(key), jsonable(value)})

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()

  defp jsonable(map) when is_map(map) and not is_struct(map),
    do: OrderedObject.new(for {key, value} <- map, do: {key_str(key), jsonable(value)})

  defp jsonable(value), do: str(value)

  # Python's str(value) of a value _jsonable does not keep.
  defp str(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp str(%DeepEvalEx.Schemas.ToolCall{} = tool_call), do: Python.str(tool_call)
  defp str(%DeepEvalEx.Schemas.RetrievedContextData{} = data), do: Python.str(data)

  defp str(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  # str(key): a string as it is, other keys as `str/1`, numbers, booleans
  # and nil as Python prints them.
  defp key_str(key) when is_binary(key), do: key
  defp key_str(key) when is_number(key) or is_boolean(key) or is_nil(key), do: Python.repr(key)
  defp key_str(key), do: str(key)
end
