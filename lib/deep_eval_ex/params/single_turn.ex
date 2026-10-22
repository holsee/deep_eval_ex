defmodule DeepEvalEx.Params.SingleTurn do
  @moduledoc """
  The single-turn test case params, as deepeval 4.3.1's `SingleTurnParams`
  (formerly `LLMTestCaseParams`).

  Each param is the `DeepEvalEx.TestCase` field it names, as an atom:

  | Param                   | deepeval member          | Display name        |
  | ----------------------- | ------------------------ | ------------------- |
  | `:input`                | `INPUT`                  | `Input`             |
  | `:actual_output`        | `ACTUAL_OUTPUT`          | `Actual Output`     |
  | `:expected_output`      | `EXPECTED_OUTPUT`        | `Expected Output`   |
  | `:context`              | `CONTEXT`                | `Context`           |
  | `:retrieval_context`    | `RETRIEVAL_CONTEXT`      | `Retrieval Context` |
  | `:metadata`             | `METADATA`               | `Metadata`          |
  | `:tags`                 | `TAGS`                   | `Tags`              |
  | `:tools_called`         | `TOOLS_CALLED`           | `Tools Called`      |
  | `:expected_tools`       | `EXPECTED_TOOLS`         | `Expected Tools`    |
  | `:mcp_servers`          | `MCP_SERVERS`            |                     |
  | `:mcp_tools_called`     | `MCP_TOOLS_CALLED`       |                     |
  | `:mcp_resources_called` | `MCP_RESOURCES_CALLED`   |                     |
  | `:mcp_prompts_called`   | `MCP_PROMPTS_CALLED`     |                     |

  The display names are deepeval's `G_EVAL_PARAMS`, which name the params in
  `DeepEvalEx.Metrics.GEval`'s prompts. deepeval gives the MCP params none.
  DeepEvalEx does not port deepeval's MCP fields yet; they are listed so the
  set matches deepeval's.
  """

  @type t ::
          :input
          | :actual_output
          | :expected_output
          | :context
          | :retrieval_context
          | :metadata
          | :tags
          | :tools_called
          | :expected_tools
          | :mcp_servers
          | :mcp_tools_called
          | :mcp_resources_called
          | :mcp_prompts_called

  @params [
    :input,
    :actual_output,
    :expected_output,
    :context,
    :retrieval_context,
    :metadata,
    :tags,
    :tools_called,
    :expected_tools,
    :mcp_servers,
    :mcp_tools_called,
    :mcp_resources_called,
    :mcp_prompts_called
  ]

  @display_names %{
    input: "Input",
    actual_output: "Actual Output",
    expected_output: "Expected Output",
    context: "Context",
    retrieval_context: "Retrieval Context",
    metadata: "Metadata",
    tags: "Tags",
    expected_tools: "Expected Tools",
    tools_called: "Tools Called"
  }

  @doc """
  Returns every single-turn param, in deepeval's order.
  """
  @spec all() :: [t()]
  def all, do: @params

  @doc """
  Returns whether `param` is a single-turn param.

  ## Examples

      iex> DeepEvalEx.Params.SingleTurn.member?(:retrieval_context)
      true

      iex> DeepEvalEx.Params.SingleTurn.member?(:name)
      false
  """
  @spec member?(term()) :: boolean()
  def member?(param), do: param in @params

  @doc """
  Returns the name deepeval's GEval prompts give `param`, or `nil` when
  deepeval gives it none.

  ## Examples

      iex> DeepEvalEx.Params.SingleTurn.display_name(:tools_called)
      "Tools Called"

      iex> DeepEvalEx.Params.SingleTurn.display_name(:mcp_servers)
      nil
  """
  @spec display_name(term()) :: String.t() | nil
  def display_name(param), do: Map.get(@display_names, param)
end
