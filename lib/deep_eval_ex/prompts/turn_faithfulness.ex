# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/turn_faithfulness/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.TurnFaithfulness do
  @moduledoc """
  Prompt templates for the TurnFaithfulness metric.

  TurnFaithfulness measures whether the claims of the assistant turns of
  each sliding window of a conversation are supported by the window's
  retrieval context.

  Each function renders deepeval 4.3.1's `TurnFaithfulnessMetric` template
  of the same name byte for byte. The window templates leave out the
  multimodal input rules (`DeepEvalEx.Prompts.Fragments`), keeping the
  blank lines around them, unless the `:multimodal` option is `true`, as
  for a multimodal `DeepEvalEx.ConversationalTestCase`. Lists are printed
  as Python lists, a window's score as `format(score, ".2f")` and the final
  score as Python's `str()` of it, unformatted, as deepeval passes them
  (see `DeepEvalEx.Prompts.Python`). `system_one_verdict/0` and
  `system_one_questions/0` are its System One templates,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`,
  which take no arguments.
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_truths: 1,
      generate_claims: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      generate_final_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]

  alias DeepEvalEx.Prompts.{Fragments, Python}

  @doc """
  Generates a prompt to extract the truths of a window's retrieval context.

  ## Options

  - `:reference_context` - the retrieval context of the window's assistant
    turns, joined with blank lines (required)
  - `:extraction_limit` - the most truths to extract, deepeval's
    `truths_extraction_limit`: `nil` for every truth (default: `nil`)
  - `:multimodal` - whether the conversation holds images, which adds the
    multimodal input rules (default: `false`)
  """
  def generate_truths(opts) do
    reference_context = Keyword.fetch!(opts, :reference_context)
    limit_description = limit_description(Keyword.get(opts, :extraction_limit))

    """

    Extract #{limit_description} from the REFERENCE CONTEXT.

    RULES:
    - Truths must be atomic, explicit factual statements.
    - Do not summarize or combine multiple facts.
    - Select truths based on reading order, not 'importance'.
    - Do not infer or expand beyond what is explicitly stated.
    - Keep each truth minimal but complete.
    - Treat images as factual evidence if multimodal, using only clearly visible information.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    Output MUST be ONLY valid JSON:

    {
      "truths": ["truth 1", "truth 2", ...]
    }

    REFERENCE CONTEXT:
    #{reference_context}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to extract the claims of a window's assistant turns.

  ## Options

  - `:input` - the window's user turns, each as `"\\n<content> "` (required)
  - `:assistant_output` - the window's assistant turns, each as
    `"\\n<content>"` (required)
  - `:multimodal` - as for `generate_truths/1`
  """
  def generate_claims(opts) do
    input = Keyword.fetch!(opts, :input)
    assistant_output = Keyword.fetch!(opts, :assistant_output)

    """

    Extract every factual-sounding claim asserted in the ASSISTANT'S OUTPUT.

    A claim is any statement presented as fact, even if it is incorrect, vague, implied, or unverifiable.

    RULES:
    - Use ONLY the assistant's output as the source of claims.
    - Use the user's preceding message ONLY to resolve pronouns or references, not as factual evidence.
    - Extract claims exactly as stated without rewriting, summarizing, merging, or omitting details.
    - If a sentence contains multiple factual assertions, extract each as a separate claim.
    - Claims may involve text or images if multimodal.
    - Do NOT add, infer, or transform information.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    Output MUST be ONLY valid JSON:

    {
      "claims": ["claim 1", "claim 2", ...]
    }

    USER MESSAGE:
    #{input}

    ASSISTANT OUTPUT:
    #{assistant_output}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to judge each claim of a window against its truths.

  ## Options

  - `:claims` - the window's claims (required)
  - `:reference_context` - the window's truths, joined with blank lines
    (required)
  - `:multimodal` - as for `generate_truths/1`
  """
  def generate_verdicts(opts) do
    claims = opts |> Keyword.fetch!(:claims) |> Python.repr()
    reference_context = Keyword.fetch!(opts, :reference_context)

    """

    For each claim, determine whether it is supported, contradicted, or not addressed by the reference context.

    DEFINITIONS:
    - "yes"  = The claim is directly supported by at least one truth.
    - "no"   = The claim directly contradicts at least one truth.
    - "borderline"  = The context does not confirm or contradict the claim.

    RULES:
    - One verdict per claim, in the same order.
    - Do NOT use prior knowledge.
    - Only use the explicit truths provided.
    - A "yes" verdict must not include a reason.
    - A "no" or "borderline" verdict must include a concise reason that quotes or paraphrases only the truths.
    - If a claim references an image and the visibility is unclear or ambiguous, use "borderline".
    - Do not create new facts or explanations.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    Output MUST be ONLY valid JSON:

    {
      "verdicts": [
        {
          "verdict": "yes"
        },
        {
          "verdict": "no",
          "reason": "<explanation>"
        },
        {
          "verdict": "borderline",
          "reason": "<explanation>"
        }
      ]
    }

    REFERENCE CONTEXT:
    #{reference_context}

    CLAIMS:
    #{claims}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain a window's score from its contradictions.

  ## Options

  - `:score` - the window's score, printed as `format(score, ".2f")`
    (required)
  - `:contradictions` - the reasons of the window's `no` verdicts (`nil`
    where the judge gave none) (required)
  - `:multimodal` - as for `generate_truths/1`
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    contradictions = opts |> Keyword.fetch!(:contradictions) |> Python.repr()

    """

    Below is a list of contradictions extracted from verdicts. Write a concise justification of the score.

    RULES:
    - If contradictions exist, summarize them in 1-3 sentences.
    - If no contradictions exist, respond:
    {
      "reason": "No contradictions were found."
    }
    - The summary must reference only the contradictions listed.
    - Tone must be neutral and concise.
    - No external knowledge may be used.

    #{Fragments.multimodal_input_rules_turn_metric(opts)}

    Output MUST be ONLY valid JSON:

    {
      "reason": "<summary>"
    }

    FAITHFULNESS SCORE:
    #{score}

    CONTRADICTIONS:
    #{contradictions}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to explain the final score from every window's reason.

  ## Options

  - `:final_score` - the metric's score, printed as Python's `str()`
    (required)
  - `:success` - whether the metric passed (required)
  - `:reasons` - every window's reason, in order (`nil` included)
    (required)
  """
  def generate_final_reason(opts) do
    final_score = opts |> Keyword.fetch!(:final_score) |> Python.repr()
    success = opts |> Keyword.fetch!(:success) |> Python.repr()
    reasons = opts |> Keyword.fetch!(:reasons) |> Python.repr()

    """
    You are an AI evaluator producing a single final explanation for the TurnFaithfulnessMetric result.

    Context:
    This metric evaluates conversational faithfulness by extracting truths from retrieval context, extracting claims from the assistant's output, and generating verdicts that compare each claim against the truths. Each interaction yields a reason indicating why a verdict failed or succeeded. You are given all those reasons.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <turn_faithfulness_score> because <your_reason>."
    }

    Inputs:
    - final_score: the averaged score across all interactions.
    - success: whether the metric passed or failed
    - reasons: a list of textual reasons generated from individual verdicts.

    Instructions:
    1. Read all reasons and synthesize them into one unified explanation.
    2. Describe patterns of claim-truth mismatches, contradictions, hallucinations, unsupported statements, or image-related errors if present.
    3. Do not repeat every reason; merge them into a concise, coherent narrative.
    5. If the metric failed, state the dominant failure modes. If it passed, state why the model's claims aligned with truths.
    6. Output a single paragraph with no lists, no bullets, no markup.

    Output:
    A single paragraph explaining the final outcome.

    Here's the inputs:

    Final Score: #{final_score}

    Reasons: 
    #{reasons}

    Success: #{success}

    Now give me a final reason that explains why the metric passed or failed. Output ONLY the reason and nothing else.

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each claim of a window
  under the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the claim, about a state
  holding the window's truths as `reference_context` (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Is `claim` supported by at least one truth in `reference_context`? Answer no if it " <>
      "contradicts them."
  end

  @doc """
  The questions a System One model answers about the whole conversation
  under the `:system_one` eval mode, deepeval's
  `_experimental_system_one_questions` template: a JSON array of two Nouls
  and a four-level Score about the `turns` and their `retrieval_context`,
  which `DeepEvalEx.SystemOne.Scored.parse!/1` reads.
  """
  @spec system_one_questions() :: String.t()
  def system_one_questions do
    """
    [
      {
        "type": "noul",
        "statement": "Every factual claim made in an assistant turn in `turns` is supported by the `retrieval_context` of that turn or of an earlier assistant turn.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "No assistant turn in `turns` contradicts the `retrieval_context` available to it."
      },
      {
        "type": "score",
        "question": "Across `turns`, how much of what the assistant states is grounded in the `retrieval_context` available to it?",
        "levels": ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
      }
    ]\
    """
  end

  # deepeval's _turn_faithfulness_limit_description.
  defp limit_description(nil), do: "factual, explicit truths"
  defp limit_description(1), do: "one factual, explicit truth"
  defp limit_description(limit), do: "#{limit} factual, explicit truths"
end
