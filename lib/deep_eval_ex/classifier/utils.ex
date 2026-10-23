# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/classifiers/utils.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Classifier.Utils do
  @moduledoc """
  Labels, test case content and run-level validation for
  `DeepEvalEx.Classifier`, deepeval 4.3.1's `classifiers/utils.py`.

  - `normalize_labels!/1`, `resolve_label/3` and `format_labels/1` handle a
    classifier's closed label set and the judge's answer
  - `single_turn_content/1`, `multi_turn_content/1` and `turns/1` print a
    test case into the `:llm` prompt; `single_turn_state/1` and
    `multi_turn_state/1` build the `:system_one` state from the same
    fields
  - `validate!/2` checks a run's classifiers against its test cases before
    any judge call, deepeval's `validate_classifiers`

  Errors deepeval raises as `ValueError` raise `ArgumentError` with
  deepeval's message.
  """

  require Logger

  alias DeepEvalEx.{Classifier, ConversationalTestCase, TestCase}
  alias DeepEvalEx.Metrics.Utils.Turns
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Prompts.Python.EnumMember
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias Jason.OrderedObject

  @none "NONE"

  # deepeval's _SINGLE_TURN_CONTENT_PARAMS, in order: every populated field
  # is shown to the judge.
  @single_turn_params [
    input: "Input",
    actual_output: "Actual Output",
    expected_output: "Expected Output",
    context: "Context",
    retrieval_context: "Retrieval Context",
    tools_called: "Tools Called",
    expected_tools: "Expected Tools"
  ]

  # deepeval's _MULTI_TURN_CONTENT_PARAMS.
  @multi_turn_params [
    scenario: "Scenario",
    expected_outcome: "Expected Outcome",
    user_description: "User Description",
    context: "Context",
    chatbot_role: "Chatbot Role"
  ]

  # deepeval's _TURN_PARAMS.
  @turn_params [:role, :content, :retrieval_context, :tools_called]

  @no_fields "Cannot classify an LLMTestCase with no populated fields (input, actual_output, " <>
               "expected_output, context, retrieval_context, tools_called, expected_tools)."

  @doc """
  The label name a judge uses to decline to classify, deepeval's
  `NONE_LABEL`. A classifier cannot declare it.
  """
  @spec none_label() :: String.t()
  def none_label, do: @none

  @doc """
  Normalizes `labels` into `{name, description}` pairs, deepeval's
  `normalize_labels`.

  A label is a name (a string), a `{name, description}` tuple, or a map
  with `:name` and `:description` (atom or string keys), the description
  optional. Raises `ArgumentError` when there are no labels, a name is
  blank, a name is `NONE` in any case (reserved for `allow_none`), or two
  names are equal ignoring case.

  ## Examples

      iex> DeepEvalEx.Classifier.Utils.normalize_labels!(["yes", {"no", "It does not."}])
      [{"yes", nil}, {"no", "It does not."}]
  """
  @spec normalize_labels!([term()]) :: [Classifier.label()]
  def normalize_labels!(labels) when labels in [nil, []],
    do: raise(ArgumentError, "A classifier needs at least one label.")

  def normalize_labels!(labels) when is_list(labels) do
    labels = Enum.map(labels, &label!/1)

    for {name, _description} <- labels do
      if String.trim(name) == "", do: raise(ArgumentError, "Label names cannot be empty.")

      if name |> String.trim() |> String.upcase() == @none do
        raise ArgumentError,
              "'#{name}' cannot be used as a label name. If you want a 'no classification' " <>
                "outcome, set allow_none=True instead."
      end
    end

    duplicates =
      labels
      |> Enum.frequencies_by(fn {name, _} -> name |> String.trim() |> String.downcase() end)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [] do
      raise ArgumentError, "Duplicate labels (case-insensitive): #{Enum.join(duplicates, ", ")}."
    end

    labels
  end

  defp label!(name) when is_binary(name), do: {name, nil}

  defp label!({name, description})
       when is_binary(name) and (is_binary(description) or is_nil(description)),
       do: {name, description}

  defp label!(%{} = label) when not is_struct(label) do
    name = Map.get(label, :name, Map.get(label, "name"))
    label!({name, Map.get(label, :description, Map.get(label, "description"))})
  end

  defp label!(other) do
    raise ArgumentError,
          "Labels must be a string, a {name, description} tuple or a map, got: " <>
            inspect(other)
  end

  @doc """
  Maps the judge's raw answer onto a declared label name, deepeval's
  `resolve_label`: the answer, trimmed, as written, then ignoring case.

  Returns `"NONE"` when the judge declined to classify (`NONE` in any case)
  and `allow_none` permits it, and `nil` when the answer matches nothing, so
  the caller records an error instead of inventing a label.

  ## Examples

      iex> labels = [{"refused", nil}, {"complied", nil}]
      iex> DeepEvalEx.Classifier.Utils.resolve_label(" REFUSED ", labels, false)
      "refused"
      iex> DeepEvalEx.Classifier.Utils.resolve_label("none", labels, true)
      "NONE"
      iex> DeepEvalEx.Classifier.Utils.resolve_label("none", labels, false)
      nil
  """
  @spec resolve_label(term(), [Classifier.label()], boolean()) :: String.t() | nil
  def resolve_label(nil, _labels, _allow_none), do: nil

  def resolve_label(raw, labels, allow_none) do
    candidate = raw |> python_str() |> String.trim()
    names = Enum.map(labels, &elem(&1, 0))

    cond do
      String.upcase(candidate) == @none -> if allow_none, do: @none
      candidate in names -> candidate
      true -> Enum.find(names, &(String.downcase(&1) == String.downcase(candidate)))
    end
  end

  @doc """
  The labels as the `:llm` prompt lists them, deepeval's `format_labels`:
  one `- name: description` (or `- name`) line each.

  ## Examples

      iex> DeepEvalEx.Classifier.Utils.format_labels([{"yes", "It does."}, {"no", nil}])
      "- yes: It does.\\n- no"
  """
  @spec format_labels([Classifier.label()]) :: String.t()
  def format_labels(labels) do
    Enum.map_join(labels, "\n", fn
      {name, description} when description in [nil, ""] -> "- #{name}"
      {name, description} -> "- #{name}: #{description}"
    end)
  end

  @doc """
  A single-turn test case's populated fields as the `:llm` prompt shows
  them, deepeval's `construct_single_turn_content`: `"<Field>:\\n<value>"`
  for each, separated by blank lines, lists printed as Python prints them
  (tool calls as a list of their `repr()`).

  Raises `ArgumentError` when no field is populated.
  """
  @spec single_turn_content(TestCase.t()) :: String.t()
  def single_turn_content(%TestCase{} = test_case) do
    case content(test_case, @single_turn_params) do
      "" -> raise ArgumentError, @no_fields
      text -> text
    end
  end

  @doc """
  A conversational test case's populated fields (`:scenario`,
  `:expected_outcome`, `:user_description`, `:context`, `:chatbot_role`)
  as the `:llm` prompt shows them, deepeval's
  `construct_multi_turn_content`; `""` when none is populated.
  """
  @spec multi_turn_content(ConversationalTestCase.t()) :: String.t()
  def multi_turn_content(%ConversationalTestCase{} = test_case),
    do: content(test_case, @multi_turn_params)

  defp content(test_case, params) do
    params
    |> Enum.flat_map(fn {param, display} ->
      value = Map.get(test_case, param)
      if populated?(value), do: ["#{display}:\n#{prompt_value(value)}"], else: []
    end)
    |> Enum.join("\n\n")
  end

  # f"{value}": a string as it is, a list as Python's str(list); tool calls
  # are first turned into their repr() strings.
  defp prompt_value(value) when is_binary(value), do: value
  defp prompt_value([%ToolCall{} | _] = tools), do: Python.repr(Enum.map(tools, &Python.repr/1))
  defp prompt_value(value), do: Python.repr(value)

  @doc """
  The turns as the multi-turn prompt prints them, deepeval's
  `construct_turns` through Jinja: Python's `str()` of a list of dicts with
  each turn's `role`, `content`, `retrieval_context` and `tools_called`
  (the unset ones left out).

  Raises `ArgumentError` for a conversation without turns.
  """
  @spec turns(ConversationalTestCase.t()) :: String.t()
  def turns(%ConversationalTestCase{} = test_case), do: Python.repr(turn_dicts(test_case))

  defp turn_dicts(%ConversationalTestCase{turns: turns}) when turns in [nil, []],
    do: raise(ArgumentError, "Cannot classify a ConversationalTestCase with no turns.")

  defp turn_dicts(%ConversationalTestCase{turns: turns}),
    do: Enum.map(turns, &Turns.convert_turn_to_dict(&1, @turn_params))

  @doc """
  A single-turn test case's `:system_one` state, deepeval's
  `construct_single_turn_state`: `{"test_case": {field: value}}` for the
  fields `single_turn_content/1` shows, as JSON (tool calls as their
  `repr()` strings).

  Raises `ArgumentError` when no field is populated.
  """
  @spec single_turn_state(TestCase.t()) :: OrderedObject.t()
  def single_turn_state(%TestCase{} = test_case) do
    case state_fields(test_case, @single_turn_params) do
      [] -> raise ArgumentError, @no_fields
      fields -> OrderedObject.new([{"test_case", OrderedObject.new(fields)}])
    end
  end

  @doc """
  A conversational test case's `:system_one` state, deepeval's
  `construct_multi_turn_state`: `{"turns": [...]}` with the turns of
  `turns/1`, then `"test_case"` with the conversation's populated fields,
  when any.

  Raises `ArgumentError` for a conversation without turns.
  """
  @spec multi_turn_state(ConversationalTestCase.t()) :: OrderedObject.t()
  def multi_turn_state(%ConversationalTestCase{} = test_case) do
    turns = test_case |> turn_dicts() |> jsonable()

    case state_fields(test_case, @multi_turn_params) do
      [] -> OrderedObject.new([{"turns", turns}])
      fields -> OrderedObject.new([{"turns", turns}, {"test_case", OrderedObject.new(fields)}])
    end
  end

  # deepeval's _experimental_system_one_fields, then _jsonable.
  defp state_fields(test_case, params) do
    for {param, _display} <- params,
        value <- [Map.get(test_case, param)],
        populated?(value),
        do: {Atom.to_string(param), state_value(value)}
  end

  defp state_value([%ToolCall{} | _] = tools), do: Enum.map(tools, &Python.repr/1)
  defp state_value(value), do: jsonable(value)

  # deepeval's _jsonable: JSON values as they are, anything else as its
  # Python str().
  defp jsonable(value)
       when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value),
       do: value

  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

  defp jsonable(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, do: {to_string(key), jsonable(value)})

  defp jsonable(%RetrievedContextData{} = data), do: Python.str(data)
  defp jsonable(%ToolCall{} = tool), do: tool_call_str(tool)

  defp jsonable(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)

  defp jsonable(value), do: inspect(value)

  # pydantic's str() of a ToolCall (it overrides only __repr__).
  defp tool_call_str(%ToolCall{} = tool) do
    type = tool.type |> to_string() |> String.upcase()

    [
      {"name", tool.name},
      {"type", %EnumMember{class: "ToolCallType", name: type, value: type}},
      {"description", tool.description},
      {"reasoning", tool.reasoning},
      {"output", tool.output},
      {"input_parameters", tool.input_parameters}
    ]
    |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{Python.repr(value)}" end)
  end

  # deepeval's _is_populated.
  defp populated?(nil), do: false
  defp populated?(""), do: false
  defp populated?([]), do: false
  defp populated?(map) when is_map(map) and not is_struct(map), do: map_size(map) > 0
  defp populated?(_value), do: true

  @doc """
  Validates a run's classifiers against its test cases before any judge
  call, deepeval's `validate_classifiers`:

  - every classifier is a `DeepEvalEx.Classifier`
  - classifier names are unique within the run
  - every `expected_labels` value is one of its classifier's labels (exact
    case)

  each raising `ArgumentError` with deepeval's message, and an
  `expected_labels` key that matches no classifier in the run logs one
  aggregated warning, so a dataset can carry expected labels for
  classifiers a run leaves out. Returns `:ok`, also for no classifiers.
  """
  @spec validate!([TestCase.t() | ConversationalTestCase.t()] | nil, [Classifier.t()] | nil) ::
          :ok
  def validate!(_test_cases, classifiers) when classifiers in [nil, []], do: :ok

  def validate!(test_cases, classifiers) when is_list(classifiers) do
    Enum.each(classifiers, fn
      %Classifier{} ->
        :ok

      other ->
        raise ArgumentError,
              "All 'classifiers' must be instances of 'BaseClassifier', got #{type_name(other)}."
    end)

    duplicates =
      classifiers
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [] do
      raise ArgumentError,
            "Classifier names must be unique within a run, duplicated: " <>
              "#{Enum.join(duplicates, ", ")}."
    end

    by_name = Map.new(classifiers, &{&1.name, &1})

    unknown =
      for test_case <- test_cases || [],
          {key, value} <- Map.get(test_case, :expected_labels) || %{},
          reduce: %{} do
        unknown ->
          case Map.fetch(by_name, key) do
            {:ok, classifier} ->
              check_expected!(classifier, key, value)
              unknown

            :error ->
              Map.update(unknown, key, 1, &(&1 + 1))
          end
      end

    warn_unknown(unknown)
  end

  defp check_expected!(classifier, key, value) do
    names = Classifier.label_names(classifier)

    if value not in names do
      raise ArgumentError,
            "expected_labels['#{key}'] = '#{value}' is not one of classifier '#{key}' labels: " <>
              "#{Enum.join(names, ", ")}."
    end
  end

  defp warn_unknown(unknown) when map_size(unknown) == 0, do: :ok

  defp warn_unknown(unknown) do
    details =
      unknown
      |> Enum.sort()
      |> Enum.map_join(", ", fn {key, count} ->
        "'#{key}' (#{count} test case#{if count != 1, do: "s"})"
      end)

    Logger.warning(
      "expected_labels keys matched no classifier in this run: #{details}. " <>
        "These expectations were ignored."
    )
  end

  defp type_name(%module{}), do: module |> Module.split() |> List.last()
  defp type_name(other), do: inspect(other)

  # Python's str() of a judge's answer.
  defp python_str(value) when is_binary(value), do: value
  defp python_str(true), do: "True"
  defp python_str(false), do: "False"
  defp python_str(value), do: Python.repr(value)
end
