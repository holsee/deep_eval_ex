# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/summarization/summarization.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Summarization do
  @moduledoc """
  Summarization metric for checking that a summary is faithful to, and
  covers, its original text.

  A port of deepeval 4.3.1's `SummarizationMetric`. The original text is
  the test case's `input` and the summary its `actual_output`.

  ## How It Works

  1. **Extract truths and claims** - The truths of the original text and
     the claims of the summary, with the Faithfulness prompts
  2. **Alignment** - For each claim, determine whether it:
     - `yes` - Agrees with the original text
     - `no` - Contradicts it
     - `borderline` - Is not backed up by it (extra information); a
       judge's legacy `idk` reads as `borderline`, and other verdicts are
       dropped

     The alignment score is (agreeing claims) / (total verdicts), so, unlike
     Faithfulness, borderline claims count against it; the integer `0` when
     the summary has no claims
  3. **Coverage** - The judge writes `n` closed-ended questions the original
     text answers "yes" (unless `:assessment_questions` are given), then
     answers each from the original text and from the summary. The coverage
     score is (questions both answer "yes") / (questions the original
     answers "yes"), the integer `0` when the original answers none
  4. **Calculate score** - the lower of the two (`result.score_breakdown`
     holds both, `"Alignment"` and `"Coverage"`); higher is better

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.Summarization}

  test_case = TestCase.new!(
    input: "The council approved a new park. It opens in May and has a lake.",
    actual_output: "The council approved a park with a lake."
  )

  {:ok, result} = Summarization.measure(test_case)
  result.score            # => 0.5
  result.score_breakdown  # => %{"Alignment" => 1.0, "Coverage" => 0.5}
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:n` - How many assessment questions to generate (default: 5)
  - `:assessment_questions` - Closed-ended questions the original text
    answers "yes", in place of generated ones (default: `nil`; an empty
    list is `nil`, as in deepeval)
  - `:truths_extraction_limit` - Max truths to extract from the original
    text (default: nil = all; a negative limit is `0`)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## As a configured metric

  The assessment questions and limits belong to the metric, as in deepeval's
  `SummarizationMetric(assessment_questions=...)`. To evaluate it with
  other metrics without its options reaching them (Faithfulness also reads
  `:truths_extraction_limit`), build it with `new/1` and pass the struct to
  `DeepEvalEx.evaluate/3`; its fields take precedence over the run's
  options.

  ## System One

  Like deepeval 4.3.1's `SummarizationMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each claim of the summary
    against the truths of the original text, one Noul per claim
    (`DeepEvalEx.Prompts.Summarization.system_one_verdict/0`), whose P(yes)
    is a verdict: above `0.65` `yes`, below `0.35` `no`, else `borderline`,
    with the reason `"P(yes)=0.91"`. The LLM still extracts the truths and
    claims, scores coverage and writes the reason, and judges the claims
    when the model fails; the result's `:system_one_fallback_reason` then
    says why
  - `:system_one` - one request about `input` and `actual_output` answers
    the whole metric (`DeepEvalEx.Prompts.Summarization.system_one_questions/1`,
    two Nouls and a Score, then one Noul per given assessment question; see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    LLM.Usage,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.Faithfulness, as: FaithfulnessTemplate
  alias DeepEvalEx.Prompts.Summarization, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Faithfulness, as: FaithfulnessSchema
  alias DeepEvalEx.Schemas.MetricOutputs.Summarization, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @default_n 5

  defstruct [
    :assessment_questions,
    :n,
    :truths_extraction_limit,
    :threshold,
    :strict_mode,
    :include_reason,
    :model,
    :verbose_mode,
    :flaky,
    :eval_mode,
    :system_one_model
  ]

  @type t :: %__MODULE__{
          assessment_questions: [String.t()] | nil,
          n: pos_integer() | nil,
          truths_extraction_limit: integer() | nil,
          threshold: number() | nil,
          strict_mode: boolean() | nil,
          include_reason: boolean() | nil,
          model: term(),
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil,
          eval_mode: atom() | String.t() | nil,
          system_one_model: term()
        }

  @typedoc """
  A coverage verdict, deepeval's `SummarizationCoverageVerdict`: the
  judge's answers to an assessment question from the summary and from the
  original text, as it gave them.
  """
  @type coverage_verdict :: %{
          summary_verdict: String.t(),
          original_verdict: String.t(),
          question: String.t()
        }

  @doc """
  Creates a Summarization metric for `DeepEvalEx.evaluate/3`. See the
  moduledoc for the options; those left unset (`nil`) fall back to the
  run's options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      assessment_questions: assessment_questions(opts),
      n: Keyword.get(opts, :n),
      truths_extraction_limit: Keyword.get(opts, :truths_extraction_limit),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode),
      include_reason: Keyword.get(opts, :include_reason),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky),
      eval_mode: Keyword.get(opts, :eval_mode),
      system_one_model: Keyword.get(opts, :system_one_model)
    }
  end

  @impl true
  def metric_name, do: "Summarization"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  original text (`input`) and the summary (`actual_output`), the metric's
  required params, with one Noul per given assessment question.
  """
  @impl true
  def system_one_eval_spec(_test_case, opts) do
    questions = assessment_questions(opts) || []

    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(Template.system_one_questions(assessment_questions: questions))
    }
  end

  @doc """
  Measures how well the summary (`actual_output`) aligns with and covers
  the original text (`input`).

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5)
  - `:n` - How many assessment questions to generate (default: 5)
  - `:assessment_questions` - Questions to use instead (default: nil)
  - `:truths_extraction_limit` - Max truths to extract (default: nil)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, opts)
    end
  end

  # deepeval reads an empty list of assessment questions as None.
  defp assessment_questions(opts) do
    case Keyword.get(opts, :assessment_questions) do
      [] -> nil
      questions -> questions
    end
  end

  # deepeval's constructor: max(limit, 0).
  defp truths_extraction_limit(opts) do
    case Keyword.get(opts, :truths_extraction_limit) do
      nil -> nil
      limit -> max(limit, 0)
    end
  end

  # In deepeval's order: the truths and claims (concurrently), the
  # assessment questions, the alignment verdicts, the answers from the
  # original text and from the summary, then the reason.
  defp measure_with_llm(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)
    truths_limit = truths_extraction_limit(opts)

    truths_task = Usage.async(fn -> generate_truths(test_case.input, truths_limit, opts) end)
    claims_task = Usage.async(fn -> generate_claims(test_case.actual_output, opts) end)

    with {:ok, truths} <- Usage.await(truths_task, 60_000),
         {:ok, claims} <- Usage.await(claims_task, 60_000),
         {:ok, questions} <- assessment_questions(test_case, opts),
         {:ok, alignment_verdicts} <- generate_alignment_verdicts(claims, truths, opts),
         {:ok, coverage_verdicts} <- generate_coverage_verdicts(questions, test_case, opts),
         {alignment_score, coverage_score, score} =
           scores(alignment_verdicts, coverage_verdicts, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(
             score,
             alignment_verdicts,
             coverage_verdicts,
             include_reason,
             opts
           ) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Truths (limit=#{Verbose.to_str(truths_limit)}):\n#{Verbose.prettify_list(truths)}",
            "Claims:\n#{Verbose.prettify_list(claims)}",
            "Assessment Questions:\n#{Verbose.prettify_list(questions)}",
            "Coverage Verdicts:\n#{coverage_verdicts |> coverage_models() |> Verbose.prettify_list()}",
            "Alignment Verdicts:\n#{alignment_verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()}",
            "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
          ],
          opts
        )

      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         score_breakdown: %{"Alignment" => alignment_score, "Coverage" => coverage_score},
         metadata: %{
           truths: truths,
           claims: claims,
           assessment_questions: questions,
           coverage_verdicts: coverage_verdicts,
           alignment_verdicts: alignment_verdicts,
           truths_extraction_limit: truths_limit
         }
       )}
    end
  end

  # deepeval borrows the Faithfulness templates, with the original text as
  # the retrieval context, as it is (not joined).
  defp generate_truths(text, limit, opts) do
    prompt =
      FaithfulnessTemplate.generate_truths(retrieval_context: text, extraction_limit: limit)

    case Adapter.generate_with_schema(prompt, FaithfulnessSchema.truths_schema(), opts) do
      {:ok, response} -> FaithfulnessSchema.parse_truths(response)
      {:error, _} = error -> error
    end
  end

  defp generate_claims(text, opts) do
    prompt = FaithfulnessTemplate.generate_claims(actual_output: text)

    case Adapter.generate_with_schema(prompt, FaithfulnessSchema.claims_schema(), opts) do
      {:ok, response} -> FaithfulnessSchema.parse_claims(response)
      {:error, _} = error -> error
    end
  end

  # The given assessment questions, else `n` generated from the original
  # text.
  defp assessment_questions(test_case, opts) do
    case assessment_questions(opts) do
      nil -> generate_questions(test_case.input, opts)
      questions -> {:ok, questions}
    end
  end

  defp generate_questions(text, opts) do
    prompt = Template.generate_questions(text: text, n: Keyword.get(opts, :n, @default_n))

    case Adapter.generate_with_schema(prompt, Schema.questions_schema(), opts) do
      {:ok, response} -> Schema.parse_questions(response)
      {:error, _} = error -> error
    end
  end

  defp generate_answers(questions, text, opts) do
    prompt = Template.generate_answers(questions: questions, text: text)

    case Adapter.generate_with_schema(prompt, Schema.answers_schema(), opts) do
      {:ok, response} -> Schema.parse_answers(response)
      {:error, _} = error -> error
    end
  end

  # The answers from the original text, then from the summary, paired with
  # the questions as deepeval pairs them: by index, failing when the two
  # lists differ in length (ValueError) or outnumber the questions
  # (IndexError).
  defp generate_coverage_verdicts(questions, test_case, opts) do
    with {:ok, original_answers} <- generate_answers(questions, test_case.input, opts),
         {:ok, summary_answers} <- generate_answers(questions, test_case.actual_output, opts) do
      cond do
        length(original_answers) != length(summary_answers) ->
          {:error, %ArgumentError{message: "Number of verdicts generated does not equal."}}

        length(original_answers) > length(questions) ->
          {:error, %ArgumentError{message: "list index out of range"}}

        true ->
          {:ok,
           [original_answers, summary_answers, questions]
           |> Enum.zip()
           |> Enum.map(fn {original, summary, question} ->
             %{summary_verdict: summary, original_verdict: original, question: question}
           end)}
      end
    end
  end

  defp generate_alignment_verdicts([], _truths, _opts), do: {:ok, []}

  # Under :hybrid the System One model judges the claims; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_alignment_verdicts(claims, truths, opts) do
    spec = %Spec.Verdicts{
      instructions: Template.system_one_verdict(),
      items: claims,
      item_key: "summary_claim",
      state: [original_text: truths]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no_borderline(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_alignment_verdicts(claims, truths, opts)
    end
  end

  defp llm_alignment_verdicts(claims, truths, opts) do
    prompt =
      Template.generate_alignment_verdicts(
        summary_claims: claims,
        original_text: Enum.join(truths, "\n\n")
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # The alignment and coverage scores, and the metric's score: the lower.
  defp scores(alignment_verdicts, coverage_verdicts, threshold, opts) do
    strict = [strict_mode: Keyword.get(opts, :strict_mode, false), threshold: threshold]
    alignment_score = alignment_score(alignment_verdicts, strict)
    coverage_score = coverage_score(coverage_verdicts, strict)
    {alignment_score, coverage_score, min_score(alignment_score, coverage_score)}
  end

  # Unlike Faithfulness, borderline (extra information) claims fail; no
  # claims score the integer 0. deepeval clamps strict mode twice, which
  # changes nothing.
  defp alignment_score(verdicts, strict) do
    QAG.score_qag_verdicts(verdicts, [passing: [:yes], empty_score: 0] ++ strict)
  end

  # The questions the summary answers among those the original answers.
  defp coverage_score(verdicts, strict) do
    covered = Enum.filter(verdicts, &yes?(&1.original_verdict))

    case covered do
      [] ->
        0

      covered ->
        score = Enum.count(covered, &yes?(&1.summary_verdict)) / length(covered)
        clamp_strict(score, strict)
    end
  end

  defp clamp_strict(score, strict) do
    if strict[:strict_mode] and score < strict[:threshold], do: 0, else: score
  end

  # Python's min(alignment, coverage): the first unless the second is
  # lower, so an integer and an equal float keep the alignment score's type.
  defp min_score(alignment, coverage) when coverage < alignment, do: coverage
  defp min_score(alignment, _coverage), do: alignment

  # deepeval's `verdict.strip().lower() == "yes"` (and "no").
  defp yes?(answer), do: answer |> String.trim() |> String.downcase() == "yes"
  defp no?(answer), do: answer |> String.trim() |> String.downcase() == "no"

  defp maybe_generate_reason(_score, _alignment, _coverage, false, _opts), do: {:ok, nil}

  # The reasons of the contradicting (`no`) and the extra (`borderline`)
  # claims, `nil` (Python's `None`) included, and the questions the summary
  # cannot answer though the original can.
  defp maybe_generate_reason(score, alignment_verdicts, coverage_verdicts, true, opts) do
    prompt =
      Template.generate_reason(
        score: score,
        contradictions: for(%{verdict: :no, reason: reason} <- alignment_verdicts, do: reason),
        redundancies:
          for(%{verdict: :borderline, reason: reason} <- alignment_verdicts, do: reason),
        questions:
          for(
            verdict <- coverage_verdicts,
            yes?(verdict.original_verdict) and no?(verdict.summary_verdict),
            do: verdict.question
          )
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's SummarizationCoverageVerdict models, in their field order,
  # for the verbose logs.
  defp coverage_models(verdicts) do
    Enum.map(
      verdicts,
      &OrderedObject.new(
        summary_verdict: &1.summary_verdict,
        original_verdict: &1.original_verdict,
        question: &1.question
      )
    )
  end
end
