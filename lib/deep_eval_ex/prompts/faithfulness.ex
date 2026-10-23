# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/faithfulness/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.Faithfulness do
  @moduledoc """
  Prompt templates for the Faithfulness metric.

  Faithfulness measures whether claims in the LLM's output are
  supported by the retrieval context (for RAG applications).

  Each function renders deepeval 4.3.1's `FaithfulnessMetric` template of
  the same name byte for byte. The claims, truths and verdicts templates
  take deepeval's `multimodal` flag as the `:multimodal` option (default
  `false`), which a multimodal `DeepEvalEx.TestCase` sets: the text is
  then an "excerpt" that may hold images, and the verdicts template has
  the multimodal example and guidelines (`DeepEvalEx.Prompts.Fragments`)
  in place of the text-only guidelines. Lists are printed
  as Python lists and scores as `format(score, ".2f")` (see
  `DeepEvalEx.Prompts.Python`). `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_claims: 1,
      generate_truths: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.{Fragments, Python}

  @doc """
  Generates a prompt to extract claims from the actual output.

  Claims are factual statements that can be verified against
  the retrieval context.

  ## Options

  - `:actual_output` - the text to extract claims from (required)
  - `:multimodal` - whether the test case holds images (default: `false`)
  """
  def generate_claims(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)
    multimodal = Keyword.get(opts, :multimodal, false)
    text = if multimodal, do: "excerpt", else: "text"
    label = if multimodal, do: "Excerpt", else: "AI Output"

    instruction =
      if multimodal,
        do:
          " The excerpt may contain both text and images, so extract claims from all provided content.",
        else: ""

    """
    Based on the given #{text}, please extract a comprehensive list of FACTUAL, undisputed truths, that can inferred from the provided actual AI output. #{instruction}
    These truths, MUST BE COHERENT, and CANNOT be taken out of context.

    Example:
    Example Text: 
    "Albert Einstein, the genius often associated with wild hair and mind-bending theories, famously won the Nobel Prize in Physics—though not for his groundbreaking work on relativity, as many assume. Instead, in 1968, he was honored for his discovery of the photoelectric effect, a phenomenon that laid the foundation for quantum mechanics."

    Example JSON: 
    {
      "claims": [
        "Einstein won the noble prize for his discovery of the photoelectric effect in 1968.",
        "The photoelectric effect is a phenomenon that laid the foundation for quantum mechanics."
      ]  
    }
    ===== END OF EXAMPLE ======

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "claims" key as a list of strings. No words or explanation is needed.
    Only include claims that are factual, BUT IT DOESN'T MATTER IF THEY ARE FACTUALLY CORRECT. The claims you extract should include the full context it was presented in, NOT cherry picked facts.
    You should NOT include any prior knowledge, and take the text at face value when extracting claims.
    You should be aware that it is an AI that is outputting these claims.
    **

    #{label}:
    #{actual_output}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to extract truths from the retrieval context.

  Truths are factual statements from the context that claims
  can be verified against.

  ## Options

  - `:retrieval_context` - the retrieval context, its documents joined with
    blank lines (required)
  - `:extraction_limit` - how many truths to extract per document; `nil`
    for no limit (default: `nil`)
  - `:multimodal` - whether the test case holds images (default: `false`)
  """
  def generate_truths(opts) do
    retrieval_context = Keyword.fetch!(opts, :retrieval_context)
    limit = opts |> Keyword.get(:extraction_limit) |> limit_phrase()
    multimodal = Keyword.get(opts, :multimodal, false)
    given = if multimodal, do: "excerpt (text and images)", else: "text"
    provided = if multimodal, do: "excerpt", else: "text"
    label = if multimodal, do: "Excerpt", else: "Text"
    instruction = if multimodal, do: " The excerpt may contain both text and images.", else: ""

    """
    Based on the given #{given}, please generate a comprehensive list of#{limit}, that can inferred from the provided #{provided}.#{instruction}
    These truths, MUST BE COHERENT. They must NOT be taken out of context.

    Example:
    Example Text: 
    "Albert Einstein, the genius often associated with wild hair and mind-bending theories, famously won the Nobel Prize in Physics—though not for his groundbreaking work on relativity, as many assume. Instead, in 1968, he was honored for his discovery of the photoelectric effect, a phenomenon that laid the foundation for quantum mechanics."

    Example JSON: 
    {
      "truths": [
        "Einstein won the noble prize for his discovery of the photoelectric effect in 1968.",
        "The photoelectric effect is a phenomenon that laid the foundation for quantum mechanics."
      ]  
    }
    ===== END OF EXAMPLE ======
    **
    IMPORTANT: Please make sure to only return in JSON format, with the "truths" key as a list of strings. No words or explanation is needed.
    Only include truths that are factual, BUT IT DOESN'T MATTER IF THEY ARE FACTUALLY CORRECT.
    **

    #{label}:
    #{retrieval_context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to produce verdicts for each claim.

  Each verdict indicates whether the claim:
  - "yes" - Is supported by the retrieval context
  - "no" - Contradicts the retrieval context
  - "borderline" - Cannot be verified (not mentioned in context)

  ## Options

  - `:claims` - the claims, a list of strings (required)
  - `:retrieval_context` - the truths, joined with blank lines (required)
  - `:multimodal` - whether the test case holds images (default: `false`)
  """
  def generate_verdicts(opts) do
    claims = opts |> Keyword.fetch!(:claims) |> Python.repr()
    retrieval_context = Keyword.fetch!(opts, :retrieval_context)

    """
    Based on the given claims, which is a list of strings, generate a list of JSON objects to indicate whether EACH claim contradicts any facts in the retrieval context. The JSON will have 2 fields: 'verdict' and 'reason'.
    The 'verdict' key should STRICTLY be either 'yes', 'no', or 'borderline', which states whether the given claim agrees with the context. 
    Provide a 'reason' ONLY if the answer is 'no' or 'borderline'. 
    The provided claim is drawn from the actual output. Try to provide a correction in the reason using the facts in the retrieval context.


    Expected JSON format:
    {
    "verdicts": [
    {
    "verdict": "yes"
    },
    {
    "reason": <explanation_for_contradiction>,
    "verdict": "no"
    },
    {
    "reason": <explanation_for_uncertainty>,
    "verdict": "borderline"
    }
    ]  
    }

    #{Fragments.faithfulness_verdicts_example_multimodal(opts)}
    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects.
    #{Fragments.faithfulness_verdicts_guidelines(opts)}
    **

    Retrieval Contexts:
    #{retrieval_context}

    Claims:
    #{claims}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:score` - the faithfulness score (required)
  - `:contradictions` - the reasons of the `"no"` verdicts, a list of
    strings (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    contradictions = opts |> Keyword.fetch!(:contradictions) |> Python.repr()

    """
    Below is a list of Contradictions. It is a list of strings explaining why the 'actual output' does not align with the information presented in the 'retrieval context'. Contradictions happen in the 'actual output', NOT the 'retrieval context'.
    Given the faithfulness score, which is a 0-1 score indicating how faithful the `actual output` is to the retrieval context (higher the better), CONCISELY summarize the contradictions to justify the score. 

    Expected JSON format:
    {
      "reason": "The score is <faithfulness_score> because <your_reason>."
    }

    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.

    If there are no contradictions, just say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).
    Your reason MUST use information in `contradiction` in your reason.
    Be sure in your reason, as if you know what the actual output is from the contradictions.
    **

    Faithfulness Score:
    #{score}

    Contradictions:
    #{contradictions}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each claim under the
  `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the claim, about a state
  holding the truths as `retrieval_context` (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Is `claim` supported by the facts in `retrieval_context`? Answer no if it contradicts them."
  end

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about
  `actual_output` and `retrieval_context`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every factual claim in `actual_output` is supported by the facts in `retrieval_context`.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No claim in `actual_output` contradicts the facts in `retrieval_context`."
      },
      {
        "type": "score",
        "question": "How much of `actual_output` is grounded in the facts in `retrieval_context`?",
        "levels": ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
      }
    ]\
    """
  end

  # deepeval's _faithfulness_truths_limit_phrase.
  defp limit_phrase(nil), do: " FACTUAL, undisputed truths"
  defp limit_phrase(1), do: " the single most important FACTUAL, undisputed truth"

  defp limit_phrase(limit),
    do: " the #{limit} most important FACTUAL, undisputed truths per document"
end
