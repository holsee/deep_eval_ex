defmodule DeepEvalEx.Dataset.Expectations do
  @moduledoc """
  The required and prohibited behaviour of a golden or test case, deepeval
  4.3.1's `Expectations` (`dataset/expectations.py`), kept as plain data.

  An expectations map has deepeval's four fields:

  - `:must` - Conditions the output must meet (strings, default `[]`)
  - `:must_not` - Conditions the output must not meet (strings, default `[]`)
  - `:model` - The model name to judge them with, or `nil`
  - `:eval_mode` - `:llm`, `:system_one` or `nil`

  DeepEvalEx carries expectations from goldens to test cases and back, as
  deepeval does. deepeval also takes a live `DeepEvalBaseLLM` as `model`,
  but serialises only a model name, so `:model` is a string here.

  `cast/1` validates as deepeval's pydantic model does (see its doc).

  ## Judging

  `DeepEvalEx.evaluate/3`, `DeepEvalEx.evaluate_run/3` and
  `DeepEvalEx.ExUnit`'s `assert_evaluation/3` judge the expectations of
  every test case that has some (`present?/1`) after its metrics, as
  deepeval's `evaluate()` and `assert_test()` do: a result named
  `"Expectations"`, threshold 1 and strict, that passes only when every
  `must` condition holds and no `must_not` one does. The test run exports
  it as the test case's `expectationsData` rather than as a metric (see
  `DeepEvalEx.TestRun.ExpectationsData`).

  The judge is the `:model` (else the run's `:model`, then the default
  model) under `:llm`, and System One under `:system_one`, one Choice per
  condition. The eval mode is the `:eval_mode` setting (see
  `DeepEvalEx.Config`) when set, else `:eval_mode`, else the run's
  `:eval_mode` option, with `:hybrid` running as `:llm`: deepeval lets
  `DEEPEVAL_EVAL_MODE` win over the expectations' own mode.

  The judge sees the observed test case, `evidence/1`. A condition the
  judge cannot evaluate (`unable_to_evaluate`) errors the result, as
  deepeval raises `"Unable to evaluate expectations: ..."`.
  """

  alias DeepEvalEx.{ConversationalTestCase, TestCase}
  alias DeepEvalEx.SystemOne.State
  alias Jason.OrderedObject

  @typedoc "Expectations, as deepeval's `Expectations` model."
  @type t :: %{
          model: String.t() | nil,
          eval_mode: :llm | :system_one | nil,
          must: [String.t()],
          must_not: [String.t()]
        }

  # deepeval's validation keys; must_not is listed before its mustNot alias
  @key_aliases [
    model: ["model"],
    eval_mode: ["eval_mode"],
    must: ["must"],
    must_not: ["must_not", "mustNot"]
  ]

  @known_keys @key_aliases |> Keyword.values() |> List.flatten()

  @eval_modes %{"llm" => :llm, "system_one" => :system_one}

  @doc """
  Validates expectations given as a map or keyword list with atom or string
  keys, and returns them with deepeval's defaults filled in.

  As deepeval's model (`extra="forbid"`), any key other than `model`,
  `eval_mode`, `must`, `must_not` and its alias `mustNot` is an error, and
  so is `mustNot` alongside `must_not`. Each condition must be a string
  that is not blank, and is stripped of surrounding whitespace. `eval_mode`
  must be `"llm"` or `"system_one"` (exactly, or as an atom).

  `nil` (deepeval's `None`, no expectations) is returned as it is. Errors
  have the shape of a Peri custom validator's, so a schema can call it.

  ## Examples

      iex> DeepEvalEx.Dataset.Expectations.cast(%{"must" => [" Cite a source "]})
      {:ok, %{model: nil, eval_mode: nil, must: ["Cite a source"], must_not: []}}
  """
  @spec cast(term()) :: {:ok, t() | nil} | {:error, String.t(), keyword()}
  def cast(nil), do: {:ok, nil}

  def cast(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: cast(Map.new(attrs)), else: invalid(attrs)
  end

  def cast(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {key_string(k), v} end)

    with :ok <- check_keys(attrs),
         {:ok, model} <- cast_model(field(attrs, :model, nil)),
         {:ok, eval_mode} <- cast_eval_mode(field(attrs, :eval_mode, nil)),
         {:ok, must} <- cast_conditions(field(attrs, :must, []), "must"),
         {:ok, must_not} <- cast_conditions(field(attrs, :must_not, []), "must_not") do
      {:ok, %{model: model, eval_mode: eval_mode, must: must, must_not: must_not}}
    end
  end

  def cast(attrs), do: invalid(attrs)

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key

  @doc """
  Whether `expectations` hold any condition, deepeval's
  `Expectations.__bool__`: `false` for `nil` and for expectations whose
  `:must` and `:must_not` are both empty.

  ## Examples

      iex> DeepEvalEx.Dataset.Expectations.present?(%{model: nil, eval_mode: nil, must: [], must_not: ["Swears"]})
      true

      iex> DeepEvalEx.Dataset.Expectations.present?(nil)
      false
  """
  @spec present?(t() | nil) :: boolean()
  def present?(%{must: must, must_not: must_not}), do: must != [] or must_not != []
  def present?(nil), do: false

  # deepeval's expectation_evidence include set, in the order of the test
  # case models' fields.
  @mcp_calls [:mcp_tools_called, :mcp_resources_called, :mcp_prompts_called]
  @single_turn_evidence [:input, :actual_output, :context, :retrieval_context, :metadata] ++
                          [:tools_called, :tags | @mcp_calls]
  @multi_turn_evidence [:turns, :scenario, :context, :chatbot_role, :metadata, :tags]
  @turn_fields [:role, :content, :user_id, :audio, :latency_ms, :interrupted] ++
                 [:provider_transcript, :retrieval_context, :tools_called] ++
                 @mcp_calls ++ [:metadata]

  @doc """
  The observed test case expectations are judged against, deepeval's
  `expectation_evidence`: `model_dump(mode="json", exclude_none=True)` over
  a fixed set of fields, as a `Jason.OrderedObject` in deepeval's field
  order.

  - a `DeepEvalEx.TestCase`: `input`, `actual_output`, `context`,
    `retrieval_context`, `metadata`, `tools_called`, `tags`,
    `mcp_tools_called`, `mcp_resources_called` and `mcp_prompts_called`
  - a `DeepEvalEx.ConversationalTestCase`: `turns` (each turn's fields,
    without `nil`s), `scenario`, `context`, `chatbot_role`, `metadata` and
    `tags`

  Unset (`nil`) fields are left out; a value inside `metadata` is kept as it
  is, `nil` included. A `DeepEvalEx.Schemas.RetrievedContextData` is dumped
  as `"source: context"`, and a tool call or an MCP call as its fields (see
  `DeepEvalEx.SystemOne.Dumpable`). It is the LLM judge's "Observed case"
  and System One's `observed_case` state.

  ## Examples

      iex> test_case = %DeepEvalEx.TestCase{input: "Hi", actual_output: "Hello!", tags: ["greeting"]}
      iex> test_case |> DeepEvalEx.Dataset.Expectations.evidence() |> DeepEvalEx.TestRun.JSON.encode!()
      ~s({"input": "Hi", "actual_output": "Hello!", "tags": ["greeting"]})
  """
  @spec evidence(TestCase.t() | ConversationalTestCase.t()) :: OrderedObject.t()
  def evidence(%TestCase{} = test_case), do: dump_fields(test_case, @single_turn_evidence)

  def evidence(%ConversationalTestCase{} = test_case) do
    %OrderedObject{values: values} = dump_fields(test_case, @multi_turn_evidence)

    values =
      List.keyreplace(values, "turns", 0, {"turns", Enum.map(test_case.turns, &dump_turn/1)})

    OrderedObject.new(values)
  end

  defp dump_turn(turn), do: dump_fields(turn, @turn_fields)

  defp dump_fields(struct, fields) do
    OrderedObject.new(
      for field <- fields,
          value <- [Map.get(struct, field)],
          not is_nil(value),
          do: {Atom.to_string(field), State.dump(value)}
    )
  end

  # The value of the first key naming the field, or the default when none is
  # given; a given nil stays nil, as pydantic does not default it
  defp field(attrs, field, default) do
    case Enum.find(Keyword.fetch!(@key_aliases, field), &Map.has_key?(attrs, &1)) do
      nil -> default
      key -> Map.fetch!(attrs, key)
    end
  end

  defp check_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @known_keys)) do
      [] when is_map_key(attrs, "must_not") and is_map_key(attrs, "mustNot") ->
        {:error, "expectations take must_not or mustNot, not both", []}

      [] ->
        :ok

      unknown ->
        {:error, "expectations do not take %{keys}", [keys: inspect(unknown)]}
    end
  end

  defp cast_model(model) when is_nil(model) or is_binary(model), do: {:ok, model}

  defp cast_model(model) do
    {:error, "expectations model must be a model name, got %{model}", [model: inspect(model)]}
  end

  defp cast_eval_mode(nil), do: {:ok, nil}
  defp cast_eval_mode(mode) when mode in [:llm, :system_one], do: {:ok, mode}

  defp cast_eval_mode(mode) when is_map_key(@eval_modes, mode),
    do: {:ok, Map.fetch!(@eval_modes, mode)}

  defp cast_eval_mode(mode) do
    {:error, "expectations eval_mode must be 'llm' or 'system_one', got %{mode}",
     [mode: inspect(mode)]}
  end

  defp cast_conditions(conditions, field) when is_list(conditions) do
    if Enum.all?(conditions, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.map(conditions, &String.trim/1)}
    else
      {:error, "expectations %{field} must contain non-empty conditions", [field: field]}
    end
  end

  defp cast_conditions(conditions, field) do
    {:error, "expectations %{field} must be a list of conditions, got %{value}",
     [field: field, value: inspect(conditions)]}
  end

  defp invalid(value) do
    {:error, "expectations must be a map, got %{value}", [value: inspect(value)]}
  end
end
