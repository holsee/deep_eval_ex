# deepeval golden fixtures

Test run exports written by **deepeval 4.3.1**, used by
`test/deep_eval_ex/parity_test.exs` to check that DeepEvalEx writes the same
`test_run_<timestamp>.json` files as deepeval, down to the bytes.

Each directory is one scenario:

| Scenario          | What it covers                                                                                 |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `exact_match`     | `ExactMatchMetric` passing and failing over 3 test cases, one with name, tags, metadata, comments |
| `llm_metric`      | Two stub metrics emulating LLM judges: reason, evaluation model, cost and token counts         |
| `metric_error`    | A metric that raises, with `ignore_errors=True`: `error` set, no `score`, counted in `errors`  |
| `rag_and_tools`   | `retrieval_context`, `context`, `tools_called` / `expected_tools`, `token_cost`, `completion_time` |
| `hyperparameters` | `identifier` and `hyperparameters` (string, float, int, bool and dropped `None` values)        |

and holds:

- `input.json` - the scenario's inputs: `test_cases` (keyword arguments of
  deepeval's `LLMTestCase`), `metrics` (`exact_match`, `stub` or `error`
  specs), `identifier` and `hyperparameters`
- `test_run.json` - the file deepeval wrote for those inputs, unchanged

No LLM is called. The `stub` and `error` metrics are custom deepeval
`BaseMetric`s returning fixed values or raising; the parity test mirrors them
with `DeepEvalEx.Test.ParityMetrics.Stub` and `.Failing`
(`test/support/parity_metrics.ex`).

## Regenerating

Run the generator inside the devcontainer, where deepeval 4.3.1 is installed,
from the repository root:

```sh
devcontainer exec --workspace-folder . \
  env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_fixtures.py
```

The script refuses any other deepeval version, opts out of telemetry, never
logs in to Confident AI, turns the console output off and runs deepeval in a
temporary working directory so its `.deepeval/` cache stays out of the
repository. It rewrites every scenario directory; scenarios are defined in
`SCENARIOS` at the top of the script. A new scenario also needs its name in
the parity test's "covers every scenario" assertion.

Then run `mix test test/deep_eval_ex/parity_test.exs`. A difference is a bug
to fix in DeepEvalEx, not something to normalise away.

## What the parity test normalises

Only values that differ between two identical runs:

- the run-level `runDuration` (wall-clock time of the whole run)

Test-case `runDuration` is compared as is: deepeval's async executor records
any test case that took under a second as the integer `0`, which these
metrics always do.
