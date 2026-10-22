# GoalAccuracy Metric

GoalAccuracy measures whether an agent achieves what the user asks of it over a conversation. For each unit interaction, the judge scores how fully the assistant achieved the user's goal and how good and well followed its plan was; the score is the mean of both means.

## When to Use

- Checking task-oriented agents finish what the user asked (bookings, lookups, multi-step requests)
- Catching agents that act without a plan, or drift from the plan they stated
- Regression testing multi-turn agents on recorded conversations

## How It Works

1. **Split the conversation** - into unit interactions (user turns, then the assistant's answers). Each one's goal is `"User messages: \n"` and its leading user messages; its steps are the assistant's messages so far, one step per assistant turn after the unit's first turn, with the tools each turn called
2. **Score each goal** - the judge scores, from `0.0` to `1.0`, how fully and correctly what the user saw achieves the goal
3. **Score each plan** - the judge scores the quality of the assistant's plan and how closely it followed it
4. **Calculate score** - `(mean goal score + mean plan score) / 2`, each mean `0.0` without unit interactions
5. **Explain** - the judge writes the reason as plain text. As in deepeval it always does: `:include_reason` is not read
6. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |

An assistant turn's `:tools_called` are shown to the judge as steps.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.GoalAccuracy}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "Book me a table for two on Saturday."},
      %{role: :assistant, content: "Booked: Café Odéon, Saturday at 19:00, for two."}
    ]
  )

{:ok, result} = GoalAccuracy.measure(test_case)

result.score   # => 0.875 (goal 1.0, plan 0.75)
result.reason  # => "The agent passed: the table was booked as asked..."
result.success # => true (0.875 >= 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.GoalAccuracy`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `GoalAccuracyMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model takes each goal and plan score: one request each about the unit's `task` and `steps_taken`, one five-level Score keyed `verdict` ("Not achieved" to "Fully achieved", "No plan" to "Complete plan, fully followed"); the chosen level over the highest is the score, with the reason `"Decided by fake-jev: goal accuracy 0.75, confidence 0.35."`. A failed request falls back to the LLM for that score and `system_one_fallback_reason` says why. The LLM still writes the reason
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `tools_called`) answers the metric with a weighted Noul and two five-level Scores; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Goal Accuracy",
  score: 0.875,
  success: true,
  threshold: 0.5,
  reason: "The agent passed: the table was booked as asked...",
  metadata: %{
    goal_scores: [%{score: 1.0, reason: "The table was booked as asked."}],
    plan_scores: [%{score: 0.75, reason: "Booked straight away, no confirmation."}]
  }
}
```

## Source

Ported from `deepeval/metrics/goal_accuracy/goal_accuracy.py`
