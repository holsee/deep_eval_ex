# ArgumentCorrectness Metric

ArgumentCorrectness measures whether an agent calls its tools with the right arguments. The judge decides, for each tool call, whether its input parameters relevantly and correctly address the input; the score is the share that do. Unlike [ToolCorrectness](ToolCorrectness.md), it needs no expected tools.

## When to Use

- Testing agents whose tools are right but whose arguments drift (wrong date, wrong city, made-up IDs)
- Catching tool calls made with no input parameters at all
- Pairing with ToolCorrectness: one checks *which* tools were called, this one *how*

## How It Works

1. **Generate verdicts** - Given the input and the tool calls, each printed as deepeval's `ToolCall.__repr__` (name, type, description, reasoning, input parameters and output), determine for each call whether its input parameters are:
   - `yes` - Relevant and correct for the input
   - `no` - Not, or missing, with a reason
2. **Calculate score** - `(correct tool calls) / (total verdicts)`, or `1` when the judge returns no verdicts. Verdicts other than `yes` and `no` are dropped
3. **Higher score is better** - Success when score ≥ threshold

A test case with no tool calls (`tools_called: []`) scores `1.0` with the reason `"No tool calls provided"`; no judge or System One model is asked.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input the agent responded to |
| `:tools_called` | The tool calls the agent made, a list of `DeepEvalEx.Schemas.ToolCall` |

A test case that does not set `:tools_called` (`nil`, deepeval's `None`) is missing it; an empty list is a test case that called no tools.

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ArgumentCorrectness}
alias DeepEvalEx.Schemas.ToolCall

test_case = TestCase.new!(
  input: "Book a table for two in Zürich on Friday.",
  tools_called: [
    %ToolCall{name: "restaurant_search", input_parameters: %{"city" => "Zürich", "party_size" => 2}},
    %ToolCall{name: "book_table", input_parameters: %{"day" => "Saturday"}}
  ]
)

{:ok, result} = ArgumentCorrectness.measure(test_case)

result.score   # => 0.5 (1 of 2 tool calls with correct arguments)
result.reason  # => "The score is 0.50 because the booking is for Saturday, not Friday."
result.success # => true (0.5 >= 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | Every tool call's arguments address the input, or there are no tool calls (best) |
| 0.5 | Half of the tool calls have correct arguments |
| 0.0 | No tool call has correct arguments (worst) |

## System One

As deepeval 4.3.1's `ArgumentCorrectnessMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model is asked whether each tool call's input parameters relevantly and correctly address the input, one Noul per call (`tool_call_0`, `tool_call_1`, ...) holding the call's `__repr__`, in one request about `input`. P(yes) of `0.5` and above is `yes` (correct), below is `no`, each with the reason `"P(yes)=0.92"`. The LLM writes the reason, and judges the tool calls when the request fails; `system_one_fallback_reason` then says why
- `eval_mode: :system_one` - one request about `input` and the structured `tools_called` (two Nouls and a four-level Score) answers the whole metric; no LLM is called. It can be batched with the test case's other `system_one` metrics

```elixir
{:ok, result} = ArgumentCorrectness.measure(test_case, eval_mode: :system_one)
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Argument Correctness",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.50 because the booking is for Saturday, not Friday.",
  metadata: %{
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "It books Saturday, not Friday."}
    ]
  }
}
```

## Source

Ported from `deepeval/metrics/argument_correctness/argument_correctness.py`
