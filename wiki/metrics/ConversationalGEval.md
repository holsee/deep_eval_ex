# ConversationalGEval Metric

G-Eval for conversations: an LLM judges a whole multi-turn conversation (a
`DeepEvalEx.ConversationalTestCase`) against your own criteria, as deepeval's
`ConversationalGEval`.

## When to Use

- Custom criteria about a chatbot's conversation as a whole (helpfulness,
  politeness, resolving the user's request)
- Checking that a conversation plays out a scenario and reaches an expected
  outcome
- When single-turn [GEval](GEval.md) cannot see enough of the exchange

## How It Works

1. **Generate evaluation steps** - the judge turns your criteria into 3-4
   steps, unless you give `evaluation_steps`
2. **Score the conversation** - the judge scores it from 0 to 10, seeing each
   turn's evaluated fields ("Per-turn fields") and the evaluated
   conversation-level fields
3. **Get result** - the judge's score divided by 10, with its reason

## Evaluation Params

`evaluation_params` takes `DeepEvalEx.Params.MultiTurn` params. `:content`
and `:role` are always evaluated: they are appended when missing, as in
deepeval.

| Parameter | Scope | Description |
|-----------|-------|-------------|
| `:content` | turn | What was said |
| `:role` | turn | `user` or `assistant` |
| `:retrieval_context` | turn | The turn's retrieved context |
| `:tools_called` | turn | The turn's tool calls |
| `:scenario` | conversation | The situation the conversation plays out |
| `:expected_outcome` | conversation | How the conversation should end |
| `:metadata` | conversation | The test case's metadata |
| `:tags` | conversation | The test case's tags |

A conversation-level param it evaluates must be set on the test case, or the
metric errors with deepeval's `MissingTestCaseParamsError` message.
`:audio` is not supported (DeepEvalEx's judges take text only), and params
deepeval cannot name in the prompt (`:context`, `:user_description`,
`:chatbot_role`, ...) are rejected by `new/1`.

## Basic Usage

```elixir
alias DeepEvalEx.{ConversationalTestCase, Evaluator}
alias DeepEvalEx.Metrics.ConversationalGEval

metric =
  ConversationalGEval.new(
    name: "Resolution",
    criteria: "Determine whether the assistant resolves the user's request politely.",
    evaluation_params: [:scenario, :content]
  )

test_case =
  ConversationalTestCase.new!(
    scenario: "A customer asks for a refund on a late order.",
    turns: [
      %{role: :user, content: "My order is late, I want a refund."},
      %{role: :assistant, content: "Sorry! Could you give me the order number?"},
      %{role: :user, content: "It's order 42."},
      %{role: :assistant, content: "Thanks, I've started a refund for order 42."}
    ]
  )

[[result]] = Evaluator.evaluate([test_case], [metric])

result.metric  # => "Resolution [Conversational GEval]"
result.score   # => 0.8
result.reason  # => "The assistant asked for the order number, then started the refund..."
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | string | required | Name for this metric |
| `:evaluation_params` | list | required | Multi-turn params to evaluate |
| `:criteria` | string | nil | Evaluation criteria (required unless `:evaluation_steps`) |
| `:evaluation_steps` | list | nil | Pre-defined evaluation steps |
| `:rubric` | list | nil | `DeepEvalEx.Metrics.GEval.Rubric` entries the judge scores by |
| `:threshold` | float | 0.5 | Pass/fail threshold; `nil` for score-only |
| `:strict_mode` | boolean | false | Threshold forced to `1`: any score below is `0` |
| `:model` | tuple/string | default | LLM model to use |
| `:top_logprobs` | integer | 20 | Score tokens a judge with logprobs returns for weighting |
| `:include_g_eval_suffix` | boolean | true | Name results `"<name> [Conversational GEval]"`; when false, just `"<name>"` |
| `:verbose_mode` | boolean | false | Print the criteria, steps, rubric and score after measuring |
| `:evaluation_template` | module | nil | Override the prompts (`DeepEvalEx.Prompts.ConversationalGEval`) |

## Differences from GEval

- The judge always scores from 0 to 10, rubric or not, and the score is
  divided by 10: a fractional score such as 2.5 is kept.
- Strict mode asks the same question; a score below 1 becomes `0`.
- With a judge that returns log probabilities, the score is weighted by the
  **first** token equal to the score (even one in the reason), and a weighting
  left with no token errors the metric (`"float division by zero"`), as in
  deepeval.
- deepeval's asynchronous `evaluate()` measures a copy of the metric that
  reports its evaluation model as `"<judge> (audio: <judge>)"`; the
  `DeepEvalEx.Evaluator` does the same unless `run_async: false`.

## Eval Modes

ConversationalGEval is always judged by its LLM: under the `:hybrid` and
`:system_one` eval modes it still calls its LLM and no System One model.
