# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/runner.py and deepeval/metrics/dag/nodes.py
# (the nodes' _execute and construct_node_verbose_log)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.Runner do
  @moduledoc false
  # Walks a DeepEvalEx.Metrics.DAG.Graph over a test case, deepeval 4.3.1's
  # _DeepAcyclicGraphRunner (its sync run; with a judge that answers at
  # once, its async run visits the nodes in the same order).
  #
  # From each root, depth first: a task or judgement runs once all its
  # incoming edges have arrived (its indegree), records its output or
  # verdict and a verbose step, then visits its children. A verdict arrives
  # like any node, and goes on only when its judgement's verdict is its own:
  # it ends the walk with its score (and the LLM's reason), visits its child
  # node, or measures its child metric and takes its score and reason.

  alias DeepEvalEx.{Evaluator, LLM.Adapter}
  alias DeepEvalEx.Metrics.DAG.{BinaryJudgementNode, Graph, Node, NonBinaryJudgementNode}
  alias DeepEvalEx.Metrics.DAG.{TaskNode, VerdictNode}
  alias DeepEvalEx.Metrics.GEval
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Params.SingleTurn
  alias DeepEvalEx.Prompts.{DAG, Python}
  alias DeepEvalEx.Schemas.MetricOutputs.DAG, as: Schema
  alias DeepEvalEx.SystemOne.{Answers, Decision, Spec}

  # The DAG's own options, which a child metric does not inherit.
  @own_options [
    :name,
    :dag,
    :threshold,
    :strict_mode,
    :include_reason,
    :verbose_mode,
    :flaky,
    :include_dag_suffix,
    :system_one,
    :metric_name
  ]

  @typedoc "What a walk ends with: the score, the reason and every verbose step."
  @type outcome :: %{score: number() | nil, reason: String.t() | nil, steps: [String.t()]}

  @doc """
  Walks `graph` over `test_case` for the metric named `name` (with its
  `[DAG]` suffix), measuring with `opts`.
  """
  @spec run(Graph.t(), map(), String.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(%Graph{} = graph, test_case, name, opts) do
    state = %{
      graph: graph,
      test_case: test_case,
      name: name,
      opts: Keyword.put(opts, :metric_name, name),
      remaining: graph.indegree,
      outputs: %{},
      verdicts: %{},
      depth: %{},
      steps: [],
      score: nil,
      reason: nil
    }

    with {:ok, state} <- each(graph.root_nodes, state, 0) do
      {:ok, %{score: state.score, reason: state.reason, steps: Enum.reverse(state.steps)}}
    end
  end

  defp each(nodes, state, depth) do
    Enum.reduce_while(nodes, {:ok, state}, fn node, {:ok, state} ->
      case visit(node, state, depth) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp visit(%VerdictNode{} = node, state, depth) do
    {ready?, state} = arrive(state, node.id)

    cond do
      not ready? -> {:ok, state}
      not verdict_matches?(state, node) -> {:ok, state}
      node.child == nil -> finish(node, state, depth)
      Node.node?(node.child) -> visit(node.child, state, depth)
      true -> hand_over(node, state, depth)
    end
  end

  defp visit(node, state, depth) do
    id = node.id
    state = %{state | depth: Map.update(state.depth, id, max(depth, 0), &max(&1, depth))}

    case arrive(state, id) do
      {false, state} ->
        {:ok, state}

      {true, state} ->
        with {:ok, result} <- execute(node, state) do
          node_depth = state.depth[id]
          state = store(state, node, result)
          state = log(state, node_log(node, node_depth, result))
          each(node.children, state, node_depth + 1)
        end
    end
  end

  # deepeval's _check_remaining: one more incoming edge has arrived.
  defp arrive(state, id) do
    remaining = Map.update!(state.remaining, id, &(&1 - 1))
    {remaining[id] <= 0, %{state | remaining: remaining}}
  end

  defp verdict_matches?(state, %VerdictNode{id: id, verdict: verdict}) do
    with [parent_id | _] <- Map.get(state.graph.parents, id),
         true <- Node.judgement?(state.graph.nodes[parent_id]) do
      state.verdicts[parent_id].verdict == verdict
    else
      _no_judgement -> true
    end
  end

  defp store(state, %TaskNode{id: id}, output),
    do: %{state | outputs: Map.put(state.outputs, id, output)}

  defp store(state, %{id: id}, verdict),
    do: %{state | verdicts: Map.put(state.verdicts, id, verdict)}

  defp log(state, step), do: %{state | steps: [step | state.steps]}

  # A verdict that ends the walk: its score, and the LLM's reason for it.
  defp finish(%VerdictNode{score: score} = node, state, depth) do
    state = log(state, node_log(node, depth, nil))
    state = %{state | score: score / 10}

    if include_reason?(state) do
      prompt =
        DAG.generate_reason(
          verbose_steps: Enum.reverse(state.steps),
          score: state.score,
          name: state.name
        )

      with {:ok, response} <-
             Adapter.generate_with_schema(prompt, Schema.reason_schema(), state.opts),
           {:ok, reason} <- Schema.parse_reason(response),
           do: {:ok, %{state | reason: reason}}
    else
      {:ok, state}
    end
  end

  # A verdict that hands over to a metric, measured on the test case with
  # the DAG's run options: its score and reason become the DAG's.
  defp hand_over(%VerdictNode{child: child} = node, state, depth) do
    metric = child_metric(child)

    child_opts =
      state.opts |> Keyword.drop(@own_options) |> Keyword.put(:verbose_mode, false)

    result = Evaluator.evaluate_metric(state.test_case, metric, child_opts)
    state = log(state, node_log(node, depth, {metric, result}))
    state = %{state | score: result.score}

    {:ok, if(include_reason?(state), do: %{state | reason: result.reason}, else: state)}
  end

  # deepeval's _build_child_metric: a GEval is rebuilt from its name, its
  # evaluation params and its criteria (or steps), to be judged by the DAG's
  # LLM; any other metric runs as it is, out of verbose mode.
  defp child_metric(%GEval{} = geval) do
    GEval.new(
      [name: geval.name, evaluation_params: geval.evaluation_params, verbose_mode: false] ++
        if(geval.criteria,
          do: [criteria: geval.criteria],
          else: [evaluation_steps: geval.evaluation_steps]
        )
    )
  end

  defp child_metric(%{verbose_mode: _} = struct), do: %{struct | verbose_mode: false}
  defp child_metric(metric), do: metric

  defp include_reason?(state), do: Keyword.get(state.opts, :include_reason, true) != false

  ## Nodes

  defp execute(%TaskNode{} = node, state) do
    if node.evaluation_params == nil and not Map.has_key?(state.graph.parents, node.id) do
      raise ArgumentError, "A TaskNode must have either a 'evaluation_params' or parent node(s)."
    end

    prompt =
      DAG.generate_task_output(instructions: node.instructions, text: text(node, state, "\n\n"))

    with {:ok, response} <-
           Adapter.generate_with_schema(prompt, Schema.task_output_schema(), state.opts),
         do: Schema.parse_task_output(response)
  end

  defp execute(%BinaryJudgementNode{} = node, state) do
    text = text(node, state, "\n\n")
    spec = %Spec.Binary{instructions: node.criteria, state: [text: text]}

    case Decision.probability(spec, state.opts) do
      {:ok, probability} ->
        {:ok,
         %{
           verdict: probability >= 0.5,
           reason: "P(true)=#{Python.format_fixed(probability, 2)}"
         }}

      :llm ->
        prompt = DAG.generate_binary_verdict(criteria: node.criteria, text: text)

        with {:ok, response} <-
               Adapter.generate_with_schema(prompt, Schema.binary_verdict_schema(), state.opts),
             do: Schema.parse_binary_verdict(response)
    end
  end

  defp execute(%NonBinaryJudgementNode{} = node, state) do
    text = text(node, state, "\n")
    options = NonBinaryJudgementNode.options(node)
    spec = %Spec.Choice{instructions: node.criteria, options: options, state: [text: text]}

    case Decision.choice(spec, state.opts) do
      {:ok, %Answers.Choice{choice: choice, probabilities: probabilities, confidence: confidence}} ->
        probability =
          case List.keyfind(probabilities, choice, 0) do
            {_choice, probability} -> probability
            nil -> 0.0
          end

        {:ok,
         %{
           verdict: choice,
           reason:
             "P=#{Python.format_fixed(probability, 2)}, " <>
               "confidence=#{Python.format_fixed(confidence, 2)}"
         }}

      :llm ->
        prompt =
          DAG.generate_non_binary_verdict(criteria: node.criteria, text: text, options: options)

        with {:ok, response} <-
               Adapter.generate_with_schema(
                 prompt,
                 Schema.non_binary_verdict_schema(options),
                 state.opts
               ),
             do: Schema.parse_non_binary_verdict(response, options)
    end
  end

  # deepeval's BaseNode._resolve_text: each parent task's output under its
  # label, then each evaluation param under its display name.
  defp text(node, state, separator) do
    outputs =
      for parent_id <- Map.get(state.graph.parents, node.id, []),
          %TaskNode{output_label: label} <- [state.graph.nodes[parent_id]] do
        "#{label}:\n#{Python.str(Map.fetch!(state.outputs, parent_id))}#{separator}"
      end

    params =
      for param <- node.evaluation_params || [] do
        "#{display_name!(param)}:\n#{Python.str(Map.get(state.test_case, param))}\n"
      end

    IO.iodata_to_binary([outputs, params])
  end

  defp display_name!(param) do
    SingleTurn.display_name(param) ||
      raise ArgumentError,
            "#{inspect(param)} cannot be shown to a DAG node: it has no display name."
  end

  ## Verbose logs

  # deepeval's construct_node_verbose_log.
  defp node_log(%TaskNode{} = node, depth, output) do
    "______________________\n" <>
      "| TaskNode | Level == #{depth} |\n" <>
      "*******************************\n" <>
      "Label: #{label(node)}\n\n" <>
      "Instructions:\n#{node.instructions}\n\n" <>
      "#{node.output_label}:\n#{Python.str(output)}\n"
  end

  defp node_log(%VerdictNode{verdict: verdict}, depth, child) do
    "________________________\n" <>
      "| VerdictNode | Level == #{depth} |\n" <>
      "**********************************\n" <>
      "Verdict: #{Python.str(verdict)}\n" <>
      "Type: #{child_log(child)}"
  end

  defp node_log(%module{} = node, depth, verdict) do
    {type, underscores, stars} =
      case module do
        BinaryJudgementNode -> {"BinaryJudgementNode", 34, 48}
        NonBinaryJudgementNode -> {"NonBinaryJudgementNode", 37, 53}
      end

    String.duplicate("_", underscores) <>
      "\n| #{type} | Level == #{depth} |\n" <>
      String.duplicate("*", stars) <>
      "\nLabel: #{label(node)}\n\n" <>
      "Criteria:\n#{node.criteria}\n\n" <>
      "Verdict: #{Python.str(verdict.verdict)}\n" <>
      "Reason: #{verdict.reason}\n"
  end

  defp child_log(nil), do: "Deterministic"

  defp child_log({%GEval{} = geval, result}) do
    steps = (result.metadata || %{})[:evaluation_steps]

    "#{result.metric} Metric" <>
      "\n\nCriteria:\n#{Verbose.to_str(geval.criteria)}\n" <>
      "Evaluation Steps:\n#{Verbose.prettify_list(steps || [])}"
  end

  defp child_log({_metric, result}),
    do: "#{result.metric} Metric\n\n#{Verbose.to_str(result.verbose_logs)}"

  defp label(%{label: label}) when label in [nil, ""], do: "None"
  defp label(%{label: label}), do: label
end
