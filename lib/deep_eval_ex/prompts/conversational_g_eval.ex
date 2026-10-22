# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/metrics/conversational_g_eval/templates/*.txt and
# deepeval/metrics/g_eval/utils.py), Copyright Confident AI, Apache-2.0.
# Original: https://github.com/confident-ai/deepeval
#
# test/deep_eval_ex/prompt_golden_test.exs checks every byte of the
# prompts against deepeval's.

defmodule DeepEvalEx.Prompts.ConversationalGEval do
  @moduledoc """
  Prompt templates for the `DeepEvalEx.Metrics.ConversationalGEval` metric.

  Each prompt function renders deepeval 4.3.1's `ConversationalGEval`
  template of the same name byte for byte. The `format_*` helpers build the
  template arguments as deepeval's
  `construct_conversational_g_eval_turn_params_string`,
  `construct_non_turns_test_case_string` and `format_rubrics` do; the
  evaluation steps are numbered as `DeepEvalEx.Prompts.GEval.format_evaluation_steps/1`
  numbers them.

  ## Examples

      iex> DeepEvalEx.Prompts.ConversationalGEval.format_params([:scenario, :content, :role])
      "Scenario, Content, and Role"
  """

  use DeepEvalEx.Prompts.EvaluationTemplate,
    templates: [
      generate_evaluation_steps: 1,
      generate_evaluation_results: 1
    ]

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Params.MultiTurn
  alias DeepEvalEx.Prompts.GEval
  alias DeepEvalEx.Prompts.Python

  # The params deepeval prints per turn rather than for the conversation.
  @turn_params [:retrieval_context, :tools_called, :content, :role, :audio]

  @doc """
  Generates a prompt to create evaluation steps from criteria.

  ## Options

  - `:criteria` - the evaluation criteria (required)
  - `:parameters` - the evaluated params, as `format_params/1` (required)
  """
  def generate_evaluation_steps(opts) do
    criteria = Keyword.fetch!(opts, :criteria)
    parameters = Keyword.fetch!(opts, :parameters)

    """
    Given an evaluation criteria which outlines how you should judge a conversation between a user and an LLM chatbot using the #{parameters} fields, generate 3-4 concise evaluation steps based on the criteria below.

    Note that #{parameters} can include both turn-level fields (e.g. content, role, retrieval_context, tools_called) and conversation-level fields (e.g. scenario, expected_outcome, metadata, tags, context, chatbot_role, user_description). Evaluate each field at its correct scope: turn-level fields appear once per turn, while conversation-level fields apply to the conversation as a whole and should NOT be expected to repeat on every turn.

    Based on the evaluation criteria, you MUST make it clear how to evaluate the #{parameters} together to assess both each turn and the overall quality of the conversation.

    Evaluation Criteria:
    #{criteria}

    **
    IMPORTANT: Please make sure to only return in JSON format, with the "steps" key as a list of strings. No words or explanation is needed.
    Example JSON:
    {
      "steps": <list_of_strings>
    }
    **

    JSON:\
    """
  end

  @doc """
  Generates a prompt scoring the conversation from 0 to 10 with the
  evaluation steps and an optional rubric.

  ## Options

  - `:evaluation_steps` - the steps, a list or as
    `DeepEvalEx.Prompts.GEval.format_evaluation_steps/1` (required)
  - `:turns` - each turn's evaluated fields, as
    `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2` returns them,
    printed as Python prints the list (required)
  - `:test_case_content` - as `format_test_case_content/2` (required)
  - `:parameters` - as `format_params/1` (required)
  - `:rubric` - as `format_rubric/1`, or `nil` (default: `nil`)
  """
  def generate_evaluation_results(opts) do
    evaluation_steps =
      opts |> Keyword.fetch!(:evaluation_steps) |> GEval.format_evaluation_steps()

    turns = opts |> Keyword.fetch!(:turns) |> Python.repr()
    test_case_content = Keyword.fetch!(opts, :test_case_content)
    parameters = Keyword.fetch!(opts, :parameters)
    rubric = Keyword.get(opts, :rubric)

    {dependencies, follows, references, rubric_section} =
      if rubric do
        {"Evaluation Steps and Rubric", "the rubric and evaluation steps",
         "both the rubric and the evaluation steps", "Rubric:\n#{rubric}\n\n"}
      else
        {"Evaluation Steps", "the evaluation steps", "the evaluation steps", ""}
      end

    """
    You are given a set of #{dependencies} that describe how to assess a conversation between a user and an LLM chatbot. Your task is to return a JSON object with exactly two fields:

    1. `"score"`: An integer from 0 to 10 (inclusive), where:
    - 10 = The conversation *fully* meets the criteria described in the Evaluation Steps
    - 0 = The conversation *completely fails* to meet the criteria
    - All other scores represent varying degrees of partial fulfillment,
    based on how well the conversation follows #{follows}.

    2. `"reason"`: A **concise but precise** explanation for the score. Your reasoning must reference specific aspects of #{references}, and mention relevant details from the conversation and the given parameters. DO NOT include the score value in your explanation.

    Evaluation Steps:
    #{evaluation_steps}

    #{rubric_section}Per-turn fields:
    #{turns}

    #{test_case_content}
    Parameters to consider during evaluation:
    #{parameters}

    Note: the "Per-turn fields" block lists each turn separately, while the "Conversation-level fields" block applies to the whole conversation. Do not penalize individual turns for missing conversation-level fields.

    ---
    IMPORTANT: You MUST return only a valid JSON object with the exact keys `"score"` and `"reason"`. No additional text, commentary, or formatting.

    ---
    Example JSON:
    {
      "reason": "Your concise and informative reason here.",
      "score": 0
    }

    JSON:\
    """
  end

  @doc """
  Formats the params as deepeval's
  `construct_conversational_g_eval_turn_params_string`: `"A"`, `"A and B"`,
  `"A, B, and C"`, each param named as
  `DeepEvalEx.Params.MultiTurn.display_name/1` names it.

  Raises `ArgumentError` for a param deepeval gives no name.

  ## Examples

      iex> DeepEvalEx.Prompts.ConversationalGEval.format_params([:content, :role])
      "Content and Role"
  """
  @spec format_params([MultiTurn.t()]) :: String.t()
  def format_params(params) when is_list(params) do
    case Enum.map(params, &display_name!/1) do
      [name] -> name
      [first, second] -> "#{first} and #{second}"
      names -> "#{names |> Enum.drop(-1) |> Enum.join(", ")}, and #{List.last(names)}"
    end
  end

  @doc """
  Formats the conversation-level params of `params` for the prompt, as
  deepeval's `construct_non_turns_test_case_string`: under a
  `"Conversation-level fields:"` heading, each param as its name, a
  newline, then its value followed by a space and a blank line; `""` when
  every param is a per-turn one (`:content`, `:role`, `:retrieval_context`,
  `:tools_called`, `:audio`).

  Values are printed as Python's `str()` prints them: strings as they are,
  lists and dicts (tags, metadata) as Python's, `nil` as `None`.

  ## Examples

      iex> test_case = DeepEvalEx.ConversationalTestCase.new!(
      ...>   scenario: "A refund.",
      ...>   turns: [%{role: :user, content: "Hi"}]
      ...> )
      iex> DeepEvalEx.Prompts.ConversationalGEval.format_test_case_content(test_case, [:scenario, :content])
      "Conversation-level fields:\\nScenario:\\nA refund. \\n\\n"
  """
  @spec format_test_case_content(ConversationalTestCase.t(), [MultiTurn.t()]) :: String.t()
  def format_test_case_content(%ConversationalTestCase{} = test_case, params) do
    case Enum.reject(params, &(&1 in @turn_params)) do
      [] ->
        ""

      params ->
        body =
          Enum.map_join(params, fn param ->
            "#{display_name!(param)}:\n#{format_value(Map.fetch!(test_case, param))} \n\n"
          end)

        "Conversation-level fields:\n" <> body
    end
  end

  @doc """
  Formats a rubric for the prompt, as deepeval's `format_rubrics` (see
  `DeepEvalEx.Metrics.GEval.Rubric.format/1`). `nil` stays `nil`.
  """
  @spec format_rubric([Rubric.t()] | nil) :: String.t() | nil
  defdelegate format_rubric(rubric), to: Rubric, as: :format

  defp display_name!(param) do
    MultiTurn.display_name(param) ||
      raise ArgumentError,
            "conversational G-Eval cannot name #{inspect(param)}: deepeval's " <>
              "CONVERSATIONAL_G_EVAL_PARAMS has no name for it"
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Python.repr(value)
end
