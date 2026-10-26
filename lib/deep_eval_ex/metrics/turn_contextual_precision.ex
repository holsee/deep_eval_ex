# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/turn_contextual_precision/turn_contextual_precision.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.TurnContextualPrecision do
  @moduledoc """
  TurnContextualPrecision, deepeval 4.3.1's `TurnContextualPrecisionMetric`:
  whether the retrieval context of the turns of a
  `DeepEvalEx.ConversationalTestCase` ranks the nodes useful for reaching
  its `expected_outcome` (required) above the others.

  ## How It Works

  1. **Slide a window** - for each unit interaction, a window of at most
     `:window_size` unit interactions ending with it
     (`DeepEvalEx.Metrics.Utils.TurnWindows`)
  2. **Judge each window as ContextualPrecision does** - the judge decides,
     for each node of the retrieval context of the window's assistant
     turns, in order, whether it was useful in arriving at the
     `expected_outcome` for the window's user turns (`yes`) or not (`no`;
     other verdicts are dropped). The window scores the weighted
     cumulative precision of its verdicts
     (`DeepEvalEx.Metrics.ContextualPrecision.calculate_score/1`), and the
     judge explains it. A window without retrieval context scores `1.0`,
     with the reason `"There were no retrieval contexts in the given turns
     to evaluate the contextual precision."`
  3. **Calculate score** - the mean of the windows' scores, or `1` without
     a window
  4. **Higher score is better** - Success when score ≥ threshold; the judge
     explains the score from every window's reason

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnContextualPrecision}

  test_case =
    ConversationalTestCase.new!(
      expected_outcome: "The assistant says order 42 shipped on 1 October.",
      turns: [
        %{role: :user, content: "Where is order 42?"},
        %{
          role: :assistant,
          content: "It shipped on 1 October.",
          retrieval_context: ["Rome is in Italy.", "Order 42 shipped on 1 October."]
        }
      ]
    )

  {:ok, result} = TurnContextualPrecision.measure(test_case)
  result.score   # => 0.5 (the useful node is ranked second)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and a window's score below
    it to `0` (default: false)
  - `:window_size` - The most unit interactions in each sliding window
    (default: 10)
  - `:include_reason` - Generate explanations (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.TurnContextualPrecision` (default: `nil`,
    deepeval's templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `TurnContextualPrecisionMetric`, the metric can
  route its decisions to a System One model (see
  `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each window's nodes, one Noul
    per node (`node_<i>`) about the window's user turns as `user_message`
    and the `expected_outcome` as `assistant_output`
    (`DeepEvalEx.Prompts.TurnContextualPrecision.system_one_verdict/0`),
    whose P(yes) is a verdict: `0.5` and above `yes`, else `no`, with the
    reason `"P(yes)=0.91"`; the LLM writes the reasons. If the model fails,
    the LLM judges that window's nodes and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about the whole conversation, each turn's
    `role`, `content` and `retrieval_context`, and the `expected_outcome`,
    answers the whole metric
    (`DeepEvalEx.Prompts.TurnContextualPrecision.system_one_questions/0`,
    see `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score
    and reason are built from the answers

  As in deepeval, a multimodal test case has no `:system_one` form.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.ContextualPrecision, Metrics.QAG}
  alias DeepEvalEx.Metrics.Utils.{TurnWindows, Verbose}
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.TurnContextualPrecision, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualPrecision, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}

  @impl true
  def metric_name, do: "Turn Contextual Precision"

  @impl true
  def required_params, do: [:role, :content, :retrieval_context, :expected_outcome]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  conversation's turns, each with its `role`, `content` and ordered
  `retrieval_context`, and its `expected_outcome`. `nil` for a multimodal
  test case.
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
  Measures how well the retrieval context of each window ranks its useful
  nodes first.

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
        score_window: &score_window(&1, test_case.expected_outcome, window_opts)
      ],
      test_case,
      opts
    )
  end

  # deepeval's _get_contextual_precision_scores: one window, judged as
  # ContextualPrecision judges a test case.
  defp score_window(contents, expected_outcome, opts) do
    with {:ok, verdicts} <- generate_verdicts(contents, expected_outcome, opts),
         {:ok, score, reason} <- score_and_reason(contents.input, verdicts, opts) do
      {:ok,
       %{
         score: score,
         reason: reason,
         verdicts: verdicts,
         steps: [
           "Verdicts: #{verdicts |> Verbose.verdict_models() |> Verbose.prettify_list()} \n",
           "Score: #{Verbose.to_str(score / 1)} \n",
           "Reason: #{Verbose.to_str(reason)} \n"
         ]
       }}
    end
  end

  defp generate_verdicts(%{retrieval_context: []}, _expected_outcome, _opts), do: {:ok, []}

  # Under :hybrid the System One model judges the nodes; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_verdicts(contents, expected_outcome, opts) do
    spec = %Spec.Verdicts{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      items: contents.retrieval_context,
      item_key: "node",
      state: [user_message: contents.input, assistant_output: expected_outcome]
    }

    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(contents, expected_outcome, opts)
    end
  end

  defp llm_verdicts(contents, expected_outcome, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        input: contents.input,
        expected_outcome: expected_outcome,
        retrieval_context: contents.retrieval_context,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts) do
      {:ok, response} -> Schema.parse_verdicts(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's _get_interaction_score_and_reason: a window without verdicts
  # scores 1, explained even without :include_reason.
  defp score_and_reason(_input, [], _opts) do
    {:ok, 1,
     "There were no retrieval contexts in the given turns to evaluate the contextual precision."}
  end

  defp score_and_reason(input, verdicts, opts) do
    score =
      verdicts
      |> ContextualPrecision.calculate_score()
      |> BaseMetric.strict_score(opts)

    with {:ok, reason} <- maybe_generate_reason(input, score, verdicts, opts),
         do: {:ok, score, reason}
  end

  defp maybe_generate_reason(input, score, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(input, score, verdicts, opts),
      else: {:ok, nil}
  end

  defp generate_reason(input, score, verdicts, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        input: input,
        verdicts: verdicts,
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end
end
