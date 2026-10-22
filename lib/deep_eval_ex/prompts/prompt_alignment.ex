# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/prompt_alignment/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.PromptAlignment do
  @moduledoc """
  Prompt templates for the PromptAlignment metric.

  PromptAlignment measures how many of the prompt instructions the actual
  output follows.

  Each function renders deepeval 4.3.1's `PromptAlignmentMetric` template of
  the same name byte for byte, as deepeval renders it for a text-only test
  case. Its `generate_verdicts` and `generate_reason` templates include the
  multimodal input rules fragment unconditionally, so these prompts carry it
  too. Lists are printed as Python lists and scores as
  `format(score, ".2f")` (see `DeepEvalEx.Prompts.Python`).
  `system_one_verdict/0` and `system_one_questions/1` are its System One
  templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`; the questions are one Noul per
  prompt instruction.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt to judge whether the actual output follows each prompt
  instruction.

  For each instruction, the verdict is:
  - "yes" - The output follows it completely
  - "no" - It does not, with a reason

  ## Options

  - `:prompt_instructions` - the instructions, a list of strings (required)
  - `:input` - the input the output responds to (required)
  - `:actual_output` - the output to judge (required)
  """
  def generate_verdicts(opts) do
    prompt_instructions = opts |> Keyword.fetch!(:prompt_instructions) |> Python.repr()
    input = Keyword.fetch!(opts, :input)
    actual_output = Keyword.fetch!(opts, :actual_output)

    """
    For the provided list of prompt instructions, determine whether each instruction has been followed in the LLM actual output.
    Please generate a list of JSON with two keys: `verdict` and `reason`.
    The 'verdict' key should STRICTLY be either a 'yes' or 'no'. Only answer 'yes' if the instruction COMPLETELY follows the instruction, and 'no' otherwise.
    You should be EXTRA STRICT AND CAREFUL when giving a 'yes'.
    The 'reason' is the reason for the verdict.
    Provide a 'reason' ONLY if the answer is 'no'. 
    The provided prompt instructions are the instructions to be followed in the prompt, which you have no access to.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key mapping to a list of JSON objects.
    Example input: What number is the stars of the sky?
    Example actual output: HEY THERE! I think what you meant is "What is the number of stars in the sky", but unfortunately I don't know the answer to it.
    Example prompt instructions: ["Answer the input in a well-mannered fashion.", "Do not correct user of any grammatical errors.", "Respond in all upper case"]
    Example JSON:
    {
      "verdicts": [
        {
          "verdict": "yes"
        },
        {
          "reason": "The LLM corrected the user when the user used the wrong grammar in asking about the number of stars in the sky.",
          "verdict": "no"
        },
        {
          "reason": "The LLM only made 'HEY THERE' uppercase, which does not follow the instruction of making everything uppercase completely.",
          "verdict": "no"
        }
      ]  
    }

    Since you are going to generate a verdict for each instruction, the number of 'verdicts' SHOULD BE STRICTLY EQUAL to the number of prompt instructions.
    **          

    Prompt Instructions:
    #{prompt_instructions}

    Input:
    #{input}

    LLM Actual Output:
    #{actual_output}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  ## Options

  - `:unalignment_reasons` - the reasons of the `"no"` verdicts, `nil`
    where the judge gave none (required)
  - `:input` - the input (required)
  - `:actual_output` - the actual output (required)
  - `:score` - the prompt alignment score (required)
  """
  def generate_reason(opts) do
    unalignment_reasons = opts |> Keyword.fetch!(:unalignment_reasons) |> Python.repr()
    input = Keyword.fetch!(opts, :input)
    actual_output = Keyword.fetch!(opts, :actual_output)
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)

    """
    Given the prompt alignment score, the reasons for unalignment found in the LLM actual output, the actual output, and input, provide a CONCISE reason for the score. Explain why it is not higher, but also why it is at its current score.
    The unalignments represent prompt instructions that are not followed by the LLM in the actual output.
    If there no unaligments, just say something positive with an upbeat encouraging tone (but don't overdo it otherwise it gets annoying).
    Don't have to talk about whether the actual output is a good fit for the input, access ENTIRELY based on the unalignment reasons.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <prompt_alignment_score> because <your_reason>."
    }
    **

    Input:
    #{input}

    LLM Actual Output:
    #{actual_output}

    Prompt Alignment Score:
    #{score}

    Reasons for unalignment:
    #{unalignment_reasons}

    JSON:\
    """
  end

  @doc """
  The question a System One model is asked about each prompt instruction
  under the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the instruction (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`). P(yes) is the probability that the
  output follows it.
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict,
    do:
      "Does `actual_output` COMPLETELY follow the prompt `instruction` when responding to `input`?"

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of one Noul per prompt instruction, that
  `actual_output` completely follows it when responding to `input`, which
  `DeepEvalEx.SystemOne.Scored.parse!/1` reads. Each statement is written
  with Jinja's `tojson` (see `DeepEvalEx.Prompts.Python.tojson/1`).

  ## Options

  - `:prompt_instructions` - the instructions, a non-empty list of strings
    (required)
  """
  @spec system_one_questions(keyword()) :: String.t()
  def system_one_questions(opts) do
    nouls =
      opts
      |> Keyword.fetch!(:prompt_instructions)
      |> Enum.map_join(",\n", fn instruction ->
        statement =
          Python.tojson(
            "`actual_output` completely follows this prompt instruction when " <>
              "responding to `input`: " <> instruction
          )

        """

          {
            "type": "noul",
            "statement": #{statement}
          }\
        """
      end)

    "[\n" <> nouls <> "\n\n]"
  end
end
