# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/dag/templates/*/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# the DAG parity scenarios check every byte.

defmodule DeepEvalEx.Prompts.DAG do
  @moduledoc """
  Prompt templates for the nodes of a `DeepEvalEx.Metrics.DAG` graph.

  Each function renders the deepeval 4.3.1 template of the same name byte
  for byte, as deepeval renders it for a text-only test case:
  `generate_task_output/1` (`TaskNode`), `generate_binary_verdict/1`
  (`BinaryJudgement`), `generate_non_binary_verdict/1`
  (`NonBinaryJudgement`) and `generate_reason/1` (`VerdictNode`). 4.3.1's
  templates include the multimodal input rules fragment unconditionally,
  so the prompts carry it too.

  deepeval's nodes render these templates under an explicit template class,
  so a metric's `evaluation_template` never overrides them; neither does
  DeepEvalEx.
  """

  alias DeepEvalEx.Prompts.Python

  @multimodal_input_rules """

  --- MULTIMODAL INPUT RULES ---
  - Treat image content as factual evidence.
  - Only reference visual details that are explicitly and clearly visible.
  - Do not infer or guess objects, text, or details not visibly present.
  - If an image is unclear or ambiguous, mark uncertainty explicitly.
  """

  @doc """
  Generates a prompt asking a `DeepEvalEx.Metrics.DAG.TaskNode`'s output.

  ## Options

  - `:instructions` - the task's instructions (required)
  - `:text` - the task's text: its parents' outputs and its evaluation
    params (required)
  """
  @spec generate_task_output(keyword()) :: String.t()
  def generate_task_output(opts) do
    instructions = Keyword.fetch!(opts, :instructions)
    text = Keyword.fetch!(opts, :text)

    """
    Given the following instructions, generate an output.

    #{@multimodal_input_rules}

    #{instructions}

    #{text}

    ===END OF INSTRUCTIONS===

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'output' key as the output from the instructions.
    Example JSON:
    {
      "output": "your output goes here"
    }
    **

    JSON:\
    """
  end

  @doc """
  Generates a prompt asking a `DeepEvalEx.Metrics.DAG.BinaryJudgementNode`'s
  verdict.

  ## Options

  - `:criteria` - the judgement's criteria (required)
  - `:text` - the judgement's text (required)
  """
  @spec generate_binary_verdict(keyword()) :: String.t()
  def generate_binary_verdict(opts) do
    criteria = Keyword.fetch!(opts, :criteria)
    text = Keyword.fetch!(opts, :text)

    """
    #{criteria}

    #{@multimodal_input_rules}

    #{text}

    **
    IMPORTANT: Please make sure to only return a json with two keys: `verdict` (true or false), and the 'reason' key providing the reason. The verdict must be a boolean only, either true or false.
    Example JSON:
    {
      "reason": "...",
      "verdict": true
    }
    **

    JSON:\
    """
  end

  @doc """
  Generates a prompt asking a
  `DeepEvalEx.Metrics.DAG.NonBinaryJudgementNode`'s verdict, one of its
  options, printed as a Python list.

  ## Options

  - `:criteria` - the judgement's criteria (required)
  - `:text` - the judgement's text (required)
  - `:options` - the verdicts to choose from (required)
  """
  @spec generate_non_binary_verdict(keyword()) :: String.t()
  def generate_non_binary_verdict(opts) do
    criteria = Keyword.fetch!(opts, :criteria)
    text = Keyword.fetch!(opts, :text)
    options = opts |> Keyword.fetch!(:options) |> Python.repr()

    """
    #{criteria}

    #{@multimodal_input_rules}

    #{text}

    **
    IMPORTANT: Please make sure to only return a json with two keys: 'verdict' #{options} and 'reason' providing the reason.
    Example JSON:
    {
      "reason": "...",
      "verdict": #{options}
    }
    **

    JSON:\
    """
  end

  @doc """
  Generates a prompt explaining the score a `DeepEvalEx.Metrics.DAG.VerdictNode`
  ended the walk with, from the path taken.

  ## Options

  - `:name` - the metric's name, with its `[DAG]` suffix (required)
  - `:score` - the score, as deepeval's float (required)
  - `:verbose_steps` - the verbose log of each node walked so far, printed
    as a Python list (required)
  """
  @spec generate_reason(keyword()) :: String.t()
  def generate_reason(opts) do
    name = Keyword.fetch!(opts, :name)
    score = opts |> Keyword.fetch!(:score) |> Python.str()
    verbose_steps = opts |> Keyword.fetch!(:verbose_steps) |> Python.repr()

    """
    Given the metric name, the score of that metric, and the DAG traversal, generate a reason for why the score is that way.\s
    In this case, the "DAG Traversal" is the steps it took to the final leaf "VerdictNode". The DAG allows for deterministic decision trees, where depending on the outcome of the previous parent nodes results in the current path you're seeing.
    Your reason should directly reference the DAG traversal path to make it concrete, factual and concise.

    Metric Name:
    #{name}

    Score:
    #{score}

    DAG Traversal:
    #{verbose_steps}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <metric_name_score> because <your_reason>."
    }
    **

    JSON:\
    """
  end
end
