defmodule DeepEvalEx.Params.MultiTurn do
  @moduledoc """
  The multi-turn test case params, as deepeval 4.3.1's `MultiTurnParams`
  (formerly `TurnParams`).

  Each param is the `DeepEvalEx.Turn` or `DeepEvalEx.ConversationalTestCase`
  field it names, as an atom:

  | Param                   | deepeval member         | Display name        |
  | ----------------------- | ----------------------- | ------------------- |
  | `:role`                 | `ROLE`                  | `Role`              |
  | `:content`              | `CONTENT`               | `Content`           |
  | `:provider_transcript`  | `PROVIDER_TRANSCRIPT`   |                     |
  | `:audio`                | `AUDIO`                 | `Audio`             |
  | `:metadata`             | `METADATA`              | `Metadata`          |
  | `:tags`                 | `TAGS`                  | `Tags`              |
  | `:scenario`             | `SCENARIO`              | `Scenario`          |
  | `:expected_outcome`     | `EXPECTED_OUTCOME`      | `Expected Outcome`  |
  | `:context`              | `CONTEXT`               |                     |
  | `:user_description`     | `USER_DESCRIPTION`      |                     |
  | `:retrieval_context`    | `RETRIEVAL_CONTEXT`     | `Retrieval Context` |
  | `:chatbot_role`         | `CHATBOT_ROLE`          |                     |
  | `:tools_called`         | `TOOLS_CALLED`          | `Tools Called`      |
  | `:mcp_tools_called`     | `MCP_TOOLS`             |                     |
  | `:mcp_resources_called` | `MCP_RESOURCES`         |                     |
  | `:mcp_prompts_called`   | `MCP_PROMPTS`           |                     |

  The display names are deepeval's `CONVERSATIONAL_G_EVAL_PARAMS`, which
  name the params in conversational G-Eval prompts; deepeval gives the
  others none. DeepEvalEx does not port deepeval's MCP fields yet; they are
  listed so the set matches deepeval's.
  """

  @type t ::
          :role
          | :content
          | :provider_transcript
          | :audio
          | :metadata
          | :tags
          | :scenario
          | :expected_outcome
          | :context
          | :user_description
          | :retrieval_context
          | :chatbot_role
          | :tools_called
          | :mcp_tools_called
          | :mcp_resources_called
          | :mcp_prompts_called

  @params [
    :role,
    :content,
    :provider_transcript,
    :audio,
    :metadata,
    :tags,
    :scenario,
    :expected_outcome,
    :context,
    :user_description,
    :retrieval_context,
    :chatbot_role,
    :tools_called,
    :mcp_tools_called,
    :mcp_resources_called,
    :mcp_prompts_called
  ]

  @display_names %{
    content: "Content",
    role: "Role",
    metadata: "Metadata",
    tags: "Tags",
    tools_called: "Tools Called",
    retrieval_context: "Retrieval Context",
    expected_outcome: "Expected Outcome",
    scenario: "Scenario",
    audio: "Audio"
  }

  @doc """
  Returns every multi-turn param, in deepeval's order.
  """
  @spec all() :: [t()]
  def all, do: @params

  @doc """
  Returns whether `param` is a multi-turn param.

  ## Examples

      iex> DeepEvalEx.Params.MultiTurn.member?(:expected_outcome)
      true

      iex> DeepEvalEx.Params.MultiTurn.member?(:input)
      false
  """
  @spec member?(term()) :: boolean()
  def member?(param), do: param in @params

  @doc """
  Returns the name deepeval's conversational G-Eval prompts give `param`,
  or `nil` when deepeval gives it none.

  ## Examples

      iex> DeepEvalEx.Params.MultiTurn.display_name(:expected_outcome)
      "Expected Outcome"

      iex> DeepEvalEx.Params.MultiTurn.display_name(:chatbot_role)
      nil
  """
  @spec display_name(term()) :: String.t() | nil
  def display_name(param), do: Map.get(@display_names, param)
end
