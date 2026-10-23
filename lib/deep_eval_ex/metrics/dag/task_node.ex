# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/nodes.py (TaskNode)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.TaskNode do
  @moduledoc """
  A step of a `DeepEvalEx.Metrics.DAG` graph that asks the LLM to produce
  something, deepeval 4.3.1's `TaskNode`: extract the headings, list the
  claims, summarise the answer...

  The LLM gets `:instructions` and the node's text: the output of each
  parent `TaskNode` under its `:output_label`, then each of
  `:evaluation_params` (test case fields, see `DeepEvalEx.Params.SingleTurn`)
  under its display name. Its answer, a string, a list of strings or a map
  of strings, is shown to the nodes after it under `:output_label`. A task
  needs evaluation params or a parent: one with neither raises when it
  runs, as in deepeval.

  A task runs in every eval mode with the LLM; only judgements are asked of
  a System One model.

  ## Examples

      judge =
        DeepEvalEx.Metrics.DAG.BinaryJudgementNode.new(criteria: "Are all three headings there?")
        |> DeepEvalEx.Metrics.DAG.BinaryJudgementNode.add_verdict(false, score: 0)
        |> DeepEvalEx.Metrics.DAG.BinaryJudgementNode.add_verdict(true, score: 10)

      DeepEvalEx.Metrics.DAG.TaskNode.new(
        instructions: "Extract all headings in `actual_output`.",
        output_label: "Summary headings",
        evaluation_params: [:actual_output],
        children: [judge]
      )
  """

  alias DeepEvalEx.Metrics.DAG.{Node, VerdictNode}

  @enforce_keys [:id, :instructions, :output_label]
  defstruct [:id, :instructions, :output_label, :evaluation_params, :label, children: []]

  @type t :: %__MODULE__{
          id: Node.id(),
          instructions: String.t(),
          output_label: String.t(),
          evaluation_params: [atom()] | nil,
          label: String.t() | nil,
          children: [Node.t()]
        }

  @doc """
  Creates a task.

  ## Options

  - `:instructions` - what the LLM should produce (required)
  - `:output_label` - the name its output goes by in the prompts of the
    nodes after it (required)
  - `:evaluation_params` - the test case fields it is shown (default: none)
  - `:label` - a name for the verbose logs (default: none)
  - `:children` - the nodes that run after it: tasks and judgements, never
    verdicts (default: none; see also `add_node/2`)

  Raises `ArgumentError` for invalid children, with deepeval's message.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    node = %__MODULE__{
      id: Node.new_id(),
      instructions: Node.fetch!(opts, :instructions, "TaskNode"),
      output_label: Node.fetch!(opts, :output_label, "TaskNode"),
      evaluation_params: Keyword.get(opts, :evaluation_params),
      label: Keyword.get(opts, :label),
      children: Keyword.get(opts, :children, [])
    }

    if node.children != [], do: validate!(node)
    node
  end

  @doc """
  Appends `child` to the task's children, deepeval's `add_node` (see
  "Identity" in `DeepEvalEx.Metrics.DAG.Node`).
  """
  @spec add_node(t(), Node.t()) :: t()
  def add_node(%__MODULE__{children: children} = task, child),
    do: %{task | children: children ++ [child]}

  @doc false
  # deepeval's TaskNode._validate.
  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{children: children}) do
    Enum.each(children, fn
      %VerdictNode{} ->
        raise ArgumentError, "A TaskNode must not have a VerdictNode as one of their 'children'."

      child ->
        if not Node.node?(child),
          do: raise(ArgumentError, "A TaskNode's children must be BaseNode instances.")
    end)
  end
end
