# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/role_adherence/role_adherence.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.RoleAdherence do
  @moduledoc """
  RoleAdherence, deepeval 4.3.1's `RoleAdherenceMetric`: whether the
  assistant stays in the character of the `:chatbot_role` throughout a
  `DeepEvalEx.ConversationalTestCase`.

  The test case must have a `:chatbot_role` (deepeval's
  `_requires_chatbot_role`); without one the metric fails as deepeval's
  does.

  ## How It Works

  1. **Find out of character turns** - the judge reads the whole
     conversation and lists, by index in the turns, each assistant turn
     that breaks the chatbot role, with a reason. Each verdict's
     `ai_message` becomes the turn's content and number,
     `"<content> (turn #<index + 1>)"`, when its index names a turn (a
     negative one counting from the end, as Python's)
  2. **Calculate score** - (assistant turns - out of character verdicts) /
     (assistant turns), at least `0`, or `1` when there are no assistant
     turns
  3. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.RoleAdherence}

  test_case =
    ConversationalTestCase.new!(
      chatbot_role: "A humble wizard who downplays his own magic.",
      turns: [
        %{role: :user, content: "Show me a spell!"},
        %{role: :assistant, content: "Oh, it's only a little spark, I'm still learning..."},
        %{role: :user, content: "Something bigger!"},
        %{role: :assistant, content: "Behold, the greatest wizard alive!"}
      ]
    )

  {:ok, result} = RoleAdherence.measure(test_case)
  result.score   # => 0.5 (1 of 2 assistant turns is out of character)
  result.success # => true (0.5 >= 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.RoleAdherence` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `RoleAdherenceMetric`, the metric can route its
  decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model judges each assistant turn, one Noul
    about the `chatbot_role`, the `previous_turns` and the turn's
    `ai_message` per turn
    (`DeepEvalEx.Prompts.RoleAdherence.system_one_verdict/0`), whose P(yes)
    is the probability that it stays in character: below `0.5` the turn is
    out of character, with the reason `"P(in character)=0.12"`. The turns
    are asked all-or-nothing, as deepeval gathers them: if any request
    fails, the LLM lists the out of character turns instead and the
    result's `:system_one_fallback_reason` says why. The LLM still writes
    the reason; a conversation without assistant turns is judged by the
    LLM
  - `:system_one` - one request about the whole conversation, each turn's
    `content` and `role`, and the `chatbot_role` answers the whole metric
    (`DeepEvalEx.Prompts.RoleAdherence.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  A multimodal test case is always judged by the LLM.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric,
    default_threshold: 0.5,
    requires_chatbot_role: true

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.Turns,
    Metrics.Utils.Verbose,
    Prompts.Python,
    Result
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.RoleAdherence, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.RoleAdherence, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Role Adherence"

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
  conversation's turns, each with its `content` and `role`, and the
  `chatbot_role`. `nil` for a multimodal test case.
  """
  @impl true
  def system_one_eval_spec(%ConversationalTestCase{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: required_params() ++ [:chatbot_role],
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions))
    }
  end

  @doc """
  Measures how well the assistant adheres to the chatbot role.

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
    role = test_case.chatbot_role

    with {:ok, verdicts} <- extract_out_of_character_verdicts(test_case, opts),
         score = calculate_score(test_case.turns, verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, role, verdicts, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Chatbot Role:\n#{role}",
            "Out-of-Character Turn(s):\n#{verdicts |> Enum.map(&verdict_model/1) |> Verbose.prettify_list()}",
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
         metadata: %{out_of_character_verdicts: verdicts}
       )}
    end
  end

  # Under :hybrid the System One model judges every assistant turn; the LLM
  # lists the out of character turns when there is none to judge, when it is
  # not asked, or when any request fails. deepeval gathers the requests, so
  # every turn is asked before the outcome is known.
  defp extract_out_of_character_verdicts(test_case, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case system_one_specs(test_case, opts) do
      [] ->
        llm_verdicts(test_case, opts)

      specs ->
        probabilities =
          Enum.map(specs, fn {index, spec} ->
            {index, Decision.probability(spec, decision_opts)}
          end)

        if Enum.all?(probabilities, &match?({_index, {:ok, _p}}, &1)),
          do: {:ok, system_one_verdicts(test_case.turns, probabilities)},
          else: llm_verdicts(test_case, opts)
    end
  end

  # deepeval's _experimental_system_one_specs: one per assistant turn, by its
  # index, or none for a multimodal test case.
  defp system_one_specs(%ConversationalTestCase{multimodal: true}, _opts), do: []

  defp system_one_specs(test_case, opts) do
    instructions = EvaluationTemplate.render(opts, Template, :system_one_verdict)
    turns = test_case.turns

    for {%{role: :assistant} = turn, index} <- Enum.with_index(turns) do
      previous_turns = turns |> Enum.take(index) |> Enum.map(&Turns.convert_turn_to_dict/1)

      {index,
       %Spec.Binary{
         instructions: instructions,
         state: [
           chatbot_role: test_case.chatbot_role,
           previous_turns: previous_turns,
           ai_message: turn.content
         ]
       }}
    end
  end

  # deepeval's _system_one_verdicts: the turns whose P(in character) is
  # below 0.5.
  defp system_one_verdicts(turns, probabilities) do
    for {index, {:ok, probability}} <- probabilities,
        Decision.verdict_from_probability(probability) == :no do
      %{
        index: index,
        reason: "P(in character)=#{Python.format_fixed(probability, 2)}",
        ai_message: ai_message(turns, index)
      }
    end
  end

  defp llm_verdicts(test_case, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :extract_out_of_character_response_verdicts,
        turns: Enum.map(test_case.turns, &Turns.convert_turn_to_dict/1),
        role: test_case.chatbot_role
      )

    with {:ok, response} <- Adapter.generate_with_schema(prompt, Schema.verdicts_schema(), opts),
         {:ok, verdicts} <- Schema.parse_verdicts(response) do
      {:ok, Enum.map(verdicts, &put_ai_message(&1, test_case.turns))}
    end
  end

  # deepeval sets each verdict's ai_message from the turn its index names,
  # Python's indexing (negative from the end), and leaves it be when the
  # index names none.
  defp put_ai_message(%{index: index} = verdict, turns) do
    case ai_message(turns, index) do
      nil -> verdict
      ai_message -> %{verdict | ai_message: ai_message}
    end
  end

  defp ai_message(turns, index) do
    case Enum.at(turns, index) do
      nil -> nil
      turn -> "#{turn.content} (turn ##{index + 1})"
    end
  end

  # deepeval's _calculate_score: the integer 1 without assistant turns, else
  # the share of assistant turns not out of character, a float.
  defp calculate_score(turns, verdicts, threshold, opts) do
    case Enum.count(turns, &(&1.role == :assistant)) do
      0 ->
        1

      assistant_turns ->
        score = (assistant_turns - min(length(verdicts), assistant_turns)) / assistant_turns

        if Keyword.get(opts, :strict_mode, false) and score < threshold, do: 0, else: score
    end
  end

  defp maybe_generate_reason(score, role, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(score, role, verdicts, opts),
      else: {:ok, nil}
  end

  defp generate_reason(score, role, verdicts, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        role: role,
        out_of_character_responses: Enum.map(verdicts, & &1.ai_message)
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's OutOfCharacterResponseVerdict models.
  defp verdict_model(verdict) do
    OrderedObject.new(
      index: verdict.index,
      reason: verdict.reason,
      ai_message: verdict.ai_message
    )
  end
end
