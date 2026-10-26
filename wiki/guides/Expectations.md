# Expectations

Expectations say what a response must do and must not do, in plain
conditions on the test case itself: "states the refund policy", "never
promises a refund". They are deepeval 4.3.1's `Expectations`. You declare
them on a test case or golden; the evaluation judges them for you, with no
metric to configure.

## Declaring expectations

```elixir
test_case =
  DeepEvalEx.TestCase.new!(
    input: "Can I get a refund on a used ticket?",
    actual_output: "Used tickets can't be refunded, but you can exchange it within 30 days.",
    expectations: %{
      must: ["States the refund policy", "Offers an exchange"],
      must_not: ["Promises a refund"]
    }
  )
```

`DeepEvalEx.ConversationalTestCase`, `DeepEvalEx.Dataset.Golden` and
`DeepEvalEx.Dataset.ConversationalGolden` take `:expectations` too, and a
golden's expectations carry over to the test case built from it. Each
condition must be a non-blank string; `DeepEvalEx.Dataset.Expectations.cast/1`
lists every rule.

## Evaluating them

`DeepEvalEx.evaluate/3`, `DeepEvalEx.evaluate_run/3`,
`DeepEvalEx.Dataset.EvaluationDataset.evaluate/4` and `assert_evaluation/3`
judge the expectations of every test case that has some, after its metrics:

```elixir
{:ok, %{test_results: [test_result]}} = DeepEvalEx.evaluate([test_case], [])

[expectations] = test_result.metrics_data
expectations.metric   #=> "Expectations"
expectations.success  #=> true when every must holds and no must_not does
```

The result is threshold 1 and strict: one failed condition fails it, and it
fails the test case like any metric. Its `:expectations_data`
(`DeepEvalEx.TestRun.ExpectationsData`) holds the judge's verdict for each
condition. Expectations alone are enough to evaluate: a run without metrics
or classifiers needs every test case to have some, and raises otherwise, as
deepeval does. With expectations in the run, the metrics need no threshold.

A condition the judge cannot evaluate (the observations it needs are
missing) errors the result with `"Unable to evaluate expectations: ..."`,
which raises unless `ignore_errors: true`.

## The judge

```elixir
expectations: %{must: ["Cites the policy page"], model: "gpt-4.1", eval_mode: :system_one}
```

- `:llm` (the default): the judge model, `:model` or else the run's
  `:model`, gives one verdict per condition, then writes the reason.
- `:system_one`: the run's `:system_one_model` (Jev by default) answers one
  Choice per condition, pass, fail or unable to evaluate, and the reason is
  deterministic. It shares one request with the test case's other System
  One metrics.

The `:eval_mode` setting (`DEEPEVAL_EVAL_MODE`) wins over the expectations'
own `:eval_mode`, as in deepeval, and `:hybrid` runs as `:llm`.

The judge sees the observed test case: its input, output, context,
retrieval context, metadata, tool calls and tags, or a conversation's turns,
scenario, context, chatbot role, metadata and tags
(`DeepEvalEx.Dataset.Expectations.evidence/1`).

## In the test run

The test run file carries the judgement as the test case's
`expectationsData`, with each condition's `kind` (`MUST` or `MUST_NOT`),
`status`, `reason` and `evidence`, and not as one of its `metricsData` or in
`metricsScores`, so deepeval's tools read it as they read deepeval's own
runs.
