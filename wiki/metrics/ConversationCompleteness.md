# ConversationCompleteness Metric

ConversationCompleteness measures whether a chatbot satisfies what the user wants over a whole conversation. The judge lists the user's intentions, then decides for each whether the conversation satisfies it; the score is the share that are satisfied.

## When to Use

- Checking that a chatbot completes every task the user asks for, not just the first
- Catching conversations that end with a question unanswered or a request half done
- Regression testing multi-turn agents on recorded conversations

## How It Works

1. **Extract intentions** - the judge lists the user's intentions in the conversation, each task separately
2. **Generate verdicts** - for each intention, the judge reads the whole conversation and decides:
   - `yes` - Satisfied
   - `no` - Not satisfied, with a reason
3. **Calculate score** - `(satisfied intentions) / (total verdicts)`, or `1` when the user expressed none. Verdicts other than `yes` and `no` are dropped
4. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.ConversationCompleteness}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "Book a table for two on Friday, and tell me the dress code."},
      %{role: :assistant, content: "Your table for two is booked for Friday at 8pm."}
    ]
  )

{:ok, result} = ConversationCompleteness.measure(test_case)

result.score   # => 0.5 (1 of 2 intentions is satisfied)
result.reason  # => "The score is 0.5 because the LLM books the table but never gives the dress code."
result.success # => true (0.5 >= 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:window_size` | integer | 3 | Taken, as deepeval 4.3.1's, but unused: every verdict sees the whole conversation |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.ConversationCompleteness`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `ConversationCompletenessMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the intentions and writes the reason; the System One model judges each intention: one request per intention about the `turns` and the `intention`, one Noul keyed `verdict`. P(yes) of `0.5` and above is `yes` (satisfied), below is `no`, each with the reason `"P(yes)=0.91"`. When a request fails, the LLM judges that intention and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `content` and `role`) answers the metric with two Nouls and a four-level Score, "None satisfied" to "All satisfied"; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM, whose prompts then carry deepeval's multimodal input rules.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Conversation Completeness",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.5 because the LLM books the table but never gives the dress code.",
  metadata: %{
    user_intentions: ["User wants to book a table for two on Friday",
                      "User wants to know the dress code"],
    verdicts: [
      %{verdict: :yes, reason: nil},
      %{verdict: :no, reason: "The LLM never says what the dress code is."}
    ]
  }
}
```

## Source

Ported from `deepeval/metrics/conversation_completeness/conversation_completeness.py`
