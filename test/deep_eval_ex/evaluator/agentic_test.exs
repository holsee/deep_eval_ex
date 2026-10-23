defmodule DeepEvalEx.Evaluator.AgenticTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Evaluator.Agentic
  alias DeepEvalEx.{Result, TestCase, TestResult}
  alias DeepEvalEx.Tracing.{NestedDict, Span, Trace}

  defmodule Probe do
    @moduledoc false
    # Reports each measure to the test, with its test case.
    use DeepEvalEx.Metrics.BaseMetric

    defstruct [
      :name,
      :pid,
      :raise,
      score: 1.0,
      threshold: 0.5,
      requires_trace: false,
      fresh_metadata: false
    ]

    @impl true
    def metric_name, do: "Probe"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:input]

    @impl true
    def requires_trace?(%__MODULE__{requires_trace: requires_trace}), do: requires_trace

    def do_measure(test_case, opts) do
      send(opts[:pid], {:measured, opts[:name], test_case})
      if opts[:raise], do: raise(opts[:raise])

      # fresh_metadata differs between two measurements, as their latency
      # does, outside the metric data deepeval compares.
      metadata = if opts[:fresh_metadata], do: %{measurement: make_ref()}

      {:ok,
       Result.new(
         metric: opts[:name],
         score: opts[:score],
         threshold: opts[:threshold],
         metadata: metadata
       )}
    end
  end

  @golden %Golden{input: "How do I reset my password?", name: "password-reset"}

  defp probe(name, opts \\ []), do: struct!(Probe, [name: name, pid: self()] ++ opts)

  defp span(name, opts \\ []) do
    Span.new!([uuid: name, name: name, status: :success, start_us: 1_000, end_us: 2_000] ++ opts)
  end

  defp trace(roots, opts \\ []) do
    Trace.new!(
      [uuid: "t1", status: :success, root_spans: roots, start_us: 1_000, end_us: 2_000] ++ opts
    )
  end

  defp measured_names do
    receive do
      {:measured, name, _test_case} -> [name | measured_names()]
    after
      0 -> []
    end
  end

  defp bucket(outcome, key), do: Enum.map(outcome.test_case.trace[key], & &1["name"])

  # A bucket's spans (or the trace's metric data) as plain maps.
  defp spans(outcome, key), do: plain(outcome.test_case.trace[key])

  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  # Two roots: r1 -> (a -> a1, b), r2 -> c, every span with a metric.
  defp forest do
    leaf = fn name -> span(name, input: %{"q" => name}, metrics: [probe(name)]) end

    trace([
      span("r1",
        input: %{"q" => "r1"},
        metrics: [probe("r1")],
        children: [
          span("a", input: %{"q" => "a"}, metrics: [probe("a")], children: [leaf.("a1")]),
          leaf.("b")
        ]
      ),
      span("r2", input: %{"q" => "r2"}, metrics: [probe("r2")], children: [leaf.("c")])
    ])
  end

  describe "walk order" do
    test "async exports every root's spans in breadth-first level order" do
      outcome = Agentic.evaluate(forest(), @golden)

      assert bucket(outcome, "baseSpans") == ["r1", "r2", "a", "b", "c", "a1"]
      assert Enum.sort(measured_names()) == ["a", "a1", "b", "c", "r1", "r2"]
    end

    test "sync exports spans in pre-order and measures them in post-order, one at a time" do
      outcome = Agentic.evaluate(forest(), @golden, mode: :sync)

      assert bucket(outcome, "baseSpans") == ["r1", "a", "a1", "b", "r2", "c"]
      assert measured_names() == ["a1", "a", "b", "r1", "c", "r2"]
    end

    test "spans keep their buckets by type, and their measured metric data" do
      root =
        span("agent",
          type: :agent,
          input: %{"q" => "hi"},
          output: "done",
          metrics: [probe("Agent Judge", score: 0.25)],
          children: [span("search", type: :tool, input: %{"q" => "hi"})]
        )

      outcome = Agentic.evaluate(trace([root]), @golden)
      [agent] = spans(outcome, "agentSpans")

      assert bucket(outcome, "toolSpans") == ["search"]

      assert [%{"name" => "Agent Judge", "score" => 0.25, "success" => false}] =
               agent["metricsData"]

      refute outcome.test_case.success
    end
  end

  describe "span test cases" do
    test "an input of %{} has a test case in sync (is not None) and none in async (truthy)" do
      root = span("ping", input: %{}, output: "pong", metrics: [probe("Span Judge")])

      sync = Agentic.evaluate(trace([root]), @golden, mode: :sync)
      assert_received {:measured, "Span Judge", %TestCase{input: "{}", actual_output: "pong"}}
      assert [%{"status" => "SUCCESS"}] = spans(sync, "baseSpans")

      async = Agentic.evaluate(trace([root]), @golden)
      refute_received {:measured, _, _}
      [api] = spans(async, "baseSpans")

      assert api["status"] == "ERRORED"

      assert api["error"] ==
               "DeepEvalError: Span has metrics but no LLMTestCase. " <>
                 "Are you sure you called `update_current_span()`?"

      # The unmeasured rows stay, and the test case is not failed by them.
      assert [%{"name" => "Span Judge", "success" => false}] =
               api["metricsData"]

      assert async.test_case.success
    end

    test "the input and output are Python's str() of the span's, the other fields its own" do
      kwargs = Jason.OrderedObject.new([{"query", "it's"}, {"k", 2}])

      root =
        span("retrieve",
          input: kwargs,
          output: ["doc"],
          expected_output: "docs",
          retrieval_context: ["ctx"],
          metrics: [probe("Span Judge")]
        )

      Agentic.evaluate(trace([root]), @golden)

      assert_received {:measured, "Span Judge", test_case}

      assert %TestCase{
               input: ~S|{'query': "it's", 'k': 2}|,
               actual_output: "['doc']",
               expected_output: "docs",
               retrieval_context: ["ctx"]
             } = test_case
    end

    test "a metric requiring the trace measures the span's nested dict, on a \"None\" input" do
      root =
        span("plan",
          input: nil,
          metrics: [probe("Trace Judge", requires_trace: true)],
          children: [span("step", input: %{"n" => 1})]
        )

      Agentic.evaluate(trace([root]), @golden, mode: :sync)

      assert_received {:measured, "Trace Judge", %TestCase{input: "None", trace_dict: dict}}
      assert dict == NestedDict.build(root)
    end

    test "{module, opts} metric specs are measured with their options" do
      root = span("ping", input: %{"q" => 1}, metrics: [{Probe, name: "Tuple", pid: self()}])

      outcome = Agentic.evaluate(trace([root]), @golden)

      assert_received {:measured, "Tuple", _test_case}
      assert [%{"metricsData" => [row]}] = spans(outcome, "baseSpans")
      assert row["name"] == "Tuple"
    end
  end

  describe "errors" do
    test "an errored span skips its metrics and its children, keeping its error" do
      root =
        span("agent",
          input: %{"q" => 1},
          metrics: [probe("Agent Judge")],
          children: [
            span("tool",
              status: :errored,
              error: "upstream timeout",
              input: %{"q" => 1},
              metrics: [probe("Tool Judge")],
              children: [span("inner", input: %{"q" => 1}, metrics: [probe("Inner")])]
            )
          ]
        )

      outcome = Agentic.evaluate(trace([root]), @golden, mode: :sync)

      assert measured_names() == ["Agent Judge"]
      assert bucket(outcome, "baseSpans") == ["agent", "tool"]

      [_agent, tool] = spans(outcome, "baseSpans")
      assert {tool["status"], tool["error"]} == {"ERRORED", "upstream timeout"}
      assert outcome.test_case.success

      # The errored span's unmeasured rows make a failed span test result.
      assert [
               %TestResult{name: "password-reset"},
               %TestResult{name: "agent", success: true},
               failed
             ] =
               outcome.test_results

      assert %TestResult{
               name: "tool",
               success: false,
               metrics_data: [%Result{metric: "Tool Judge"}]
             } =
               failed
    end

    test "an errored trace skips every metric; its spans get the first span error" do
      root =
        span("agent",
          status: :errored,
          error: "planner crashed",
          input: %{"q" => 1},
          metrics: [probe("Agent Judge")],
          children: [span("tool", input: %{"q" => 1}, metrics: [probe("Tool Judge")])]
        )

      second = span("other", input: %{"q" => 2}, metrics: [probe("Other")])
      errored = trace([root, second], status: :errored, metrics: [probe("Trace Judge")])

      outcome = Agentic.evaluate(errored, @golden)

      assert measured_names() == []
      assert outcome.test_case.trace["status"] == "ERRORED"
      assert outcome.test_case.trace["metricsData"] == nil

      assert Enum.map(spans(outcome, "baseSpans"), &{&1["name"], &1["error"]}) ==
               [{"agent", "planner crashed"}, {"other", "planner crashed"}]

      assert outcome.test_case.metrics_data == []
      assert outcome.test_case.success
    end

    test "async: the iterator's metrics that never ran are the test case's, unmeasured" do
      errored = trace([span("agent", status: :errored, error: "boom")], status: :errored)

      outcome = Agentic.evaluate(errored, @golden, metrics: [probe("Stub Judge")])

      assert [%{name: "Stub Judge", success: false, score: nil}] = outcome.test_case.metrics_data
      refute outcome.test_case.success

      sync = Agentic.evaluate(errored, @golden, mode: :sync, metrics: [probe("Stub Judge")])
      assert sync.test_case.metrics_data == []
    end

    test "async: a trace with metrics but no test case marks its first root errored" do
      root = span("agent", input: %{"q" => 1}, metrics: [probe("Agent Judge")])
      outcome = Agentic.evaluate(trace([root], input: nil), @golden, metrics: [probe("Stub")])

      assert measured_names() == []
      assert outcome.test_case.trace["status"] == "ERRORED"

      assert [%{"status" => "ERRORED", "error" => error}] = spans(outcome, "baseSpans")

      assert error ==
               "DeepEvalError: Trace has metrics but no LLMTestCase (missing input/output). " <>
                 "Are you sure you called `update_current_trace()`?"

      assert [%{name: "Stub", success: false}] = outcome.test_case.metrics_data
    end

    test "an ignored metric error is format_error_text in sync, the message in async" do
      root = span("ping", input: %{"q" => 1}, metrics: [probe("Boom", raise: "boom")])

      [sync, async] =
        for mode <- [:sync, :async] do
          outcome = Agentic.evaluate(trace([root]), @golden, mode: mode, ignore_errors: true)
          [%{"metricsData" => [row]}] = spans(outcome, "baseSpans")
          row["error"]
        end

      assert {sync, async} == {"RuntimeError: boom", "boom"}
    end

    test "a metric error is raised without :ignore_errors" do
      root = span("ping", input: %{"q" => 1}, metrics: [probe("Boom", raise: "boom")])

      for mode <- [:sync, :async] do
        assert_raise RuntimeError, "boom", fn ->
          Agentic.evaluate(trace([root]), @golden, mode: mode)
        end
      end
    end
  end

  describe "trace-level metrics" do
    test "sync measures the golden's input and the trace's output" do
      root = span("agent", input: %{"q" => 1})
      traced = trace([root], input: %{}, output: "pong", metrics: [probe("Trace Judge")])

      outcome = Agentic.evaluate(traced, @golden, mode: :sync)

      assert_received {:measured, "Trace Judge", %TestCase{input: input, actual_output: "pong"}}
      assert input == @golden.input
      assert [%{"name" => "Trace Judge"}] = spans(outcome, "metricsData")
    end

    test "async measures the trace's input, as str()" do
      traced = trace([span("agent")], input: %{"q" => "hi"}, metrics: [probe("Trace Judge")])

      Agentic.evaluate(traced, @golden)

      assert_received {:measured, "Trace Judge", %TestCase{input: "{'q': 'hi'}"}}
    end

    test ":metrics replaces the trace's own, and a trace metric requiring the trace gets the first root's dict" do
      root = span("agent", input: %{"q" => 1})
      traced = trace([root], input: %{"q" => 1}, metrics: [probe("Own")])

      Agentic.evaluate(traced, @golden, metrics: [probe("Iterator", requires_trace: true)])

      assert measured_names() == ["Iterator"]
    end

    test "requires_trace places the root's nested dict on the trace test case" do
      root = span("agent", input: %{"q" => 1})
      traced = trace([root], metrics: [probe("Trace Judge", requires_trace: true)])

      Agentic.evaluate(traced, @golden)

      assert_received {:measured, "Trace Judge", %TestCase{input: "None", trace_dict: dict}}
      assert dict == NestedDict.build(root)
    end
  end

  describe "results" do
    test "the golden's test case carries its name, order, trace-level data and cost" do
      root = span("ping", input: %{"q" => 1}, metrics: [probe("Span Judge", score: 0.1)])
      traced = trace([root], input: %{"q" => 1}, output: "pong", metrics: [probe("Trace Judge")])

      outcome = Agentic.evaluate(traced, @golden, index: 3)
      test_case = outcome.test_case

      assert {test_case.name, test_case.order, test_case.input, test_case.actual_output} ==
               {"password-reset", 3, @golden.input, "pong"}

      assert Enum.map(test_case.metrics_data, & &1.name) == ["Trace Judge"]
      refute test_case.success
      assert is_float(test_case.run_duration)

      assert [%TestResult{name: "password-reset", success: false, index: 3}, span_result] =
               outcome.test_results

      assert %TestResult{name: "ping", success: true, input: %{"q" => 1}} = span_result
    end

    test "a golden without a name is named after its order" do
      outcome = Agentic.evaluate(trace([span("a")]), %Golden{input: "hi"}, index: 2)
      assert outcome.test_case.name == "test_case_2"
    end

    test "span results come bucket by bucket, base first" do
      root =
        span("agent",
          type: :agent,
          input: %{"q" => 1},
          metrics: [probe("A")],
          children: [span("step", input: %{"q" => 2}, metrics: [probe("B")])]
        )

      outcome = Agentic.evaluate(trace([root]), @golden)

      assert Enum.map(outcome.test_results, & &1.name) == ["password-reset", "step", "agent"]
    end

    for mode <- [:async, :sync] do
      test "#{mode}: a span result identical to the golden's is dropped" do
        judge = probe("Judge", fresh_metadata: true)
        root = span("echo", input: "hi", output: "hi", metrics: [judge])
        traced = trace([root], input: "hi", output: "hi", metrics: [judge])

        outcome = Agentic.evaluate(traced, %Golden{input: "hi"}, mode: unquote(mode))

        assert [%TestResult{name: "test_case_0", input: "hi", actual_output: "hi"}] =
                 outcome.test_results

        assert bucket(outcome, "baseSpans") == ["echo"]
      end
    end

    test "a span result whose metric data differs from the golden's is kept" do
      root = span("echo", input: "hi", output: "hi", metrics: [probe("Judge", score: 0.1)])
      traced = trace([root], input: "hi", output: "hi", metrics: [probe("Judge")])

      outcome = Agentic.evaluate(traced, %Golden{input: "hi"})

      assert Enum.map(outcome.test_results, & &1.name) == ["test_case_0", "echo"]
    end

    test "the prompts of the walked LLM spans, once per alias" do
      prompt = %{alias: "draft", version: "00.00.01"}

      root =
        span("agent",
          children: [
            span("first", type: :llm, prompt: prompt),
            span("second", type: :llm, prompt: prompt)
          ]
        )

      assert Agentic.evaluate(trace([root]), @golden).prompts == [prompt]
    end
  end

  test "an unknown mode raises" do
    assert_raise ArgumentError, "unknown mode :parallel", fn ->
      Agentic.evaluate(trace([]), @golden, mode: :parallel)
    end
  end
end
