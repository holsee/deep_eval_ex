# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/graph.py and deepeval/metrics/dag/utils.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.Graph do
  @moduledoc """
  The graph a `DeepEvalEx.Metrics.DAG` metric walks, deepeval 4.3.1's
  `DeepAcyclicGraph`: its root nodes and everything reachable from them
  (see `DeepEvalEx.Metrics.DAG.Node`).

  `new/1` checks the graph as deepeval does, raising `ArgumentError` with
  deepeval's message:

  - every node's children are valid (see each node's `new/1`);
  - it has no cycle;
  - a judgement is a root only when it is the only root;
  - no root is reachable from another root.

  It also counts each node's incoming edges, so that when the metric runs,
  a node reached from several parents runs once, after all of them. Several
  verdicts of one judgement leading to the same node count as one edge, as
  only one of them can fire.

  ## JSON

  `to_map/1` and `to_json/2` write the graph as deepeval's `to_dict` and
  `to_json` do, and `from_map/1` and `from_json/1` read what they write
  (deepeval's `from_dict` and `from_json`), so a graph moves between
  deepeval and DeepEvalEx:

      {
        "nodes": {
          "<id>": {"type": "TaskNode", "instructions": "...", "output_label": "...",
                   "label": null, "evaluation_params": ["actual_output"], "children": ["<id>"]},
          "<id>": {"type": "BinaryJudgementNode", "criteria": "...", "label": null,
                   "evaluation_params": null, "children": ["<id>", "<id>"]},
          "<id>": {"type": "VerdictNode", "verdict": false, "score": 0},
          "<id>": {"type": "VerdictNode", "verdict": true, "child": {"type": "node", "ref": "<id>"}}
        }
      }

  The document describes the graph's structure only. Node ids are fresh
  random uuids each time it is written; the roots are the nodes no other
  node refers to, in document order (decode with ordered objects, as
  `from_json/1` does, to keep it). A verdict's child is a node
  (`"node"`), a GEval (`"geval"`, with its constructor arguments) or
  another metric (`"metric"`, with deepeval's class name, such as
  `"AnswerRelevancyMetric"`, and its JSON-able options as `"kwargs"`).
  A metric class names a `DeepEvalEx.Metrics` module, with deepeval's
  `Metric` suffix, or any other metric module by its Elixir name. Models,
  adapters, API keys and other options that are not JSON are left out.
  Only single-turn graphs are supported.
  """

  alias DeepEvalEx.Metrics.DAG.{Node, Serialization, TaskNode, VerdictNode}

  @enforce_keys [:root_nodes]
  defstruct root_nodes: [], nodes: %{}, indegree: %{}, parents: %{}

  @typedoc """
  A checked graph:

  - `:root_nodes` - the nodes the walk starts from, in order
  - `:nodes` - every node by id
  - `:indegree` - each node's number of incoming edges
  - `:parents` - each node's parents' ids, in the order they were reached
  """
  @type t :: %__MODULE__{
          root_nodes: [Node.t()],
          nodes: %{Node.id() => Node.t()},
          indegree: %{Node.id() => non_neg_integer()},
          parents: %{Node.id() => [Node.id()]}
        }

  @doc """
  Builds and checks the graph from its root nodes, deepeval's
  `DeepAcyclicGraph(root_nodes)`. Raises `ArgumentError` for an invalid
  graph (see the moduledoc).
  """
  @spec new([Node.t()]) :: t()
  def new([_ | _] = root_nodes) do
    if not Enum.all?(root_nodes, &Node.node?/1),
      do: raise(ArgumentError, "A DAG's root nodes must be DAG nodes.")

    if length(root_nodes) > 1 and Enum.any?(root_nodes, &Node.judgement?/1) do
      raise ArgumentError,
            "You cannot provide more than one root node when a BinaryJudgementNode or " <>
              "NonBinaryJudgementNode is a root."
    end

    graph =
      root_nodes
      |> Enum.reduce(%__MODULE__{root_nodes: root_nodes}, &visit(&1, [], &2))
      |> collapse_exclusive_verdict_edges()

    if Enum.any?(root_nodes, &(graph.indegree[&1.id] > 0)) do
      raise ArgumentError,
            "You cannot declare a node as a root node when it is also reachable from another " <>
              "root node."
    end

    graph
  end

  def new(_root_nodes), do: raise(ArgumentError, "A DAG needs at least one root node.")

  @doc """
  The test case params the graph's nodes are shown, in the order first
  met, deepeval's `extract_required_params`: those of every task and
  judgement reached from the roots without passing a verdict. The nodes
  after a verdict are not included, as in deepeval.
  """
  @spec required_params(t()) :: [atom()]
  def required_params(%__MODULE__{root_nodes: roots}) do
    roots |> Enum.flat_map(&params_before_verdicts/1) |> Enum.uniq()
  end

  defp params_before_verdicts(%VerdictNode{}), do: []

  defp params_before_verdicts(node),
    do: (node.evaluation_params || []) ++ Enum.flat_map(node.children, &params_before_verdicts/1)

  @doc """
  The graph as deepeval's `to_dict` writes it (see "JSON"), its nodes in
  breadth-first order from the roots.
  """
  @spec to_map(t()) :: %{String.t() => Jason.OrderedObject.t()}
  defdelegate to_map(graph), to: Serialization

  @doc """
  The graph as deepeval's `to_json` writes it: `to_map/1` as Python's
  `json.dumps(indent=indent)` prints it.
  """
  @spec to_json(t(), non_neg_integer()) :: String.t()
  defdelegate to_json(graph, indent \\ 2), to: Serialization

  @doc """
  Builds the graph from what `to_map/1` (or deepeval's `to_dict`) wrote,
  with string keys; a `Jason.OrderedObject` keeps the roots' order.
  Raises `ArgumentError` for a malformed document, with deepeval's
  message, or an invalid graph.
  """
  @spec from_map(map() | Jason.OrderedObject.t()) :: t()
  defdelegate from_map(map), to: Serialization

  @doc """
  Builds the graph from what `to_json/2` (or deepeval's `to_json`) wrote,
  as `from_map/1` does.
  """
  @spec from_json(String.t()) :: t()
  defdelegate from_json(json), to: Serialization

  # deepeval's _build_graph: a depth-first visit that validates every node,
  # rejects cycles and counts incoming edges.
  defp visit(node, stack, graph) do
    id = node.id

    cond do
      id in stack ->
        raise ArgumentError, "Cycle detected in DAG graph."

      Map.has_key?(graph.nodes, id) ->
        if graph.nodes[id] != node, do: raise(ArgumentError, two_versions(node))
        graph

      true ->
        Node.validate!(node)
        stack = [id | stack]

        graph = %{
          graph
          | nodes: Map.put(graph.nodes, id, node),
            indegree: Map.put_new(graph.indegree, id, 0)
        }

        node
        |> Node.edges()
        |> Enum.reduce(graph, fn child, graph ->
          graph = %{
            graph
            | indegree: Map.update(graph.indegree, child.id, 1, &(&1 + 1)),
              parents: Map.update(graph.parents, child.id, [id], &(&1 ++ [id]))
          }

          visit(child, stack, graph)
        end)
    end
  end

  defp two_versions(%module{} = node) do
    "#{module |> Module.split() |> List.last()} #{describe(node)} appears in two versions in " <>
      "the DAG: a node keeps its id when add_node/2 or add_verdict/3 extends it, so place " <>
      "only its final version."
  end

  defp describe(%TaskNode{instructions: instructions}), do: inspect(instructions)
  defp describe(%VerdictNode{verdict: verdict}), do: inspect(verdict)
  defp describe(%{criteria: criteria}), do: inspect(criteria)

  # deepeval's _collapse_exclusive_verdict_edges: several verdicts of one
  # judgement leading to the same node count as one incoming edge, as only
  # one of them ever fires. Only a verdict with exactly one parent, a
  # judgement, and that is not a root qualifies.
  defp collapse_exclusive_verdict_edges(%__MODULE__{} = graph) do
    root_ids = Enum.map(graph.root_nodes, & &1.id)

    indegree =
      Enum.reduce(graph.parents, graph.indegree, fn {id, parent_ids}, indegree ->
        parent_ids
        |> Enum.flat_map(&exclusive_owner(graph, &1, root_ids))
        |> Enum.frequencies()
        |> Enum.reduce(indegree, fn
          {_owner, count}, indegree when count > 1 ->
            Map.update!(indegree, id, &(&1 - (count - 1)))

          _single, indegree ->
            indegree
        end)
      end)

    %{graph | indegree: indegree}
  end

  defp exclusive_owner(graph, parent_id, root_ids) do
    with %VerdictNode{} <- graph.nodes[parent_id],
         false <- parent_id in root_ids,
         [owner_id] <- Map.get(graph.parents, parent_id, []),
         true <- Node.judgement?(graph.nodes[owner_id]) do
      [owner_id]
    else
      _not_exclusive -> []
    end
  end
end
