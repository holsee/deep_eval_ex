# TurnContextualRelevancy Metric

TurnContextualRelevancy measures whether what a RAG chatbot retrieves is relevant to what the user asks, throughout a conversation. For each of the assistant's answers, it judges a sliding window of the conversation that ends with it as [ContextualRelevancy](ContextualRelevancy.md) judges a single answer: the statements of each node of the retrieval context of the window's assistant turns against the window's user turns. The score is the mean of the windows' scores.

## When to Use

- Catching retrievers that pull in off-topic documents as a conversation goes on
- Tuning chunk sizes and top-k of a multi-turn RAG pipeline

## How It Works

1. **Slide a window** - for each unit interaction, a window of at most `:window_size` unit interactions ending with it
2. **Generate verdicts** - for each node of the window's retrieval context, one after the other, the judge extracts its statements and decides whether each is relevant to the window's user turns (`yes`) or not (`no`, with a reason; other verdicts are dropped)
3. **Score the window** - `yes / verdicts` over every node; the judge explains it from the relevant statements and the reasons of the irrelevant ones. A window without verdicts scores `1.0`
4. **Calculate score** - the mean of the windows' scores, or `1` without a window; the judge explains it from every window's reason
5. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have `:role`, `:content` and `:retrieval_context`.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnContextualRelevancy}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "Where is order 42?"},
      %{
        role: :assistant,
        content: "It shipped on 1 October.",
        retrieval_context: ["Order 42 shipped on 1 October. Rome is in Italy."]
      }
    ]
  )

{:ok, result} = TurnContextualRelevancy.measure(test_case)

result.score # => 0.5 (Rome is irrelevant)
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
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TurnContextualRelevancy`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TurnContextualRelevancyMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the System One model judges each node of each window, one request per node with one Noul per sentence of the node (`statement_<i>`) about the window's user turns (`user_message`). P(yes) of `0.5` and above is `yes`, each verdict with the reason `"P(yes)=0.91"`; the LLM writes the reasons. When a request fails, the LLM judges that node and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `retrieval_context`) answers the metric; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation is always judged by the LLM. A `RetrievedContextData` node is judged as Python's `str()` of it, as deepeval's prompt prints it (deepeval 4.3.1 raises on one before asking).

## Source

Ported from `deepeval/metrics/turn_contextual_relevancy/turn_contextual_relevancy.py`
