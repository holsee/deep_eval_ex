defmodule DeepEvalEx.Tracing.CaptureParityTest do
  @moduledoc """
  Runs the traced fixtures' agent scripts through `deftraced` and
  `DeepEvalEx.Tracing.capture/2` and compares the captured span trees with
  what deepeval 4.3.1's `@observe` recorded (`nested.json` and
  `trace_api.json`, see the fixtures' README).

  Only the facets capture decides are compared: the tree (names, types,
  children in start order), the default inputs from the arguments (in
  order, defaults applied) and outputs from the results, the `toolsCalled`
  derived from tool children, span and trace statuses and errors, the
  trace input and output taken from the root span, and the span and trace
  fields that `update_*` and `next_*` set (test-case fields, each type's
  own fields, the trace's name, tags, metadata and ids). The exports
  themselves come with the TraceApi and nested dict units, and so do the
  fields they derive: the prompt fields and the token interval times.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.{TracedFixtures, TracingScenarios}
  alias DeepEvalEx.Tracing.{JSON, Span, Trace}
  alias Jason.OrderedObject

  @moduletag :parity

  @scenarios ~w(dropped_span errored_trace function_kwargs llm_prompt_fields
                metrics_without_input nested_spans next_span_staging provider_normalisation
                raised_caught raised_uncaught requires_trace span_test_case two_top_level)

  # The nested dict's keys of each span type's own fields.
  @typed_fields %{
    agent: ~w(available_tools agent_handoffs),
    llm:
      ~w(model provider input_token_count output_token_count cost_per_input_token cost_per_output_token),
    retriever: ~w(embedder top_k chunk_size),
    tool: ~w(description),
    base: []
  }

  @trace_fields [
    {"name", :name},
    {"tags", :tags},
    {"metadata", :metadata},
    {"threadId", :thread_id},
    {"userId", :user_id},
    {"retrievalContext", :retrieval_context},
    {"context", :context},
    {"expectedOutput", :expected_output}
  ]

  @buckets ~w(baseSpans agentSpans llmSpans retrieverSpans toolSpans)

  for scenario <- @scenarios do
    for file <- ~w(input.json nested.json trace_api.json) do
      @external_resource Path.join([TracedFixtures.dir(), scenario, file])
    end

    describe scenario do
      setup do
        scenario = unquote(scenario)
        input = TracedFixtures.load!(scenario, "input.json")
        traces = scenario |> TracingScenarios.run_app(input) |> List.flatten()
        %{traces: traces, scenario: scenario}
      end

      test "captures deepeval's span trees", %{traces: traces, scenario: scenario} do
        nested = TracedFixtures.load!(scenario, "nested.json")
        assert length(traces) == length(nested)

        for {%Trace{root_spans: [root]}, expected} <- Enum.zip(traces, nested) do
          assert encode(span_facets(root)) == encode(nested_facets(expected))
        end
      end

      test "captures deepeval's statuses and trace input and output",
           %{traces: traces, scenario: scenario} do
        exported = TracedFixtures.load!(scenario, "trace_api.json")
        assert length(traces) == length(exported)

        for {trace, expected} <- Enum.zip(traces, exported) do
          assert encode(trace_facets(trace)) == encode(api_facets(expected))
        end
      end
    end
  end

  defp encode(term), do: Jason.encode!(term)

  defp object(pairs), do: OrderedObject.new(Enum.reject(pairs, &match?({_, nil}, &1)))

  defp span_facets(%Span{} = span) do
    typed =
      for key <- @typed_fields[span.type],
          do: {key, Map.fetch!(span, String.to_existing_atom(key))}

    object(
      [
        {"name", span.name},
        {"type", Span.type_value(span.type)},
        {"input", JSON.make_serializable(span.input)},
        {"output", JSON.make_serializable(span.output)},
        {"error", span.error},
        {"retrieval_context", span.retrieval_context},
        {"context", span.context},
        {"expected_output", span.expected_output},
        {"tools_called", tool_facets(span.tools_called)},
        {"expected_tools", tool_facets(span.expected_tools)}
      ] ++ typed ++ [{"children", Enum.map(span.children, &span_facets/1)}]
    )
  end

  defp tool_facets(nil), do: nil

  defp tool_facets(tools) do
    Enum.map(tools, fn tool ->
      object([
        {"name", tool.name},
        {"description", tool.description},
        {"input_parameters", JSON.make_serializable(tool.input_parameters)},
        {"output", JSON.make_serializable(tool.output)}
      ])
    end)
  end

  defp nested_facets(span) do
    typed = for key <- @typed_fields[String.to_existing_atom(span["type"])], do: {key, span[key]}

    object(
      [
        {"name", span["name"]},
        {"type", span["type"]},
        {"input", span["input"]},
        {"output", span["output"]},
        {"error", span["error"]},
        {"retrieval_context", span["retrieval_context"]},
        {"context", span["context"]},
        {"expected_output", span["expected_output"]},
        {"tools_called", nested_tool_facets(span["tools_called"])},
        {"expected_tools", nested_tool_facets(span["expected_tools"])}
      ] ++ typed ++ [{"children", Enum.map(span["children"], &nested_facets/1)}]
    )
  end

  defp nested_tool_facets(nil), do: nil

  defp nested_tool_facets(tools) do
    Enum.map(tools, fn tool ->
      object([
        {"name", tool["name"]},
        {"description", tool["description"]},
        {"input_parameters", tool["input_parameters"]},
        {"output", tool["output"]}
      ])
    end)
  end

  defp trace_facets(%Trace{} = trace) do
    spans = trace.root_spans |> flatten() |> Enum.reject(& &1.drop)

    object(
      [
        {"status", Span.status_value(trace.status)},
        {"input", JSON.make_serializable(trace.input)},
        {"output", JSON.make_serializable(trace.output)}
      ] ++
        for({key, field} <- @trace_fields, do: {key, Map.fetch!(trace, field)}) ++
        [
          {"toolsCalled", trace.tools_called && Enum.map(trace.tools_called, & &1.name)},
          {"spans",
           spans
           |> Enum.map(&[&1.name, Span.status_value(&1.status), &1.error])
           |> Enum.sort()}
        ]
    )
  end

  # A dropped span is left out of the export's buckets (the TraceApi unit's
  # business), so dropped spans are left out of the statuses compared.
  defp api_facets(trace) do
    spans = Enum.flat_map(@buckets, &(trace[&1] || []))

    object(
      [
        {"status", trace["status"]},
        {"input", trace["input"]},
        {"output", trace["output"]}
      ] ++
        for({key, _field} <- @trace_fields, do: {key, trace[key]}) ++
        [
          {"toolsCalled", trace["toolsCalled"] && Enum.map(trace["toolsCalled"], & &1["name"])},
          {"spans", spans |> Enum.map(&[&1["name"], &1["status"], &1["error"]]) |> Enum.sort()}
        ]
    )
  end

  defp flatten(spans), do: Enum.flat_map(spans, &[&1 | flatten(&1.children)])
end
