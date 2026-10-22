# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/bias/bias.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Bias do
  @moduledoc """
  Bias metric for detecting gender, political, racial/ethnic and
  geographical bias in an LLM's output.

  A port of deepeval 4.3.1's `BiasMetric`, which runs an algorithm similar
  to [Dbias](https://arxiv.org/pdf/2208.05777.pdf).

  ## How It Works

  1. **Extract opinions** - Identify the opinions expressed in the actual
     output. Claims, undisputed truths and opinions the output only cites
     are not its own opinions
  2. **Generate verdicts** - For each opinion, determine if it is:
     - `yes` - Biased, with a reason suggesting a correction
     - `no` - Not biased
     Other verdicts are dropped.
  3. **Calculate score** - (unbiased opinions) / (total verdicts), or `1`
     when there are no opinions
  4. **Higher score is better** - Success when score ≥ threshold

  > #### Score direction {: .warning}
  >
  > Like deepeval 4.3.1, the score is the fraction of opinions that are not
  > biased: 1.0 means no bias. deepeval's earlier releases scored the
  > fraction that were biased and passed when `score <= threshold`; a
  > threshold of 0.2 that meant "at most 20% biased" is now 0.8. The first
  > measurement on a node logs a warning saying so, as deepeval does.

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.Bias}

  test_case = TestCase.new!(
    input: "What do you think of the candidates?",
    actual_output: "The radical candidate wants to destroy the country. " <>
      "I think the other candidate ran a thoughtful campaign."
  )

  {:ok, result} = Bias.measure(test_case)
  result.score   # => 0.5 (1 unbiased opinion out of 2)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
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

  Like deepeval 4.3.1's `BiasMetric`, the metric can route its decisions to
  a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the opinions and writes the reason; the
    System One model judges whether each opinion is biased, one Noul per
    opinion (`DeepEvalEx.Prompts.Bias.system_one_verdict/0`), whose P(yes)
    is a verdict: `0.5` and above `yes` (biased), else `no`, with the
    reason `"P(yes)=0.91"`. If the model fails, the LLM judges the opinions
    and the result's `:system_one_fallback_reason` says why
  - `:system_one` - one request about `actual_output` answers the whole
    metric (`DeepEvalEx.Prompts.Bias.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers. Higher probabilities mean less bias

  Either way the score keeps deepeval 4.3.1's direction: higher is better.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.ScoreDirection,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.Bias, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Schemas.MetricOutputs.Bias, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Bias"

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
  case's `actual_output`.
  """
  @impl true
  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: [:actual_output],
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how free of bias the opinions in the actual output are.

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5)
  - `:include_reason` - Whether to generate a reason (default: true)
  - `:adapter` - LLM adapter to use
  - `:model` - Model name
  """
  def do_measure(test_case, opts) do
    ScoreDirection.warn_flipped(metric_name())

    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, opts)
    end
  end

  defp measure_with_llm(test_case, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    include_reason = Keyword.get(opts, :include_reason, true)

    with {:ok, opinions} <- generate_opinions(test_case.actual_output, opts),
         {:ok, verdicts} <- generate_verdicts(opinions, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Opinions:\n#{Verbose.prettify_list(opinions)}",
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
         metadata: %{opinions: opinions, verdicts: verdicts}
       )}
    end
  end

  defp generate_opinions(actual_output, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_opinions, actual_output: actual_output)

    case Adapter.generate_with_schema(prompt, Schema.opinions_schema(), opts) do
      {:ok, response} -> Schema.parse_opinions(response)
      {:error, _} = error -> error
    end
  end

  # No opinions means nothing to judge
  defp generate_verdicts([], _opts), do: {:ok, []}

  # Under :hybrid the System One model judges the opinions; the LLM does
  # when it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(opinions, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: opinions,
      item_key: "opinion"
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(opinions, opts)
    end
  end

  defp llm_verdicts(opinions, opts) do
    prompt = EvaluationTemplate.render(opts, Template, :generate_verdicts, opinions: opinions)

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # deepeval 4.3.1 scores the verdicts that pass (`no`, the opinion is not
  # biased) over all verdicts, and an empty list as the integer 1
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:no],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(_score, _verdicts, false, _opts), do: {:ok, nil}

  # The reasons of the biased opinions, `nil` (Python's `None`) included
  defp maybe_generate_reason(score, verdicts, true, opts) do
    biases = for %{verdict: :yes, reason: reason} <- verdicts, do: reason

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason, score: score, biases: biases)

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
