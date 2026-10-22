# TurnFaithfulness Metric

TurnFaithfulness measures whether a RAG chatbot's answers stay grounded in what it retrieved, throughout a conversation. For each of the assistant's answers, it judges a sliding window of the conversation that ends with it as [Faithfulness](Faithfulness.md) judges a single answer: the claims of the window's assistant turns against the truths of their retrieval context. The score is the mean of the windows' scores.

## When to Use

- Checking that a RAG support chatbot does not make up facts, turn after turn
- Catching answers that contradict the documents retrieved for them
- Regression testing multi-turn RAG pipelines on recorded conversations

## How It Works

1. **Slide a window** - for each unit interaction (the user's turn(s) and the assistant's answer), a window of at most `:window_size` unit interactions ending with it
2. **Extract truths** - from the retrieval context of the window's assistant turns, joined with blank lines
3. **Extract claims** - from the window's assistant turns, the user turns only resolving references
4. **Generate verdicts** - for each claim:
   - `yes` - Supported by the truths
   - `no` - Contradicts the truths
   - `borderline` - Neither (a legacy `idk` reads as `borderline`; other verdicts are dropped)
5. **Score the window** - `(yes + borderline) / verdicts` (`yes / verdicts` with `penalize_ambiguous_claims: true`), or `1.0` without a claim; the judge explains it from the contradictions
6. **Calculate score** - the mean of the windows' scores, or `1` without a window; the judge explains it from every window's reason
7. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` whose turns have:

| Parameter | Description |
|-----------|-------------|
| `:role` | `:user` or `:assistant` |
| `:content` | What was said |
| `:retrieval_context` | What the assistant retrieved for its turn |

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnFaithfulness}

test_case =
  ConversationalTestCase.new!(
    turns: [
      %{role: :user, content: "When did order 42 ship?"},
      %{
        role: :assistant,
        content: "On 1 October. Refunds take 2 days.",
        retrieval_context: ["Order 42 shipped on 1 October.", "Refunds take 5 business days."]
      }
    ]
  )

{:ok, result} = TurnFaithfulness.measure(test_case)

result.score   # => 0.5 (the refund claim contradicts the context)
result.success # => true (0.5 >= 0.5 threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:strict_mode` | boolean | false | Threshold `1`, and a window's score below it is `0` (the mean is not clamped) |
| `:window_size` | integer | 10 | The most unit interactions in each window |
| `:truths_extraction_limit` | integer | nil | The most truths to extract per window |
| `:penalize_ambiguous_claims` | boolean | false | Count borderline claims as unfaithful |
| `:include_reason` | boolean | true | Generate explanations |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:evaluation_template` | module | `nil` | Overrides some of the prompts (`DeepEvalEx.Prompts.TurnFaithfulness`) |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `TurnFaithfulnessMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts each window's truths and claims and writes the reasons; the System One model judges each window's claims, one request per window with one Noul per claim (`claim_<i>`) about the truths as `reference_context`. P(yes) above `0.65` is `yes`, below `0.35` `no`, else `borderline`, each with the reason `"P(yes)=0.91"`. When a request fails, the LLM judges that window and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about the whole conversation (each turn's `role`, `content` and `retrieval_context`) answers the metric with two Nouls and a four-level Score, "Fabricated" to "Fully grounded"; no LLM is called. It can be batched with the test case's other `system_one` conversational metrics

A multimodal conversation has no `:system_one` form.

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Turn Faithfulness",
  score: 0.5,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.5 because the refund time contradicts the context.",
  metadata: %{
    windows: [
      %{score: 0.5, reason: "Refunds take 5 business days, not 2.", truths: [...], claims: [...],
        verdicts: [%{verdict: :yes, reason: nil}, %{verdict: :no, reason: "..."}]}
    ]
  }
}
```

## Source

Ported from `deepeval/metrics/turn_faithfulness/turn_faithfulness.py`
