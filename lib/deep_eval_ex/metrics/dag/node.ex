# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/nodes.py and deepeval/metrics/dag/graph.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.Node do
  @moduledoc """
  What the nodes of a `DeepEvalEx.Metrics.DAG` graph share, deepeval 4.3.1's
  `BaseNode`.

  A graph is built from four node structs:

  - `DeepEvalEx.Metrics.DAG.TaskNode` - asks the LLM to produce something
    (extract, summarise, list...) for the nodes after it
  - `DeepEvalEx.Metrics.DAG.BinaryJudgementNode` - a yes/no judgement
  - `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode` - a judgement between
    named options
  - `DeepEvalEx.Metrics.DAG.VerdictNode` - one outcome of a judgement: a
    score from 0 to 10, or the node or metric to run next

  ## Identity

  deepeval tells nodes apart by object identity, so one node object reached
  from two parents is one node of the graph. Elixir values have no
  identity, so every node gets a unique `:id` when it is created and keeps
  it: the same node value placed under two parents is still one node, and
  two nodes created alike are two. `add_node/2` and `add_verdict/3` return
  the node with the same id, so build a node completely before placing it,
  or place only its last version: a graph holding two versions of one node
  is rejected (see `DeepEvalEx.Metrics.DAG.Graph.new/1`).
  """

  alias DeepEvalEx.Metrics.DAG.{
    BinaryJudgementNode,
    NonBinaryJudgementNode,
    TaskNode,
    VerdictNode
  }

  @typedoc "A node of a DAG."
  @type t :: TaskNode.t() | BinaryJudgementNode.t() | NonBinaryJudgementNode.t() | VerdictNode.t()

  @typedoc "A node's identity, see \"Identity\"."
  @type id :: pos_integer()

  @doc """
  Whether `term` is a DAG node.

  ## Examples

      iex> DeepEvalEx.Metrics.DAG.Node.node?(DeepEvalEx.Metrics.DAG.VerdictNode.new(verdict: true, score: 1))
      true

      iex> DeepEvalEx.Metrics.DAG.Node.node?(DeepEvalEx.Metrics.ExactMatch)
      false
  """
  @spec node?(term()) :: boolean()
  def node?(%module{})
      when module in [TaskNode, BinaryJudgementNode, NonBinaryJudgementNode, VerdictNode],
      do: true

  def node?(_term), do: false

  @doc false
  # A fresh node identity.
  @spec new_id() :: id()
  def new_id, do: System.unique_integer([:positive, :monotonic])

  @doc false
  # The nodes a node leads to, deepeval's _edges_of: its children, then a
  # verdict's child when that is a node (not a metric).
  @spec edges(t()) :: [t()]
  def edges(%VerdictNode{child: child}), do: if(node?(child), do: [child], else: [])
  def edges(%{children: children}), do: children

  @doc false
  # Checks a node's children, deepeval's _validate, raising ArgumentError.
  @spec validate!(t()) :: :ok
  def validate!(%module{} = node) when module != VerdictNode, do: module.validate!(node)
  def validate!(%VerdictNode{}), do: :ok

  @doc false
  # Whether a node is a binary or non-binary judgement.
  @spec judgement?(term()) :: boolean()
  def judgement?(%module{}) when module in [BinaryJudgementNode, NonBinaryJudgementNode], do: true
  def judgement?(_term), do: false

  @doc false
  # A required constructor option, raising ArgumentError when missing, as
  # deepeval's dataclass constructors raise TypeError.
  @spec fetch!(keyword(), atom(), String.t()) :: term()
  def fetch!(opts, key, node_type) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{node_type} requires :#{key}"
    end
  end
end
