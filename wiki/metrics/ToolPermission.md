# ToolPermission Metric

ToolPermission checks that an agent only called the tools it was authorized to. It is a non-LLM metric: it calls no judge and is fully deterministic, so it is cheap and reliable to run as a CI gate.

Unlike [ToolCorrectness](ToolCorrectness.md), which compares the tools called with the tools expected, it checks the tools called against a **permission policy**, whether or not the task was solved.

## When to Use

- Least privilege: an agent must stay within a fixed set of tools
- Guarding destructive tools (`delete_account`, `wire_transfer`, `rm_rf`) in every test
- Pairing with ToolCorrectness and [ArgumentCorrectness](ArgumentCorrectness.md): which tools, how, and whether they were allowed

## How It Works

1. **Check each call** in `tools_called` by its name against the policy:
   - `:allowed_tools` - an allowlist. When given, a tool not in it is unauthorized; `[]` authorizes nothing
   - `:denied_tools` - a denylist. A tool in it is unauthorized. **A denial always wins over an allow**
2. **Calculate score** - `(authorized calls) / (all calls)`, or `1.0` when no tools were called
3. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:tools_called` | The tool calls the agent made, a list of `DeepEvalEx.Schemas.ToolCall` |

A test case that does not set `:tools_called` (`nil`, deepeval's `None`) is missing it; an empty list is a test case that called no tools, and scores `1.0`.

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ToolPermission}

test_case = TestCase.new!(
  input: "Close my account.",
  actual_output: "Done.",
  tools_called: [%{name: "search_kb"}, %{name: "delete_account"}]
)

{:ok, result} =
  ToolPermission.measure(test_case,
    allowed_tools: ["search_kb", "reply"],
    denied_tools: ["delete_account"]
  )

result.score   # => 0.5
result.success # => false (0.5 < 1.0 threshold)
result.reason
# => "1 of 2 tool call(s) were unauthorized: ['delete_account']. Allowed=['reply', 'search_kb'], Denied=['delete_account']."
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:allowed_tools` | list of strings | any tool | The tools the agent may call |
| `:denied_tools` | list of strings | none | The tools the agent must not call |
| `:threshold` | float | 1.0 | Minimum passing score (the float `1.0`, as in deepeval) |
| `:strict_mode` | boolean | false | Threshold `1.0`, and a score below it is `0` |
| `:include_reason` | boolean | true | Explain the score |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |

At least one of `:allowed_tools` and `:denied_tools` is required; without either, measuring raises `ArgumentError`, as deepeval's constructor raises `ValueError`.

### Partial Credit

```elixir
# 2 of 3 calls authorized: 0.67 passes a 0.6 threshold.
ToolPermission.measure(test_case, allowed_tools: ["a", "b"], threshold: 0.6)
```

## As a Configured Metric

The policy belongs to the metric, as in deepeval's `ToolPermissionMetric(allowed_tools=..., denied_tools=...)`. To evaluate with other metrics, or two policies at once, build the metric with `new/1`:

```elixir
metrics = [
  ToolPermission.new(denied_tools: ["delete_account", "wire_transfer"]),
  DeepEvalEx.Metrics.ToolCorrectness
]

DeepEvalEx.evaluate(test_cases, metrics)
```

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | Every call was authorized, or no tools were called (best) |
| 0.5 | Half of the calls were authorized |
| 0.0 | No call was authorized (worst) |

## Reasons and Verbose Logs

The reason is deepeval's: `"No tools were called, so no permission boundary could be violated."`, `"All 2 tool call(s) stayed within the permitted set."`, or the unauthorized calls with the sorted policy (`Allowed=ANY` without an allowlist). The verbose logs are always written, as deepeval's:

```
Allowed tools: ['reply', 'search_kb']

Denied tools: ['delete_account']

Tools called: ['search_kb', 'delete_account']

Unauthorized calls: ['delete_account']
```

## Eval Modes

Like deepeval's, the metric ignores `:eval_mode`: it measures the same way under `:hybrid` and `:system_one`, and builds and calls no System One model.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Tool Permission",
  score: 0.5,
  success: false,
  threshold: 1.0,
  reason: "1 of 2 tool call(s) were unauthorized: ['delete_account']. ...",
  metadata: %{
    allowed_tools: ["reply", "search_kb"],
    denied_tools: ["delete_account"],
    unauthorized_tools: ["delete_account"]
  }
}
```

## Source

Ported from `deepeval/metrics/tool_permission/tool_permission.py`
