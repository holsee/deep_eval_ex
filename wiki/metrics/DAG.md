# DAG Metric

Scores a test case by walking a decision tree of small LLM judgements, deepeval's `DAGMetric` (Deep Acyclic Graph). Where [GEval](GEval.md) asks one judge for one score, a DAG breaks the evaluation into steps whose outcomes decide which step comes next; the score comes from the leaf the walk reaches, so the same answers always give the same score.

## When to Use

- Format and structure checks with clear rules ("all three headings, in order")
- Rubrics where a failed precondition should decide the score outright
- Evaluations you want to explain step by step: the verbose logs show the path taken

## How It Works

A graph (`DeepEvalEx.Metrics.DAG.Graph`) is built from four kinds of node:

| Node | Does |
|------|------|
| `TaskNode` | The LLM produces something (the headings, the claims...) from its `instructions`, shown to the nodes after it under its `output_label` |
| `BinaryJudgementNode` | A yes/no judgement of its `criteria`, with one `true` and one `false` verdict |
| `NonBinaryJudgementNode` | A judgement of its `criteria` choosing between its verdicts, named options |
| `VerdictNode` | An outcome of a judgement: a score from 0 to 10 (the metric scores a tenth of it), or the node or metric to run next |

From each root, depth first, a node runs once every node leading to it has run, and a judgement goes on only through the verdict matching its outcome. Each node is shown the outputs of the tasks just before it, then its `evaluation_params` (test case fields). When a verdict ends the walk, the LLM explains the score from the path taken.

## Required Parameters

The `evaluation_params` of every node reached from the roots before any verdict, as deepeval checks them (`DeepEvalEx.Metrics.DAG.Graph.required_params/1`).

## Basic Usage

```elixir
alias DeepEvalEx.Metrics.DAG
alias DeepEvalEx.Metrics.DAG.{BinaryJudgementNode, Graph, NonBinaryJudgementNode, TaskNode}

order =
  NonBinaryJudgementNode.new(
    criteria: "Are the summary headings in the correct order: 'intro' => 'body' => 'conclusion'?",
    evaluation_params: [:actual_output]
  )
  |> NonBinaryJudgementNode.add_verdict("In order", score: 10)
  |> NonBinaryJudgementNode.add_verdict("Partly out of order", score: 4)
  |> NonBinaryJudgementNode.add_verdict("Out of order", score: 2)

has_headings =
  BinaryJudgementNode.new(
    criteria: "Does the summary headings contain all three: 'intro', 'body', and 'conclusion'?"
  )
  |> BinaryJudgementNode.add_verdict(false, score: 0)
  |> BinaryJudgementNode.add_verdict(true, then: order)

extract =
  TaskNode.new(
    instructions: "Extract all headings in `actual_output`.",
    output_label: "Summary headings",
    evaluation_params: [:actual_output],
    children: [has_headings]
  )

dag = Graph.new([extract])

{:ok, result} = DAG.measure(test_case, name: "Format Correctness", dag: dag)

result.metric  # => "Format Correctness [DAG]"
result.score   # => 0.4
result.reason  # => "The score is 0.4 because the body and conclusion headings are swapped."

# Or configured once, beside other metrics
DeepEvalEx.evaluate(test_cases, [DAG.new(name: "Format Correctness", dag: dag)])
```

Nodes are values: build a node (its children, its verdicts) before placing it under a parent. A node keeps the id it was created with, so a node placed under two parents is one node of the graph and runs once, after both. `Graph.new/1` rejects cycles, invalid verdicts, a judgement root among several roots, a root reachable from another, and two versions of one node.

## Handing Over to a Metric

A verdict can hand over to a metric instead of a score: its score and reason become the DAG's.

```elixir
concision =
  DeepEvalEx.Metrics.GEval.new(
    name: "Concision",
    criteria: "Is every section of `actual_output` a single sentence?",
    evaluation_params: [:actual_output]
  )

NonBinaryJudgementNode.add_verdict(order, "In order", then: concision)
```

As in deepeval, a GEval is rebuilt from its name, criteria (or evaluation steps) and evaluation params and judged by the DAG's LLM. Any other metric (a module, `{module, opts}` or a metric struct) is measured as it is, with the run's options but not the DAG's own.

## Saving a Graph as JSON

`Graph.to_json/2` and `Graph.from_json/1` write and read deepeval's `DeepAcyclicGraph.to_json` format, so a graph moves between deepeval and DeepEvalEx:

```elixir
json = Graph.to_json(dag)
dag = Graph.from_json(json)
```

Node ids are fresh uuids each time; GEval children keep their constructor arguments, other metrics their deepeval class name (`"AnswerRelevancyMetric"`) and JSON-able options. Models, adapters and keys are never written.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | string | required | The metric's name |
| `:dag` | `Graph` | required | The graph to walk |
| `:threshold` | float | 0.5 | Minimum passing score |
| `:strict_mode` | boolean | false | Threshold `1`; the score is kept as it is, as deepeval's DAG does |
| `:include_reason` | boolean | true | Have the LLM explain the score |
| `:include_dag_suffix` | boolean | true | Name results `"<name> [DAG]"` |
| `:adapter` | atom | :openai | LLM adapter to use |
| `:model` | string | default | Model for the tasks, judgements and reason |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | configured (`:llm`) | `:llm`, `:hybrid` or `:system_one`, see below |
| `:system_one_model` | term | TypeSafe Jev | The System One model for `:hybrid` and `:system_one` |

## System One

As deepeval 4.3.1's `DAGMetric`, the judgements can be handed to a System One model (ADR-0009):

- `eval_mode: :hybrid` - the LLM runs the tasks and writes the reason; each BinaryJudgementNode is one Noul about `{"text": ...}` (the node's text), `true` from P(true) `0.5`, with the reason `"P(true)=0.92"`; each NonBinaryJudgementNode is one Choice over its options, with the reason `"P=0.75, confidence=0.62"`. A failed request falls back to the LLM and `system_one_fallback_reason` says why
- `eval_mode: :system_one` - runs as `:hybrid`: the graph is yours, so there is no whole-metric request, and its tasks still need the LLM

## Divergences from deepeval

- A NonBinaryJudgementNode offers its options in the order of its verdicts; deepeval follows a Python set's order
- Nodes run one at a time; deepeval's async mode runs a node's children concurrently
- A task output that is a map prints in map order
- Confident AI `upload()` and `pull()` are not ported, nor is the conversational DAG

## Result Structure

```elixir
%DeepEvalEx.Result{
  metric: "Format Correctness [DAG]",
  score: 0.4,
  success: false,
  threshold: 0.5,
  reason: "The score is 0.4 because the body and conclusion headings are swapped.",
  verbose_logs: "______________________\n| TaskNode | Level == 0 |\n..."
}
```

## Source

Ported from `deepeval/metrics/dag/`
