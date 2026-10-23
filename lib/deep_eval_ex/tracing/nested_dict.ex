defmodule DeepEvalEx.Tracing.NestedDict do
  @moduledoc """
  A span tree as deepeval 4.3.1's nested trace dict: what
  `TraceManager.create_nested_spans_dict` (`tracing/tracing.py`) builds
  and the trace metrics read as a test case's private `_trace_dict`
  (`DeepEvalEx.TestCase`'s `:trace_dict`).

  `build/1` takes a span, usually a trace's first root, and returns a
  `Jason.OrderedObject` of its exported fields (`_convert_span_to_api_span`)
  by field name, in `BaseApiSpan`'s declaration order:

  - the uuid, trace and parent uuids, start and end times, status, test
    case, metric data, metric collection and metadata are left out;
  - `nil` values are left out, other falsy ones kept (`""`, `[]`, `%{}`);
  - `type` is the span type's value (`"agent"`), the retrieval context
    keeps only each `DeepEvalEx.Schemas.RetrievedContextData`'s context
    (and an empty one is left out), an LLM span's prompt fields come from
    its `:prompt` under its own `:prompt_*` fields and its token intervals
    are keyed by microsecond ISO times, as in `DeepEvalEx.Tracing.Api`;
  - the provider is kept as it is, not normalised;
  - `children` is last, each child built the same way, a dropped span
    included.

  The values are the span's own, as in deepeval's dict: inputs and
  outputs are not made serializable and tool calls stay
  `DeepEvalEx.Schemas.ToolCall` structs. `to_json/2` serialises the dict
  as the trace metrics' `serialize_to_json(trace_dict, indent=2)`, and
  `DeepEvalEx.Tracing.CompactTrace.compact/1` compacts it for a System
  One state.

  ## Examples

      iex> alias DeepEvalEx.Tracing.{NestedDict, Span}
      iex> tool = Span.new!(uuid: "s2", type: :tool, name: "search", input: %{"q" => "hi"})
      iex> root = Span.new!(uuid: "s1", type: :agent, name: "answer", output: "ok", children: [tool])
      iex> root |> NestedDict.build() |> NestedDict.to_json(indent: nil)
      ~S({"name": "answer", "type": "agent", "output": "ok", "available_tools": [], "agent_handoffs": [], "children": [{"name": "search", "type": "tool", "input": {"q": "hi"}, "children": []}]})
  """

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.JSON, as: TestRunJSON
  alias DeepEvalEx.Tracing.{Api, JSON, Span}
  alias Jason.OrderedObject

  @typedoc """
  A nested trace dict: string keys in `BaseApiSpan` order, the span's own
  values, and `"children"` holding the children's dicts.
  """
  @type t :: OrderedObject.t()

  @doc """
  Builds `span`'s nested trace dict, as deepeval's
  `create_nested_spans_dict` (see the moduledoc).
  """
  @spec build(Span.t()) :: t()
  def build(%Span{} = span) do
    pairs =
      [
        {"name", span.name},
        {"type", Span.type_value(span.type)},
        {"input", span.input},
        {"output", span.output},
        {"error", span.error},
        {"integration", span.integration},
        {"retrieval_context", TestRun.flat_contexts(span.retrieval_context)},
        {"context", span.context},
        {"expected_output", span.expected_output},
        {"tools_called", span.tools_called},
        {"expected_tools", span.expected_tools}
      ] ++
        typed_pairs(span) ++
        for({field, value} <- Api.prompt_fields(span), do: {Atom.to_string(field), value})

    pairs
    |> Enum.reject(&match?({_key, nil}, &1))
    |> Kernel.++([{"children", Enum.map(span.children, &build/1)}])
    |> OrderedObject.new()
  end

  # BaseApiSpan's type-specific fields, set on their type's spans only.
  defp typed_pairs(%Span{type: :agent} = span),
    do: [{"available_tools", span.available_tools}, {"agent_handoffs", span.agent_handoffs}]

  defp typed_pairs(%Span{type: :tool} = span), do: [{"description", span.description}]

  defp typed_pairs(%Span{type: :retriever} = span),
    do: [{"embedder", span.embedder}, {"top_k", span.top_k}, {"chunk_size", span.chunk_size}]

  defp typed_pairs(%Span{type: :llm} = span) do
    [
      {"model", span.model},
      {"provider", span.provider},
      {"input_token_count", span.input_token_count},
      {"output_token_count", span.output_token_count},
      {"cost_per_input_token", span.cost_per_input_token},
      {"cost_per_output_token", span.cost_per_output_token},
      {"token_intervals", Api.token_intervals(span.token_intervals)}
    ]
  end

  defp typed_pairs(%Span{}), do: []

  @doc """
  Serialises a nested trace dict, or any term holding them, as deepeval's
  `serialize_to_json(trace_dict, indent=2)`: through
  `DeepEvalEx.Tracing.JSON.make_serializable/1`, with each tool call as
  every one of its fields (`vars()`, `nil` ones included, `type` as
  `"FUNCTION"` or `"MCP"`), encoded by `DeepEvalEx.TestRun.JSON.encode!/2`.

  ## Options

  `DeepEvalEx.TestRun.JSON.encode!/2`'s, over `indent: 2`: pass
  `indent: nil` for one line, `ensure_ascii: false` to keep non-ASCII
  characters.
  """
  @spec to_json(term(), keyword()) :: String.t()
  def to_json(term, opts \\ []) do
    term
    |> tool_calls_as_vars()
    |> JSON.make_serializable()
    |> TestRunJSON.encode!(Keyword.merge([indent: 2], opts))
  end

  # make_json_serializable reads a ToolCall's vars(), every field included,
  # where `Tracing.JSON` dumps it without its nil fields.
  defp tool_calls_as_vars(%ToolCall{} = tool_call) do
    OrderedObject.new([
      {"name", tool_call.name},
      {"type", tool_call.type |> Atom.to_string() |> String.upcase()},
      {"description", tool_call.description},
      {"reasoning", tool_call.reasoning},
      {"output", tool_calls_as_vars(tool_call.output)},
      {"input_parameters", tool_calls_as_vars(tool_call.input_parameters)}
    ])
  end

  defp tool_calls_as_vars(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, do: {key, tool_calls_as_vars(value)})

  # Element by element, so an improper list keeps its tail.
  defp tool_calls_as_vars([head | tail]),
    do: [tool_calls_as_vars(head) | tool_calls_as_vars(tail)]

  defp tool_calls_as_vars(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> tool_calls_as_vars()

  defp tool_calls_as_vars(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, tool_calls_as_vars(value)} end)

  defp tool_calls_as_vars(value), do: value
end
