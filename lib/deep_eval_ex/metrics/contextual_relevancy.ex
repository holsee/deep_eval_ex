# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/contextual_relevancy/contextual_relevancy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ContextualRelevancy do
  @moduledoc """
  Contextual Relevancy metric for RAG retrieval relevance evaluation.

  Measures how much of the retrieval context is relevant to the input:
  each node's statements are judged relevant or not, so a retriever that
  pads its context with off-topic text scores lower.

  ## How It Works

  1. **Generate verdicts** - For each node of the retrieval context, in its
     own prompt, extract the statements it makes and judge each:
     - `yes` - Relevant to the input
     - `no` - Irrelevant, with a reason quoting it
     Other verdicts are dropped.
  2. **Calculate score** - (relevant statements) / (total statements over
     every node), or `0` when there are none
  3. **Higher score is better** - Success when score ≥ threshold

  ## Precision, Recall and Relevancy

  - **ContextualPrecision**: Are relevant nodes ranked first? (ranking)
  - **ContextualRecall**: Is expected output covered by context? (coverage)
  - **ContextualRelevancy**: How much of the context is relevant? (noise)

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ContextualRelevancy}

  test_case = TestCase.new!(
    input: "What is the capital of France?",
    actual_output: "Paris.",
    retrieval_context: [
      "Paris is the capital of France. There was a cat.",
      "Rome is the capital of Italy."
    ]
  )

  {:ok, result} = ContextualRelevancy.measure(test_case)
  result.score   # => 0.3333333333333333 (one of three statements relevant)
  result.success # => false (score < threshold)
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

  Like deepeval 4.3.1's `ContextualRelevancyMetric`, the metric can route
  its decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - each node is split into sentences
    (`DeepEvalEx.SystemOne.Decision.split_sentences/1`) and the System One
    model judges them against `input`, one request per node and one Noul
    per sentence (`DeepEvalEx.Prompts.ContextualRelevancy.system_one_verdict/0`),
    whose P(yes) is a verdict: `0.5` and above `yes`, with the reason
    `"P(yes)=0.91"`, else `no`, with the reason
    `"'<sentence>' is not relevant to the input (P(yes)=0.12)."`. The LLM
    still writes the reason. If the model fails for a node, the LLM judges
    that node and the result's `:system_one_fallback_reason` says why
  - `:system_one` - one request about `input` and `retrieval_context`
    answers the whole metric
    (`DeepEvalEx.Prompts.ContextualRelevancy.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.ContextualRelevancy, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualRelevancy, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Contextual Relevancy"

  @impl true
  def required_params, do: [:input, :retrieval_context]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the test
  case's `input` and `retrieval_context` (the metric's required params).

  A multimodal test case has none (`nil`), as in deepeval: System One
  reads text only.
  """
  @impl true
  def system_one_eval_spec(%{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how relevant the retrieval context is to the input.

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
    # deepeval passes the test case's multimodal flag to its templates.
    opts = Keyword.put(opts, :multimodal, Map.get(test_case, :multimodal, false))
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    input = test_case.input
    retrieval_context = test_case.retrieval_context

    with {:ok, verdicts_list} <- generate_verdicts_list(input, retrieval_context, opts),
         score = calculate_score(verdicts_list, threshold, opts),
         {:ok, reason} <-
           maybe_generate_reason(score, input, verdicts_list, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Verdicts:\n#{verdicts_list |> Enum.map(&verdicts_model/1) |> Verbose.prettify_list()}",
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
           verdicts: verdicts_list,
           context_count: length(retrieval_context)
         }
       )}
    end
  end

  # One list of verdicts per node, in order. deepeval gathers the nodes
  # concurrently; they are judged one after the other here so a scripted
  # judge answers them in the same order. A RetrievedContextData node is
  # judged as its "source: context" text (deepeval 4.3.1 raises on it).
  defp generate_verdicts_list(input, retrieval_context, opts) do
    retrieval_context
    |> Enum.map(&to_string/1)
    |> Enum.reduce_while({:ok, []}, fn context, {:ok, acc} ->
      case generate_verdicts(input, context, opts) do
        {:ok, verdicts} -> {:cont, {:ok, [verdicts | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verdicts_list} -> {:ok, Enum.reverse(verdicts_list)}
      error -> error
    end
  end

  # Under :hybrid the System One model judges each sentence of the node; the
  # LLM does when it is not asked or fails (deepeval's generate_qag_verdicts).
  # A multimodal test case has no System One spec.
  defp generate_verdicts(input, context, opts) do
    spec =
      unless opts[:multimodal] do
        %Spec.Verdicts{
          instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
          items: Decision.split_sentences(context),
          item_key: "statement",
          state: [input: input],
          build_verdict: &system_one_verdict/3
        }
      end

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(input, context, opts)
    end
  end

  # deepeval's _system_one_relevancy_verdict.
  defp system_one_verdict(statement, verdict, probability) do
    p_yes = "P(yes)=#{Python.format_fixed(probability, 2)}"

    reason =
      case verdict do
        :no -> "'#{statement}' is not relevant to the input (#{p_yes})."
        _ -> p_yes
      end

    %{statement: statement, verdict: verdict, reason: reason}
  end

  defp llm_verdicts(input, context, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        input: input,
        context: context,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # As in deepeval 4.3.1, the verdicts of every node are scored together,
  # and no verdicts scores the integer 0
  defp calculate_score(verdicts_list, threshold, opts) do
    QAG.score_qag_verdicts(List.flatten(verdicts_list),
      passing: [:yes],
      empty_score: 0,
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _input, _verdicts_list, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, input, verdicts_list, true, opts) do
    # An irrelevant statement is listed by its reason (nil included, as
    # deepeval's None), a relevant one by itself.
    {irrelevant, relevant} =
      verdicts_list |> List.flatten() |> Enum.split_with(&(&1.verdict == :no))

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        input: input,
        irrelevant_statements: Enum.map(irrelevant, & &1.reason),
        relevant_statements: Enum.map(relevant, & &1.statement)
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's ContextualRelevancyVerdicts, as prettify_list dumps it.
  defp verdicts_model(verdicts) do
    OrderedObject.new(
      verdicts:
        Enum.map(
          verdicts,
          &OrderedObject.new(statement: &1.statement, verdict: &1.verdict, reason: &1.reason)
        )
    )
  end
end
