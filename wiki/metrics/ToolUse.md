# ToolUse Metric

ToolUse measures how well an agent uses its tools over a conversation: whether, in each unit interaction, it picked the right ones from the tools available to it, and whether it called them with correct arguments. The score is the lower of the two means.

## When to Use

- Checking tool-calling agents pick the best available tool, and no needless ones
- Catching calls with missing, generic or wrong arguments
- Regression testing multi-turn agents on recorded conversations

## How It Works

1. **Split the conversation** - into unit interactions of at least two turns. Each one's user messages are its leading user turns, its assistant messages and tool calls those of the assistant turns after its first turn; tools are shown as deepeval's `ToolCall.__repr__`, joined with commas
2. **Score tool selection** - for each unit, the judge scores from `0.0` to `1.0` how well the tools called match what the user asked, given the available tools
3. **Score arguments** - for each unit that called a tool, the judge scores the correctness of the calls' arguments
4. **Calculate score** - `min(mean tool selection score, mean argument correctness score)`, each mean `0.0` without scores: as in deepeval, a conversation without tool calls scores `0.0`
5. **Explain** - the judge explains each mean (with deepeval's tool selection reason template for both, as deepeval does); the reason is both, joined with a newline. As in deepeval it always does: `:include_reason` is not read
6. **Higher score is better** - Success when score ≥ threshold. As deepeval's `measure()` never sets it, `measure/2` returns `success: nil` (but under `:system_one`); `DeepEvalEx.evaluate/3` and the exported test run report `score >= threshold`, as deepeval's `is_successful()`

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |

An assistant turn's `:tools_called` are the calls judged. The metric itself requires `:available_tools`.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.ToolUse, Schemas.ToolCall}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "What's the weather in Paris?"},
      %{
        role: :assistant,
        content: "It is 18°C in Paris.",
        tools_called: [%{name: "get_weather", input_parameters: %{"city" => "Paris"}}]
      }
    ]
  )

tools = [
  %ToolCall{name: "get_weather", description: "Fetch current weather for a city"},
  %ToolCall{name: "search_web", description: "Search the web"}
]

{:ok, result} = ToolUse.measure(test_case, available_tools: tools)
result.score # => 1.0

# With other metrics, as deepeval's ToolUseMetric(available_tools=...):
DeepEvalEx.evaluate([test_case], [ToolUse.new(available_tools: tools)])
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:available_tools` | list | required | The `DeepEvalEx.Schemas.ToolCall`s the agent could call |
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.ToolUse`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `ToolUseMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model takes each tool selection and argument correctness score: one request each about the unit's `user_messages`, `assistant_messages`, `tools_called` and `available_tools` (the texts the LLM prompt shows), one five-level Score keyed `verdict`; the chosen level over the highest is the score, with the reason `"Decided by fake-jev: tool selection 1.00, confidence 0.55."`. A failed request falls back to the LLM for that score and `system_one_fallback_reason` says why. The LLM still writes the reasons
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `tools_called`) and the `available_tools` answers the metric with two Nouls; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Tool Use",
  score: 1.0,
  success: nil,
  threshold: 0.5,
  reason: "The score is 1.0 because get_weather was the right tool.\nThe score is 1.0 because...",
  metadata: %{
    tool_selection_scores: [%{score: 1.0, reason: "get_weather was the right tool."}],
    argument_correctness_scores: [%{score: 1.0, reason: "The city is right."}]
  }
}
```

## Source

Ported from `deepeval/metrics/tool_use/tool_use.py`
