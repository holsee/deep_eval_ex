# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/conversation_completeness/conversation_completeness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ConversationCompleteness do
  @moduledoc """
  ConversationCompleteness, deepeval 4.3.1's
  `ConversationCompletenessMetric`: whether the assistant satisfies what the
  user wants throughout a `DeepEvalEx.ConversationalTestCase`.

  ## How It Works

  1. **Extract intentions** - the judge lists the user's intentions in the
     conversation, each task separately
  2. **Generate verdicts** - for each intention, the judge decides whether
     the conversation satisfies it:
     - `yes` - Satisfied
     - `no` - Not satisfied, with a reason

     Other verdicts are dropped.
  3. **Calculate score** - (satisfied intentions) / (total verdicts), or
     `1` when there are none
  4. **Higher score is better** - Success when score ≥ threshold

  Every verdict sees the whole conversation. deepeval's `window_size`
  option is taken (default: 3) but, as in deepeval 4.3.1, not used.

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.ConversationCompleteness}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "Book a table for two on Friday, and tell me the dress code."},
        %{role: :assistant, content: "Your table for two is booked for Friday at 8pm."}
      ]
    )

  {:ok, result} = ConversationCompleteness.measure(test_case)
  result.score   # => 0.5 (1 of 2 intentions is satisfied)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:window_size` - Taken, as deepeval's, but unused (default: 3)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.ConversationCompleteness` (default: `nil`,
    deepeval's templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `ConversationCompletenessMetric`, the metric can
  route its decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the intentions and writes the reason; the
    System One model judges each intention, one Noul about the
    conversation's `turns` and the `intention` per intention
    (`DeepEvalEx.Prompts.ConversationCompleteness.system_one_verdict/0`),
    whose P(yes) is a verdict: `0.5` and above `yes` (satisfied), else
    `no`, with the reason `"P(yes)=0.91"`. If the model fails, the LLM
    judges that intention and the result's `:system_one_fallback_reason`
    says why
  - `:system_one` - one request about the whole conversation, each turn's
    `content` and `role`, answers the whole metric
    (`DeepEvalEx.Prompts.ConversationCompleteness.system_one_questions/0`,
    see `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score
    and reason are built from the answers

  As in deepeval, a multimodal test case is always judged by the LLM, whose
  prompts then include the multimodal input rules.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.Turns,
    Metrics.Utils.Verbose,
    Result,
    Turn
  }

  alias DeepEvalEx.Prompts.ConversationCompleteness, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Schemas.MetricOutputs.ConversationCompleteness, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Conversation Completeness"

  @impl true
  def required_params, do: [:content, :role]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  conversation's turns, each with its `content` and `role`. `nil` for a
  multimodal test case.
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
  Measures how completely the assistant satisfies the user's intentions.

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
    template_opts = Keyword.put(opts, :multimodal, test_case.multimodal)
    turns = Enum.map(test_case.turns, &Turns.convert_turn_to_dict/1)

    with {:ok, intentions} <- extract_user_intentions(turns, template_opts),
         {:ok, verdicts} <- generate_verdicts(turns, intentions, template_opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, intentions, verdicts, template_opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Turns:\n#{test_case.turns |> Enum.map(&Turn.model_dump/1) |> Verbose.prettify_list()}",
            "User Intentions:\n#{Verbose.prettify_list(intentions)}",
            "Verdicts:\n#{verdicts |> verdict_models() |> Verbose.prettify_list()}",
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
         metadata: %{user_intentions: intentions, verdicts: verdicts}
       )}
    end
  end

  defp extract_user_intentions(turns, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :extract_user_intentions,
        turns: turns,
        multimodal: Keyword.fetch!(opts, :multimodal)
      )

    case Adapter.generate_with_schema(prompt, Schema.intentions_schema(), opts) do
      {:ok, response} -> Schema.parse_intentions(response)
      {:error, _} = error -> error
    end
  end

  # One verdict per intention, in order, as deepeval gathers them.
  defp generate_verdicts(turns, intentions, opts) do
    Enum.reduce_while(intentions, {:ok, []}, fn intention, {:ok, verdicts} ->
      case generate_verdict(turns, intention, opts) do
        {:ok, verdict} -> {:cont, {:ok, [verdict | verdicts]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verdicts} -> {:ok, Enum.reverse(verdicts)}
      error -> error
    end
  end

  # Under :hybrid the System One model judges the intention; the LLM does
  # when it is not asked or fails (deepeval's generate_qag_verdict).
  defp generate_verdict(turns, intention, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdict(system_one_spec(turns, intention, opts), QAG.yes_no(), decision_opts) do
      {:ok, verdict} -> {:ok, verdict}
      :llm -> llm_verdict(turns, intention, opts)
    end
  end

  # deepeval's _experimental_system_one_spec.
  defp system_one_spec(turns, intention, opts) do
    unless Keyword.fetch!(opts, :multimodal) do
      %Spec.Binary{
        instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
        state: [turns: turns, intention: intention]
      }
    end
  end

  defp llm_verdict(turns, intention, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        turns: turns,
        intention: intention,
        multimodal: Keyword.fetch!(opts, :multimodal)
      )

    case Adapter.generate_with_schema(prompt, Schema.verdict_schema(), opts) do
      {:ok, response} -> Schema.parse_verdict(response)
      {:error, _} = error -> error
    end
  end

  # deepeval 4.3.1 scores the satisfied intentions over all verdicts
  # (dropped ones aside), and an empty list as the integer 1.
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(score, intentions, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(score, intentions, verdicts, opts),
      else: {:ok, nil}
  end

  # The reasons of the unsatisfied intentions, `nil` (Python's `None`)
  # included.
  defp generate_reason(score, intentions, verdicts, opts) do
    incompletenesses = for %{verdict: :no, reason: reason} <- verdicts, do: reason

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        incompletenesses: incompletenesses,
        intentions: intentions,
        multimodal: Keyword.fetch!(opts, :multimodal)
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's ConversationCompletenessVerdict models, and None for a
  # dropped verdict.
  defp verdict_models(verdicts) do
    Enum.map(verdicts, fn
      nil -> nil
      verdict -> OrderedObject.new(verdict: verdict.verdict, reason: verdict.reason)
    end)
  end
end
