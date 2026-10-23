# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/dag.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG do
  @moduledoc """
  A deterministic decision tree of LLM judgements, deepeval 4.3.1's
  `DAGMetric` (Deep Acyclic Graph).

  Where `DeepEvalEx.Metrics.GEval` asks one judge for one score, a DAG
  breaks the evaluation into small steps whose outcomes decide which step
  comes next, and the score comes from the leaf the walk reaches. Each step
  is a node of a `DeepEvalEx.Metrics.DAG.Graph`:

  - `DeepEvalEx.Metrics.DAG.TaskNode` - the LLM produces something (the
    headings, the claims...) for the nodes after it
  - `DeepEvalEx.Metrics.DAG.BinaryJudgementNode` - a yes/no judgement
  - `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode` - a judgement between
    named options
  - `DeepEvalEx.Metrics.DAG.VerdictNode` - an outcome of a judgement: a
    score from 0 to 10 (the metric's score is a tenth of it), or the node or
    metric to run next

  ## Usage

  ```elixir
  alias DeepEvalEx.Metrics.DAG
  alias DeepEvalEx.Metrics.DAG.{BinaryJudgementNode, Graph, NonBinaryJudgementNode, TaskNode}

  order =
    NonBinaryJudgementNode.new(
      criteria: "Are the summary headings in the correct order: 'intro' => 'body' => 'conclusion'?"
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

  metric = DAG.new(name: "Format Correctness", dag: Graph.new([extract]))

  DeepEvalEx.evaluate(test_cases, [metric])
  ```

  The result is named `"Format Correctness [DAG]"`; its reason is the
  LLM's explanation of the path walked, or the reason of the metric a
  verdict handed over to; its verbose logs describe every node walked.

  ## How It Runs

  From each root, depth first: a node runs once every node leading to it
  has run, and a judgement goes on only through the verdict matching its
  outcome. A task is shown the outputs of the tasks before it and its
  `:evaluation_params`; a judgement likewise. The test case must have the
  evaluation params of every node reached from the roots without passing a
  verdict (`DeepEvalEx.Metrics.DAG.Graph.required_params/1`), as deepeval
  checks; a node after a verdict is shown `None` for a missing one.

  A verdict handing over to a metric measures it on the test case, with the
  run's options but not the DAG's own (name, threshold, strict mode...),
  and out of verbose mode; its usage adds to the DAG's. A
  `DeepEvalEx.Metrics.GEval` is rebuilt from its name, evaluation params and
  criteria (or evaluation steps) and judged by the DAG's LLM, as deepeval
  does, so its other settings (threshold, rubric, strict mode, model) are
  not used.

  ## Eval Modes

  - `:llm` - the LLM runs every node
  - `:hybrid` - the LLM runs the tasks and writes the reason; a System One
    model takes every judgement (see
    `DeepEvalEx.Metrics.DAG.BinaryJudgementNode` and
    `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode`), the LLM covering a
    failed request
  - `:system_one` - runs as `:hybrid`, as deepeval's: the graph is the
    user's, so there is no whole-metric System One form, and its tasks
    still need the LLM

  ## Options

  - `:name` - the metric's name (required)
  - `:dag` - its `DeepEvalEx.Metrics.DAG.Graph` (required)
  - `:threshold` - Pass/fail threshold (default: 0.5); `nil` for score-only
  - `:strict_mode` - Forces the threshold to `1`; the score is kept as it
    is, as deepeval's DAG does not round it to 0 (default: false)
  - `:include_reason` - Have the LLM explain the score (default: true)
  - `:include_dag_suffix` - Name results `"<name> [DAG]"` rather than
    `"<name>"` (default: true, as in deepeval)
  - `:model` - LLM model for the tasks, the judgements and the reason
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:flaky` - Report the result without letting it decide its test case's
    success (default: false)
  - `:eval_mode`, `:system_one_model` - see "Eval Modes"

  ## Divergences

  - Each node runs one at a time; deepeval's async mode runs the children
    of a node concurrently, which changes nothing but timing.
  - A task's output that is a map prints in map order, where deepeval keeps
    the judge's key order.
  - Missing evaluation params are listed in the order first met, where
    deepeval follows a Python set's order.
  - Uploading to and pulling from Confident AI (`upload()`, `pull()`) are
    not ported.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Metrics.DAG.{Graph, Runner}
  alias DeepEvalEx.Metrics.Utils.Verbose

  @enforce_keys [:name, :dag]
  defstruct [
    :name,
    :dag,
    :threshold,
    :strict_mode,
    :include_reason,
    :model,
    :verbose_mode,
    :flaky,
    :eval_mode,
    :system_one_model,
    include_dag_suffix: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          dag: Graph.t(),
          threshold: number() | nil,
          strict_mode: boolean() | nil,
          include_reason: boolean() | nil,
          model: term(),
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil,
          eval_mode: atom() | String.t() | nil,
          system_one_model: term(),
          include_dag_suffix: boolean()
        }

  @doc """
  Creates a DAG metric for `DeepEvalEx.evaluate/3`, as deepeval's
  constructor (see "Options"). Options left unset (`nil`) fall back to the
  run's options.

  Raises `ArgumentError` without a `:name` or a `:dag` graph.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: name!(opts),
      dag: dag!(opts),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode),
      include_reason: Keyword.get(opts, :include_reason),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky),
      eval_mode: Keyword.get(opts, :eval_mode),
      system_one_model: Keyword.get(opts, :system_one_model),
      include_dag_suffix: Keyword.get(opts, :include_dag_suffix, true)
    }
  end

  @impl true
  def metric_name, do: "DAG"

  @doc """
  Returns the name results of this configured metric carry, deepeval's
  `DAGMetric.__name__`: `"<name> [DAG]"`, or just `"<name>"` when
  `:include_dag_suffix` is false.
  """
  @impl true
  @spec metric_name(t()) :: String.t()
  def metric_name(%__MODULE__{name: name, include_dag_suffix: suffix?}), do: name(name, suffix?)

  @doc """
  None: the params a DAG needs depend on its graph, and are checked when it
  measures (see "How It Runs").
  """
  @impl true
  def required_params, do: []

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  Walks the `:dag` graph over the test case (see "How It Runs").
  """
  def do_measure(test_case, opts) do
    dag = dag!(opts)
    name = name(name!(opts), Keyword.get(opts, :include_dag_suffix, true))

    with :ok <- TestCase.validate_params(test_case, Graph.required_params(dag)),
         {:ok, %{score: score, reason: reason, steps: steps}} <-
           Runner.run(dag, test_case, name, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          name,
          steps ++ ["Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"],
          opts
        )

      {:ok,
       Result.new(
         metric: name,
         score: score,
         threshold: BaseMetric.threshold(opts, default_threshold()),
         reason: reason,
         verbose_logs: verbose_logs,
         # deepeval's DAG keeps its score in strict mode.
         strict_applied: true
       )}
    end
  end

  defp name(name, false), do: name
  defp name(name, _suffix?), do: "#{name} [DAG]"

  defp name!(opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) -> name
      _ -> raise ArgumentError, "DAG requires a :name"
    end
  end

  defp dag!(opts) do
    case Keyword.get(opts, :dag) do
      %Graph{} = dag -> dag
      _ -> raise ArgumentError, "DAG requires a :dag, a DeepEvalEx.Metrics.DAG.Graph"
    end
  end
end
