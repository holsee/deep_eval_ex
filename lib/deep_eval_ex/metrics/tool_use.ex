# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/tool_use/tool_use.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ToolUse do
  @moduledoc """
  ToolUse, deepeval 4.3.1's `ToolUseMetric`: how well the assistant of a
  `DeepEvalEx.ConversationalTestCase` chooses among the `:available_tools`
  and how correct the arguments of its tool calls are.

  ## How It Works

  1. **Split the conversation** - into unit interactions
     (`DeepEvalEx.Metrics.Utils.Turns.get_unit_interactions/1`) of at least
     two turns. Each one's user messages are its leading user turns, its
     assistant messages and tool calls those of the assistant turns after
     its first turn; tools are printed as deepeval's `ToolCall.__repr__`,
     joined with commas
  2. **Score tool selection** - for each unit, the judge scores how well
     the tools called match what the user asked, given the available
     tools, from `0.0` to `1.0`, with a reason
  3. **Score arguments** - for each unit that called a tool, the judge
     scores the correctness of the calls' arguments, likewise
  4. **Calculate score** - the lower of the mean tool selection score and
     the mean argument correctness score, each `0.0` without scores: as in
     deepeval, a conversation without tool calls scores `0.0`
  5. **Explain** - the judge explains each mean with deepeval's tool
     selection reason template (argument correctness included, as deepeval
     does), and the reason is both, joined with a newline. As in deepeval,
     it always does: `:include_reason` is not read
  6. **Higher score is better** - Success when score ≥ threshold. As in
     deepeval, whose `measure()` never sets it, `measure/2`'s result has
     `success: nil` (but under `:system_one`); `DeepEvalEx.evaluate/3` and
     the exported test run report `score >= threshold`, as deepeval's
     `is_successful()`

  ## Usage

  ```elixir
  alias DeepEvalEx.{ConversationalTestCase, Metrics.ToolUse, Schemas.ToolCall}

  test_case =
    ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "What's the weather in Paris?"},
        %{
          role: :assistant,
          content: "It is 18°C in Paris.",
          tools_called: [%{name: "get_weather", input_parameters: %{"city" => "Paris"}}]
        }
      ]
    )

  {:ok, result} =
    ToolUse.measure(test_case,
      available_tools: [
        %ToolCall{name: "get_weather", description: "Fetch current weather for a city"},
        %ToolCall{name: "search_web", description: "Search the web"}
      ]
    )

  result.score   # => 1.0
  result.success # => nil (see "How It Works")
  ```

  ## Options

  - `:available_tools` - The tools the assistant could call, a list of
    `DeepEvalEx.Schemas.ToolCall`s (required, as deepeval's constructor
    argument)
  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0`
    (default: false)
  - `:model` - LLM model for evaluation
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.ToolUse` (default: `nil`, deepeval's templates)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)
  - `:eval_mode` and `:system_one_model` - who decides, see "System One"

  ## As a configured metric

  The available tools belong to the metric, as in deepeval's
  `ToolUseMetric(available_tools=...)`. To evaluate with other metrics,
  build the metric with `new/1` and pass the struct to
  `DeepEvalEx.evaluate/3`; its fields take precedence over the run's
  options:

  ```elixir
  metric = ToolUse.new(available_tools: [%ToolCall{name: "get_weather"}])
  DeepEvalEx.evaluate([test_case], [metric, DeepEvalEx.Metrics.GoalAccuracy])
  ```

  ## System One

  Like deepeval 4.3.1's `ToolUseMetric`, the metric can route its decisions
  to a System One model (see `DeepEvalEx.SystemOne.Mode`):

  - `:hybrid` - the System One model takes each tool selection and argument
    correctness score, one `DeepEvalEx.SystemOne.Spec.Score` request each
    about the unit's `user_messages`, `assistant_messages`, `tools_called`
    and `available_tools` (the texts the LLM prompt shows), over five
    levels (`DeepEvalEx.Prompts.ToolUse.system_one_tool_selection_score/0`
    and `system_one_argument_correctness_score/0`): the chosen level over
    the highest is the score, and the reason is
    `"Decided by <model>: tool selection 0.75."`. A request that fails
    falls back to the LLM for that score, and the result's
    `:system_one_fallback_reason` says why. The LLM still writes the
    reasons
  - `:system_one` - one request about the whole conversation, each turn's
    `role`, `content` and `tools_called`, with the `available_tools` under
    their own key, answers the whole metric
    (`DeepEvalEx.Prompts.ToolUse.system_one_questions/0`, see
    `DeepEvalEx.SystemOne.Runner`): no LLM call is made, and the score and
    reason are built from the answers

  A multimodal test case is always judged by the LLM.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{
    LLM.Adapter,
    Metrics.BaseMetric,
    Metrics.Utils.Turns,
    Metrics.Utils.Verbose,
    Prompts.Python,
    Result,
    Schemas.ToolCall,
    Turn
  }

  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Prompts.ToolUse, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ToolUse, as: Schema
  alias DeepEvalEx.SystemOne.{Decision, EvalSpec, Runner, Scored, Spec}
  alias Jason.OrderedObject

  @enforce_keys [:available_tools]
  defstruct [
    :available_tools,
    :threshold,
    :strict_mode,
    :model,
    :verbose_mode,
    :flaky,
    :eval_mode,
    :system_one_model,
    :evaluation_template
  ]

  @type t :: %__MODULE__{
          available_tools: [ToolCall.t()],
          threshold: number() | nil,
          strict_mode: boolean() | nil,
          model: term(),
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil,
          eval_mode: atom() | String.t() | nil,
          system_one_model: term(),
          evaluation_template: module() | nil
        }

  # deepeval's TOOL_SELECTION_LEVELS and ARGUMENT_CORRECTNESS_LEVELS, lowest
  # first.
  @tool_selection_levels [
    "Irrelevant or unjustified",
    "Poor selection",
    "Mixed selection",
    "Mostly correct",
    "Perfectly matched"
  ]

  @argument_correctness_levels [
    "Nonsensical or unrelated",
    "Poor arguments",
    "Partially correct",
    "Mostly correct",
    "Fully correct"
  ]

  @doc """
  Creates a ToolUse metric for `DeepEvalEx.evaluate/3`. See the moduledoc
  for the options; those left unset (`nil`) fall back to the run's
  options.

  Raises `ArgumentError` without `:available_tools`, deepeval's required
  constructor argument.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      available_tools: available_tools!(opts),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky),
      eval_mode: Keyword.get(opts, :eval_mode),
      system_one_model: Keyword.get(opts, :system_one_model),
      evaluation_template: Keyword.get(opts, :evaluation_template)
    }
  end

  @impl true
  def metric_name, do: "Tool Use"

  @impl true
  def required_params, do: [:role, :content]

  @doc """
  Returns the judge model this metric calls with `opts`.
  """
  @impl true
  defdelegate evaluation_model(opts), to: Adapter, as: :model_name

  @doc """
  The whole metric as one System One request under the `:system_one` eval
  mode, deepeval's `_system_one_eval_spec`: its questions about the
  conversation's turns, each with its `role`, `content` and `tools_called`,
  and the `:available_tools`. `nil` for a multimodal test case.

  Raises `ArgumentError` without `:available_tools`.
  """
  @impl true
  def system_one_eval_spec(%ConversationalTestCase{multimodal: true}, _opts), do: nil

  def system_one_eval_spec(_test_case, opts) do
    %EvalSpec{
      evaluation_params: [:role, :content, :tools_called],
      questions: Scored.parse!(EvaluationTemplate.render(opts, Template, :system_one_questions)),
      extra_state: [available_tools: available_tools!(opts)]
    }
  end

  @doc """
  Measures how well the assistant chooses and calls its tools.

  ## Options

  See the moduledoc, plus:

  - `:adapter` - LLM adapter to use

  Raises `ArgumentError` without `:available_tools`.
  """
  def do_measure(test_case, opts) do
    available_tools = available_tools!(opts)

    case Runner.run(__MODULE__, test_case, opts) do
      {:ok, result} -> {:ok, result}
      :continue -> measure_with_llm(test_case, available_tools, opts)
    end
  end

  defp available_tools!(opts) do
    case Keyword.fetch(opts, :available_tools) do
      {:ok, tools} when is_list(tools) ->
        tools

      _ ->
        raise ArgumentError,
              "ToolUse requires :available_tools, a list of DeepEvalEx.Schemas.ToolCall"
    end
  end

  defp measure_with_llm(test_case, available_tools, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    template_opts = Keyword.put(opts, :multimodal, test_case.multimodal)

    units =
      test_case.turns
      |> Turns.get_unit_interactions()
      |> Enum.flat_map(&user_input_and_tools(&1, available_tools))

    with {:ok, selection_scores} <- score_all(units, :tool_selection, template_opts),
         {:ok, argument_scores} <-
           units
           |> Enum.filter(& &1.tools_used)
           |> score_all(:argument_correctness, template_opts),
         score = calculate_score(selection_scores, argument_scores, threshold, opts),
         {:ok, selection_reason} <- generate_reason(selection_scores, score, threshold, opts),
         {:ok, argument_reason} <- generate_reason(argument_scores, score, threshold, opts) do
      reason = selection_reason <> "\n" <> argument_reason

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(),
          [
            "Tool Selection Scores: #{prettify_scores(selection_scores)} \n",
            "Argument Correctness Scores: #{prettify_scores(argument_scores)} \n",
            "Final Score: #{Verbose.to_str(score)}",
            "Final Reason: #{reason}"
          ],
          opts
        )

      # deepeval's measure() never sets ToolUse's success, which stays None
      # until evaluate() asks is_successful() (see DeepEvalEx.Evaluator).
      {:ok,
       Result.new(
         metric: metric_name(),
         score: score,
         success: nil,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{
           tool_selection_scores: selection_scores,
           argument_correctness_scores: argument_scores
         }
       )}
    end
  end

  # deepeval's _get_user_input_and_turns: a unit of fewer than two turns is
  # skipped; the user messages are its leading user turns, the assistant
  # messages and tool calls those of its assistant turns after the first
  # turn.
  defp user_input_and_tools([_, _ | _] = unit, available_tools) do
    user_messages =
      unit
      |> Enum.take_while(&(&1.role == :user))
      |> Enum.map_join(&"#{&1.content} \n")

    assistant_turns = unit |> Enum.drop(1) |> Enum.filter(&match?(%Turn{role: :assistant}, &1))
    tools_called = Enum.flat_map(assistant_turns, &(&1.tools_called || []))

    [
      %{
        user_messages: user_messages,
        assistant_messages: Enum.map_join(assistant_turns, &"#{&1.content} \n"),
        tools_called: reprs(tools_called),
        available_tools: reprs(available_tools),
        tools_used: tools_called != []
      }
    ]
  end

  defp user_input_and_tools(_unit, _available_tools), do: []

  defp reprs(tools), do: Enum.map_join(tools, ",", &Python.repr/1)

  # Every unit's score, in order, as deepeval gathers them.
  defp score_all(units, kind, opts) do
    units
    |> Enum.reduce_while({:ok, []}, fn unit, {:ok, scores} ->
      case score_unit(unit, kind, opts) do
        {:ok, score} -> {:cont, {:ok, [score | scores]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, scores} -> {:ok, Enum.reverse(scores)}
      error -> error
    end
  end

  # Under :hybrid and :system_one the System One model takes the score; the
  # LLM does when it is not asked or fails.
  defp score_unit(unit, kind, opts) do
    decision_opts = Keyword.put_new(opts, :metric_name, metric_name())

    case Decision.score(system_one_spec(unit, kind, opts), decision_opts) do
      {:ok, value} ->
        {:ok, %{score: value, reason: Decision.format_reason(decision_opts, what(kind), value)}}

      :llm ->
        llm_score(unit, kind, opts)
    end
  end

  # deepeval's _system_one_score_spec: none for a multimodal test case.
  defp system_one_spec(unit, kind, opts) do
    if Keyword.fetch!(opts, :multimodal), do: nil, else: score_spec(unit, kind, opts)
  end

  defp score_spec(unit, kind, opts) do
    {template, levels} =
      case kind do
        :tool_selection ->
          {:system_one_tool_selection_score, @tool_selection_levels}

        :argument_correctness ->
          {:system_one_argument_correctness_score, @argument_correctness_levels}
      end

    %Spec.Score{
      instructions: EvaluationTemplate.render(opts, Template, template),
      levels: levels,
      state: [
        user_messages: unit.user_messages,
        assistant_messages: unit.assistant_messages,
        tools_called: unit.tools_called,
        available_tools: unit.available_tools
      ]
    }
  end

  defp what(:tool_selection), do: "tool selection"
  defp what(:argument_correctness), do: "argument correctness"

  defp llm_score(unit, kind, opts) do
    template =
      case kind do
        :tool_selection -> :get_tool_selection_score
        :argument_correctness -> :get_argument_correctness_score
      end

    prompt =
      EvaluationTemplate.render(opts, Template, template,
        user_input: unit.user_messages,
        assistant_messages: unit.assistant_messages,
        tools_called: unit.tools_called,
        available_tools: unit.available_tools
      )

    case Adapter.generate_with_schema(prompt, Schema.score_schema(), opts) do
      {:ok, response} -> Schema.parse_score(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's _calculate_score: the lower of the two means, each 0.0
  # without scores.
  defp calculate_score(selection_scores, argument_scores, threshold, opts) do
    score = min(mean(selection_scores), mean(argument_scores))
    BaseMetric.strict_score(score, Keyword.put(opts, :threshold, threshold))
  end

  defp mean([]), do: 0.0
  defp mean(scores), do: (scores |> Enum.map(& &1.score) |> Enum.sum()) / length(scores)

  # deepeval's _generate_reason_for_tool_selection, which its
  # _generate_reason_for_argument_correctness repeats, template included.
  defp generate_reason(scores, score, threshold, opts) do
    prompt =
      EvaluationTemplate.render(opts, Template, :get_tool_selection_final_reason,
        all_scores_and_reasons:
          Enum.map_join(scores, &"\nScore: #{Python.repr(&1.score)} \nReason: #{&1.reason} \n"),
        final_score: score,
        threshold: threshold
      )

    case Adapter.generate_with_schema(prompt, Schema.reason_schema(), opts) do
      {:ok, response} -> Schema.parse_reason(response)
      {:error, _} = error -> error
    end
  end

  # deepeval's ToolSelectionScore and ArgumentCorrectnessScore models.
  defp prettify_scores(scores),
    do:
      scores
      |> Enum.map(&OrderedObject.new(score: &1.score, reason: &1.reason))
      |> Verbose.prettify_list()
end
