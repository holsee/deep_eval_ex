# Copyright 2024 DeepEvalEx Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/faithfulness/template.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Prompts.Faithfulness do
  @moduledoc """
  Prompt templates for the Faithfulness metric.

  Faithfulness measures whether claims in the LLM's output are
  supported by the retrieval context (for RAG applications).
  """

  @doc """
  Generates a prompt to extract claims from the actual output.

  Claims are factual statements that can be verified against
  the retrieval context.
  """
  def generate_claims(opts) do
    actual_output = Keyword.fetch!(opts, :actual_output)

    """
    Based on the given text, please extract a comprehensive list of FACTUAL, undisputed claims that can be inferred from the provided AI output.
    These claims MUST BE COHERENT, and CANNOT be taken out of context.

    Example:
    Example Text:
    "Albert Einstein, the genius often associated with wild hair and mind-bending theories, famously won the Nobel Prize in Physics—though not for his groundbreaking work on relativity, as many assume. Instead, in 1968, he was honored for his discovery of the photoelectric effect, a phenomenon that laid the foundation for quantum mechanics."

    Example JSON:
    {
        "claims": [
            "Einstein won the Nobel Prize for his discovery of the photoelectric effect in 1968.",
            "The photoelectric effect is a phenomenon that laid the foundation for quantum mechanics."
        ]
    }
    ===== END OF EXAMPLE ======

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "claims" key as a list of strings. No words or explanation is needed.
    Only include claims that are factual, BUT IT DOESN'T MATTER IF THEY ARE FACTUALLY CORRECT. The claims you extract should include the full context it was presented in, NOT cherry picked facts.
    You should NOT include any prior knowledge, and take the text at face value when extracting claims.
    **

    AI Output:
    #{actual_output}

    JSON:
    """
  end

  @doc """
  Generates a prompt to extract truths from the retrieval context.

  Truths are factual statements from the context that claims
  can be verified against.
  """
  def generate_truths(opts) do
    retrieval_context = Keyword.fetch!(opts, :retrieval_context)
    extraction_limit = Keyword.get(opts, :extraction_limit)

    limit_text =
      case extraction_limit do
        nil -> " FACTUAL, undisputed truths"
        1 -> " the single most important FACTUAL, undisputed truth"
        n -> " the #{n} most important FACTUAL, undisputed truths per document"
      end

    """
    Based on the given text, please generate a comprehensive list of#{limit_text} that can be inferred from the provided text.
    These truths MUST BE COHERENT. They must NOT be taken out of context.

    Example:
    Example Text:
    "Albert Einstein, the genius often associated with wild hair and mind-bending theories, famously won the Nobel Prize in Physics—though not for his groundbreaking work on relativity, as many assume. Instead, in 1968, he was honored for his discovery of the photoelectric effect, a phenomenon that laid the foundation for quantum mechanics."

    Example JSON:
    {
        "truths": [
            "Einstein won the Nobel Prize for his discovery of the photoelectric effect in 1968.",
            "The photoelectric effect is a phenomenon that laid the foundation for quantum mechanics."
        ]
    }
    ===== END OF EXAMPLE ======

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "truths" key as a list of strings. No words or explanation is needed.
    Only include truths that are factual, BUT IT DOESN'T MATTER IF THEY ARE FACTUALLY CORRECT.
    **

    Text:
    #{retrieval_context}

    JSON:
    """
  end

  @doc """
  Generates a prompt to produce verdicts for each claim.

  Each verdict indicates whether the claim:
  - "yes" - Is supported by the retrieval context
  - "no" - Contradicts the retrieval context
  - "idk" - Cannot be verified (not mentioned in context)
  """
  def generate_verdicts(opts) do
    claims = Keyword.fetch!(opts, :claims)
    retrieval_context = Keyword.fetch!(opts, :retrieval_context)

    claims_formatted = format_claims(claims)

    """
    Based on the given claims, which is a list of strings, generate a list of JSON objects to indicate whether EACH claim contradicts any facts in the retrieval context. The JSON will have 2 fields: 'verdict' and 'reason'.
    The 'verdict' key should STRICTLY be either 'yes', 'no', or 'idk', which states whether the given claim agrees with the context.
    Provide a 'reason' ONLY if the answer is 'no' or 'idk'.
    The provided claim is drawn from the actual output. Try to provide a correction in the reason using the facts in the retrieval context.

    Expected JSON format:
    {
        "verdicts": [
            {
                "verdict": "yes"
            },
            {
                "reason": "<explanation_for_contradiction>",
                "verdict": "no"
            },
            {
                "reason": "<explanation_for_uncertainty>",
                "verdict": "idk"
            }
        ]
    }

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects.
    Generate ONE verdict per claim - length of 'verdicts' MUST equal number of claims.
    No 'reason' needed for 'yes' verdicts.
    Only use 'no' if retrieval context DIRECTLY CONTRADICTS the claim - never use prior knowledge.
    Use 'idk' for claims not backed up by context OR factually incorrect but non-contradictory.
    Vague/speculative language in claims (e.g. 'may have', 'possibility') does NOT count as contradiction.
    **

    Retrieval Contexts:
    #{retrieval_context}

    Claims:
    #{claims_formatted}

    JSON:
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.
  """
  def generate_reason(opts) do
    score = Keyword.fetch!(opts, :score)
    contradictions = Keyword.fetch!(opts, :contradictions)

    score_formatted = Float.round(score * 1.0, 2)
    contradictions_formatted = format_contradictions(contradictions)

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
    Your reason MUST use information in `contradictions` in your reason.
    Be sure in your reason, as if you know what the actual output is from the contradictions.
    **

    Faithfulness Score:
    #{score_formatted}

    Contradictions:
    #{contradictions_formatted}

    JSON:
    """
  end

  defp format_claims(claims) when is_list(claims) do
    claims
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {claim, i} -> "#{i}. #{claim}" end)
  end

  defp format_contradictions([]), do: "(none)"

  defp format_contradictions(contradictions) when is_list(contradictions) do
    contradictions
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {c, i} -> "#{i}. #{c}" end)
  end
end
