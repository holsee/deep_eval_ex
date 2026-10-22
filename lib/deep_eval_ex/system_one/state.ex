defmodule DeepEvalEx.SystemOne.State do
  @moduledoc """
  The JSON state a whole-metric System One request is about, ports of
  deepeval 4.3.1's `construct_single_turn_state`,
  `construct_multi_turn_state`, `_field` and `_jsonable`
  (`deepeval/metrics/jev_eval/utils.py`,
  `deepeval/metrics/utils/decision.py`) and of the state half of
  `_request_for` (`deepeval/metrics/utils/system_one.py`).

  `build/2` sends a test case as `{"test_case": {field: value, ...}}`, in
  the order of the spec's `evaluation_params`, and a conversational test
  case as `{"turns": [...], "test_case": {...}}` (`multi_turn/2`, deepeval's
  `construct_multi_turn_state`), then the spec's `extra_state`. Objects are
  `Jason.OrderedObject`s, so the state is encoded in the order deepeval's
  dicts are.
  """

  alias DeepEvalEx.{ConversationalTestCase, TestCase}
  alias DeepEvalEx.Metrics.Utils.Turns
  alias DeepEvalEx.SystemOne.{Dumpable, EvalSpec}
  alias Jason.OrderedObject

  # deepeval's _TURN_LEVEL_PARAMS, but for the MCP params DeepEvalEx does
  # not port.
  @turn_level_params [:role, :content, :retrieval_context, :tools_called]

  @doc """
  The state of `spec` for `test_case`: `"test_case"` holds the populated
  `evaluation_params` fields (`single_turn/2`) and is left out when none
  is, then each non-`nil` `extra_state` value, dumped, under its key
  (replacing `"test_case"` in place if named so, as Python's dict does).

  ## Examples

      iex> spec = %DeepEvalEx.SystemOne.EvalSpec{
      ...>   evaluation_params: [:input, :expected_output],
      ...>   extra_state: [relevant_topics: ["billing"], unused: nil]
      ...> }
      iex> state = DeepEvalEx.SystemOne.State.build(spec, %DeepEvalEx.TestCase{input: "Q"})
      iex> DeepEvalEx.TestRun.JSON.encode!(state)
      ~s({"test_case": {"input": "Q"}, "relevant_topics": ["billing"]})
  """
  @spec build(EvalSpec.t(), TestCase.t() | ConversationalTestCase.t()) :: OrderedObject.t()
  def build(%EvalSpec{} = spec, %TestCase{} = test_case) do
    %OrderedObject{values: [{"test_case", fields}]} =
      single_turn(spec.evaluation_params, test_case)

    base = if fields.values == [], do: [], else: [{"test_case", fields}]
    put_extra_state(base, spec)
  end

  def build(%EvalSpec{} = spec, %ConversationalTestCase{} = test_case) do
    %OrderedObject{values: base} = multi_turn(spec.evaluation_params, test_case)
    put_extra_state(base, spec)
  end

  defp put_extra_state(base, spec) do
    spec.extra_state
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce(base, fn {key, value}, values ->
      key = to_string(key)
      put(values, key, dump(value))
    end)
    |> OrderedObject.new()
  end

  @doc """
  `a` and `b` as one state, or `nil` when they give the same top-level key
  different values, deepeval's `_merge_states`
  (`deepeval/metrics/utils/system_one_batch.py`), which merges the states
  of a batched request.

  `"test_case"` fields always merge, `b`'s after `a`'s, and so do each
  turn's fields under `"turns"`: both states were built from the same test
  case. Keys keep their order, `b`'s new keys after `a`'s.

  ## Examples

      iex> alias Jason.OrderedObject
      iex> a = OrderedObject.new([{"test_case", OrderedObject.new([{"input", "Q"}])}])
      iex> b = OrderedObject.new([{"test_case", OrderedObject.new([{"actual_output", "A"}])}, {"topics", ["x"]}])
      iex> DeepEvalEx.TestRun.JSON.encode!(DeepEvalEx.SystemOne.State.merge(a, b))
      ~s({"test_case": {"input": "Q", "actual_output": "A"}, "topics": ["x"]})

      iex> alias Jason.OrderedObject
      iex> DeepEvalEx.SystemOne.State.merge(OrderedObject.new([{"topics", ["x"]}]), OrderedObject.new([{"topics", ["y"]}]))
      nil
  """
  @spec merge(OrderedObject.t(), OrderedObject.t()) :: OrderedObject.t() | nil
  def merge(%OrderedObject{values: a}, %OrderedObject{values: b}) do
    case Enum.reduce_while(b, a, &merge_key/2) do
      nil -> nil
      values -> OrderedObject.new(values)
    end
  end

  defp merge_key({key, value}, merged) do
    case List.keyfind(merged, key, 0) do
      nil -> {:cont, merged ++ [{key, value}]}
      {"test_case", mine} -> {:cont, put(merged, key, merge_fields(mine, value))}
      {"turns", mine} -> {:cont, put(merged, key, merge_turns(mine, value))}
      {_key, mine} -> if same?(mine, value), do: {:cont, merged}, else: {:halt, nil}
    end
  end

  # Python's {**mine, **theirs}.
  defp merge_fields(%OrderedObject{values: mine}, %OrderedObject{values: theirs}),
    do:
      OrderedObject.new(
        Enum.reduce(theirs, mine, fn {key, value}, acc -> put(acc, key, value) end)
      )

  # Python's [{**mine, **theirs} for mine, theirs in zip(...)].
  defp merge_turns(mine, theirs) when is_list(mine) and is_list(theirs),
    do: Enum.zip_with(mine, theirs, &merge_fields/2)

  # Python's dict equality ignores key order.
  defp same?(a, b), do: plain(a) == plain(b)

  defp plain(%OrderedObject{values: values}), do: Map.new(values, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  defp plain(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, plain(v)} end)

  defp plain(value), do: value

  @doc """
  A single-turn test case's state, deepeval's `construct_single_turn_state`:
  `{"test_case": {param: value}}` for each of `params` whose field is
  populated (not `nil`, `""`, `[]` or an empty map), in order, each value
  dumped with `dump/1`.

  ## Examples

      iex> test_case = %DeepEvalEx.TestCase{input: "Q", actual_output: "", retrieval_context: ["A"]}
      iex> state = DeepEvalEx.SystemOne.State.single_turn([:retrieval_context, :actual_output, :input], test_case)
      iex> DeepEvalEx.TestRun.JSON.encode!(state)
      ~s({"test_case": {"retrieval_context": ["A"], "input": "Q"}})
  """
  @spec single_turn([atom() | String.t()], TestCase.t()) :: OrderedObject.t()
  def single_turn(params, %TestCase{} = test_case) when is_list(params) do
    fields =
      for param <- params,
          value <- [field(test_case, param)],
          populated?(value),
          do: {to_string(param), dump(value)}

    OrderedObject.new([{"test_case", OrderedObject.new(fields)}])
  end

  @doc """
  A conversational test case's state, deepeval's
  `construct_multi_turn_state`: `{"turns": [...]}`, each turn's fields among
  `params` that name a turn field (`:role`, `:content`,
  `:retrieval_context` and `:tools_called`, in the order of `params`, unset
  ones left out, see
  `DeepEvalEx.Metrics.Utils.Turns.convert_turn_to_dict/2`), then, when any
  is populated, `"test_case"` with the other params' fields (`:scenario`,
  `:expected_outcome`, ...), as `single_turn/2` sends them. Every value is
  dumped with `dump/1`.

  ## Examples

      iex> test_case = DeepEvalEx.ConversationalTestCase.new!(
      ...>   scenario: "Refund",
      ...>   turns: [%{role: :user, content: "Hi"}, %{role: :assistant, content: "Hello!"}]
      ...> )
      iex> state = DeepEvalEx.SystemOne.State.multi_turn([:content, :role, :scenario, :tags], test_case)
      iex> DeepEvalEx.TestRun.JSON.encode!(state)
      ~s({"turns": [{"content": "Hi", "role": "user"}, {"content": "Hello!", "role": "assistant"}], "test_case": {"scenario": "Refund"}})
  """
  @spec multi_turn([atom()], ConversationalTestCase.t()) :: OrderedObject.t()
  def multi_turn(params, %ConversationalTestCase{} = test_case) when is_list(params) do
    turn_params = Enum.filter(params, &(&1 in @turn_level_params))

    turns =
      Enum.map(test_case.turns, fn turn ->
        turn |> Turns.convert_turn_to_dict(turn_params) |> dump()
      end)

    fields =
      for param <- params,
          param not in @turn_level_params,
          value <- [field(test_case, param)],
          populated?(value),
          do: {to_string(param), dump(value)}

    case fields do
      [] -> OrderedObject.new([{"turns", turns}])
      fields -> OrderedObject.new([{"turns", turns}, {"test_case", OrderedObject.new(fields)}])
    end
  end

  @doc """
  A value as a System One state sends it, deepeval's `_field` then
  `_jsonable`:

  - `nil`, strings, numbers and booleans as they are
  - other atoms as their name
  - lists and tuples as lists, each element dumped
  - maps with their keys as strings, and `Jason.OrderedObject`s in order,
    each value dumped
  - other structs through `DeepEvalEx.SystemOne.Dumpable`

  ## Examples

      iex> tool = %DeepEvalEx.Schemas.ToolCall{name: "search", input_parameters: %{"q" => "x"}}
      iex> DeepEvalEx.TestRun.JSON.encode!(DeepEvalEx.SystemOne.State.dump([tool]))
      ~s([{"name": "search", "type": "FUNCTION", "input_parameters": {"q": "x"}}])
  """
  @spec dump(term()) :: term()
  def dump(value)
      when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value),
      do: value

  def dump(value) when is_atom(value), do: Atom.to_string(value)
  def dump(value) when is_list(value), do: Enum.map(value, &dump/1)
  def dump(value) when is_tuple(value), do: value |> Tuple.to_list() |> dump()

  def dump(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, do: {key_string(key), dump(value)})

  def dump(value) when is_struct(value), do: value |> Dumpable.dump() |> dump()

  def dump(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key_string(key), dump(value)} end)

  def dump(value), do: inspect(value)

  # deepeval's _is_populated.
  defp populated?(nil), do: false
  defp populated?(""), do: false
  defp populated?([]), do: false
  defp populated?(%OrderedObject{values: []}), do: false
  defp populated?(value) when is_map(value) and not is_struct(value), do: map_size(value) > 0
  defp populated?(_value), do: true

  defp field(test_case, param) when is_atom(param), do: Map.get(test_case, param)

  defp field(test_case, param) when is_binary(param) do
    case Enum.find(Map.from_struct(test_case), fn {key, _value} ->
           Atom.to_string(key) == param
         end) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key |> dump() |> to_string()

  # Python's state[key] = value: an existing key keeps its place.
  defp put(values, key, value) do
    if List.keymember?(values, key, 0),
      do: List.keyreplace(values, key, 0, {key, value}),
      else: values ++ [{key, value}]
  end
end
