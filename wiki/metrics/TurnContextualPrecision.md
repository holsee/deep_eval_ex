# TurnContextualPrecision Metric

TurnContextualPrecision measures whether a RAG chatbot's retriever ranks the useful documents first, throughout a conversation. For each of the assistant's answers, it judges a sliding window of the conversation that ends with it as [ContextualPrecision](ContextualPrecision.md) judges a single answer: whether each node of the retrieval context of the window's assistant turns helps reach the conversation's `expected_outcome`, and how well the useful nodes are ranked. The score is the mean of the windows' scores.

## When to Use

- Tuning the reranker of a multi-turn RAG pipeline
- Catching retrievers whose useful documents sink below irrelevant ones as a conversation goes on

## How It Works

1. **Slide a window** - for each unit interaction, a window of at most `:window_size` unit interactions ending with it
2. **Generate verdicts** - for each node of the retrieval context of the window's assistant turns, in order, whether it was useful in arriving at the `expected_outcome` for the window's user turns (`yes`) or not (`no`; other verdicts are dropped)
3. **Score the window** - the weighted cumulative precision of its verdicts; the judge explains it. A window without retrieval context scores `1.0`
4. **Calculate score** - the mean of the windows' scores, or `1` without a window; the judge explains it from every window's reason
5. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` with an `:expected_outcome`, whose turns have `:role`, `:content` and `:retrieval_context`.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnContextualPrecision}

test_case =
  ConversationalTestCase.new!(
    expected_outcome: "The assistant says order 42 shipped on 1 October.",
    turns: [
      %{role: :user, content: "Where is order 42?"},
      %{
        role: :assistant,
        content: "It shipped on 1 October.",
        retrieval_context: ["Rome is in Italy.", "Order 42 shipped on 1 October."]
      }
    ]
  )

{:ok, result} = TurnContextualPrecision.measure(test_case)

result.score # => 0.5 (the useful node is ranked second)
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
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TurnContextualPrecision`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TurnContextualPrecisionMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model judges each window's nodes, one request per window with one Noul per node (`node_<i>`) about the window's user turns (`user_message`) and the `expected_outcome` (`assistant_output`). P(yes) of `0.5` and above is `yes`; the LLM writes the reasons. When a request fails, the LLM judges that window and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `retrieval_context`, and the `expected_outcome`) answers the metric; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation has no `:system_one` form.

## Source

Ported from `deepeval/metrics/turn_contextual_precision/turn_contextual_precision.py`
