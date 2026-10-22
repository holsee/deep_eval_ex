# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/turn_faithfulness/turn_faithfulness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.TurnFaithfulness do
  @moduledoc """
  TurnFaithfulness, deepeval 4.3.1's `TurnFaithfulnessMetric`: whether the
  assistant's claims throughout a `DeepEvalEx.ConversationalTestCase` are
  supported by the retrieval context of its turns.

  ## How It Works

  1. **Slide a window** - for each unit interaction, a window of at most
     `:window_size` unit interactions ending with it
     (`DeepEvalEx.Metrics.Utils.TurnWindows`)
  2. **Judge each window as Faithfulness does** - the judge extracts the
     truths of the retrieval context of the window's assistant turns and
     the claims of its assistant turns, then decides for each claim:
     - `yes` - Supported by the truths
     - `no` - Contradicts the truths
     - `borderline` - Neither (a judge's legacy `idk` reads as
       `borderline`, and other verdicts are dropped)

     The window scores (supported + borderline claims) / verdicts, or
     `1.0` without a claim. With `penalize_ambiguous_claims: true`,
     borderline claims count against it. The judge explains each window's
     score from its contradictions
  3. **Calculate score** - the mean of the windows' scores, or `1` without
     a window
  4. **Higher score is better** - Success when score ≥ threshold; the judge
     explains the score from every window's reason

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnFaithfulness}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "When did order 42 ship?"},
        %{
          role: :assistant,
          content: "On 1 October.",
          retrieval_context: ["Order 42 shipped on 1 October."]
        }
      ]
    )

  {:ok, result} = TurnFaithfulness.measure(test_case)
  result.score   # => 1.0 (the one claim is supported)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and a window's score below
    it to `0` (default: false)
  - `:window_size` - The most unit interactions in each sliding window
    (default: 10)
  - `:truths_extraction_limit` - The most truths to extract per window
    (default: nil, every truth; a negative limit reads as `0`)
  - `:penalize_ambiguous_claims` - Count borderline claims as unfaithful
    (default: false)
  - `:include_reason` - Generate explanations (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.TurnFaithfulness` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  As in deepeval, a window's retrieval context is joined with blank lines;
  a `DeepEvalEx.Schemas.RetrievedContextData` joins as its
  `"source: context"` text, where deepeval 4.3.1 raises.

  ## System One

  Like deepeval 4.3.1's `TurnFaithfulnessMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts each window's truths and claims and writes
    the reasons; the System One model judges each window's claims, one
    Noul per claim (`claim_<i>`) about the window's truths as
    `reference_context` (`DeepEvalEx.Prompts.TurnFaithfulness.system_one_verdict/0`),
    whose P(yes) is a verdict: above `0.65` `yes`, below `0.35` `no`, else
    `borderline`, with the reason `"P(yes)=0.91"`. If the model fails, the
    LLM judges that window's claims and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about the whole conversation, each turn's
    `role`, `content` and `retrieval_context`, answers the whole metric
    (`DeepEvalEx.Prompts.TurnFaithfulness.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  As in deepeval, a multimodal test case has no `:system_one` form.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG}
  alias DeepEvalEx.Metrics.Utils.{TurnWindows, Verbose}
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.TurnFaithfulness, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.Faithfulness, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Turn Faithfulness"

  @impl true
  def required_params, do: [:role, :content, :retrieval_context]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  conversation's turns, each with its `role`, `content` and
  `retrieval_context`. `nil` for a multimodal test case.
  """
  @impl true
  def system_one_eval_spec(%ConversationalTestCase{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how faithful the assistant's turns are to their retrieval
  context.

  ## Options

  See the moduledoc, plus:

  - `:adapter` - LLM adapter to use
  """
  def do_measure(test_case, opts) do
    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, opts)
    end
  end

  defp measure_with_llm(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    window_opts = Keyword.merge(opts, multimodal: test_case.multimodal, threshold: threshold)

    TurnWindows.measure(
      [
        metric_name: metric_name(),
        threshold: threshold,
        template: Template,
        schema: Schema,
        score_window: &score_window(&1, window_opts)
      ],
      test_case,
      opts
    )
  end

  # deepeval's _get_faithfulness_scores: one window, judged as Faithfulness
  # judges a test case.
  defp score_window(contents, opts) do
    with {:ok, truths} <- generate_truths(contents.retrieval_context, opts),
         {:ok, claims} <- generate_claims(contents, opts),
         {:ok, verdicts} <- generate_verdicts(claims, truths, opts),
         {:ok, score, reason} <- score_and_reason(verdicts, opts) do
      {:ok,
       %{
         score: score,
         reason: reason,
         truths: truths,
         claims: claims,
         verdicts: verdicts,
         steps: [
           "Truths: #{Verbose.prettify_list(truths)} \n",
           "Claims: #{Verbose.prettify_list(claims)} \n",
           "Verdicts: #{verdicts |> Enum.map(&verdict_model/1) |> Verbose.prettify_list()} \n",
           "Score: #{Verbose.to_str(score / 1)} \n",
           "Reason: #{Verbose.to_str(reason)} \n"
         ]
       }}
    end
  end

  defp generate_truths(retrieval_context, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_truths,
        reference_context: Enum.join(retrieval_context, "\n\n"),
        extraction_limit: extraction_limit(opts),
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.truths_schema(), opts) do
      {:ok, response} -> Schema.parse_truths(response)
      {:error, _} = error -> error
    end
  end

  defp generate_claims(contents, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_claims,
        input: contents.input,
        assistant_output: contents.assistant_output,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.claims_schema(), opts) do
      {:ok, response} -> Schema.parse_claims(response)
      {:error, _} = error -> error
    end
  end

  defp generate_verdicts([], _truths, _opts), do: {:ok, []}

  # Under :hybrid the System One model judges the claims; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(claims, truths, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: claims,
      item_key: "claim",
      state: [reference_context: truths]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no_borderline(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(claims, truths, opts)
    end
  end

  defp llm_verdicts(claims, truths, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        claims: claims,
        reference_context: Enum.join(truths, "\n\n"),
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's _get_interaction_score_and_reason: no claim is faithful.
  defp score_and_reason([], opts) do
    {:ok, 1.0, if(Keyword.get(opts, :include_reason, true), do: "<no claims to verify>")}
  end

  defp score_and_reason(verdicts, opts) do
    passing =
      if Keyword.get(opts, :penalize_ambiguous_claims, false),
        do: [:yes],
        else: [:yes, :borderline]

    score =
      QAG.score_qag_verdicts(verdicts,
        passing: passing,
        strict_mode: Keyword.get(opts, :strict_mode, false),
        threshold: Keyword.fetch!(opts, :threshold)
      )

    with {:ok, reason} <- maybe_generate_reason(score, verdicts, opts), do: {:ok, score, reason}
  end

  defp maybe_generate_reason(score, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(score, verdicts, opts),
      else: {:ok, nil}
  end

  # The reasons of the `no` verdicts, nil included; unlike Faithfulness,
  # penalized borderline claims are not listed.
  defp generate_reason(score, verdicts, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        contradictions: for(%{verdict: :no, reason: reason} <- verdicts, do: reason),
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval keeps a truths_extraction_limit of at least 0.
  defp extraction_limit(opts) do
    case Keyword.get(opts, :truths_extraction_limit) do
      nil -> nil
      limit -> max(limit, 0)
    end
  end

  # deepeval's FaithfulnessVerdict, reason first.
  defp verdict_model(verdict),
    do: OrderedObject.new(reason: verdict.reason, verdict: verdict.verdict)
end
