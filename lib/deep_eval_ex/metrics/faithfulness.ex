# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/faithfulness/faithfulness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Faithfulness do
  @moduledoc """
  Faithfulness metric for RAG evaluation.

  Measures whether the claims in an LLM's output are supported by
  the retrieval context. Essential for evaluating RAG pipelines
  to ensure responses are grounded in retrieved information.

  ## How It Works

  1. **Extract claims** - Identify factual claims from the actual output
  2. **Extract truths** - Identify facts from the retrieval context
  3. **Generate verdicts** - For each claim, determine if it's:
     - `yes` - Supported by the context
     - `no` - Contradicts the context
     - `borderline` - Cannot be verified (not mentioned); a judge's legacy
       `idk` reads as `borderline`, and other verdicts are dropped
  4. **Calculate score** - (supported + borderline claims) / total verdicts,
     or `1` when there are none. With `penalize_ambiguous_claims: true`,
     borderline claims count against the score: supported claims / total
     verdicts

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.Faithfulness}

  test_case = TestCase.new!(
    input: "What is the company's vacation policy?",
    actual_output: "Employees get 20 days of PTO per year.",
    retrieval_context: [
      "Section 3.2: Full-time employees receive 20 days paid time off annually.",
      "Section 3.3: PTO can be carried over up to 5 days."
    ]
  )

  {:ok, result} = Faithfulness.measure(test_case)
  result.score   # => 1.0 (claim is supported)
  result.reason  # => "All claims are supported by the context..."
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:truths_extraction_limit` - Max truths to extract per doc (default: nil = all)
  - `:penalize_ambiguous_claims` - Count borderline (unverifiable) claims as
    unfaithful, and list them as `(Ambiguous)` contradictions in the reason
    (default: false)
  - `:model` - LLM model for evaluation
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `FaithfulnessMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the truths and claims and writes the
    reason; the System One model judges each claim against the truths, one
    Noul per claim (`DeepEvalEx.Prompts.Faithfulness.system_one_verdict/0`), whose
    P(yes) is a verdict: above `0.65` `yes`, below `0.35` `no`, else
    `borderline`, with the reason `"P(yes)=0.91"`. If the model fails, the
    LLM judges the claims and the result's `:system_one_fallback_reason`
    says why
  - `:system_one` - one request about `actual_output` and
    `retrieval_context` answers the whole metric
    (`DeepEvalEx.Prompts.Faithfulness.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, LLM.Usage, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.Faithfulness, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Faithfulness, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Faithfulness"

  @impl true
  def required_params, do: [:input, :actual_output, :retrieval_context]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the test
  case's `actual_output` and `retrieval_context`.
  """
  @impl true
  def system_one_eval_spec(_test_case, _opts) do
    %EvalSpec{
      evaluation_params: [:actual_output, :retrieval_context],
      questions: Scored.parse!(Template.system_one_questions())
    }
  end

  @doc """
  Measures faithfulness of the actual output against retrieval context.

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:truths_extraction_limit` - Max truths to extract (default: nil)
  - `:penalize_ambiguous_claims` - Count borderline claims as unfaithful
    (default: false)
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
    truths_limit = Keyword.get(opts, :truths_extraction_limit)

    retrieval_context = test_case.retrieval_context
    actual_output = test_case.actual_output

    # Run truths and claims extraction concurrently; Usage.async/1 carries
    # the tasks' token usage back into this metric's usage scope.
    truths_task =
      Usage.async(fn ->
        generate_truths(retrieval_context, truths_limit, opts)
      end)

    claims_task =
      Usage.async(fn ->
        generate_claims(actual_output, opts)
      end)

    with {:ok, truths} <- Usage.await(truths_task, 60_000),
         {:ok, claims} <- Usage.await(claims_task, 60_000),
         {:ok, verdicts} <- generate_verdicts(claims, truths, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Truths (limit=#{Verbose.to_str(truths_limit)}):\n#{Verbose.prettify_list(truths)}",
            "Claims:\n#{Verbose.prettify_list(claims)}",
            "Verdicts:\n#{verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()}",
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
           truths: truths,
           claims: claims,
           verdicts: verdicts,
           truths_extraction_limit: truths_limit
         }
       )}
    end
  end

  defp generate_truths(retrieval_context, limit, opts) do
    context_text = Enum.join(retrieval_context, "\n\n")

    prompt =
      Template.generate_truths(
        retrieval_context: context_text,
        extraction_limit: limit
      )

    case Adapter.generate_with_schema(prompt, Schema.truths_schema(), opts) do
      {:ok, response} -> Schema.parse_truths(response)
      {:error, _} = error -> error
    end
  end

  defp generate_claims(actual_output, opts) do
    prompt = Template.generate_claims(actual_output: actual_output)

    case Adapter.generate_with_schema(prompt, Schema.claims_schema(), opts) do
      {:ok, response} -> Schema.parse_claims(response)
      {:error, _} = error -> error
    end
  end

  defp generate_verdicts([], _truths, _opts) do
    # No claims means perfectly faithful
    {:ok, []}
  end

  # Under :hybrid the System One model judges the claims; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(claims, truths, opts) do
    spec = %Spec.Verdicts{
      instructions: Template.system_one_verdict(),
      items: claims,
      item_key: "claim",
      state: [retrieval_context: truths]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no_borderline(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(claims, truths, opts)
    end
  end

  defp llm_verdicts(claims, truths, opts) do
    truths_text = Enum.join(truths, "\n\n")

    prompt =
      Template.generate_verdicts(
        claims: claims,
        retrieval_context: truths_text
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # Borderline claims count as faithful unless `penalize_ambiguous_claims`
  # is set, as in deepeval 4.3.1's `_calculate_score`
  defp calculate_score(verdicts, threshold, opts) do
    passing = if penalize_ambiguous_claims?(opts), do: [:yes], else: [:yes, :borderline]

    QAG.score_qag_verdicts(verdicts,
      passing: passing,
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, verdicts, true, opts) do
    penalize_ambiguous_claims = penalize_ambiguous_claims?(opts)

    # In verdict order; a penalized borderline claim is an ambiguous
    # contradiction, its reason formatted as deepeval's f-string does
    # (`None` when the judge gave none).
    contradictions =
      Enum.flat_map(verdicts, fn
        %{verdict: :no, reason: reason} when not is_nil(reason) ->
          [reason]

        %{verdict: :borderline, reason: reason} when penalize_ambiguous_claims ->
          ["(Ambiguous) " <> Verbose.to_str(reason)]

        _verdict ->
          []
      end)

    prompt =
      Template.generate_reason(
        score: score,
        contradictions: contradictions
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  defp penalize_ambiguous_claims?(opts), do: Keyword.get(opts, :penalize_ambiguous_claims, false)
end
