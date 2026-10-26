# AgentLoopDetection Metric

AgentLoopDetection measures whether an agent got stuck in a loop. It is a trace metric: it reads the agent's whole run, the nested trace dict a traced evaluation gives the test case, and scores it from `1.0` (clean execution) down to `0.0` (severe looping). It is deterministic: no LLM or System One model is called, so it costs nothing, needs no API key and reports no evaluation model.

## When to Use

- Catching agents that call the same tool with the same arguments again and again
- Catching reasoning that repeats itself step after step
- Catching an agent that delegates back to itself with the same input
- Guarding production runs at zero cost and latency

## How It Works

Three independent checks run over every span of the nested trace dict, each scoring `1.0`, `0.5` or `0.0`:

1. **Tool repetition** (weight 0.40) - tool spans are counted by name and arguments. An input map, or a string holding a JSON object, counts as its key/value pairs printed as Python's `str()` does, in any key order; any other input as its `str()`. The most repeated call scores `0.5` at `:repetition_threshold` calls and `0.0` at twice that
2. **Reasoning stagnation** (weight 0.35) - consecutive LLM span outputs are lowercased, split on whitespace and stripped of stop words ("the", "will", "now", "based", "step", ...) and words of two characters or fewer. A pair with fewer than 20 words left either side is skipped. The pair's similarity is the larger of the bigram Jaccard index and Python's `difflib.SequenceMatcher` ratio of the remaining words (`DeepEvalEx.Metrics.Utils.SequenceMatcher`). The most similar pair scores `0.5` at `:similarity_threshold` and `0.0` above `0.95`
3. **Call graph cycles** (weight 0.25) - a depth-first walk flags a span whose `type:name:input` label already appears on its own ancestry path. The input is the span's input as sorted-key JSON (or its `str()`), cut at 64 characters. Repeated siblings are left to the first check

The score is the weighted mean of the checks that run (`1.0` when none does). In strict mode a score below `1` becomes `0.0`. The reason gathers the reasons of the checks that scored below `1.0`, such as `"Tool 'search' called 3 times with identical arguments."`, or is `"No loop patterns detected."`.

Without a trace the score is `0.0`, the test case fails and the reason is `"No trace data found. This metric requires trace data from @observe."`.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The user's request (`"None"` on a traced span without one) |
| `:actual_output` | The agent's final output |

`requires_trace?/0` is `true`: in a traced evaluation the test case also carries the trace as `:trace_dict`.

## Basic Usage

```elixir
# Over goldens, checking each whole trace
DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
  metrics: [DeepEvalEx.Metrics.AgentLoopDetection]
)

# On a traced component: the span's own subtree is checked
deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.AgentLoopDetection] do
  ...
end

# In an ExUnit test
assert_trace golden, [DeepEvalEx.Metrics.AgentLoopDetection], fn -> MyApp.Agent.run(golden.input) end
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0.0` |
| `:repetition_threshold` | integer | 3 | Identical tool calls that score `0.5`; twice as many score `0.0` |
| `:similarity_threshold` | float | 0.85 | Similarity of consecutive LLM outputs that scores `0.5` |
| `:check_tool_repetition` | boolean | true | Run the tool repetition check |
| `:check_reasoning_stagnation` | boolean | true | Run the reasoning stagnation check |
| `:check_call_graph_cycles` | boolean | true | Run the call graph cycle check |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |

Like deepeval's, the metric ignores `:eval_mode`: it measures the same way under `:hybrid` and `:system_one`.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Agent Loop Detection",
  score: 0.8,
  success: true,
  threshold: 0.5,
  reason: "Tool 'search' called 3 times with identical arguments.",
  evaluation_model: nil,
  evaluation_cost: 0,
  metadata: %{
    score_breakdown: %{
      tool_repetition: 0.5,
      reasoning_stagnation: 1.0,
      call_graph_cycles: 1.0
    }
  }
}
```

## Limitations

As in deepeval:

- Cycles are found by `type:name:input` labels, as the nested trace dict holds no span ids: two different spans with the same type and name whose inputs agree on their first 64 characters count as the same span
- Stagnation is structural text similarity: reasoning that repeats itself in other words is missed

## Source

Ported from `deepeval/metrics/agent_loop_detection/agent_loop_detection.py`
