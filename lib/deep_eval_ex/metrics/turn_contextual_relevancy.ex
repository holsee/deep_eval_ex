# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/turn_contextual_relevancy/turn_contextual_relevancy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.TurnContextualRelevancy do
  @moduledoc """
  TurnContextualRelevancy, deepeval 4.3.1's `TurnContextualRelevancyMetric`:
  whether the retrieval context of the turns of a
  `DeepEvalEx.ConversationalTestCase` is relevant to what the user asks.

  ## How It Works

  1. **Slide a window** - for each unit interaction, a window of at most
     `:window_size` unit interactions ending with it
     (`DeepEvalEx.Metrics.Utils.TurnWindows`)
  2. **Judge each window as ContextualRelevancy does** - for each node of
     the retrieval context of the window's assistant turns, one after the
     other, the judge extracts its statements and decides whether each is
     relevant to the window's user turns (`yes`) or not (`no`, with a
     reason; other verdicts are dropped). The window scores the share of
     `yes` verdicts over every node, and the judge explains it. A window
     without verdicts scores `1.0`, with the reason `"There were no
     retrieval contexts in the given turns to evaluate the contextual
     relevancy."`
  3. **Calculate score** - the mean of the windows' scores, or `1` without
     a window
  4. **Higher score is better** - Success when score ≥ threshold; the judge
     explains the score from every window's reason

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnContextualRelevancy}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "Where is order 42?"},
        %{
          role: :assistant,
          content: "It shipped on 1 October.",
          retrieval_context: ["Order 42 shipped on 1 October. Rome is in Italy."]
        }
      ]
    )

  {:ok, result} = TurnContextualRelevancy.measure(test_case)
  result.score   # => 0.5 (Rome is irrelevant)
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
    `DeepEvalEx.Prompts.TurnContextualRelevancy` (default: `nil`,
    deepeval's templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  A `DeepEvalEx.Schemas.RetrievedContextData` node is judged as Python's
  `str()` of it, `context='...' source='...'`, as deepeval's prompt prints
  it; deepeval 4.3.1 raises on one before asking.

  ## System One

  Like deepeval 4.3.1's `TurnContextualRelevancyMetric`, the metric can
  route its decisions to a System One model (see
  `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each node of each window, one
    request per node: one Noul per sentence of the node (`statement_<i>`,
    split with `DeepEvalEx.SystemOne.Decision.split_sentences/1`) about the
    window's user turns as `user_message`
    (`DeepEvalEx.Prompts.TurnContextualRelevancy.system_one_verdict/0`),
    whose P(yes) is a verdict: `0.5` and above `yes`, else `no`, with the
    reason `"P(yes)=0.91"`; the LLM writes the reasons. If the model fails,
    the LLM judges that node and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about the whole conversation, each turn's
    `role`, `content` and `retrieval_context`, answers the whole metric
    (`DeepEvalEx.Prompts.TurnContextualRelevancy.system_one_questions/0`,
    see `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score
    and reason are built from the answers

  As in deepeval, a multimodal test case is always judged by the LLM: it
  has no System One form.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Metrics.QAG}
  alias DeepEvalEx.Metrics.Utils.{TurnWindows, Verbose}
  alias DeepEvalEx.Prompts.{EvaluationTemplate, Python}
  alias DeepEvalEx.Prompts.TurnContextualRelevancy, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ContextualRelevancy, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Turn Contextual Relevancy"

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
  Measures how relevant the retrieval context of each window is to its user
  turns.

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

  # deepeval's _get_contextual_relevancy_scores: one window, judged as
  # ContextualRelevancy judges a test case.
  defp score_window(contents, opts) do
    with {:ok, verdicts} <- generate_verdicts(contents, opts),
         {:ok, score, reason} <- score_and_reason(contents.input, verdicts, opts) do
      {:ok,
       %{
         score: score,
         reason: reason,
         verdicts: verdicts,
         steps: [
           "Verdicts: #{verdicts |> Enum.map(&verdict_model/1) |> Verbose.prettify_list()} \n",
           "Score: #{Verbose.to_str(score / 1)} \n",
           "Reason: #{Verbose.to_str(reason)} \n"
         ]
       }}
    end
  end

  # Each node's verdicts in turn, flattened.
  defp generate_verdicts(contents, opts) do
    contents.retrieval_context
    |> Enum.map(&Python.str/1)
    |> Enum.reduce_while({:ok, []}, fn context, {:ok, acc} ->
      case generate_node_verdicts(contents.input, context, opts) do
        {:ok, verdicts} -> {:cont, {:ok, [verdicts | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verdicts} -> {:ok, verdicts |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  # Under :hybrid the System One model judges each sentence of the node; the
  # LLM does when it is not asked or fails (deepeval's generate_qag_verdicts).
  defp generate_node_verdicts(input, context, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdicts(system_one_spec(input, context, opts), QAG.yes_no(), decision_opts) do
      {:ok, verdicts} -> {:ok, verdicts}
      :llm -> llm_verdicts(input, context, opts)
    end
  end

  # deepeval's _experimental_system_one_spec: none for a multimodal case.
  defp system_one_spec(input, context, opts) do
    unless opts[:multimodal] do
      %Spec.Verdicts{
        instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
        items: Decision.split_sentences(context),
        item_key: "statement",
        state: [user_message: input],
        build_verdict: &system_one_verdict/3
      }
    end
  end

  # The ContextualRelevancyVerdict deepeval builds from P(yes).
  defp system_one_verdict(statement, verdict, probability),
    do: %{
      statement: statement,
      verdict: verdict,
      reason: "P(yes)=#{Python.format_fixed(probability, 2)}"
    }

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

  # deepeval's _get_interaction_score_and_reason: a window without verdicts
  # scores 1, explained even without :include_reason.
  defp score_and_reason(_input, [], _opts) do
    {:ok, 1,
     "There were no retrieval contexts in the given turns to evaluate the contextual relevancy."}
  end

  defp score_and_reason(input, verdicts, opts) do
    score =
      QAG.score_qag_verdicts(verdicts,
        passing: [:yes],
        strict_mode: Keyword.get(opts, :strict_mode, false),
        threshold: Keyword.fetch!(opts, :threshold)
      )

    with {:ok, reason} <- maybe_generate_reason(input, score, verdicts, opts),
         do: {:ok, score, reason}
  end

  defp maybe_generate_reason(input, score, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(input, score, verdicts, opts),
      else: {:ok, nil}
  end

  # A relevant statement is listed by itself, an irrelevant one as
  # "<statement>: <reason>", its reason formatted as deepeval's f-string does
  # (`None` when the judge gave none).
  defp generate_reason(input, score, verdicts, opts) do
    {relevant, irrelevant} = Enum.split_with(verdicts, &(&1.verdict == :yes))

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        input: input,
        irrelevant_statements:
          Enum.map(irrelevant, &"#{&1.statement}: #{Verbose.to_str(&1.reason)}"),
        relevant_statements: Enum.map(relevant, & &1.statement),
        multimodal: opts[:multimodal]
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's ContextualRelevancyVerdict, as prettify_list dumps it.
  defp verdict_model(verdict),
    do:
      OrderedObject.new(
        statement: verdict.statement,
        verdict: verdict.verdict,
        reason: verdict.reason
      )
end
