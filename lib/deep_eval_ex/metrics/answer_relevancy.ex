# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/answer_relevancy/answer_relevancy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.AnswerRelevancy do
  @moduledoc """
  Answer Relevancy metric for evaluating response quality.

  Measures whether the statements in an LLM's output are relevant
  to addressing the input question. This metric evaluates the
  appropriateness and focus of responses.

  ## How It Works

  1. **Extract statements** - Identify statements from the actual output
  2. **Generate verdicts** - For each statement, determine if it's:
     - `yes` - Relevant to addressing the input
     - `no` - Irrelevant to the input
     - `borderline` - Ambiguous (supporting information); a judge's legacy
       `idk` reads as `borderline`, and other verdicts are dropped
  3. **Calculate score** - (relevant + borderline) / total verdicts, or `1`
     when there are none
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.AnswerRelevancy}

  test_case = TestCase.new!(
    input: "What are the features of the new laptop?",
    actual_output: "The laptop has a Retina display and 12-hour battery life."
  )

  {:ok, result} = AnswerRelevancy.measure(test_case)
  result.score   # => 1.0 (all statements are relevant)
  result.success # => true (score >= threshold)
  ```

  ## Options

  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `AnswerRelevancyMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the statements and writes the reason; the
    System One model judges each statement against the input, one Noul per
    statement (`DeepEvalEx.Prompts.AnswerRelevancy.system_one_verdict/0`),
    whose P(yes) is a verdict: above `0.65` `yes`, below `0.35` `no`, else
    `borderline`, with the reason `"P(yes)=0.91"`. If the model fails, the
    LLM judges the statements and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about `input` and `actual_output` answers
    the whole metric
    (`DeepEvalEx.Prompts.AnswerRelevancy.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.AnswerRelevancy, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.AnswerRelevancy, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Answer Relevancy"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the test
  case's `input` and `actual_output` (the metric's required params).
  """
  @impl true
  def system_one_eval_spec(_test_case, _opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(Template.system_one_questions())
    }
  end

  @doc """
  Measures answer relevancy of the actual output to the input.

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

    input = test_case.input
    actual_output = test_case.actual_output

    with {:ok, statements} <- generate_statements(actual_output, opts),
         {:ok, verdicts} <- generate_verdicts(input, statements, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, input, verdicts, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Statements:\n#{Verbose.prettify_list(statements)}",
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
           statements: statements,
           verdicts: verdicts,
           statement_count: length(statements)
         }
       )}
    end
  end

  defp generate_statements(actual_output, opts) do
    prompt = Template.generate_statements(actual_output: actual_output)

    case Adapter.generate_with_schema(prompt, Schema.statements_schema(), opts) do
      {:ok, response} -> Schema.parse_statements(response)
      {:error, _} = error -> error
    end
  end

  defp generate_verdicts(_input, [], _opts) do
    # No statements means nothing to evaluate
    {:ok, []}
  end

  # Under :hybrid the System One model judges the statements; the LLM does
  # when it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(input, statements, opts) do
    spec = %Spec.Verdicts{
      instructions: Template.system_one_verdict(),
      items: statements,
      item_key: "statement",
      state: [input: input]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no_borderline(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(input, statements, opts)
    end
  end

  defp llm_verdicts(input, statements, opts) do
    prompt =
      Template.generate_verdicts(
        input: input,
        statements: statements
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # Borderline statements count as relevant, as in deepeval 4.3.1
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes, :borderline],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _input, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, input, verdicts, true, opts) do
    # Collect reasons from irrelevant verdicts
    irrelevant_statements =
      verdicts
      |> Enum.filter(fn %{verdict: v} -> v == :no end)
      |> Enum.map(fn %{reason: r} -> r end)
      |> Enum.reject(&is_nil/1)

    prompt =
      Template.generate_reason(
        score: score,
        input: input,
        irrelevant_statements: irrelevant_statements
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
