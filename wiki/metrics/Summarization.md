# Summarization Metric

Summarization measures how good a summary is: whether its claims agree with the original text (alignment) and whether it keeps the original's key information (coverage). The original text is the test case's `input` and the summary its `actual_output`; the score is the lower of the two scores.

## When to Use

- Evaluating summarisation features: meeting notes, ticket digests, article and document summaries
- Catching summaries that contradict their source or pad it with information it does not contain
- Checking that summaries keep the facts that matter to you, with your own assessment questions

## How It Works

1. **Extract truths and claims** - The truths of the original text and the claims of the summary, with the Faithfulness prompts (`:truths_extraction_limit` caps the truths)
2. **Alignment** - For each claim, determine if it:
   - `yes` - Agrees with the original text
   - `no` - Contradicts it
   - `borderline` - Is not backed up by it (extra information)

   The alignment score is `(agreeing claims) / (total verdicts)`: unlike Faithfulness, borderline claims count against it. It is `0` when the summary has no claims
3. **Coverage** - The judge writes `n` closed-ended questions the original text answers "yes" (or takes your `:assessment_questions`), then answers each from the original text and from the summary. The coverage score is `(questions both answer "yes") / (questions the original answers "yes")`, or `0` when the original answers none
4. **Calculate score** - `min(alignment, coverage)`; both are in `result.score_breakdown`
5. **Higher score is better** - Success when score ≥ threshold

The reason prompt lists the contradicting claims, the extra ones and the questions the summary cannot answer.

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The original text |
| `:actual_output` | The summary |

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.Summarization}

test_case = TestCase.new!(
  input: """
  The city council approved a new riverside park on Monday. Construction starts
  in March and the park opens in May. It will have a lake, a playground and 200
  new trees.
  """,
  actual_output: "The council approved a riverside park with a lake. It opens in May."
)

{:ok, result} = Summarization.measure(test_case, n: 3)

result.score            # => 0.6666666666666666
result.score_breakdown  # => %{"Alignment" => 1.0, "Coverage" => 0.6666666666666666}
result.reason           # => "The score is 0.67 because the summary leaves out the playground."
```

## Assessment Questions

Generated questions vary from run to run. To check the facts that matter to you, give your own closed-ended questions, which the original text should answer "yes":

```elixir
Summarization.measure(test_case,
  assessment_questions: [
    "Did the council approve a riverside park?",
    "Does the park open in May?",
    "Will the park have a playground?"
  ]
)
```

As in deepeval, an empty list counts as none given.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Minimum passing score (higher is better) |
| `:n` | integer | 5 | How many assessment questions to generate |
| `:assessment_questions` | list | nil | Your own questions, in place of generated ones |
| `:truths_extraction_limit` | integer | nil (all) | Max truths to extract from the original text (a negative limit is `0`) |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

`Summarization.new/1` takes the same options and builds a configured metric for `DeepEvalEx.evaluate/3`, so its assessment questions and truths limit do not reach the other metrics of the run (Faithfulness also reads `:truths_extraction_limit`):

```elixir
metric = Summarization.new(assessment_questions: ["Does the park open in May?"])
DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.AnswerRelevancy])
```

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | Every claim agrees with the original, and every key point is covered (best) |
| 0.5 | Half of the claims agree, or half of the key points are covered |
| 0.0 | No claim agrees, no key point is covered, or the summary has no claims (worst) |

## System One

As deepeval 4.3.1's `SummarizationMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM extracts the truths and claims, scores coverage and writes the reason; the System One model judges each claim against the truths, one Noul per claim (`summary_claim_0`, `summary_claim_1`, ...) in one request. P(yes) above `0.65` is `yes`, below `0.35` `no`, else `borderline`, each with the reason `"P(yes)=0.96"`. When the request fails, the LLM judges the claims and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about `input` and `actual_output` answers the whole metric: a Noul (weight 2) that every claim agrees with the original, a Noul that the summary covers its main points and a four-level Score, "Almost none" to "All of it", then one Noul per assessment question you gave, that the summary answers it as the original does. No LLM is called, and the request can be batched with the test case's other `system_one` metrics

```elixir
{:ok, result} = Summarization.measure(test_case, eval_mode: :hybrid)
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Summarization",
  score: 0.6666666666666666,
  success: true,
  threshold: 0.5,
  reason: "The score is 0.67 because the summary leaves out the playground.",
  score_breakdown: %{"Alignment" => 1.0, "Coverage" => 0.6666666666666666},
  metadata: %{
    truths: ["The city council approved a new riverside park on Monday.", ...],
    claims: ["The council approved a riverside park.", ...],
    assessment_questions: ["Did the council approve a riverside park?", ...],
    coverage_verdicts: [
      %{summary_verdict: "yes", original_verdict: "yes",
        question: "Did the council approve a riverside park?"},
      ...
    ],
    alignment_verdicts: [%{verdict: :yes, reason: nil}, ...],
    truths_extraction_limit: nil
  }
}
```

## Source

Ported from `deepeval/metrics/summarization/summarization.py`
