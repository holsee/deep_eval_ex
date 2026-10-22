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
