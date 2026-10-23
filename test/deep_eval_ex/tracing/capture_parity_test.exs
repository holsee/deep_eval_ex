defmodule DeepEvalEx.Tracing.CaptureParityTest do
  @moduledoc """
  Runs the traced fixtures' agent scripts through `deftraced` and
  `DeepEvalEx.Tracing.capture/2` and compares the captured span trees with
  what deepeval 4.3.1's `@observe` recorded (`nested.json` and
  `trace_api.json`, see the fixtures' README).

  Only the facets capture decides are compared: the tree (names, types,
  children in start order), the default inputs from the arguments (in
  order, defaults applied) and outputs from the results, the `toolsCalled`
  derived from tool children, span and trace statuses and errors, and the
  trace input and output taken from the root span. The exports themselves
  come with the TraceApi and nested dict units. The scenarios that update
  spans or stage the next one need those APIs and are not run here.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.{TracedFixtures, TracingScenarios}
  alias DeepEvalEx.Tracing.{JSON, Span, Trace}
  alias Jason.OrderedObject

  @moduletag :parity

  @scenarios ~w(errored_trace function_kwargs metrics_without_input raised_caught
                raised_uncaught two_top_level)

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
    object([
      {"name", span.name},
      {"type", Span.type_value(span.type)},
      {"input", JSON.make_serializable(span.input)},
      {"output", JSON.make_serializable(span.output)},
      {"error", span.error},
      {"tools_called",
       span.tools_called &&
         Enum.map(span.tools_called, fn tool ->
           object([
             {"name", tool.name},
             {"input_parameters", JSON.make_serializable(tool.input_parameters)},
             {"output", JSON.make_serializable(tool.output)}
           ])
         end)},
      {"children", Enum.map(span.children, &span_facets/1)}
    ])
  end

  defp nested_facets(span) do
    object([
      {"name", span["name"]},
      {"type", span["type"]},
      {"input", span["input"]},
      {"output", span["output"]},
      {"error", span["error"]},
      {"tools_called",
       span["tools_called"] &&
         Enum.map(span["tools_called"], fn tool ->
           object([
             {"name", tool["name"]},
             {"input_parameters", tool["input_parameters"]},
             {"output", tool["output"]}
           ])
         end)},
      {"children", Enum.map(span["children"], &nested_facets/1)}
    ])
  end

  defp trace_facets(%Trace{} = trace) do
    spans = flatten(trace.root_spans)

    object([
      {"status", Span.status_value(trace.status)},
      {"input", JSON.make_serializable(trace.input)},
      {"output", JSON.make_serializable(trace.output)},
      {"spans",
       spans
       |> Enum.map(&[&1.name, Span.status_value(&1.status), &1.error])
       |> Enum.sort()}
    ])
  end

  defp api_facets(trace) do
    spans = Enum.flat_map(@buckets, &(trace[&1] || []))

    object([
      {"status", trace["status"]},
      {"input", trace["input"]},
      {"output", trace["output"]},
      {"spans", spans |> Enum.map(&[&1["name"], &1["status"], &1["error"]]) |> Enum.sort()}
    ])
  end

  defp flatten(spans), do: Enum.flat_map(spans, &[&1 | flatten(&1.children)])
end
