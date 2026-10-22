# TestRun

`DeepEvalEx.TestRun` is a completed evaluation run in deepeval's `TestRun`
export format: the same `test_run_<timestamp>.json` files deepeval writes,
down to the bytes, and the same files read back.

## Overview

deepeval saves every `evaluate()` call as a JSON file when a results folder
is configured. DeepEvalEx does the same, so dashboards, scripts and diff
tools built for deepeval's files work unchanged, and runs written by either
library can be loaded by DeepEvalEx.

## Exporting

`DeepEvalEx.evaluate_run/3` evaluates, builds the run and writes the file:

```elixir
{results, test_run, path} =
  DeepEvalEx.evaluate_run(test_cases, [DeepEvalEx.Metrics.ExactMatch],
    results_folder: "eval_results",
    identifier: "nightly",
    hyperparameters: [model: "gpt-4o", temperature: 0.7]
  )

path # => "eval_results/test_run_20261022_101500.json"
```

Without `:results_folder` (or the `DEEPEVAL_RESULTS_FOLDER` environment
variable) nothing is written and `path` is `nil`. To build and encode a run
yourself:

```elixir
results = DeepEvalEx.evaluate_batch(test_cases, metrics)

json =
  test_cases
  |> DeepEvalEx.TestRun.from_results(results, identifier: "nightly")
  |> DeepEvalEx.TestRun.to_map()
  |> DeepEvalEx.TestRun.JSON.encode!()
```

`to_map/1` uses deepeval's camelCase keys and key order and leaves out
`nil` values; `DeepEvalEx.TestRun.JSON` formats it like Python's
`json.dumps` (`", "` separators, `\uXXXX` escapes, Python float formatting).

## Importing

`load/1` reads a file written by deepeval or DeepEvalEx; `from_map/1` takes
already decoded JSON:

```elixir
{:ok, test_run} = DeepEvalEx.TestRun.load("eval_results/test_run_20261022_101500.json")

test_run.test_passed      # => 2
test_run.evaluation_cost  # => 0.000642

[test_case | _] = test_run.test_cases
[metric_data | _] = test_case.metrics_data

metric_data.score            # => 0.75
metric_data.evaluation_model # => "gpt-4o-mini"
metric_data.strict_mode      # => false
```

Test cases are `DeepEvalEx.TestRun.TestCase` structs and their metric
results are `DeepEvalEx.TestRun.MetricData` structs, keeping everything in
the file: scores, reasons, errors, evaluation model, token counts, cost,
strict mode and flakiness. `to_results/1` converts them to the structs the
rest of DeepEvalEx uses, in the shape `DeepEvalEx.evaluate_batch/3`
returns:

```elixir
{test_cases, results} = DeepEvalEx.TestRun.to_results(test_run)

# test_cases :: [DeepEvalEx.TestCase.t()]
# results    :: [[DeepEvalEx.Result.t()]]
Enum.filter(List.flatten(results), &DeepEvalEx.Result.errored?/1)
```

### Round trip

Loading is lossless for every field DeepEvalEx models. Re-encoding a loaded
deepeval file gives back the original bytes:

```elixir
{:ok, test_run} = DeepEvalEx.TestRun.load(path)

json = test_run |> DeepEvalEx.TestRun.to_map() |> DeepEvalEx.TestRun.JSON.encode!()
json == File.read!(path)
# => true
```

Values are kept as they appear in the file: a test case `runDuration` of
`0` stays the integer `0`, and JSON objects (metadata, tool call
parameters, hyperparameters) stay `Jason.OrderedObject`s so their key order
survives.

### Missing and unknown keys

- **Required**: a test case's and a metric's `name`, and each
  `metricsScores` entry's `metric`. Anything else may be missing.
- **Missing optional keys** get deepeval's defaults (`nil`, `false`, `[]`).
  A test case's `success` is computed from its metric data and its `order`
  from its position; `metricsScores`, `testPassed` and `testFailed` are
  computed from the test cases; a metric's missing `success` is `false`.
- **Unknown keys** (`testFile`, `datasetAlias`, `trace`, `verboseLogs`, ...)
  are ignored, as deepeval's pydantic models ignore extra keys, and are not
  written back. Conversational test cases and prompts are ignored too.

### Errors

| Return | Cause |
|--------|-------|
| `{:error, :enoent}` (any `File.posix()`) | The file could not be read |
| `{:error, %Jason.DecodeError{}}` | The file is not JSON |
| `{:error, {:invalid_test_run, message}}` | A required key is missing or a value has the wrong shape; `message` starts with its path, e.g. `"testCases[1].name: expected a string, got nil"` |

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `test_cases` | `[TestRun.TestCase.t()]` | One entry per evaluated test case |
| `metrics_scores` | `[map()]` | Per metric: `scores`, `passes`, `fails` and `errors` |
| `identifier` | `String.t() \| nil` | Name of the run |
| `hyperparameters` | `[{String.t(), term()}] \| nil` | Settings that produced the outputs |
| `test_passed` / `test_failed` | `non_neg_integer()` | Passing and failing test cases |
| `run_duration` | `float()` | Wall-clock seconds of the whole run |
| `evaluation_cost` | `float() \| nil` | Summed cost; `nil` when nothing was priced |

## See Also

- [Evaluator](Evaluator.md) - Batch evaluation
- [Result](Result.md) - Metric results
- [TestCase](TestCase.md) - Test case structure
