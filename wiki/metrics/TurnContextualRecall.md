# TurnContextualRecall Metric

TurnContextualRecall measures whether a RAG chatbot retrieves what it needs, throughout a conversation. For each of the assistant's answers, it judges a sliding window of the conversation that ends with it as [ContextualRecall](ContextualRecall.md) judges a single answer: whether each sentence of the conversation's `expected_outcome` can be attributed to the retrieval context of the window's assistant turns. The score is the mean of the windows' scores.

## When to Use

- Checking that a multi-turn RAG pipeline retrieves the facts the ideal outcome needs
- Comparing embedding models or chunking strategies on recorded conversations

## How It Works

1. **Slide a window** - for each unit interaction, a window of at most `:window_size` unit interactions ending with it
2. **Generate verdicts** - for each sentence of the `expected_outcome`, whether the window's retrieval context supports it (`yes`) or not (`no`; other verdicts are dropped)
3. **Score the window** - `yes / verdicts`; the judge explains it from the supportive and unsupportive reasons. A window without retrieval context scores `1.0`
4. **Calculate score** - the mean of the windows' scores, or `1` without a window; the judge explains it from every window's reason
5. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` with an `:expected_outcome`, whose turns have `:role`, `:content` and `:retrieval_context`.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnContextualRecall}

test_case =
  ConversationalTestCase.new!(
    expected_outcome: "Order 42 shipped on 1 October. Refunds take 5 days.",
    turns: [
      %{role: :user, content: "Where is order 42?"},
      %{
        role: :assistant,
        content: "It shipped on 1 October.",
        retrieval_context: ["Order 42 shipped on 1 October."]
      }
    ]
  )

{:ok, result} = TurnContextualRecall.measure(test_case)

result.score # => 0.5 (no node supports the refund sentence)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a window's score below it is `0` (the mean is not clamped) |
| `:window_size` | integer | 10 | The most unit interactions in each window |
| `:include_reason` | boolean | true | Generate explanations |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TurnContextualRecall`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TurnContextualRecallMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model judges each window, one request per window with one Noul per sentence of the `expected_outcome` (`sentence_<i>`) about the window's `retrieval_context`. P(yes) of `0.5` and above is `yes`; the LLM writes the reasons. When a request fails, the LLM judges that window and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `retrieval_context`, and the `expected_outcome`) answers the metric; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM.

## Source

Ported from `deepeval/metrics/turn_contextual_recall/turn_contextual_recall.py`
