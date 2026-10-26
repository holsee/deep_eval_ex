# EvaluationResult

`DeepEvalEx.evaluate/3` returns `{:ok, %DeepEvalEx.EvaluationResult{}}`, the
counterpart of what deepeval's `evaluate()` returns: one
`DeepEvalEx.TestResult` per test case.

## Overview

```elixir
{:ok, %DeepEvalEx.EvaluationResult{test_results: test_results}} =
  DeepEvalEx.evaluate(test_cases, [DeepEvalEx.Metrics.ExactMatch])

for test_result <- test_results do
  IO.puts("#{test_result.name}: #{test_result.success}")

  for result <- test_result.metrics_data do
    IO.puts("  #{result.metric}: #{result.score}")
  end
end
```

## EvaluationResult Fields

| Field | Type | Description |
|-------|------|-------------|
| `test_results` | `[TestResult.t()]` | One per test case, in the order given |
| `confident_link` | `nil` | Always `nil`: DeepEvalEx does not upload to Confident AI |
| `test_run_id` | `nil` | Always `nil` |

## TestResult Fields

Built as deepeval's `create_test_result` builds deepeval's `TestResult`.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String.t()` | The test case's name, or `"test_case_<index>"` |
| `success` | `boolean() \| nil` | `false` when a non-flaky metric failed, else `true`; `nil` when nothing gave a verdict |
| `metrics_data` | `[Result.t()]` | One `DeepEvalEx.Result` per metric that ran (deepeval's `MetricData`); skipped metrics are left out |
| `conversational` | `boolean()` | Always `false` |
| `index` | `non_neg_integer()` | The test case's position in the list |
| `input`, `actual_output`, `expected_output` | `String.t() \| nil` | From the test case |
| `context`, `retrieval_context` | `[String.t()] \| nil` | From the test case |
| `metadata` | `map() \| nil` | From the test case |
| `classifications` | `list()` | Classifier results; always `[]` until DeepEvalEx has classifiers |

Score-only results (`success: nil`) and flaky ones never decide a test
case's `success`, as in deepeval. Where deepeval uses `None` for an empty
`metrics_data` or `classifications`, DeepEvalEx uses `[]`.

## The test run

`DeepEvalEx.evaluate_run/3` evaluates the same way and returns
`{results, test_run, path}`, with the result lists, the
[`DeepEvalEx.TestRun`](TestRun.md) and the path of the file it saved. Build
an `EvaluationResult` from its results with
`DeepEvalEx.EvaluationResult.from_results/2`:

```elixir
{results, test_run, _path} = DeepEvalEx.evaluate_run(test_cases, metrics)
evaluation = DeepEvalEx.EvaluationResult.from_results(test_cases, results)
```

## Migrating from the old return shapes

Until the next release, the old shapes still work with a deprecation warning:

| Old | New |
|-----|-----|
| `{:ok, results} = DeepEvalEx.evaluate(test_case, metrics)` | `{:ok, %EvaluationResult{test_results: [%TestResult{metrics_data: results}]}} = DeepEvalEx.evaluate([test_case], metrics)` |
| `results = DeepEvalEx.evaluate_batch(test_cases, metrics)` | `{:ok, evaluation} = DeepEvalEx.evaluate(test_cases, metrics)`, or `{results, _, _} = DeepEvalEx.evaluate_run(test_cases, metrics)` for the result lists |

`evaluate_run/3` is not deprecated.
