# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/hallucination/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.Hallucination do
  @moduledoc """
  Prompt templates for the Hallucination metric.

  Hallucination measures whether the actual output contradicts
  the provided context. Unlike Faithfulness which extracts claims
  and truths separately, Hallucination directly compares the output
  against each context item.

  Each function renders deepeval 4.3.1's `HallucinationMetric` template of
  the same name byte for byte, as deepeval renders it for a text-only test
  case (`multimodal=False`). Unlike the other metrics' templates, 4.3.1's
  Hallucination templates include the multimodal input rules fragment
  unconditionally, so these prompts carry it too. Lists are printed as
  Python lists and scores as `format(score, ".2f")` (see
  `DeepEvalEx.Prompts.Python`).
  `system_one_verdict/0` and `system_one_questions/0` are its System One
  templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`, which take no arguments and carry
  no multimodal fragment.
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
  Generates a prompt to produce verdicts for each context.

  For each context, determines whether the actual output:
  - "yes" - Agrees with the context (factual alignment)
  - "no" - Contradicts the context (hallucination)

  ## Options

  - `:actual_output` - the output to check (required)
  - `:contexts` - the test case's context, a list of strings (required)
  """
  def generate_verdicts(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)
    contexts_list = Keyword.fetch!(opts, :contexts)
    contexts = Python.repr(contexts_list)
    contexts_count = length(contexts_list)

    """
    For each context in contexts, which is a list of strings, please generate a list of JSON objects to indicate whether the given 'actual output' agrees with EACH context. The JSON will have 2 fields: 'verdict' and 'reason'.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    The 'verdict' key should STRICTLY be either 'yes' or 'no', and states whether the given text agrees with the context. 
    The 'reason' is the reason for the verdict. When the answer is 'no', try to provide a correction in the reason. 

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects.
    Example contexts: ["Einstein won the Nobel Prize for his discovery of the photoelectric effect.", "Einstein won the Nobel Prize in 1968."]
    Example actual output: "Einstein won the Nobel Prize in 1969 for his discovery of the photoelectric effect."

    Example:
    {
      "verdicts": [
        {
          "reason": "The actual output agrees with the provided context which states that Einstein won the Nobel Prize for his discovery of the photoelectric effect.",
          "verdict": "yes"
        },
        {
          "reason": "The actual output contradicts the provided context which states that Einstein won the Nobel Prize in 1968, not 1969.",
          "verdict": "no"
        }
      ]  
    }

    You should NOT incorporate any prior knowledge you have and take each context at face value. Since you are going to generate a verdict for each context, the number of 'verdicts' SHOULD BE STRICTLY EQUAL TO #{contexts_count}.
    You should FORGIVE cases where the actual output is lacking in detail, you should ONLY provide a 'no' answer if IT IS A CONTRADICTION.
    **

    Contexts:
    #{contexts}

    Actual Output:
    #{actual_output}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the hallucination score (required)
  - `:factual_alignments` - the reasons of the `"yes"` verdicts (required)
  - `:contradictions` - the reasons of the `"no"` verdicts (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    factual_alignments = opts |> Keyword.fetch!(:factual_alignments) |> Python.repr()
    contradictions = opts |> Keyword.fetch!(:contradictions) |> Python.repr()

    """
    Given a list of factual alignments and contradictions, which highlights alignment/contradictions between the `actual output` and `contexts, use it to provide a reason for the hallucination score in a CONCISELY. Note that the hallucination score ranges from 0 - 1 and measures how well the `actual output` aligns with the `contexts`, and the higher the better.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <hallucination_score> because <your_reason>."
    }
    **

    Factual Alignments:
    #{factual_alignments}

    Contradictions:
    #{contradictions}

    Hallucination Score:
    #{score}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each context under the
  `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the context, about a
  state holding the `actual_output` (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict,
    do: "Does `actual_output` agree with `context`? Answer no if it contradicts it."

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about
  `actual_output` and `context`, which `DeepEvalEx.SystemOne.Scored.parse!/1`
  reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "`actual_output` agrees with every document in `context`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No statement in `actual_output` contradicts a document in `context`."
      },
      {
        "type": "score",
        "question": "How much of `actual_output` is consistent with the documents in `context`?",
        "levels": ["Contradicts them", "Mostly contradicts them", "Mostly consistent", "Fully consistent"]
      }
    ]\
    """
  end
end
