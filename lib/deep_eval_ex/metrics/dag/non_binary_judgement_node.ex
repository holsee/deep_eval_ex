# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/nodes.py (NonBinaryJudgementNode)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode do
  @moduledoc """
  A judgement between named options in a `DeepEvalEx.Metrics.DAG` graph,
  deepeval 4.3.1's `NonBinaryJudgementNode`.

  It judges `:criteria` against its text (the output of each parent
  `DeepEvalEx.Metrics.DAG.TaskNode`, then its `:evaluation_params`) by
  choosing one of its options, the verdicts of its child
  `DeepEvalEx.Metrics.DAG.VerdictNode`s (at least one, all distinct
  strings), and the walk goes on through the chosen one.

  ## Eval modes

  Under `:llm` the LLM chooses, and must answer one of the options. Under
  `:hybrid` (and `:system_one`, which a DAG runs as `:hybrid`) a System One
  model does, deepeval's `SystemOneChoiceSpec`: one Choice over the options
  whose instructions are the criteria, about the state `{"text": text}`,
  with the reason `"P=0.75, confidence=0.62"`. A failed request falls back
  to the LLM (see `DeepEvalEx.SystemOne.Decision`).

  ## Divergence

  deepeval offers the options in the order a Python set of them iterates,
  which follows string hashing; DeepEvalEx offers them in the order of the
  children.

  ## Examples

      DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode.new(
        criteria: "How formal is the answer?",
        evaluation_params: [:actual_output]
      )
      |> DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode.add_verdict("Formal", score: 10)
      |> DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode.add_verdict("Casual", score: 5)
      |> DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode.add_verdict("Rude", score: 0)
  """

  alias DeepEvalEx.Metrics.DAG.{Node, VerdictNode}

  @enforce_keys [:id, :criteria]
  defstruct [:id, :criteria, :evaluation_params, :label, children: []]

  @type t :: %__MODULE__{
          id: Node.id(),
          criteria: String.t(),
          evaluation_params: [atom()] | nil,
          label: String.t() | nil,
          children: [VerdictNode.t()]
        }

  @doc """
  Creates a non-binary judgement.

  ## Options

  - `:criteria` - what is judged (required)
  - `:evaluation_params` - the test case fields it is shown (default: none)
  - `:label` - a name for the verbose logs (default: none)
  - `:children` - its verdicts, one per option (default: none; see also
    `add_verdict/3`)

  Raises `ArgumentError` for invalid children, with deepeval's message.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    node = %__MODULE__{
      id: Node.new_id(),
      criteria: Node.fetch!(opts, :criteria, "NonBinaryJudgementNode"),
      evaluation_params: Keyword.get(opts, :evaluation_params),
      label: Keyword.get(opts, :label),
      children: Keyword.get(opts, :children, [])
    }

    if node.children != [], do: validate!(node)
    node
  end

  @doc """
  Appends a verdict for the option `verdict`, deepeval's `add_verdict`:
  ending the walk with `score:` or handing over to `then:`, a node or a
  metric (see `DeepEvalEx.Metrics.DAG.VerdictNode`).
  """
  @spec add_verdict(t(), String.t(), keyword()) :: t()
  def add_verdict(%__MODULE__{children: children} = node, verdict, opts) do
    verdict_node =
      VerdictNode.new(verdict: verdict, score: opts[:score], child: opts[:then])

    %{node | children: children ++ [verdict_node]}
  end

  @doc """
  The node's options, its verdicts in order.
  """
  @spec options(t()) :: [String.t()]
  def options(%__MODULE__{children: children}), do: Enum.map(children, & &1.verdict)

  @doc false
  # deepeval's NonBinaryJudgementNode._validate.
  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{children: []}),
    do: raise(ArgumentError, "NonBinaryJudgementNode must have at least one child.")

  def validate!(%__MODULE__{children: children}), do: validate_children!(children, [])

  defp validate_children!([], _seen), do: :ok

  defp validate_children!([%VerdictNode{verdict: verdict} | rest], seen)
       when is_binary(verdict) do
    if verdict in seen do
      raise ArgumentError,
            "Duplicate verdict found: #{verdict} in children of NonBinaryJudgementNode."
    end

    validate_children!(rest, [verdict | seen])
  end

  defp validate_children!([%VerdictNode{} | _rest], _seen) do
    raise ArgumentError,
          "The verdict attribute of all NonBinaryJudgementNode children must be a string."
  end

  defp validate_children!([_other | _rest], _seen),
    do: raise(ArgumentError, "All children must be of type VerdictNode.")
end
