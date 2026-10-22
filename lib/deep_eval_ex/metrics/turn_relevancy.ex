# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/turn_relevancy/turn_relevancy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.TurnRelevancy do
  @moduledoc """
  TurnRelevancy, deepeval 4.3.1's `TurnRelevancyMetric`: whether the
  assistant stays relevant throughout a `DeepEvalEx.ConversationalTestCase`.

  ## How It Works

  1. **Split the conversation** - into unit interactions, each user turn(s)
     and the assistant's answer
     (`DeepEvalEx.Metrics.Utils.Turns.get_unit_interactions/1`)
  2. **Slide a window** - for each unit interaction, a window of at most
     `:window_size` unit interactions ending with it, flattened into its
     turns (`DeepEvalEx.Metrics.Utils.Turns.get_turns_in_sliding_window/2`)
  3. **Generate verdicts** - for each window, the judge decides whether its
     last assistant turn is relevant to the turns before it:
     - `yes` - Relevant (vague replies to vague turns, such as greetings,
       count as relevant)
     - `no` - Completely irrelevant, with a reason

     Other verdicts are dropped.
  4. **Calculate score** - (relevant windows) / (total verdicts), or `1`
     when there are none
  5. **Higher score is better** - Success when score ≥ threshold

  The reason prompt lists each irrelevant window by its message number,
  counting windows from 1.

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.TurnRelevancy}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "My order is late."},
        %{role: :assistant, content: "Sorry! Let me check order 42 for you."},
        %{role: :user, content: "Thanks. When will it arrive?"},
        %{role: :assistant, content: "Have you tried our new pizza?"}
      ]
    )

  {:ok, result} = TurnRelevancy.measure(test_case)
  result.score   # => 0.5 (1 of 2 assistant turns is relevant)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:window_size` - The most unit interactions in each sliding window
    (default: 10)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.TurnRelevancy` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  deepeval's `template_class`, which renders the prompts of another
  metric's templates, is not ported: use `:evaluation_template`.

  ## System One

  Like deepeval 4.3.1's `TurnRelevancyMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each window, one Noul about its
    `turns` per window (`DeepEvalEx.Prompts.TurnRelevancy.system_one_verdict/0`),
    whose P(yes) is a verdict: `0.5` and above `yes` (relevant), else `no`,
    with the reason `"P(yes)=0.91"`; the LLM writes the reason. If the model
    fails, the LLM judges that window and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about the whole conversation, each turn's
    `content` and `role`, answers the whole metric
    (`DeepEvalEx.Prompts.TurnRelevancy.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  As in deepeval, a multimodal test case is always judged by the LLM: it
  has no System One form.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.QAG,
    Metrics.Utils.Turns,
    Metrics.Utils.Verbose,
    Result
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.TurnRelevancy, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.TurnRelevancy, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @default_window_size 10

  @impl true
  def metric_name, do: "Turn Relevancy"

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
  Measures how relevant the assistant's turns are to the conversation.

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
    window_size = Keyword.get(opts, :window_size, @default_window_size)

    windows =
      test_case.turns
      |> Turns.get_unit_interactions()
      |> Turns.get_turns_in_sliding_window(window_size)
      |> Enum.map(&Enum.concat/1)

    with {:ok, verdicts} <- generate_verdicts(windows, test_case.multimodal, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Turns Sliding Windows (size=#{window_size}):\n#{Verbose.prettify_list(windows)}",
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
         metadata: %{verdicts: verdicts}
       )}
    end
  end

  # One verdict per window, in order, as deepeval gathers them.
  defp generate_verdicts(windows, multimodal, opts) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, verdicts} ->
      case generate_verdict(window, multimodal, opts) do
        {:ok, verdict} -> {:cont, {:ok, [verdict | verdicts]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verdicts} -> {:ok, Enum.reverse(verdicts)}
      error -> error
    end
  end

  # Under :hybrid the System One model judges the window; the LLM does when
  # it is not asked or fails (deepeval's generate_qag_verdict).
  defp generate_verdict(window, multimodal, opts) do
    sliding_window = Enum.map(window, &Turns.convert_turn_to_dict/1)
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.verdict(
           system_one_spec(sliding_window, multimodal, opts),
           QAG.yes_no(),
           decision_opts
         ) do
      {:ok, verdict} -> {:ok, verdict}
      :llm -> llm_verdict(sliding_window, opts)
    end
  end

  # deepeval's _experimental_system_one_spec.
  defp system_one_spec(_sliding_window, true, _opts), do: nil

  defp system_one_spec(sliding_window, false, opts) do
    %Spec.Binary{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      state: [turns: sliding_window]
    }
  end

  defp llm_verdict(sliding_window, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdicts,
        sliding_window: sliding_window
      )

    case Adapter.generate_with_schema(prompt, Schema.verdict_schema(), opts) do
      {:ok, response} -> Schema.parse_verdict(response)
      {:error, _} = error -> error
    end
  end

  # deepeval 4.3.1 scores the relevant windows over all verdicts (dropped
  # ones aside), and an empty list as the integer 1.
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:yes],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(score, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(score, verdicts, opts),
      else: {:ok, nil}
  end

  # Each irrelevant window by its message number, counting every window
  # from 1, dropped verdicts included.
  defp generate_reason(score, verdicts, opts) do
    irrelevancies =
      for {%{verdict: :no, reason: reason}, index} <- Enum.with_index(verdicts, 1) do
        OrderedObject.new([{"message number", Integer.to_string(index)}, {"reason", reason}])
      end

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        irrelevancies: irrelevancies
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's TurnRelevancyVerdict models, and None for a dropped verdict.
  defp verdict_models(verdicts) do
    Enum.map(verdicts, fn
      nil -> nil
      verdict -> OrderedObject.new(verdict: verdict.verdict, reason: verdict.reason)
    end)
  end
end
