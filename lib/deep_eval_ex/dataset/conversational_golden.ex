defmodule DeepEvalEx.Dataset.ConversationalGolden do
  @moduledoc """
  A multi-turn golden: the situation a conversation should play out and how
  it should end, before the chatbot under test has spoken. deepeval 4.3.1's
  `ConversationalGolden` (`dataset/golden.py`).

  Running the chatbot through the golden's `:scenario` fills in the
  `:turns` and turns it into a `DeepEvalEx.ConversationalTestCase`
  (`to_test_case/1`).

  ## Fields

  - `:scenario` - The situation the conversation plays out (required)
  - `:expected_outcome` - How the conversation should end
  - `:persona` - Who the user is, a `DeepEvalEx.Dataset.Persona`
  - `:user_description` - Deprecated: who the user is, kept equal to the
    persona's `:characteristics` (see "Persona" below)
  - `:context` - Ideal, ground-truth context for the conversation (strings)
  - `:additional_metadata` - A map of metadata; the test case's `:metadata`
  - `:comments` - Free-text comments
  - `:name` - A name identifying the golden
  - `:custom_column_key_values` - Custom columns, a map of string keys to
    string values
  - `:expectations` - Required and prohibited behaviour, plain data as
    `DeepEvalEx.Dataset.Expectations` describes
  - `:expected_labels` - The label each classifier should give, a map of
    classifier name to label (both strings)
  - `:turns` - The conversation so far, `DeepEvalEx.Turn`s

  deepeval's Confident AI `id`, its multimodal flag and image mapping and
  its private dataset attributes are not ported.

  ## Persona

  As deepeval's `resolve_persona`, `new/1` keeps `:persona` and
  `:user_description` in sync:

  - a persona sets `:user_description` to its `:characteristics`;
  - a `:user_description` alone becomes a persona with those
    characteristics, with a deprecation warning;
  - a `:user_description` that differs from the persona's characteristics
    is an error.

  ## deepeval keys

  `new/1` accepts each field name, as an atom or a string, and the
  camelCase alias `expectedLabels`, which wins over `expected_labels`.
  deepeval declares the other camelCase names (`expectedOutcome`,
  `userDescription`, `additionalMetadata`, `customColumnKeyValues`) for
  serialisation only, so `ConversationalGolden(expectedOutcome=...)`
  ignores them; so does `new/1`, which drops every key it does not know, as
  deepeval's `extra="ignore"`.

  ## Examples

      iex> alias DeepEvalEx.Dataset.ConversationalGolden
      iex> golden =
      ...>   ConversationalGolden.new!(
      ...>     scenario: "A customer asks for a refund",
      ...>     expected_outcome: "The refund is issued",
      ...>     persona: %{name: "Ann", characteristics: "A busy parent"}
      ...>   )
      iex> golden.user_description
      "A busy parent"
      iex> test_case =
      ...>   ConversationalGolden.to_test_case(%{
      ...>     golden
      ...>     | turns: [
      ...>         DeepEvalEx.Turn.new!(role: :user, content: "I'd like a refund."),
      ...>         DeepEvalEx.Turn.new!(role: :assistant, content: "Done!")
      ...>       ]
      ...>   })
      iex> {test_case.scenario, length(test_case.turns)}
      {"A customer asks for a refund", 2}
  """

  import Peri

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Dataset.{Expectations, Persona}
  alias DeepEvalEx.Turn

  @type t :: %__MODULE__{
          scenario: String.t(),
          expected_outcome: String.t() | nil,
          persona: Persona.t() | nil,
          user_description: String.t() | nil,
          context: [String.t()] | nil,
          additional_metadata: map() | nil,
          comments: String.t() | nil,
          name: String.t() | nil,
          custom_column_key_values: %{optional(String.t()) => String.t()} | nil,
          expectations: Expectations.t() | nil,
          expected_labels: %{optional(String.t()) => String.t()} | nil,
          turns: [Turn.t()] | nil
        }

  defstruct [
    :scenario,
    :expected_outcome,
    :persona,
    :user_description,
    :context,
    :additional_metadata,
    :comments,
    :name,
    :custom_column_key_values,
    :expectations,
    :expected_labels,
    :turns
  ]

  # deepeval 4.3.1's ConversationalGolden validation keys, in its order of
  # precedence. Keys not listed here are dropped, as deepeval's
  # extra="ignore".
  @key_aliases [
    scenario: ["scenario"],
    expected_outcome: ["expected_outcome"],
    persona: ["persona"],
    user_description: ["user_description"],
    context: ["context"],
    additional_metadata: ["additional_metadata"],
    comments: ["comments"],
    name: ["name"],
    custom_column_key_values: ["custom_column_key_values"],
    expectations: ["expectations"],
    expected_labels: ["expectedLabels", "expected_labels"],
    turns: ["turns"]
  ]

  @persona_conflict "Pass either 'persona' or the deprecated 'user_description', not both " <>
                      "with conflicting text."

  defschema(:conversational_golden_schema, %{
    scenario: {:required, :string},
    expected_outcome: :string,
    persona: {:custom, {Persona, :cast}},
    user_description: :string,
    context: {:list, :string},
    additional_metadata: :map,
    comments: :string,
    name: :string,
    custom_column_key_values: {:map, :string, :string},
    expectations: {:custom, {Expectations, :cast}},
    expected_labels: {:map, :string, :string},
    turns: {:list, {:custom, {Turn, :cast}}}
  })

  @doc """
  Creates a conversational golden from a keyword list or map.

  Keys may be atoms or strings (see "deepeval keys" above). `:persona` may
  be a `DeepEvalEx.Dataset.Persona` or a map or keyword list that
  `DeepEvalEx.Dataset.Persona.new/1` builds one from, and each turn a
  `DeepEvalEx.Turn` or a map or keyword list that `DeepEvalEx.Turn.new/1`
  builds one from. `:expectations` is validated by
  `DeepEvalEx.Dataset.Expectations.cast/1`.

  The persona and `:user_description` are then reconciled as "Persona"
  above describes; a conflict returns `{:error, message}` with deepeval's
  message.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with {:ok, validated} <- attrs |> normalize_attrs() |> conversational_golden_schema(),
         {:ok, persona, user_description} <-
           resolve_persona(validated[:persona], validated[:user_description]) do
      {:ok,
       struct(
         __MODULE__,
         Map.merge(validated, %{persona: persona, user_description: user_description})
       )}
    end
  end

  @doc """
  Creates a conversational golden, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, golden} -> golden
      {:error, errors} -> raise "Invalid conversational golden: #{inspect(errors)}"
    end
  end

  @doc """
  Converts a golden into a conversational test case, as one golden of
  deepeval's `convert_convo_goldens_to_convo_test_cases`.

  `:additional_metadata` becomes the test case's `:metadata` and the
  persona reaches it as `:user_description`; the other fields keep their
  names. `:custom_column_key_values` is left out, as deepeval leaves it
  out.

  Raises `ArgumentError` when the test case does not build: a golden
  without turns gives `"'turns' must not be empty"`, as deepeval's
  `ConversationalTestCase(turns=[])` raises.
  """
  @spec to_test_case(t()) :: ConversationalTestCase.t()
  def to_test_case(%__MODULE__{} = golden) do
    attrs = [
      turns: golden.turns || [],
      scenario: golden.scenario,
      expected_outcome: golden.expected_outcome,
      user_description: golden.user_description,
      context: golden.context,
      name: golden.name,
      metadata: golden.additional_metadata,
      comments: golden.comments,
      expected_labels: golden.expected_labels,
      expectations: golden.expectations
    ]

    case attrs
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> ConversationalTestCase.new() do
      {:ok, test_case} ->
        test_case

      {:error, errors} ->
        raise ArgumentError, "Invalid conversational test case: #{inspect(errors)}"
    end
  end

  @doc """
  Converts a conversational test case into a golden, as one test case of
  deepeval's `convert_convo_test_cases_to_convo_goldens`.

  The test case's `:metadata` becomes `:additional_metadata`, and a
  non-empty `:user_description` becomes a persona with those
  characteristics, without the deprecation warning. As deepeval, the golden
  does not keep the test case's `:name`, `:comments`, `:expected_labels`,
  `:chatbot_role` or `:tags`.

  Raises `ArgumentError` with deepeval's message when the test case has no
  scenario.
  """
  @spec from_test_case(ConversationalTestCase.t()) :: t()
  def from_test_case(%ConversationalTestCase{scenario: scenario}) when scenario in [nil, ""] do
    raise ArgumentError,
          "Please provide a scenario in your 'ConversationalTestCase' to convert it to a " <>
            "'ConversationalGolden'."
  end

  def from_test_case(%ConversationalTestCase{} = test_case) do
    persona =
      if test_case.user_description not in [nil, ""],
        do: %Persona{characteristics: test_case.user_description}

    %__MODULE__{
      scenario: test_case.scenario,
      turns: test_case.turns,
      expected_outcome: test_case.expected_outcome,
      persona: persona,
      user_description: persona && persona.characteristics,
      context: test_case.context,
      additional_metadata: test_case.metadata,
      expectations: test_case.expectations
    }
  end

  @doc """
  Converts goldens into conversational test cases, in order, as deepeval's
  `convert_convo_goldens_to_convo_test_cases` (see `to_test_case/1`).

  As deepeval, each test case's `:dataset_rank` is its golden's position.
  """
  @spec convert_goldens_to_test_cases([t()]) :: [ConversationalTestCase.t()]
  def convert_goldens_to_test_cases(goldens) do
    goldens
    |> Enum.with_index()
    |> Enum.map(fn {golden, rank} -> %{to_test_case(golden) | dataset_rank: rank} end)
  end

  @doc """
  Converts conversational test cases into goldens, in order, as deepeval's
  `convert_convo_test_cases_to_convo_goldens` (see `from_test_case/1`).
  """
  @spec convert_test_cases_to_goldens([ConversationalTestCase.t()]) :: [t()]
  def convert_test_cases_to_goldens(test_cases), do: Enum.map(test_cases, &from_test_case/1)

  # deepeval's resolve_persona
  defp resolve_persona(nil, nil), do: {:ok, nil, nil}

  defp resolve_persona(nil, user_description) do
    IO.warn(
      "'user_description' is deprecated and will be removed in a future release. " <>
        "Use 'persona: %DeepEvalEx.Dataset.Persona{characteristics: ...}' instead."
    )

    {:ok, %Persona{characteristics: user_description}, user_description}
  end

  defp resolve_persona(%Persona{characteristics: characteristics} = persona, user_description)
       when user_description in [nil, characteristics],
       do: {:ok, persona, characteristics}

  defp resolve_persona(_persona, _user_description), do: {:error, @persona_conflict}

  # Maps deepeval's keys (atoms or strings, field names or aliases) to
  # fields, dropping the rest
  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {key_string(k), v} end)

    @key_aliases
    |> Enum.flat_map(fn {field, aliases} ->
      case Enum.find(aliases, &Map.has_key?(attrs, &1)) do
        nil -> []
        key -> [{field, Map.fetch!(attrs, key)}]
      end
    end)
    |> Map.new()
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key
end
