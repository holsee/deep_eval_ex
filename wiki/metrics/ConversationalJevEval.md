# ConversationalJevEval Metric

ConversationalJevEval scores a whole conversation with your own questions, answered by a System One model (TypeSafe AI's Jev by default) with calibrated probabilities rather than generated text. It is the multi-turn counterpart of `DeepEvalEx.Metrics.JevEval`: the same Noul, Score and Choice questions, asked about a `DeepEvalEx.ConversationalTestCase`'s turns instead of a single test case's fields.

## When to Use

- Checks of a conversation you can phrase as yes/no propositions, ordered levels or a closed set of options
- Scoring chatbots without an LLM judge or LLM key: no LLM is called at any point
- Cheap, deterministic, explainable conversation scores (the reason is built from the answers, not generated)

## How It Works

1. **Build the state** - the conversation as JSON, deepeval's `construct_multi_turn_state`: `"turns"`, each turn's fields among the evaluation params (`role`, `content`, `retrieval_context`, `tools_called`), then `"test_case"` with the conversation-level params that are set (`scenario`, `expected_outcome`, `chatbot_role`, ...). `:content` and `:role` are always sent
2. **Ask once** - one System One request answers every question, keyed `q_0`, `q_1`, ...
3. **Value each answer** in `0..1`:
   - `Noul` - P(true)
   - `Score` - the expected level over the top level
   - `Choice` - the credit of the options, weighted by their probabilities; a Choice whose not-applicable options (credit `nil`) carry half the mass or more is dropped
4. **Calculate score** - the weighted mean of the questions that applied, or `1.0` when none did
5. **Higher score is better** - Success when score ≥ threshold

## Required Parameters

A `DeepEvalEx.ConversationalTestCase` with:

| Parameter | Description |
|-----------|-------------|
| `turns` | The conversation, each turn's `:role` and `:content` |
| the conversation-level evaluation params | e.g. `:chatbot_role`, `:scenario` or `:expected_outcome` when the questions refer to them |

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Metrics.ConversationalJevEval}
alias DeepEvalEx.SystemOne.Scored

metric =
  ConversationalJevEval.new(
    name: "Travel Agent",
    evaluation_params: [:chatbot_role],
    questions: [
      Scored.Noul.new!(statement: "The assistant remembers what the user told it.", weight: 2),
      Scored.Score.new!(
        question: "How well do the assistant's turns keep to `chatbot_role`?",
        levels: ["Not at all", "Partly", "Fully"]
      ),
      Scored.Choice.new!(
        question: "How does the assistant end the conversation?",
        options: [confirms_the_booking: 1.0, asks_again: 0.0, still_open: nil]
      )
    ],
    threshold: 0.7
  )

test_case =
  ConversationalTestCase.new!(
    chatbot_role: "A cheerful travel agent who keeps every reply short.",
    turns: [
      %{role: :user, content: "I'm flying to Lisbon on 3 May."},
      %{role: :assistant, content: "Lovely! Where are you flying to?"}
    ]
  )

{:ok, result} = ConversationalJevEval.evaluate(metric, test_case)

result.metric           # => "Travel Agent [Conversational JevEval]"
result.score            # => the weighted mean of the answers' values
result.confidence       # => the least decisive answer's confidence
result.score_breakdown  # => one outcome per question
```

The struct can also be passed to `DeepEvalEx.evaluate/3` like any other metric; its results export under `conversationalTestCases`.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | string | required | The metric's name; results are named `"<name> [Conversational JevEval]"` |
| `:evaluation_params` | list | required | The multi-turn params the questions refer to; `:content` and `:role` are appended when missing |
| `:questions` | list | required | `DeepEvalEx.SystemOne.Scored` Noul, Score and Choice questions |
| `:system_one_model` | term | TypeSafe Jev | The System One model |
| `:threshold` | float | 0.5 | Minimum passing score; `nil` for score-only |
| `:strict_mode` | boolean | false | Threshold `1`; the score is `1.0` only when every applicable question is answered at its best |
| `:include_reason` | boolean | true | Build the deterministic reason |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:flaky` | boolean | false | Never decide the test case's success |
| `:include_jev_eval_suffix` | boolean | true | Append `" [Conversational JevEval]"` to the name |

## Eval Modes

ConversationalJevEval is always decided by System One, whatever the `:eval_mode`: it has no LLM to fall back to. A System One error is raised, never caught (`DeepEvalEx.evaluate/3` records it as the metric's error), and the metric is not batched with other metrics.

## Test Case Checks

As deepeval's: a multimodal conversation raises `ArgumentError` (Jev has no image input); a missing conversation-level param (`:expected_outcome`, `:scenario`, `:metadata`, `:tags`, or `:chatbot_role` when it is an evaluation param) returns its error, as any conversational metric's.

## Differences from deepeval

- deepeval's MCP turn params are not ported, so they never reach the state

## Source

Ported from `deepeval/metrics/conversational_jev_eval/conversational_jev_eval.py` and `construct_multi_turn_state` in `deepeval/metrics/jev_eval/utils.py`
