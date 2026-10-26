# Contextual Relevancy Metric

Contextual Relevancy measures how much of the retrieval context is relevant to the input. Each retrieved node is broken into statements and each statement is judged relevant or not, so a retriever that pads its results with off-topic text scores lower.

## When to Use

- Evaluating how noisy your RAG retrieval results are
- Tuning chunk size and top-k (larger chunks and more nodes carry more irrelevant text)
- Comparing retrievers or embedding models on the same questions
- Catching retrieval that returns the right topic with a lot of filler

## How It Works

1. **Generate verdicts** - For each node in the retrieval context, in its own judge call, extract the statements it makes and judge each:
   - `yes` - Relevant to the input
   - `no` - Irrelevant, with a reason quoting the irrelevant part
2. **Calculate score** - (relevant statements) / (total statements over every node), or `0` when there are none. Verdicts other than `yes` and `no` are dropped
3. **Higher score is better** - Success when score ≥ threshold

A node with no content gets one `no` verdict, its reason `"No statements found in provided context."`, as deepeval's prompt asks the judge.

## Precision, Recall and Relevancy

| Metric | Question | Focus |
|--------|----------|-------|
| Contextual Precision | Are relevant nodes ranked first? | Ranking quality |
| Contextual Recall | Is expected output covered? | Coverage |
| Contextual Relevancy | How much of the context is relevant? | Noise |

## Required Parameters

| Parameter | Description |
|-----------|-------------|
| `:input` | The input prompt/question |
| `:retrieval_context` | List of retrieved context documents |

Like deepeval 4.3.1, ContextualRelevancy needs no `actual_output` or `expected_output`, and `context` does not stand in for `retrieval_context`.

## Basic Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.ContextualRelevancy}

test_case = TestCase.new!(
  input: "What is the capital of France?",
  actual_output: "Paris.",
  retrieval_context: [
    "Paris is the capital of France. There was a cat.",
    "Rome is the capital of Italy."
  ]
)

{:ok, result} = ContextualRelevancy.measure(test_case)

result.score   # => 0.3333333333333333 (one of three statements relevant)
result.reason  # => "The score is 0.33 because only 'Paris is the capital of France.' ..."
result.success # => false (score < threshold)
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:threshold` | float | 0.5 | Pass/fail threshold |
| `:strict_mode` | boolean | false | Threshold `1`, and a score below it is `0` |
| `:include_reason` | boolean | true | Generate explanation |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model name |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 1.0 | Every retrieved statement is relevant |
| 0.5 | Half of the retrieved statements are relevant |
| 0 | No retrieved statement is relevant, or no statements were found |

## System One

As deepeval 4.3.1's `ContextualRelevancyMetric`, the metric can hand its decisions to a System One model (ADR-0009):

- `eval_mode: :hybrid` - each node is split into sentences, and the System One model judges them against the input, one request per node and one Noul per sentence (`statement_0`, `statement_1`, ...). P(yes) of `0.5` and above is `yes` with the reason `"P(yes)=0.97"`; below is `no` with the reason `"'<sentence>' is not relevant to the input (P(yes)=0.04)."`. The LLM still writes the reason. When a request fails, the LLM judges that node and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - one request about `input` and `retrieval_context` answers the whole metric with two Nouls and a four-level Score; no LLM is called

```elixir
{:ok, result} = ContextualRelevancy.measure(test_case, eval_mode: :hybrid)
```

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Contextual Relevancy",
  score: 0.3333333333333333,
  success: false,
  threshold: 0.5,
  reason: "The score is 0.33 because ...",
  metadata: %{
    context_count: 2,
    # One list per node, in retrieval order
    verdicts: [
      [
        %{statement: "Paris is the capital of France.", verdict: :yes, reason: nil},
        %{statement: "There was a cat.", verdict: :no, reason: "'There was a cat' is unrelated."}
      ],
      [
        %{statement: "Rome is the capital of Italy.", verdict: :no, reason: "Rome is in Italy."}
      ]
    ]
  }
}
```

## Finding the Noise

```elixir
{:ok, result} = ContextualRelevancy.measure(test_case)

irrelevant =
  result.metadata.verdicts
  |> Enum.with_index(1)
  |> Enum.flat_map(fn {verdicts, node} ->
    for %{verdict: :no, statement: statement} <- verdicts, do: {node, statement}
  end)

# => [{1, "There was a cat."}, {2, "Rome is the capital of Italy."}]
```

## Source

Ported from `deepeval/metrics/contextual_relevancy/contextual_relevancy.py`
