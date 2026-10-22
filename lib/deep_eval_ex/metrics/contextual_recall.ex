# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/contextual_recall/contextual_recall.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ContextualRecall do
  @moduledoc """
  Contextual Recall metric for RAG retrieval coverage evaluation.

  Measures whether sentences in the expected output can be attributed
  to the retrieval context. This evaluates if the retrieved context
  contains all the information needed to produce the expected output.

  ## How It Works

  1. **Generate verdicts** - For each sentence in expected output, determine if it's:
     - `yes` - Can be attributed to nodes in retrieval context
     - `no` - Cannot be attributed to any context
     Other verdicts are dropped.
  2. **Calculate score** - (attributed sentences) / (total verdicts), or `0`
     when there are none
  3. **Higher score is better** - Success when score ≥ threshold

  ## Precision vs Recall

  - **ContextualPrecision**: Are retrieved nodes useful? (ranking quality)
  - **ContextualRecall**: Is expected output covered by context? (coverage)

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ContextualRecall}

  test_case = TestCase.new!(
    input: "What is the capital of France?",
    expected_output: "Paris is the capital of France. It is known for the Eiffel Tower.",
    retrieval_context: [
      "Paris is the capital city of France.",
      "The Eiffel Tower is located in Paris."
    ]
  )

  {:ok, result} = ContextualRecall.measure(test_case)
  result.score   # => 1.0 (all sentences attributable)
  result.success # => true (score >= threshold)
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `ContextualRecallMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the expected output is split into sentences
    (`DeepEvalEx.SystemOne.Decision.split_sentences/1`) and the System One
    model judges each against `retrieval_context`, one Noul per sentence
    (`DeepEvalEx.Prompts.ContextualRecall.system_one_verdict/0`), whose
    P(yes) is a verdict: `0.5` and above `yes`, else `no`, with the reason
    `"P(yes)=0.91"`. The LLM still writes the reason. If the model fails,
    the LLM judges the sentences and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about `expected_output` and
    `retrieval_context` answers the whole metric
    (`DeepEvalEx.Prompts.ContextualRecall.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.ContextualRecall, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualRecall, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Contextual Recall"

  @impl true
  def required_params, do: [:input, :retrieval_context, :expected_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the test
  case's `expected_output` and `retrieval_context`.
  """
  @impl true
  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: [:expected_output, :retrieval_context],
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures contextual recall of the expected output against retrieval context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
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

  defp measure_with_llm(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    expected_output = test_case.expected_output
    retrieval_context = test_case.retrieval_context

    with {:ok, verdicts} <- generate_verdicts(expected_output, retrieval_context, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(score, expected_output, verdicts, include_reason, opts) do
      # deepeval's verdicts carry the expected output they were judged
      # against (VerdictWithExpectedOutput).
      verdict_models = Verbose.verdict_models(verdicts, expected_output: expected_output)

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Verdicts:\n#{Verbose.prettify_list(verdict_models)}",
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
         metadata: %{
           verdicts: verdicts,
           sentence_count: length(verdicts),
           context_count: length(retrieval_context)
         }
       )}
    end
  end

  defp generate_verdicts(_expected_output, [], _opts) do
    {:ok, []}
  end

  # Under :hybrid the System One model judges each sentence of the expected
  # output; the LLM does when it is not asked or fails (deepeval's
  # generate_qag_verdicts).
  defp generate_verdicts(expected_output, retrieval_context, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: Decision.split_sentences(expected_output),
      item_key: "sentence",
      state: [retrieval_context: retrieval_context]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(expected_output, retrieval_context, opts)
    end
  end

  defp llm_verdicts(expected_output, retrieval_context, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        expected_output: expected_output,
        retrieval_context: retrieval_context
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # As in deepeval 4.3.1, no verdicts scores the integer 0
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      empty_score: 0,
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _expected_output, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, expected_output, verdicts, true, opts) do
    {supportive, unsupportive} =
      Enum.split_with(verdicts, fn %{verdict: v} -> v == :yes end)

    supportive_reasons =
      supportive
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    unsupportive_reasons =
      unsupportive
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        expected_output: expected_output,
        supportive_reasons: supportive_reasons,
        unsupportive_reasons: unsupportive_reasons
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
