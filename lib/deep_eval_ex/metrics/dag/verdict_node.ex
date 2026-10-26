# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/nodes.py (VerdictNode)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.VerdictNode do
  @moduledoc """
  One outcome of a judgement in a `DeepEvalEx.Metrics.DAG` graph, deepeval
  4.3.1's `VerdictNode`.

  It is reached when its judgement's verdict is its `:verdict` (`true` or
  `false` under a `DeepEvalEx.Metrics.DAG.BinaryJudgementNode`, one of the
  options under a `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode`), and
  then either:

  - ends the walk with `:score`, an integer from 0 to 10: the metric's
    score is `score / 10`, and the LLM explains it from the path taken; or
  - hands over to `:child`: another node, which runs next, or a metric,
    which is measured on the test case and whose score and reason become
    the DAG's. A metric is a module, `{module, opts}` or a metric struct;
    a `DeepEvalEx.Metrics.GEval` is rebuilt from its name, criteria (or
    evaluation steps) and evaluation params and judged by the DAG's LLM, as
    deepeval does.

  Usually built with `DeepEvalEx.Metrics.DAG.BinaryJudgementNode.add_verdict/3`
  or `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode.add_verdict/3`.
  """

  alias DeepEvalEx.Metrics.DAG.Node

  @enforce_keys [:id, :verdict]
  defstruct [:id, :verdict, :score, :child]

  @typedoc "A metric a verdict hands over to: a module, `{module, opts}` or a metric struct."
  @type metric :: module() | {module(), keyword()} | struct()

  @type t :: %__MODULE__{
          id: Node.id(),
          verdict: boolean() | String.t(),
          score: number() | nil,
          child: Node.t() | metric() | nil
        }

  @doc """
  Creates a verdict.

  ## Options

  - `:verdict` - the judgement's outcome it stands for: `true`/`false`, or
    an option's name (required)
  - `:score` - the score it ends the walk with, from 0 to 10
  - `:child` - the node or metric it hands over to

  Raises `ArgumentError`, as deepeval's constructor raises `ValueError`,
  unless exactly one of `:score` and `:child` is given, or for a score
  outside 0 to 10.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    verdict = Node.fetch!(opts, :verdict, "VerdictNode")
    score = Keyword.get(opts, :score)
    child = Keyword.get(opts, :child)

    cond do
      score != nil and child != nil ->
        raise ArgumentError, "A VerdictNode can have either a 'score' or a 'child', but not both."

      score == nil and child == nil ->
        raise ArgumentError, "A VerdictNode must have either a 'score' or a 'child'."

      not valid_score?(score) ->
        raise ArgumentError, "The score must be between 0 and 10, inclusive."

      true ->
        %__MODULE__{id: Node.new_id(), verdict: verdict, score: score, child: child}
    end
  end

  defp valid_score?(nil), do: true
  defp valid_score?(score), do: is_number(score) and score >= 0 and score <= 10
end
