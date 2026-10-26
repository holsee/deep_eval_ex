# Console Report

After a run, deepeval 4.3.1's `evaluate()` prints an evaluation report and
a short summary. `DeepEvalEx.evaluate_run/3` prints the same, with the
same strings, so a run reads the same in either.

## What is printed

```elixir
DeepEvalEx.evaluate_run(test_cases, [Faithfulness, {AnswerRelevancy, threshold: 0.7}])
```

```
╭──────────────────────────────────────────────────────────────────────────────╮
│ 🚀 DeepEval Evaluation Results                                               │
╰──────────────────────────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────────────────────────╮
│ ✅ test_case_0 (Passed 2 metrics)                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────────────────────────╮
│                                                                              │
│  ❌ refund question                                                          │
│  ├──   Input:              Can I get a refund on a used ticket?              │
│  │     Actual Output:      Yes, always.                                      │
│  └── Metrics                                                                 │
│       Status ┃ Metric           ┃ Score ┃ Threshold ┃ Reason                 │
│      ━━━━━━━━╇━━━━━━━━━━━━━━━━━━╇━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━  │
│        FAIL  │ Answer Relevancy │ 0.33  │ 0.70      │ Off topic.             │
│                                                                              │
╰──────────────────────────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────────────────────────╮
│ Aggregate Metrics                                                            │
│  Metric           ┃ Average Score ┃ Pass Rate                       ┃ Total  │
│ ━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━ │
│  Answer Relevancy │ 0.62          │ 50.00% | passed=1 | failed=1    │ 2      │
╰──────────────────────────────────────────────────────────────────────────────╯

⚠ WARNING: No hyperparameters logged.
» Log hyperparameters to attribute prompts and models to your test runs.

================================================================================

✓ Evaluation completed 🎉! (time taken: 1.23s | token cost: 0.0012 USD)
» Test Results (2 total tests):
   » Pass Rate: 50.0% | Passed: 1 | Failed: 1
```

- A panel per test case, sorted by index, then by name (`case 2` before
  `case 10`). A passing test case is one line; a failing one shows its
  input and outputs (or a conversation's turns), its metrics and its
  classifications. Statuses are PASS, FAIL, ERROR and NONE: a score-only
  metric, or a classification without an expected label, has no verdict.
- The aggregate tables, over every test case: each metric's average
  score and pass rate (flaky results counted in a `(flaky=N)`
  sub-count), and each classifier's labels, pass rate and errors.
- The wrap-up: a warning when no hyperparameters (or no prompts) were
  logged, or when every metric errored, then the time, cost and pass
  rate.

`DeepEvalEx.evaluate/3` stays silent unless you pass `print_results:
true`, so library code calling it prints nothing.

## Options

| Option | deepeval | Default |
|---|---|---|
| `:print_results` | `DisplayConfig.print_results` | the `:print_results` setting, `true` |
| `:display` | `display_option`: `:all`, `:failing` or `:passing` | `:all` |
| `:truncate_passing_cases` | `truncate_passing_cases` | `true` |
| `:file_output_dir` | `file_output_dir` with `file_type="md"` | `nil` |

```elixir
DeepEvalEx.evaluate_run(test_cases, metrics,
  display: :failing,
  truncate_passing_cases: false,
  file_output_dir: "reports",
  identifier: "Nightly Run"
)
#=> also writes reports/nightly_run_20261023_101500.md
```

With `display: :failing` only failing test cases (and those without a
verdict) are shown; when none is, a panel says so. Untruncated, passing
test cases are shown in full; truncated, a passing row's reason over 50
characters is cut. `:file_output_dir` writes the whole report, untruncated,
as Markdown (`DeepEvalEx.Report.Markdown`), and only while printing, as in
deepeval. deepeval's HTML export is not ported.

Turn printing off everywhere, in your test suite for instance:

```elixir
# config/test.exs
config :deep_eval_ex, print_results: false
```

## Building the report yourself

The report is data first: `DeepEvalEx.Report.Console.build/2` returns the
panels, trees and tables deepeval hands to Rich, every string exactly
deepeval's, and `DeepEvalEx.Report.Terminal.render/2` draws them.

```elixir
{:ok, %DeepEvalEx.EvaluationResult{test_results: test_results}} =
  DeepEvalEx.evaluate(test_cases, metrics)

test_results
|> DeepEvalEx.Report.Console.build(display: :all)
|> DeepEvalEx.Report.Terminal.render(width: 100)
|> IO.write()

File.write!("report.md", DeepEvalEx.Report.Markdown.render(test_results))
```

`DeepEvalEx.TestRun.Manager.wrap_up/2` wraps up a `DeepEvalEx.TestRun` as
deepeval's `wrap_up_test_run` does: it saves the run, prints the warnings
and summary and, with `display_table: true`, deepeval's `Test Results`
table (`DeepEvalEx.Report.ResultsTable`). `Manager.new/1` and `add/2`
collect evaluated test cases into a run, for a runner of your own.

## Parity

The strings match deepeval's byte for byte: every cell, title and label of
the report and the table, the summary text and the Markdown file, checked
against fixtures written by deepeval (`test/fixtures/deepeval/report/`).
The drawing only resembles Rich's: DeepEvalEx lays the panels and tables
out itself, with box-drawing characters and ANSI colours. It honours
`COLUMNS`, the terminal's width (80 without one), `NO_COLOR` and
`IO.ANSI.enabled?/0`, and counts emoji and East Asian wide characters as
two columns.

Differences from deepeval:

- The lines advertising Confident AI (the table's `Note: Use Confident
  AI...` row, the `deepeval view` footer) are kept in the data but not
  printed, and the warnings print without their documentation links.
- `print_results: false` silences the wrap-up too; deepeval always prints
  it.
- deepeval divides by zero when no test case has a verdict; DeepEvalEx
  prints a pass rate of `N/A`.
- "Test run saved at ..." is logged with `Logger`, not printed.
