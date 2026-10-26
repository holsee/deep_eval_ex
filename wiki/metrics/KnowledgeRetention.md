# KnowledgeRetention Metric

KnowledgeRetention measures whether a chatbot remembers what the user has told it over a whole conversation. The judge extracts the facts each user turn states, then decides for each assistant turn whether it forgets or contradicts the facts given before it; the score is the share of assistant turns that do not.

## When to Use

- Catching chatbots that ask for the same information twice
- Checking that form-filling or booking assistants keep the details the user gave
- Regression testing multi-turn agents on recorded conversations

## How It Works

1. **Extract knowledge** - for each user turn, the judge extracts the facts it states, given the turns before it: a dict of strings or lists of strings, or none
2. **Generate verdicts** - for each assistant turn that follows any facts, the judge decides:
   - `yes` - It forgets or contradicts a known fact (an attrition)
   - `no` - It is consistent with them, or only asks to clarify, confirm or correct one

   An assistant turn with no facts before it gets no verdict
3. **Calculate score** - `(no verdicts) / (total verdicts)`, or `1` when there are none
4. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.KnowledgeRetention}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "I'm flying to Lisbon on 3 May."},
      %{role: :assistant, content: "Great! Where are you flying to?"}
    ]
  )

{:ok, result} = KnowledgeRetention.measure(test_case)

result.score   # => 0.0 (the one assistant turn forgets the destination)
result.reason  # => "The score is 0.00 because the LLM asks for the destination, Lisbon, again."
result.success # => false (0.0 < 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.KnowledgeRetention`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `KnowledgeRetentionMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the facts and writes the reason; the System One model judges each assistant turn: one request per turn about its `llm_message` and the `accumulated_knowledge`, one Noul keyed `verdict`. P(yes), the probability that it forgets, of `0.5` and above is `yes`, below is `no`, each with the reason `"P(yes)=0.74"`. When a request fails, the LLM judges that turn and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `content` and `role`) answers the metric with two Nouls and a four-level Score, "Forgets most facts" to "Retains every fact"; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM.

## Differences from deepeval

- deepeval prints each dict of facts in the order the judge gave its keys. An answer decoded to an Elixir map prints its keys in map order; one decoded to `Jason.OrderedObject`s keeps the judge's order
- As in deepeval, a verdict outside yes and no (from a judge without structured outputs) cannot be explained: with `include_reason: true` the measure fails with deepeval's `'NoneType' object has no attribute 'verdict'`
- The facts are a free-form dict, as deepeval's `Knowledge` schema, which OpenAI's strict structured outputs cannot express: use a judge without them, or in JSON mode

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Knowledge Retention",
  score: 0.0,
  success: false,
  threshold: 0.5,
  reason: "The score is 0.00 because the LLM asks for the destination, Lisbon, again.",
  metadata: %{
    knowledges: [%{data: %{"Date" => "3 May", "Destination" => "Lisbon"}}, nil],
    verdicts: [%{verdict: :yes, reason: "The LLM asks for the destination, Lisbon, again."}]
  }
}
```

## Source

Ported from `deepeval/metrics/knowledge_retention/knowledge_retention.py`
