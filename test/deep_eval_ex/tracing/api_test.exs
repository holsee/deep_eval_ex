defmodule DeepEvalEx.Tracing.ApiTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Test.ParityMetrics.Stub
  alias DeepEvalEx.TestRun.{JSON, MetricData}
  alias DeepEvalEx.Tracing.{Api, Span, Trace}
  alias Jason.OrderedObject

  doctest Api

  # 2023-11-14T22:13:20.999999Z
  @t0 1_700_000_000_999_999

  defp span(uuid, attrs \\ []) do
    Span.new!(
      [uuid: uuid, trace_uuid: "t", name: uuid, status: :success, start_us: @t0, end_us: @t0] ++
        attrs
    )
  end

  defp trace(roots, attrs \\ []) do
    Trace.new!(
      [uuid: "t", status: :success, root_spans: roots, start_us: @t0, end_us: @t0] ++ attrs
    )
  end

  defp names(api, bucket), do: Enum.map(api[bucket], & &1["name"])

  defp keys(%OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  describe "trace_api/2" do
    test "buckets spans by type in deepeval's LIFO span_stack order" do
      tool = span("search", type: :tool, parent_uuid: "agent")
      llm1 = span("draft", type: :llm, parent_uuid: "agent")
      llm2 = span("polish", type: :llm, parent_uuid: "agent")
      inner = span("inner", parent_uuid: "plan")
      plan = span("plan", parent_uuid: "agent", children: [inner])
      agent = span("agent", type: :agent, children: [llm1, tool, plan, llm2])
      other_root = span("other")

      api = Api.trace_api(trace([agent, other_root]))

      # Roots are popped last first, then each span's children last first.
      assert names(api, "baseSpans") == ["other", "plan", "inner"]
      assert names(api, "agentSpans") == ["agent"]
      assert names(api, "llmSpans") == ["polish", "draft"]
      assert names(api, "toolSpans") == ["search"]
      assert api["retrieverSpans"] == []
    end

    test "leaves a dropped span out and gives its children its parent" do
      child = span("child", type: :tool, parent_uuid: "dropped")
      dropped = span("dropped", parent_uuid: "root", drop: true, children: [child])
      root = span("root", type: :agent, children: [dropped])

      api = Api.trace_api(trace([root]))

      assert api["baseSpans"] == []
      assert [exported] = api["toolSpans"]
      assert {exported["name"], exported["parentUuid"]} == {"child", "root"}
    end

    test "writes the trace's fields in TraceApi order, leaving nil ones out" do
      api =
        Api.trace_api(
          trace([],
            name: "support",
            tags: ["beta"],
            metadata: %{"channel" => "chat"},
            thread_id: "th",
            user_id: "u",
            input: OrderedObject.new([{"query", "q"}]),
            output: "a",
            retrieval_context: ["r"],
            context: ["c"],
            expected_output: "e",
            tools_called: [%ToolCall{name: "t"}],
            metric_collection: "mc",
            test_case_id: "tc",
            turn_id: "turn"
          )
        )

      assert keys(api) ==
               ~w(uuid baseSpans agentSpans llmSpans retrieverSpans toolSpans startTime endTime
                  name metadata tags environment threadId userId input output status testCaseId
                  turnId retrievalContext context expectedOutput toolsCalled metricCollection)

      assert api["startTime"] == "2023-11-14T22:13:20.999Z"
      assert api["environment"] == "development"
      assert api["status"] == "SUCCESS"

      assert JSON.encode!(api["toolsCalled"]) == ~s([{"name": "t", "type": "FUNCTION"}])
    end

    test "exports any status but :success as ERRORED, and takes an environment" do
      assert Api.trace_api(trace([], status: :errored))["status"] == "ERRORED"
      assert Api.trace_api(trace([], status: :in_progress))["status"] == "ERRORED"
      assert Api.trace_api(trace([]), environment: "staging")["environment"] == "staging"
    end

    test "falls back to the current time for a missing start or end" do
      api = Api.trace_api(%Trace{uuid: "t", status: :success})
      assert api["startTime"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
      assert api["endTime"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
    end

    test "normalises LLM providers, as normalize_trace_api_span_providers" do
      providers = [
        "openai",
        "anthropic/claude-3-haiku",
        "Vertex AI",
        "  My Lab ",
        "x_ai",
        "",
        " "
      ]

      spans =
        providers
        |> Enum.with_index()
        |> Enum.map(fn {provider, i} -> span("llm#{i}", type: :llm, provider: provider) end)

      api = Api.trace_api(trace([span("root", children: spans)]))

      assert api["llmSpans"] |> Enum.map(& &1["provider"]) |> Enum.reverse() ==
               ["OpenAI", "Anthropic", "VertexAI", "My Lab", "XAI", "", nil]

      # A blank provider normalises to None, which the export leaves out.
      refute JSON.encode!(api) =~ "null"
    end
  end

  describe "span_api/2" do
    test "writes BaseApiSpan's fields in order, a type's own fields only on its spans" do
      agent =
        span("agent",
          type: :agent,
          parent_uuid: "p",
          metadata: %{"k" => 1},
          input: OrderedObject.new([{"b", 1}, {"a", {2, :x}}]),
          output: %{answer: "ok"},
          error: "boom",
          integration: "LangChain",
          retrieval_context: ["r"],
          context: [],
          expected_output: "e",
          tools_called: [%ToolCall{name: "t", input_parameters: %{"q" => "x"}, output: [1]}],
          expected_tools: [],
          metric_collection: "mc",
          available_tools: ["t"]
        )

      api = Api.span_api(agent)

      assert keys(api) ==
               ~w(uuid name status type parentUuid startTime endTime metadata input output error
                  integration retrievalContext context expectedOutput toolsCalled expectedTools
                  availableTools agentHandoffs metricCollection)

      assert JSON.encode!(api["input"]) == ~s({"b": 1, "a": [2, "x"]})
      assert api["output"] == %{"answer" => "ok"}
      assert api["agentHandoffs"] == []
      assert api["type"] == "agent"

      retriever = Api.span_api(span("r", type: :retriever, embedder: "e", top_k: 2))
      assert {retriever["embedder"], retriever["topK"], retriever["chunkSize"]} == {"e", 2, nil}

      tool = Api.span_api(span("t", type: :tool, description: "d"))
      assert tool["description"] == "d"
      refute Map.has_key?(Map.new(tool.values), "availableTools")
    end

    test "truncates times to milliseconds and token interval keys to microseconds" do
      llm =
        span("llm",
          type: :llm,
          start_us: 1_700_000_000_000_999,
          model: "gpt-4o",
          input_token_count: 42,
          cost_per_output_token: 6.0e-7,
          token_intervals: %{1_700_000_000_500_000 => "lo", 1_700_000_000_250_001 => "Hel"}
        )

      api = Api.span_api(llm)

      assert api["startTime"] == "2023-11-14T22:13:20.000Z"
      assert api["inputTokenCount"] == 42.0

      assert api["tokenIntervals"] ==
               OrderedObject.new([
                 {"2023-11-14T22:13:20.250001Z", "Hel"},
                 {"2023-11-14T22:13:20.500000Z", "lo"}
               ])

      assert JSON.encode!(api["costPerOutputToken"]) == "6e-07"
    end

    test "takes the prompt's fields, overridden by the span's own" do
      prompt = %{alias: "draft", version: "1", label: "production", hash: "aaa"}

      from_prompt = Api.span_api(span("a", type: :llm, prompt: prompt))

      assert Enum.take(from_prompt.values, -4) == [
               {"promptAlias", "draft"},
               {"promptVersion", "1"},
               {"promptLabel", "production"},
               {"promptCommitHash", "aaa"}
             ]

      overridden =
        Api.span_api(
          span("b",
            type: :llm,
            prompt: %{"alias" => "draft", "label" => "production"},
            prompt_alias: "polish",
            prompt_label: ""
          )
        )

      assert overridden["promptAlias"] == "polish"
      assert overridden["promptLabel"] == "production"
      assert overridden["promptVersion"] == nil
    end

    test "writes unmeasured metric data for the span's metrics, as an OFF-mode export" do
      stub = %Stub{name: "Span Judge", threshold: 0.7, evaluation_model: "gpt-4o-mini"}
      api = Api.span_api(span("s", metrics: [stub, ExactMatch, {ExactMatch, strict_mode: true}]))

      assert JSON.encode!(api["metricsData"]) ==
               ~s([{"name": "Span Judge", "threshold": 0.7, "success": false, ) <>
                 ~s("strictMode": false, "flaky": false}, ) <>
                 ~s({"name": "Exact Match", "threshold": 1.0, "success": false, ) <>
                 ~s("strictMode": false, "flaky": false}, ) <>
                 ~s({"name": "Exact Match", "threshold": 1.0, "success": false, ) <>
                 ~s("strictMode": true, "flaky": false}])
    end

    test "writes the given metric data instead, expectations rows included" do
      data = [
        %MetricData{name: "M", score: 1.0, success: true, threshold: 0.5},
        %MetricData{name: "E", success: true, expectations_data: OrderedObject.new([])}
      ]

      api = Api.span_api(span("s", metrics: [ExactMatch]), metrics_data: data)
      assert Enum.map(api["metricsData"], & &1["name"]) == ["M", "E"]

      assert Api.span_api(span("s"), metrics_data: [])["metricsData"] == []
      assert Api.span_api(span("s"))["metricsData"] == nil
    end

    test "keeps the raw provider, as the evaluation walker exports it" do
      assert Api.span_api(span("l", type: :llm, provider: "openai"))["provider"] == "openai"
    end
  end

  describe "trace_api/2 :metrics_data" do
    test "puts measured metric data on the spans it names" do
      measured = [%MetricData{name: "Span Judge", score: 0.75, success: true, threshold: 0.7}]
      child = span("c", type: :tool, parent_uuid: "r", metrics: [ExactMatch])
      root = span("r", metrics: [ExactMatch], children: [child])

      api = Api.trace_api(trace([root]), metrics_data: %{"c" => measured})

      assert [tool] = api["toolSpans"]
      assert [%OrderedObject{} = measured_row] = tool["metricsData"]
      assert measured_row["score"] == 0.75

      assert [root_api] = api["baseSpans"]
      assert [unmeasured_row] = root_api["metricsData"]
      assert {unmeasured_row["name"], unmeasured_row["success"]} == {"Exact Match", false}
    end
  end

  describe "eval_trace_api/2" do
    test "starts with empty buckets and only create_api_trace's fields" do
      root = span("root", type: :agent)

      api =
        Api.eval_trace_api(
          trace([root],
            input: "from trace",
            output: %{"a" => 1},
            name: "n",
            context: ["c"],
            metadata: %{"k" => 1},
            tags: ["t"],
            thread_id: "th",
            user_id: "u",
            # create_api_trace passes these by field name, which TraceApi drops
            expected_output: "e",
            retrieval_context: ["r"],
            tools_called: [%ToolCall{name: "t"}],
            expected_tools: [%ToolCall{name: "t"}],
            metric_collection: "mc",
            test_case_id: "tc"
          ),
          %Golden{input: "from golden"}
        )

      assert keys(api) ==
               ~w(uuid baseSpans agentSpans llmSpans retrieverSpans toolSpans startTime endTime
                  name metadata tags threadId userId input output status context)

      assert api["agentSpans"] == []
      assert api["input"] == "from trace"
    end

    test "falls back to the golden's input for a falsy trace input" do
      golden = %Golden{input: "from golden"}

      for input <- [nil, "", OrderedObject.new([]), %{}] do
        assert Api.eval_trace_api(trace([], input: input), golden)["input"] == "from golden"
      end
    end

    test "leaves out a missing start or end time" do
      api = Api.eval_trace_api(%Trace{uuid: "t", status: :errored}, %Golden{input: "q"})
      assert {api["startTime"], api["endTime"], api["status"]} == {nil, nil, "ERRORED"}
    end
  end

  describe "add_span/2 and put_metrics_data/2" do
    test "append api spans to their buckets and set the trace's metric data in place" do
      golden = %Golden{input: "q"}
      api = Api.eval_trace_api(trace([], context: ["c"]), golden)

      api =
        api
        |> Api.add_span(Api.span_api(span("a", type: :tool)))
        |> Api.add_span(Api.span_api(span("b", type: :tool)))
        |> Api.add_span(Api.span_api(span("c")))

      assert names(api, "toolSpans") == ["a", "b"]
      assert names(api, "baseSpans") == ["c"]

      data = [
        %MetricData{name: "M", score: 1.0, success: true},
        %MetricData{name: "Expectations", success: true, expectations_data: OrderedObject.new([])}
      ]

      api = Api.put_metrics_data(api, data)

      assert Enum.take(keys(api), -3) == ["status", "context", "metricsData"]
      assert Enum.map(api["metricsData"], & &1["name"]) == ["M"]
    end
  end
end
