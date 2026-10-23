# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/nodes.py (BinaryJudgementNode)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.BinaryJudgementNode do
  @moduledoc """
  A yes/no judgement in a `DeepEvalEx.Metrics.DAG` graph, deepeval 4.3.1's
  `BinaryJudgementNode`.

  It judges `:criteria` against its text (the output of each parent
  `DeepEvalEx.Metrics.DAG.TaskNode`, then its `:evaluation_params`), and the
  walk goes on through the child `DeepEvalEx.Metrics.DAG.VerdictNode` whose
  verdict is the judgement's: it has exactly two, one `true` and one
  `false`.

  ## Eval modes

  Under `:llm` the LLM judges it. Under `:hybrid` (and `:system_one`, which
  a DAG runs as `:hybrid`) a System One model does, deepeval's
  `SystemOneBinarySpec`: one Noul whose instructions are the criteria about
  the state `{"text": text}`, `true` when P(true) is 0.5 or more, with the
  reason `"P(true)=0.92"`. A failed request falls back to the LLM (see
  `DeepEvalEx.SystemOne.Decision`).

  ## Examples

      DeepEvalEx.Metrics.DAG.BinaryJudgementNode.new(criteria: "Is the answer polite?",
        evaluation_params: [:actual_output]
      )
      |> DeepEvalEx.Metrics.DAG.BinaryJudgementNode.add_verdict(false, score: 0)
      |> DeepEvalEx.Metrics.DAG.BinaryJudgementNode.add_verdict(true, score: 10)
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
  Creates a binary judgement.

  ## Options

  - `:criteria` - what is judged, a yes/no question (required)
  - `:evaluation_params` - the test case fields it is shown (default: none)
  - `:label` - a name for the verbose logs (default: none)
  - `:children` - its two verdicts (default: none; see also
    `add_verdict/3`)

  Raises `ArgumentError` for children other than one `true` and one
  `false` verdict, with deepeval's message.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    node = %__MODULE__{
      id: Node.new_id(),
      criteria: Node.fetch!(opts, :criteria, "BinaryJudgementNode"),
      evaluation_params: Keyword.get(opts, :evaluation_params),
      label: Keyword.get(opts, :label),
      children: Keyword.get(opts, :children, [])
    }

    if node.children != [], do: validate!(node)
    node
  end

  @doc """
  Appends a verdict for `verdict` (`true` or `false`), deepeval's
  `add_verdict`: ending the walk with `score:` or handing over to `then:`, a
  node or a metric (see `DeepEvalEx.Metrics.DAG.VerdictNode`).
  """
  @spec add_verdict(t(), boolean(), keyword()) :: t()
  def add_verdict(%__MODULE__{children: children} = node, verdict, opts) do
    verdict_node =
      VerdictNode.new(verdict: verdict, score: opts[:score], child: opts[:then])

    %{node | children: children ++ [verdict_node]}
  end

  @doc false
  # deepeval's BinaryJudgementNode._validate.
  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{children: children}) do
    if length(children) != 2,
      do: raise(ArgumentError, "BinaryJudgementNode must have exactly 2 children.")

    Enum.each(children, fn
      %VerdictNode{verdict: verdict} when is_boolean(verdict) ->
        :ok

      %VerdictNode{} ->
        raise ArgumentError, "All children BinaryJudgementNode must have a boolean verdict."

      _other ->
        raise ArgumentError, "All children must be of type VerdictNode."
    end)

    verdicts = Enum.map(children, & &1.verdict)

    if Enum.count(verdicts, &(&1 == true)) != 1 or Enum.count(verdicts, &(&1 == false)) != 1,
      do:
        raise(
          ArgumentError,
          "BinaryJudgementNode must have one True and one False VerdictNode child."
        )

    :ok
  end
end
