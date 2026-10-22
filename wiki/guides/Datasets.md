# Datasets

Keep the inputs you evaluate against as goldens in a dataset, as deepeval's
`EvaluationDataset` does.

## Goldens

A golden (`DeepEvalEx.Dataset.Golden`) is a test case before the application
under test has run: the input, and what it should produce.

```elixir
alias DeepEvalEx.Dataset.Golden

golden = Golden.new!(input: "What is the capital of France?", expected_output: "Paris")
```

`Golden.new/1` takes deepeval's keys too, as atoms or strings, including
`tokenCost`, `inputTokenCount`, `outputTokenCount` and `expectedLabels`.

## Building a dataset

`DeepEvalEx.Dataset.EvaluationDataset` is an immutable struct: every function
returns a new dataset.

```elixir
alias DeepEvalEx.Dataset.EvaluationDataset

dataset =
  EvaluationDataset.new([golden])
  |> EvaluationDataset.add_golden(Golden.new!(input: "What is 2 + 2?", expected_output: "4"))
```

`put_goldens/2` replaces the goldens. Anything other than a `Golden` raises
`ArgumentError`, as deepeval raises `TypeError`.

A dataset enumerates its goldens, so `Enum` and `Stream` work on it:

```elixir
Enum.count(dataset)
#=> 2

Enum.map(dataset, & &1.input)
#=> ["What is the capital of France?", "What is 2 + 2?"]
```

## From goldens to test cases

Run your application over each golden, fill in `:actual_output` and convert
the goldens to test cases:

```elixir
test_cases =
  dataset.goldens
  |> Enum.map(fn golden -> %{golden | actual_output: MyApp.answer(golden.input)} end)
  |> Golden.convert_goldens_to_test_cases()

dataset = EvaluationDataset.put_test_cases(dataset, test_cases)

{:ok, result} = DeepEvalEx.evaluate(dataset.test_cases, [DeepEvalEx.Metrics.ExactMatch])
```

`add_test_case/2` appends one test case.

## Evaluating a task over the goldens

`EvaluationDataset.evaluate/4` does all of that in one call, as deepeval's
`evals_iterator` (without its tracing): it calls your task with each golden,
concurrently, builds a test case from the golden and the task's output, and
evaluates the test cases:

```elixir
{:ok, result} =
  EvaluationDataset.evaluate(
    dataset,
    fn golden -> MyApp.answer(golden.input) end,
    [DeepEvalEx.Metrics.AnswerRelevancy],
    max_concurrent: 5,
    results_folder: "eval_results"
  )
```

The task returns the actual output, or a map or keyword list of test case
fields (`%{actual_output: answer, retrieval_context: chunks}`), or a whole
`DeepEvalEx.TestCase`. Each test case is ranked by its golden's position, and
the run records the dataset's alias, id and version, as deepeval's does. If
the task raises for a golden, the error is raised again and nothing is
evaluated. `evaluate_run/4` also returns the test cases and the test run.

## Dataset rank

Every test case in a dataset carries its position as `:dataset_rank`, as
deepeval's `_dataset_rank`. An evaluation uses the rank as the test case's
`order` and default name, so the third test case of a dataset is always
`test_case_2`, even when you evaluate only some of the test cases or reorder
them. The test run lists its test cases sorted by that order, as deepeval's
does.

## Single-turn only

deepeval's datasets hold single-turn or multi-turn (conversational) goldens,
never both. DeepEvalEx has no conversational goldens or test cases yet, so
its datasets are single-turn.

## Loading goldens and test cases from files

`EvaluationDataset` reads the CSV, JSON and JSONL files deepeval's
`save_as` writes, and files of your own, with deepeval's loaders. Each
returns the dataset with what it loaded appended:

```elixir
dataset =
  EvaluationDataset.new()
  |> EvaluationDataset.add_goldens_from_csv_file("goldens.csv")
  |> EvaluationDataset.add_goldens_from_json_file("goldens.json")
  |> EvaluationDataset.add_goldens_from_jsonl_file("goldens.jsonl")

dataset =
  EvaluationDataset.add_test_cases_from_csv_file(dataset, "runs.csv", "question", "answer",
    context_col_name: "ctx",
    context_col_delimiter: ";"
  )
```

`add_test_cases_from_json_file/5` reads a JSON list of objects the same
way. The options are deepeval's argument names, with its defaults: a
golden's columns or keys are named after its fields, list cells (context,
retrieval context) are joined on `"|"`, and tool calls, metadata, custom
columns and expectations are JSON. A `nil` name leaves that field unset.

CSV files are read as pandas reads them for deepeval: `NA`, `null`,
`None`, `N/A`, an empty cell and pandas' other missing-value markers are
`nil`; a context or tool column that is present but empty gives `[]`, an
absent one `nil`. Retrieved context written as
`deepeval_source=...,deepeval_context=...` comes back as
`DeepEvalEx.Schemas.RetrievedContextData`; as in deepeval, an item that
itself contains the delimiter comes back split.

A file that does not load raises: `File.Error` when it cannot be read,
`ArgumentError` otherwise. Goldens with a `scenario` are deepeval's
conversational goldens, which DeepEvalEx does not support yet, so they
raise too.

## Saving a dataset to a file

`EvaluationDataset.save_as/4` writes the goldens to a CSV, JSON or JSONL file
deepeval loads as it loads its own, and returns the file's path:

```elixir
EvaluationDataset.save_as(dataset, :csv, "datasets", file_name: "capitals")
#=> "datasets/capitals.csv"

EvaluationDataset.save_as(dataset, :jsonl, "datasets", include_test_cases: true)
#=> "datasets/20261022_142501.jsonl"
```

The directory is created when missing. Without `:file_name` the file is named
after the local time, as deepeval names it. `include_test_cases: true` writes
the test cases too, after the goldens, converted to goldens.

The files have deepeval's keys, columns and formats, so the loaders above, and
deepeval's, read them back. As deepeval, a golden's token cost and counts are
not written (a test case's are). The one difference from deepeval's bytes is
the order of map keys (metadata, custom columns, tool call parameters): an
Elixir map holds its keys sorted, where deepeval keeps the order they were
added in.
