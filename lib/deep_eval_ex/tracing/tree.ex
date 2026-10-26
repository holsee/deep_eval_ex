defmodule DeepEvalEx.Tracing.Tree do
  @moduledoc """
  Builds a closed trace's span tree from its flat spans: the tree half of
  deepeval 4.3.1's `TraceManager` (`add_span_to_trace`,
  `_reparent_orphan_roots`, `end_trace`) and the fields `Observer.__exit__`
  derives (`tracing/tracing.py`).

  The capture store keeps one row per span, written by the process that
  owns it, and builds the tree once, when the trace closes. `build/3` is
  pure, so the tree rules are tested from hand-built spans:

  - children are nested under their parent in start order (`:seq`), as
    deepeval appends a child when it starts;
  - a span whose parent is not among the spans becomes a root, keeping
    its `:parent_uuid`, as `add_span_to_trace` does when the parent is
    not active;
  - a span without `:tools_called` gets one `DeepEvalEx.Schemas.ToolCall`
    per `:tool` child (name, description, the child's input as
    `prepare_tool_call_input_parameters` makes it, and its output);
  - a root span (no `:parent_uuid`) that errored marks the trace
    `:errored`;
  - `mode: :sync` applies the sync `evals_iterator`'s `end_trace`
    rewrite: only the first root's first child is kept, and every kept
    root loses its parent.

  ## Divergence

  deepeval derives `tools_called` when the parent exits, so a tool span
  that ends after its parent (in another process) is missing from it, or
  recorded with no output. Here it is derived from every tool child.
  """

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.{Fields, JSON, Span, Trace}

  @doc """
  Nests `spans` into `trace`'s `:root_spans` and sets its status (see the
  moduledoc). `trace`'s other fields are kept.

  ## Options

  - `:mode` - `:sync` applies the sync iterator's wrapper strip
  """
  @spec build(Trace.t(), [Span.t()], keyword()) :: Trace.t()
  def build(%Trace{} = trace, spans, opts \\ []) do
    uuids = MapSet.new(spans, & &1.uuid)

    {roots, children} =
      Enum.split_with(spans, fn span ->
        is_nil(span.parent_uuid) or not MapSet.member?(uuids, span.parent_uuid)
      end)

    by_parent = Enum.group_by(children, & &1.parent_uuid)
    roots = roots |> in_start_order() |> Enum.map(&nest(&1, by_parent))

    status =
      if Enum.any?(roots, &(is_nil(&1.parent_uuid) and &1.status == :errored)),
        do: :errored,
        else: trace.status

    roots = if Keyword.get(opts, :mode) == :sync, do: strip_wrapper(roots), else: roots

    %{trace | root_spans: roots, status: status}
  end

  defp nest(span, by_parent) do
    children =
      by_parent
      |> Map.get(span.uuid, [])
      |> in_start_order()
      |> Enum.map(&nest(&1, by_parent))

    derive_tools_called(%{span | children: children})
  end

  defp in_start_order(spans), do: Enum.sort_by(spans, &{&1.seq, &1.start_us})

  # Observer.__exit__: `if not current_span.tools_called`, from ToolSpan children.
  defp derive_tools_called(%Span{tools_called: [_ | _]} = span), do: span

  defp derive_tools_called(span) do
    case for(%Span{type: :tool} = child <- span.children, do: tool_call(child)) do
      [] -> span
      tools_called -> %{span | tools_called: tools_called}
    end
  end

  defp tool_call(child) do
    %ToolCall{
      name: child.name,
      description: child.description,
      input_parameters: input_parameters(child.input),
      output: child.output
    }
  end

  # prepare_tool_call_input_parameters: a truthy value that is not a dict
  # becomes {"output": value}.
  defp input_parameters(input) do
    value = JSON.make_serializable(input)
    if Fields.truthy?(value) and not is_map(value), do: %{"output" => value}, else: value
  end

  # end_trace under EvalMode.EVALUATE / ITERATOR_SYNC.
  defp strip_wrapper([%Span{children: [first | _]} | _]), do: [%{first | parent_uuid: nil}]
  defp strip_wrapper(roots), do: Enum.map(roots, &%{&1 | parent_uuid: nil})
end
