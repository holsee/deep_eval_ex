# TurnRelevancy Metric

TurnRelevancy measures whether a chatbot stays relevant throughout a conversation. For each of the assistant's answers, the judge sees a sliding window of the conversation that ends with it and decides whether the answer is relevant to what came before; the score is the share of relevant answers.

## When to Use

- Checking that a support or sales chatbot answers what the user asked, turn after turn
- Catching assistants that change the subject, advertise, or ignore follow-up questions
- Regression testing multi-turn prompts and models on recorded conversations

## How It Works

1. **Split the conversation** - into unit interactions: the user's turn(s) and the assistant's answer. Turns before the first user turn join the first unit; a trailing user turn without an answer is left out
2. **Slide a window** - for each unit interaction, a window of at most `:window_size` unit interactions ending with it, flattened into its turns
3. **Generate verdicts** - for each window, the judge decides whether its last assistant turn is:
   - `yes` - Relevant (vague replies to vague turns, such as greetings, count as relevant)
   - `no` - Completely irrelevant, with a reason
4. **Calculate score** - `(relevant windows) / (total verdicts)`, or `1` when there are none (no answered user turn). Verdicts other than `yes` and `no` are dropped
5. **Higher score is better** - Success when score ≥ threshold

The reason prompt lists each irrelevant window by its message number, counting windows from 1.

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnRelevancy}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "My order is late."},
      %{role: :assistant, content: "Sorry! Let me check order 42 for you."},
      %{role: :user, content: "Thanks. When will it arrive?"},
      %{role: :assistant, content: "Have you tried our new pizza?"}
    ]
  )

{:ok, result} = TurnRelevancy.measure(test_case, window_size: 5)

result.score   # => 0.5 (1 of 2 assistant turns is relevant)
result.reason  # => "The score is 0.5 because message 2 advertises pizza..."
result.success # => true (0.5 >= 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:window_size` | integer | 10 | The most unit interactions in each window |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TurnRelevancy`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TurnRelevancyMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model judges each window: one request per window about its `turns`, one Noul keyed `verdict`. P(yes) of `0.5` and above is `yes` (relevant), below is `no`, each with the reason `"P(yes)=0.91"`; the LLM writes the reason. When a request fails, the LLM judges that window and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `content` and `role`) answers the metric with two Nouls and a four-level Score, "Mostly irrelevant" to "All relevant"; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Turn Relevancy",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.5 because message 2 advertises pizza...",
  metadata: %{
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "The assistant advertises pizza instead of answering."}
    ]
  }
}
```

## Source

Ported from `deepeval/metrics/turn_relevancy/turn_relevancy.py`
