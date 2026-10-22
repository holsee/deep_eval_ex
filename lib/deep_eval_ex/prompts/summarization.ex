# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/summarization/templates/*.txt and the shared
# deepeval/templates/metrics/fragments), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the trailing whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/prompt_golden_test.exs checks every byte.

defmodule DeepEvalEx.Prompts.Summarization do
  @moduledoc """
  Prompt templates for the Summarization metric.

  Summarization measures how well a summary (the actual output) aligns
  with and covers its original text (the input).

  Each function renders deepeval 4.3.1's `SummarizationMetric` template of
  the same name byte for byte, as deepeval renders it for a text-only test
  case. Its `generate_questions`, `generate_answers`,
  `generate_alignment_verdicts` and `generate_reason` templates include the
  multimodal input rules fragment unconditionally, so these prompts carry
  it too. `generate_reason/1` also appends what the metric adds to its
  template: the questions the summary cannot answer, when there are any,
  and `JSON:`. Lists are printed as Python lists and scores as
  `format(score, ".2f")` (see `DeepEvalEx.Prompts.Python`).

  The metric extracts the truths of the original text and the claims of
  the summary with `DeepEvalEx.Prompts.Faithfulness.generate_truths/1` and
  `generate_claims/1`, as deepeval borrows the Faithfulness templates.

  `system_one_verdict/0` and `system_one_questions/1` are its System One
  templates, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions`; the questions end with one Noul per
  assessment question.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  Generates a prompt asking for `n` closed-ended questions the original
  text answers with "yes", the assessment questions of the coverage score.

  ## Options

  - `:text` - the original text (required)
  - `:n` - how many questions to generate (required)
  """
  def generate_questions(opts) do
    text = Keyword.fetch!(opts, :text)
    n = Keyword.fetch!(opts, :n)

    """
    Based on the given text, generate #{n} closed-ended questions that can be answered with either a 'yes' or 'no'. 
    The questions generated should ALWAYS result in a 'yes' based on the given text. 


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ** IMPORTANT
    Only return a JSON with a 'questions' key, which is a list of strings. 
    The questions have to be STRICTLY closed ended.
    The given text should be able to answer 'yes' for each question.
    **
    Text:
    #{text}

    JSON:\
    """
  end

  @doc """
  Generates a prompt asking whether a text holds enough information to
  answer each assessment question: one `"yes"` or `"no"` per question.

  ## Options

  - `:questions` - the assessment questions, a list of strings (required)
  - `:text` - the original text or the summary (required)
  """
  def generate_answers(opts) do
    questions = opts |> Keyword.fetch!(:questions) |> Python.repr()
    text = Keyword.fetch!(opts, :text)

    """
    Based on the list of close-ended 'yes' or 'no' questions, generate a JSON with key 'answers', which is a list of strings that determines whether the provided text contains sufficient information to answer EACH question.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    Answers should STRICTLY be either 'yes' or 'no'.
    Answer 'no' if the provided text does not contain enough information to answer the question.
    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'answers' key as a list of strings.

    Example:
    Example Text: Mario and Luigi were best buds but since Luigi had a crush on Peach Mario ended up killing him.
    Example Questions: ["Are there enough information about Luigi and Mario?"]
    Example Answers:
    {
      "answers": ["yes"]
    }

    The length of 'answers' SHOULD BE STRICTLY EQUAL to that of questions.
    ===== END OF EXAMPLE ======

    Text:
    #{text}

    Questions:
    #{questions}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to judge whether each claim of the summary agrees
  with the original text.

  For each claim, the verdict is:
  - "yes" - It agrees with the original text
  - "no" - It contradicts the original text, with a reason
  - "borderline" - The original text does not back it up, with a reason

  ## Options

  - `:summary_claims` - the claims of the summary, a list of strings
    (required)
  - `:original_text` - the truths of the original text, joined with blank
    lines (required)
  """
  def generate_alignment_verdicts(opts) do
    summary_claims = opts |> Keyword.fetch!(:summary_claims) |> Python.repr()
    original_text = Keyword.fetch!(opts, :original_text)

    """
    Based on the given summary claims, which is a list of strings, generate a list of JSON objects to indicate whether EACH piece of info contradicts any facts in the original text. The JSON will have 2 fields: 'verdict' and 'reason'.


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    The 'verdict' key should STRICTLY be either 'yes', 'no', or 'borderline', which states whether the given summary claim agrees with the original text. 
    Provide a 'reason' ONLY if the answer is 'no' OR 'borderline'. 
    The provided summary claims is drawn from the summary. Try to provide a correction in the reason using the facts in the original text.

    **
    IMPORTANT: Please make sure to only return in JSON format, with the 'verdicts' key as a list of JSON objects.
    Example Original Text: "Einstein won the Nobel Prize for his discovery of the photoelectric effect. Einstein won the Nobel Prize in 1968. Einstein is a German Scientist."
    Example Summary Claims: ["Barack Obama is a caucasian male.", "Zurich is a city in London", "Einstein won the Nobel Prize for the discovery of the photoelectric effect which may have contributed to his fame.", "Einstein won the Nobel Prize in 1969 for his discovery of the photoelectric effect.", "Einstein was a German chef."]

    Example:
    {
      "verdicts": [
        {
          "verdict": "borderline",
          "reason": "The original text does not mention Barack Obama at all, let alone his racial features.
        },
        {
          "verdict": "borderline",
          "reason": "The original text does not mention Zurich, not does it mention Zurich being in London".
        },
        {
          "verdict": "yes"
        },
        {
          "verdict": "no",
          "reason": "The summary claims Einstein won the Nobel Prize in 1969, which is untrue as the original text states it is 1968 instead."
        },
        {
          "verdict": "no",
          "reason": "The summary claims Einstein is a German chef, which is not correct as the original text states he was a German scientist instead."
        },
      ]  
    }
    ===== END OF EXAMPLE ======

    The length of 'verdicts' SHOULD BE STRICTLY EQUAL to that of summary claims.
    You DON'T have to provide a reason if the answer is 'yes'.
    ONLY provide a 'no' answer if the summary DIRECTLY CONTRADICTS the claims. YOU SHOULD NEVER USE YOUR PRIOR KNOWLEDGE IN YOUR JUDGEMENT.
    Claims made using vague, suggestive, speculative language such as 'may have', 'possibility due to', does NOT count as a contradiction.
    Claims that is not backed up due to a lack of information/is not mentioned in the summary MUST be answered 'borderline'.
    **

    Original Text:
    #{original_text}

    Summary Claims:
    #{summary_claims}

    JSON:\
    """
  end

  @doc """
  Generates a prompt to summarize the evaluation with a reason.

  deepeval's metric appends to its rendered template, which ends with the
  redundancies and no newline, the questions the original text can answer
  but the summary cannot, when there are any, and then `"JSON:\\n"`; so
  does this function.

  ## Options

  - `:score` - the summarization score (required)
  - `:contradictions` - the reasons of the `"no"` alignment verdicts, `nil`
    (Python's `None`) where the judge gave none (required)
  - `:redundancies` - the reasons of the `"borderline"` alignment verdicts,
    likewise (required)
  - `:questions` - the assessment questions the original text answers but
    the summary does not, a list of strings (required)
  """
  def generate_reason(opts) do
    score = opts |> Keyword.fetch!(:score) |> Python.format_fixed(2)
    contradictions = opts |> Keyword.fetch!(:contradictions) |> Python.repr()
    redundancies = opts |> Keyword.fetch!(:redundancies) |> Python.repr()
    questions = Keyword.fetch!(opts, :questions)

    template = """
    You will be given the following: 1) information in the summary contradicting the original text, 2) extra information in the summary not mentioned in the original text, 3) [Optional] questions cannot be answered by the summary. Your task is to explain the quality of this summarization task.
    Given the summarization score, which is a 0-1 score indicating how good the summary is to the original text (higher the better), CONCISELY summarize the provided information to justify the score.  


    --- MULTIMODAL INPUT RULES ---
    - Treat image content as factual evidence.
    - Only reference visual details that are explicitly and clearly visible.
    - Do not infer or guess objects, text, or details not visibly present.
    - If an image is unclear or ambiguous, mark uncertainty explicitly.


    ** 
    IMPORTANT: Please make sure to only return in JSON format, with the 'reason' key providing the reason.
    Example JSON:
    {
      "reason": "The score is <summarization_score> because <your_reason>."
    }

    For 'None' values in contradictions, extra information, or questions that the original text can answer but not the summary, DON'T mention anything and instead offer some praise.
    Be sure in your reason, as if you know what the summary and original text is.
    **

    Summarization Score:
    #{score}

    Contradicting Information in the original text:
    #{contradictions}

    Extra Information not mentioned in the original text:
    #{redundancies}\
    """

    template <> unanswered_questions(questions) <> "JSON:\n"
  end

  defp unanswered_questions([]), do: ""

  defp unanswered_questions(questions) do
    "Questions the original text can answer but not the summary:\n#{Python.repr(questions)}\n\n"
  end

  @doc """
  The question a System One model is asked about each claim of the summary
  under the `:hybrid` eval mode, deepeval's `_experimental_system_one_verdict`
  template: a Noul whose instructions pair it with the claim, about a state
  holding the truths of the original text as `original_text` (see
  `DeepEvalEx.SystemOne.Spec.Verdicts`).
  """
  @spec system_one_verdict() :: String.t()
  def system_one_verdict do
    "Does `summary_claim` agree with the facts in `original_text`? Answer no if it contradicts them."
  end

  @doc """
  The questions a System One model answers about the whole test case under
  the `:system_one` eval mode, deepeval's `_experimental_system_one_questions`
  template: a JSON array of two Nouls and a four-level Score about the
  summary (`actual_output`) and the original text (`input`), then one Noul
  per assessment question, that the summary answers it as the original
  does, which `DeepEvalEx.SystemOne.Scored.parse!/1` reads. Each of those
  statements is written with Jinja's `tojson` (see
  `DeepEvalEx.Prompts.Python.tojson/1`).

  ## Options

  - `:assessment_questions` - the user's assessment questions, a list of
    strings, possibly empty (required)
  """
  @spec system_one_questions(keyword()) :: String.t()
  def system_one_questions(opts) do
    questions = Keyword.fetch!(opts, :assessment_questions)
    separator = if questions == [], do: "", else: ","

    nouls =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join(fn {question, position} ->
        statement =
          Python.tojson(
            "Reading only the summary `actual_output`, this question can be answered " <>
              "the same way as from the original text `input`: " <> question
          )

        comma = if position == length(questions), do: "", else: ","

        """

          {
            "type": "noul",
            "statement": #{statement}
          }#{comma}
        """
      end)

    """
    [
      {
        "type": "noul",
        "statement": "Every claim in the summary `actual_output` agrees with the facts in the original text `input`; none contradicts it or adds information the original does not contain.",
        "weight": 2
      },
      {
        "type": "noul",
        "statement": "The summary `actual_output` covers the main points of the original text `input`."
      },
      {
        "type": "score",
        "question": "How much of the important information in the original text `input` does the summary `actual_output` preserve?",
        "levels": ["Almost none", "Less than half", "Most of it", "All of it"]
      }#{separator}
    """ <> nouls <> "\n]"
  end
end
