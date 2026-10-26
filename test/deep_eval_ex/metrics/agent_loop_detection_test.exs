defmodule DeepEvalEx.Metrics.AgentLoopDetectionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.AgentLoopDetection
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{NestedDict, Span}
  alias Jason.OrderedObject

  doctest AgentLoopDetection

  @input_hashes Path.expand("../../fixtures/deepeval/loop_detection/input_hash.json", __DIR__)
  @external_resource @input_hashes

  # Twenty-odd meaningful words each, so the stagnation check compares them.
  @reasoning "Searching the help centre returned several password reset articles describing " <>
               "the forgot password link, account recovery email, verification code, login " <>
               "page settings, security questions, support contact options and browser cache " <>
               "troubleshooting steps."

  @other_reasoning "Reviewing the documentation again, the account recovery email and " <>
                     "verification code flow seem relevant; however the login page settings, " <>
                     "security questions and support contact options also need checking " <>
                     "before answering the user carefully today."

  defp test_case(trace_dict \\ nil) do
    %{
      TestCase.new!(input: "How do I reset my password?", actual_output: "Use the link.")
      | trace_dict: trace_dict
    }
  end

  defp span(type, name, opts) do
    Span.new!(
      [uuid: "#{name}-#{System.unique_integer([:positive])}", type: type, name: name] ++ opts
    )
  end

  defp traced(children, opts \\ []) do
    :agent
    |> span("support_agent", [input: %{"query" => "reset"}, children: children] ++ opts)
    |> NestedDict.build()
    |> test_case()
  end

  describe "metric_name/0, required_params/0 and requires_trace?/0" do
    test "are deepeval's __name__, _required_params and requires_trace" do
      assert AgentLoopDetection.metric_name() == "Agent Loop Detection"
      assert AgentLoopDetection.required_params() == [:input, :actual_output]
      assert AgentLoopDetection.default_threshold() == 0.5
      assert AgentLoopDetection.requires_trace?()
      refute AgentLoopDetection.system_one?()
    end
  end

  describe "measure/2" do
    test "scores a clean trace 1.0 at no cost and with no judge" do
      test_case =
        traced([
          span(:tool, "search", input: %{"query" => "reset"}),
          span(:tool, "search", input: %{"query" => "login"}),
          span(:llm, "think", input: %{}, output: "I will search.")
        ])

      assert {:ok, result} = AgentLoopDetection.measure(test_case)

      assert result.metric == "Agent Loop Detection"
      assert result.score === 1.0
      assert result.success
      assert result.reason == "No loop patterns detected."
      assert result.evaluation_model == nil
      assert result.evaluation_cost === 0

      assert result.metadata.score_breakdown == %{
               tool_repetition: 1.0,
               reasoning_stagnation: 1.0,
               call_graph_cycles: 1.0
             }

      assert result.verbose_logs ==
               "Tool Repetition Score: 1.0 (Tool calls are within acceptable repetition limits.) \n \n" <>
                 "Reasoning Stagnation Score: 1.0 (Not enough LLM spans to check for reasoning stagnation.) \n \n" <>
                 "Call Graph Cycles Score: 1.0 (No execution cycles detected.) \n \n" <>
                 "Combined Loop Score: 1.0"
    end

    test "counts tool calls by name and arguments, whatever their key order or JSON form" do
      args = OrderedObject.new([{"query", "reset"}, {"limit", 5}])

      test_case =
        traced([
          span(:tool, "search", input: %{"limit" => 5, "query" => "reset"}),
          span(:tool, "search", input: args),
          span(:tool, "search", input: ~s({"query": "reset", "limit": 5})),
          # str(5) == str("5"): the same call to deepeval.
          span(:tool, "search", input: %{"limit" => "5", "query" => "reset"}),
          span(:tool, "lookup", input: %{"limit" => 5, "query" => "reset"})
        ])

      assert {:ok, result} = AgentLoopDetection.measure(test_case)
      assert result.metadata.score_breakdown.tool_repetition === 0.5
      assert result.reason == "Tool 'search' called 4 times with identical arguments."
      assert result.score == (0.0 + 0.5 * 0.40 + 1.0 * 0.35 + 1.0 * 0.25) / (0.40 + 0.35 + 0.25)
    end

    test "scores 0.0 for repetition at twice the threshold, and takes the first most repeated call" do
      test_case =
        traced(
          List.duplicate(span(:tool, "lookup", input: "id-1"), 2) ++
            List.duplicate(span(:tool, "search", input: %{"q" => "a"}), 2),
          []
        )

      assert {:ok, result} = AgentLoopDetection.measure(test_case, repetition_threshold: 1)
      assert result.metadata.score_breakdown.tool_repetition === 0.0
      assert result.reason == "Tool 'lookup' called 2 times with identical arguments."
    end

    test "flags identical consecutive reasoning and names the steps" do
      test_case =
        traced([
          span(:llm, "think", output: @other_reasoning),
          span(:llm, "think", output: @reasoning),
          span(:llm, "think", output: @reasoning)
        ])

      assert {:ok, result} = AgentLoopDetection.measure(test_case)
      assert result.metadata.score_breakdown.reasoning_stagnation === 0.0
      assert result.reason == "Identical reasoning outputs at steps 1 and 2."
    end

    test "skips reasoning shorter than twenty meaningful words, and outputs that are not text" do
      short = "I will now search the help centre for the password reset steps."

      test_case =
        traced([
          span(:llm, "think", output: short),
          span(:llm, "think", output: short),
          span(:llm, "think", output: %{"text" => @reasoning}),
          span(:llm, "think", output: %{"text" => @reasoning})
        ])

      assert {:ok, result} = AgentLoopDetection.measure(test_case)
      assert result.metadata.score_breakdown.reasoning_stagnation === 1.0
    end

    test "detects a span recurring on its own ancestry path, by type, name and input" do
      inner = span(:agent, "planner", input: %{"goal" => "reset"})
      delegate = span(:tool, "delegate", input: %{"to" => "planner"}, children: [inner])
      sibling = span(:agent, "planner", input: %{"goal" => "other"})

      root =
        span(:agent, "planner", input: %{"goal" => "reset"}, children: [sibling, delegate])

      assert {:ok, result} = AgentLoopDetection.measure(test_case(NestedDict.build(root)))
      assert result.metadata.score_breakdown.call_graph_cycles === 0.0

      assert result.reason ==
               "Cycle detected in execution path: agent:planner -> tool:delegate -> agent:planner."
    end

    test "does not flag repeated siblings or the same name with another input" do
      root =
        span(:agent, "planner",
          input: %{"goal" => "reset"},
          children: [
            span(:tool, "search", input: %{"q" => "a"}),
            span(:tool, "search", input: %{"q" => "a"}),
            span(:agent, "planner", input: %{"goal" => "other"})
          ]
        )

      assert {:ok, result} = AgentLoopDetection.measure(test_case(NestedDict.build(root)))
      assert result.metadata.score_breakdown.call_graph_cycles === 1.0
    end

    test "without a trace scores 0.0 and fails, with no verbose logs" do
      assert {:ok, result} = AgentLoopDetection.measure(test_case())

      assert result.score === 0.0
      refute result.success

      assert result.reason ==
               "No trace data found. This metric requires trace data from @observe."

      assert result.verbose_logs == ""
    end

    test "strict mode scores a loop 0.0 under the threshold 1" do
      test_case = traced(List.duplicate(span(:tool, "search", input: %{"q" => "a"}), 3))

      assert {:ok, result} = AgentLoopDetection.measure(test_case, strict_mode: true)
      assert result.score === 0.0
      assert result.threshold == 1
      refute result.success
      assert result.reason == "Tool 'search' called 3 times with identical arguments."
    end

    test "weighs only the checks it runs, and scores 1.0 with none" do
      test_case = traced(List.duplicate(span(:tool, "search", input: %{"q" => "a"}), 3))

      assert {:ok, result} =
               AgentLoopDetection.measure(test_case,
                 check_reasoning_stagnation: false,
                 check_call_graph_cycles: false
               )

      assert result.score === 0.5 * 0.40 / 0.40

      assert {:ok, result} =
               AgentLoopDetection.measure(test_case,
                 check_tool_repetition: false,
                 check_reasoning_stagnation: false,
                 check_call_graph_cycles: false
               )

      assert result.score === 1.0
      assert result.reason == "No loop patterns detected."
      assert result.verbose_logs =~ "Tool Repetition Score: 1.0 (Tool repetition check skipped.)"
    end

    test "ignores the eval mode: no System One model is built or asked" do
      test_case = traced([span(:tool, "search", input: %{"q" => "a"})])

      for mode <- [:hybrid, :system_one] do
        assert {:ok, result} = AgentLoopDetection.measure(test_case, eval_mode: mode)
        assert result.score === 1.0
        assert result.evaluation_model == nil
      end
    end

    test "takes inputs JSON cannot dump without raising" do
      test_case =
        traced([
          span(:tool, "search", input: %{1 => "a", "b" => 2}),
          span(:tool, "search", input: %{"at" => ~D[2026-10-23], "pid" => self()}),
          span(:tool, "search", input: {:ok, 1})
        ])

      assert {:ok, result} = AgentLoopDetection.measure(test_case)
      assert result.score === 1.0
    end
  end

  describe "input_hash/1 against deepeval's _input_hash (input_hash.json)" do
    rows = @input_hashes |> File.read!() |> Jason.decode!(objects: :ordered_objects)

    for {row, index} <- Enum.with_index(rows) do
      @row row

      test "row #{index}: #{inspect(row["input_hash"])}" do
        assert AgentLoopDetection.input_hash(@row["span"]) == @row["input_hash"]
      end
    end

    test "falls back to str() when the keys cannot be sorted, as json.dumps raises" do
      span = OrderedObject.new([{"input", OrderedObject.new([{"b", 1}, {2, "x"}])}])
      assert AgentLoopDetection.input_hash(span) == "{'b': 1, 2: 'x'}"
    end

    test "sorts the keys of an Elixir map, atoms as their names" do
      span = %{"input" => %{zeta: 1, alpha: %{"y" => nil, "b" => 1.0}}}

      assert AgentLoopDetection.input_hash(span) ==
               ~s({"alpha": {"b": 1.0, "y": null}, "zeta": 1})
    end
  end
end
