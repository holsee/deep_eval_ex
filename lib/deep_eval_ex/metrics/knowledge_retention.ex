# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/knowledge_retention/knowledge_retention.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.KnowledgeRetention do
  @moduledoc """
  KnowledgeRetention, deepeval 4.3.1's `KnowledgeRetentionMetric`: whether
  the assistant remembers what the user has told it throughout a
  `DeepEvalEx.ConversationalTestCase`.

  ## How It Works

  1. **Extract knowledge** - for each user turn, the judge extracts the
     facts it states, given the turns before it (a dict of strings or lists
     of strings, or none)
  2. **Generate verdicts** - for each assistant turn that follows any
     facts, the judge decides whether it forgets or contradicts them:
     - `yes` - It forgets or contradicts a known fact (an attrition)
     - `no` - It is consistent with them, or only asks to clarify, confirm
       or correct one

     An assistant turn with no facts before it gets no verdict. Other
     verdicts are dropped from the score.
  3. **Calculate score** - (`no` verdicts) / (total verdicts), or `1` when
     there are none
  4. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.KnowledgeRetention}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "I'm flying to Lisbon on 3 May."},
        %{role: :assistant, content: "Great! Where are you flying to?"}
      ]
    )

  {:ok, result} = KnowledgeRetention.measure(test_case)
  result.score   # => 0.0 (the one assistant turn forgets the destination)
  result.success # => false (0.0 < 0.5 threshold)
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:include_reason` - Generate explanation (default: true)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.KnowledgeRetention` (default: `nil`, deepeval's
    templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## System One

  Like deepeval 4.3.1's `KnowledgeRetentionMetric`, the metric can route
  its decisions to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the LLM extracts the knowledge and writes the reason; the
    System One model judges each assistant turn, one Noul about its
    `llm_message` and the `accumulated_knowledge` per turn
    (`DeepEvalEx.Prompts.KnowledgeRetention.system_one_verdict/0`), whose
    P(yes), the probability that it forgets, is a verdict: `0.5` and above
    `yes` (an attrition), else `no`, with the reason `"P(yes)=0.91"`. If the
    model fails, the LLM judges that turn and the result's
    `:system_one_fallback_reason` says why
  - `:system_one` - one request about the whole conversation, each turn's
    `content` and `role`, answers the whole metric
    (`DeepEvalEx.Prompts.KnowledgeRetention.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  A multimodal test case is always judged by the LLM.

  ## Differences from deepeval

  - deepeval prints each extracted dict of facts in the order the judge
    gave its keys. A judge's answer decoded to an Elixir map keeps no key
    order, so a dict of several facts prints in the map's order; one
    decoded to `Jason.OrderedObject`s keeps the judge's.
  - As in deepeval, a verdict outside yes and no (from a judge without
    structured outputs) cannot be explained: with `:include_reason` the
    measure fails with deepeval's error, `'NoneType' object has no
    attribute 'verdict'`.
  - The facts' schema is a free-form dict, as deepeval's `Knowledge`, which
    OpenAI's strict structured outputs cannot express: use a judge without
    them, or in JSON mode.
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
  alias DeepEvalEx.Prompts.KnowledgeRetention, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.KnowledgeRetention, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @impl true
  def metric_name, do: "Knowledge Retention"

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
  Measures how well the assistant retains the facts the user gives.

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

    with {:ok, knowledges} <- generate_knowledges(test_case.turns, opts),
         {:ok, verdicts} <- generate_verdicts(test_case, knowledges, opts),
         score = calculate_score(verdicts, threshold, opts),
         {:ok, reason} <- maybe_generate_reason(score, verdicts, opts) do
      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Knowledges:\n#{knowledges |> Enum.map(&knowledge_model/1) |> Verbose.prettify_list()}",
            "Verdicts:\n#{verdicts |> Enum.map(&verdict_model/1) |> Verbose.prettify_list()}",
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
         metadata: %{knowledges: knowledges, verdicts: verdicts}
       )}
    end
  end

  # One knowledge per turn, nil for an assistant turn, in order, each user
  # turn's facts extracted given the turns before it.
  defp generate_knowledges(turns, opts) do
    turns
    |> Enum.with_index()
    |> reduce_ok(fn
      {%{role: :assistant}, _index} ->
        {:ok, nil}

      {turn, index} ->
        previous_turns = turns |> Enum.take(index) |> Enum.map(&Turns.convert_turn_to_dict/1)
        extract_knowledge(turn.content, previous_turns, opts)
    end)
  end

  defp extract_knowledge(user_message, previous_turns, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :extract_data,
        user_message: user_message,
        previous_turns: previous_turns
      )

    case Adapter.generate_with_schema(prompt, Schema.knowledge_schema(), opts) do
      {:ok, response} -> Schema.parse_knowledge(response)
      {:error, _} = error -> error
    end
  end

  # A verdict per assistant turn that follows any facts, in order.
  defp generate_verdicts(test_case, knowledges, opts) do
    test_case.turns
    |> Enum.with_index()
    |> Enum.filter(fn {turn, _index} -> turn.role == :assistant end)
    |> Enum.flat_map(fn {turn, index} ->
      case accumulated_knowledge(knowledges, index) do
        [] -> []
        knowledge -> [{turn.content, knowledge}]
      end
    end)
    |> reduce_ok(fn {llm_message, knowledge} ->
      generate_verdict(llm_message, knowledge, test_case.multimodal, opts)
    end)
  end

  # The facts of the user turns before `index`, deepeval's falsy data (none
  # or an empty dict) left out.
  defp accumulated_knowledge(knowledges, index) do
    for %{data: data} <- Enum.take(knowledges, index), facts?(data), do: data
  end

  defp facts?(nil), do: false
  defp facts?(%OrderedObject{values: values}), do: values != []
  defp facts?(data) when is_map(data), do: map_size(data) > 0

  # Under :hybrid the System One model judges the turn; the LLM does when it
  # is not asked or fails (deepeval's generate_qag_verdict).
  defp generate_verdict(llm_message, knowledge, multimodal, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())
    spec = system_one_spec(llm_message, knowledge, multimodal, opts)

    case Decision.verdict(spec, QAG.yes_no(), decision_opts) do
      {:ok, verdict} -> {:ok, verdict}
      :llm -> llm_verdict(llm_message, knowledge, opts)
    end
  end

  # deepeval's _experimental_system_one_spec.
  defp system_one_spec(_llm_message, _knowledge, true, _opts), do: nil

  defp system_one_spec(llm_message, knowledge, false, opts) do
    %Spec.Binary{
      instructions: EvaluationTemplate.render(opts, Template, :system_one_verdict),
      state: [llm_message: llm_message, accumulated_knowledge: knowledge]
    }
  end

  defp llm_verdict(llm_message, knowledge, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :generate_verdict,
        llm_message: llm_message,
        accumulated_knowledge: knowledge
      )

    case Adapter.generate_with_schema(prompt, Schema.verdict_schema(), opts) do
      {:ok, response} -> Schema.parse_verdict(response)
      {:error, _} = error -> error
    end
  end

  # "yes" means the assistant forgot something, so "no" passes; no verdicts
  # score the integer 1.
  defp calculate_score(verdicts, threshold, opts) do
    QAG.score_qag_verdicts(verdicts,
      passing: [:no],
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: threshold
    )
  end

  defp maybe_generate_reason(score, verdicts, opts) do
    if Keyword.get(opts, :include_reason, true),
      do: generate_reason(score, verdicts, opts),
      else: {:ok, nil}
  end

  # The reasons of the "yes" verdicts, nil (Python's None) included. deepeval
  # reads every verdict's .verdict here, so a dropped (None) one fails.
  defp generate_reason(score, verdicts, opts) do
    if nil in verdicts, do: raise("'NoneType' object has no attribute 'verdict'")

    attritions = for %{verdict: :yes, reason: reason} <- verdicts, do: reason

    prompt =
      EvaluationTemplate.render(opts, Template, :generate_reason,
        score: score,
        attritions: attritions
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's Knowledge models, and None for an assistant turn.
  defp knowledge_model(nil), do: nil
  defp knowledge_model(%{data: data}), do: OrderedObject.new(data: data)

  # deepeval's KnowledgeRetentionVerdict models, and None for a dropped
  # verdict.
  defp verdict_model(nil), do: nil

  defp verdict_model(verdict),
    do: OrderedObject.new(verdict: verdict.verdict, reason: verdict.reason)

  # Maps `fun` over `items` in order, stopping at the first error.
  defp reduce_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
