# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/utils/turns.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.Turns do
  @moduledoc """
  Multi-turn helpers shared by the conversational metrics, deepeval 4.3.1's
  `metrics/utils/turns.py`.

  - `convert_turn_to_dict/2` - the fields of a `DeepEvalEx.Turn` that a
    metric's prompt (or System One state) shows
  - `format_turns/2` - the same for a list of `DeepEvalEx.TestCase`s
  - `get_turns_in_sliding_window/2` - the window of turns that ends at each
    turn
  - `get_unit_interactions/1` - a conversation split into user/assistant
    exchanges

  The dicts are `Jason.OrderedObject`s with deepeval's keys (strings) in
  deepeval's order, so `DeepEvalEx.Prompts.Python.repr/1` and `Jason`
  print them as deepeval does. Values are kept as they are (a turn's tool
  calls as `DeepEvalEx.Schemas.ToolCall`s, for example), except a turn's
  role, which is the string deepeval stores.

  ## Examples

      iex> alias DeepEvalEx.Metrics.Utils.Turns
      iex> turns = [
      ...>   DeepEvalEx.Turn.new!(role: :user, content: "Hi"),
      ...>   DeepEvalEx.Turn.new!(role: :assistant, content: "Hello!")
      ...> ]
      iex> turns |> hd() |> Turns.convert_turn_to_dict() |> DeepEvalEx.Prompts.Python.repr()
      "{'content': 'Hi', 'role': 'user'}"
      iex> turns |> Turns.get_unit_interactions() |> length()
      1
  """

  alias DeepEvalEx.Params.{MultiTurn, SingleTurn}
  alias DeepEvalEx.{TestCase, Turn}
  alias Jason.OrderedObject

  # The multi-turn params that name a field of a turn. deepeval skips the
  # case-level params (scenario, expected outcome, metadata, tags, audio) and
  # those its Turn has no attribute for; DeepEvalEx's Turn has no MCP
  # fields, which deepeval would skip anyway when unset.
  @turn_params [:role, :content, :provider_transcript, :retrieval_context, :tools_called]

  @default_turn_params [:content, :role]

  @doc """
  The given params of each test case, deepeval's `format_turns`: one
  `Jason.OrderedObject` per test case, keyed by param name in the order of
  `params`, with only the params whose value Python considers truthy (not
  `nil`, `""`, `[]`, `%{}`, `false` or zero).

  Raises `ArgumentError` for a param that is not a
  `DeepEvalEx.Params.SingleTurn` param.
  """
  @spec format_turns([TestCase.t()], [SingleTurn.t()]) :: [OrderedObject.t()]
  def format_turns(test_cases, params) when is_list(test_cases) and is_list(params) do
    Enum.each(params, &check_param!(&1, SingleTurn, "single-turn"))

    Enum.map(test_cases, &format_test_case(&1, params))
  end

  defp format_test_case(%TestCase{} = test_case, params) do
    params
    |> Enum.map(&{Atom.to_string(&1), Map.get(test_case, &1)})
    |> Enum.filter(fn {_key, value} -> truthy?(value) end)
    |> OrderedObject.new()
  end

  @doc """
  The given params of `turn`, deepeval's `convert_turn_to_dict`: a
  `Jason.OrderedObject` keyed by param name in the order of `params`
  (by default `[:content, :role]`).

  Params that do not name a turn field (`:scenario`, `:expected_outcome`,
  `:metadata`, `:tags`, `:audio` and the other case-level params) are
  skipped, as are fields that are `nil`; an empty string or list is kept.

  Raises `ArgumentError` for a param that is not a
  `DeepEvalEx.Params.MultiTurn` param.
  """
  @spec convert_turn_to_dict(Turn.t(), [MultiTurn.t()] | nil) :: OrderedObject.t()
  def convert_turn_to_dict(%Turn{} = turn, params \\ nil) do
    params = params || @default_turn_params
    Enum.each(params, &check_param!(&1, MultiTurn, "multi-turn"))

    params
    |> Enum.filter(&(&1 in @turn_params))
    |> Enum.flat_map(fn param ->
      case Map.fetch!(turn, param) do
        nil -> []
        value -> [{Atom.to_string(param), turn_value(param, value)}]
      end
    end)
    |> OrderedObject.new()
  end

  @doc """
  For each turn, the window of at most `window_size` turns that ends at it,
  deepeval's `get_turns_in_sliding_window`: windows start at the first turn
  until they are `window_size` long.

  deepeval yields the windows from a generator; this returns them as a
  list. As Python's slicing, a `window_size` below one gives empty windows.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.Turns.get_turns_in_sliding_window([1, 2, 3], 2)
      [[1], [1, 2], [2, 3]]
  """
  @spec get_turns_in_sliding_window([turn], integer()) :: [[turn]] when turn: term()
  def get_turns_in_sliding_window(turns, window_size)
      when is_list(turns) and is_integer(window_size) do
    turns
    |> Enum.with_index()
    |> Enum.map(fn {_turn, index} ->
      Enum.slice(turns, max(0, index - window_size + 1)..index//1)
    end)
  end

  @doc """
  The conversation's unit interactions, deepeval's `get_unit_interactions`:
  runs of turns that each end with the assistant answering the user.

  A unit ends where a user turn follows an assistant turn, once the unit
  has a user turn; turns before the first user turn join the first unit. A
  trailing run of turns that has no user turn, or does not end with the
  assistant, is dropped.
  """
  @spec get_unit_interactions([Turn.t()]) :: [[Turn.t()]]
  def get_unit_interactions(turns) when is_list(turns) do
    {units, current, has_user} =
      Enum.reduce(turns, {[], [], false}, fn %Turn{role: role} = turn,
                                             {units, current, has_user} ->
        case current do
          # current is reversed: its head is the last turn
          [%Turn{role: :assistant} | _] when role == :user and has_user ->
            {[Enum.reverse(current) | units], [turn], true}

          _ ->
            {units, [turn | current], has_user or role == :user}
        end
      end)

    units =
      case current do
        [%Turn{role: :assistant}, _ | _] when has_user -> [Enum.reverse(current) | units]
        _ -> units
      end

    Enum.reverse(units)
  end

  defp check_param!(param, params_module, kind) do
    unless params_module.member?(param) do
      raise ArgumentError, "expected a #{kind} param, got: #{inspect(param)}"
    end
  end

  defp turn_value(:role, role), do: Atom.to_string(role)
  defp turn_value(_param, value), do: value

  # Python's truthiness, for deepeval's `if value:`
  defp truthy?(value) when value in [nil, false, "", []], do: false
  defp truthy?(value) when is_number(value) and value == 0, do: false
  defp truthy?(value) when is_map(value) and map_size(value) == 0, do: false
  defp truthy?(_value), do: true
end
