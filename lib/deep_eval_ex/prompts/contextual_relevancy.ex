# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/contextual_relevancy/templates/*.txt), Copyright
# Confident AI, Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.ContextualRelevancy do
  @moduledoc """
  Prompt templates for the ContextualRelevancy metric.

  ContextualRelevancy measures how much of each retrieval context node is
  relevant to the input.

  Each function renders deepeval 4.3.1's `ContextualRelevancyMetric`
  template of the same name byte for byte, as deepeval renders it for a
  text-only test case (`multimodal=False`, with the arguments of its
  `_contextual_relevancy_verdict_kwargs`): statements rather than "statement
  or image", and the empty-context instruction, as DeepEvalEx has no
  multimodal test cases. Lists are printed as Python lists and scores as
  `format(score, ".2f")` (see `DeepEvalEx.Prompts.Python`).
  `system_one_verdict/0` and `system_one_questions/0` are its System One
  templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`, which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to extract the statements of one retrieval context
  node and judge whether each is relevant to the input.

  The metric renders one per node.

  ## Options

  - `:input` - the test case input (required)
  - `:context` - one retrieval context node, a string (required)
  """
  def generate_verdicts(opts) do
    input = Keyword.fetch!(opts, :input)
    context = Keyword.fetch!(opts, :context)

    """
    Based on the input and context, please generate a JSON object to indicate whether each statement found in the context is relevant to the provided input. The JSON will be a list of 'verdicts', with 2 mandatory fields: 'verdict' and 'statement', and 1 optional field: 'reason'.
    You should first extract statements found in the context, which are high level information found in the context, before deciding on a verdict and optionally a reason for each statement.
    The 'verdict' key should STRICTLY be either 'yes' or 'no', and states whether the statement is relevant to the input.
    Provide a 'reason' ONLY IF verdict is no. You MUST quote the irrelevant parts of the statement to back up your reason.
    If provided context contains no actual content or statements then: give "no" as a "verdict",
    put context into "statement", and "No statements found in provided context." into "reason".
    **
    IMPORTANT: Please make sure to only return in JSON format.
    Example Context: "Einstein won the Nobel Prize for his discovery of the photoelectric effect. He won the Nobel Prize in 1968. There was a cat."
    Example Input: "What were some of Einstein's achievements?"

    Example:
    {
      "verdicts": [
        {
          "statement": "Einstein won the Nobel Prize for his discovery of the photoelectric effect in 1968",
          "verdict": "yes"
        },
        {
          "statement": "There was a cat.",
          "reason": "The retrieval context contained the information 'There was a cat' when it has nothing to do with Einstein's achievements.",
          "verdict": "no"
        }
      ]
    }
    **

    Input:
    #{input}

    Context:
    #{context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the contextual relevancy score (required)
  - `:input` - the test case input (required)
  - `:irrelevant_statements` - the reasons of the `"no"` verdicts, `nil`
    where the judge gave none (required)
  - `:relevant_statements` - the statements of the other verdicts
    (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    input = Keyword.fetch!(opts, :input)
    irrelevant_statements = opts |> Keyword.fetch!(:irrelevant_statements) |> Python.repr()
    relevant_statements = opts |> Keyword.fetch!(:relevant_statements) |> Python.repr()

    """
    Based on the given input, reasons for why the retrieval context is irrelevant to the input, the statements in the retrieval context that is actually relevant to the retrieval context, and the contextual relevancy score (the closer to 1 the better), please generate a CONCISE reason for the score.
    In your reason, you should quote data provided in the reasons for irrelevancy and relevant statements to support your point.

    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <contextual_relevancy_score> because <your_reason>."
    }

    If the score is 1, keep it short and say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).
    **


    Contextual Relevancy Score:
    #{score}

    Input:
    #{input}

    Reasons for why the retrieval context is irrelevant to the input:
    #{irrelevant_statements}

    Statement in the retrieval context that is relevant to the input:
    #{relevant_statements}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each sentence of a
  retrieval context node under the `:hybrid` eval mode, deepeval's
  `_experimental_system_one_verdict` template: a Noul whose instructions
  pair it with the sentence, about a state holding the `input` (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict, do: "Is `statement` relevant to addressing `input`?"

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about `input`
  and `retrieval_context`, which `DeepEvalEx.SystemOne.Scored.parse!/1`
  reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every statement in `retrieval_context` is relevant to addressing `input`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "Every node in `retrieval_context` contains at least one statement relevant to addressing `input`."
      },
      {
        "type": "score",
        "question": "How much of `retrieval_context` is relevant to addressing `input`?",
        "levels": ["None of it", "Less than half", "Most of it", "All of it"]
      }
    ]\
    """
  end
end
