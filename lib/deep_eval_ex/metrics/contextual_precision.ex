# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/contextual_precision/contextual_precision.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ContextualPrecision do
  @moduledoc """
  Contextual Precision metric for RAG retrieval quality evaluation.

  Measures how well the retrieval system ranks relevant context nodes
  higher than irrelevant ones. Uses weighted cumulative precision
  (similar to Average Precision in information retrieval).

  ## How It Works

  1. **Generate verdicts** - For each retrieval context node, determine if it's:
     - `yes` - Useful in arriving at the expected output
     - `no` - Not useful/irrelevant
     Other verdicts are dropped.
  2. **Calculate score** - Weighted cumulative precision:
     - For each relevant node at position k: precision@k = relevant_so_far / k
     - Score = sum(precision@k for relevant nodes) / total_relevant_nodes
  3. **Higher score is better** - Success when score ≥ threshold

  ## Why Order Matters

  If relevant nodes are ranked first (top positions), the score is higher.
  If irrelevant nodes appear before relevant ones, the score decreases.

  Example:
  - [yes, yes, no] → score = 1.0 (relevant nodes first)
  - [yes, no, yes] → score = 0.83 (irrelevant node in middle)
  - [no, yes, yes] → score = 0.67 (irrelevant node first)

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ContextualPrecision}

  test_case = TestCase.new!(
    input: "Who won the Nobel Prize in 1921?",
    expected_output: "Einstein won the Nobel Prize in 1921.",
    retrieval_context: [
      "Einstein won the Nobel Prize in 1921.",
      "The prize was for the photoelectric effect.",
      "There was a cat."
    ]
  )

  {:ok, result} = ContextualPrecision.measure(test_case)
  result.score   # => 1.0 (relevant nodes ranked first)
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

  Like deepeval 4.3.1's `ContextualPrecisionMetric`, the metric can route
  its decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each retrieval context node
    against `input` and `expected_output`, one Noul per node
    (`DeepEvalEx.Prompts.ContextualPrecision.system_one_verdict/0`), whose
    P(yes) is a verdict: `0.5` and above `yes`, else `no`, with the reason
    `"P(yes)=0.91"`. The LLM still writes the reason. If the model fails,
    the LLM judges the nodes and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about `input`, `retrieval_context` and
    `expected_output` answers the whole metric
    (`DeepEvalEx.Prompts.ContextualPrecision.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG, Result}
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.ContextualPrecision, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualPrecision, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Contextual Precision"

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
  case's `input`, `retrieval_context` (in its order) and `expected_output`
  (the metric's required params).
  """
  @impl true
  def system_one_eval_spec(_test_case, _opts) do
    %EvalSpec{
      evaluation_params: required_params(),
      questions: Scored.parse!(Template.system_one_questions())
    }
  end

  @doc """
  Measures contextual precision of the retrieval context ranking.

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
    expected_output = test_case.expected_output
    retrieval_context = test_case.retrieval_context

    with {:ok, verdicts} <- generate_verdicts(input, expected_output, retrieval_context, opts),
         score =
           BaseMetric.strict_score(calculate_score(verdicts),
             strict_mode: Keyword.get(opts, :strict_mode, false),
             threshold: threshold
           ),
         {:ok, reason} <- maybe_generate_reason(score, input, verdicts, include_reason, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
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
           verdicts: verdicts,
           context_count: length(retrieval_context)
         }
       )}
    end
  end

  defp generate_verdicts(_input, _expected_output, [], _opts) do
    {:ok, []}
  end

  # Under :hybrid the System One model judges the nodes; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(input, expected_output, retrieval_context, opts) do
    spec = %Spec.Verdicts{
      instructions: Template.system_one_verdict(),
      items: retrieval_context,
      item_key: "node",
      state: [input: input, expected_output: expected_output]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(input, expected_output, retrieval_context, opts)
    end
  end

  defp llm_verdicts(input, expected_output, retrieval_context, opts) do
    prompt =
      Template.generate_verdicts(
        input: input,
        expected_output: expected_output,
        retrieval_context: retrieval_context
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  @doc """
  Calculates weighted cumulative precision score.

  The score rewards having relevant nodes ranked higher. For each relevant
  node at position k, we calculate precision@k (relevant_so_far / k) and
  sum these values, then divide by total relevant nodes.

  ## Examples

      # All relevant nodes first: [yes, yes, no]
      # Position 1: precision@1 = 1/1 = 1.0
      # Position 2: precision@2 = 2/2 = 1.0
      # Score = (1.0 + 1.0) / 2 = 1.0

      # Irrelevant node first: [no, yes, yes]
      # Position 2: precision@2 = 1/2 = 0.5
      # Position 3: precision@3 = 2/3 = 0.67
      # Score = (0.5 + 0.67) / 2 = 0.58
  """
  def calculate_score([]), do: 0.0

  def calculate_score(verdicts) do
    # Convert verdicts to binary: yes = 1, no = 0
    relevance_list =
      Enum.map(verdicts, fn %{verdict: v} ->
        if v == :yes, do: 1, else: 0
      end)

    {sum_weighted_precision, relevant_count, _} =
      relevance_list
      |> Enum.with_index(1)
      |> Enum.reduce({0.0, 0, 0}, fn {is_relevant, k}, {sum, rel_count, _} ->
        if is_relevant == 1 do
          new_rel_count = rel_count + 1
          precision_at_k = new_rel_count / k
          {sum + precision_at_k, new_rel_count, k}
        else
          {sum, rel_count, k}
        end
      end)

    if relevant_count == 0 do
      0.0
    else
      sum_weighted_precision / relevant_count
    end
  end

  defp maybe_generate_reason(_score, _input, _verdicts, false, _opts), do: {:ok, nil}

  defp maybe_generate_reason(score, input, verdicts, true, opts) do
    prompt =
      Template.generate_reason(
        score: score,
        input: input,
        verdicts: verdicts
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
