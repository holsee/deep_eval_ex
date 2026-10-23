defmodule DeepEvalEx.ConversationalTestCase do
  @moduledoc """
  A multi-turn test case: a conversation between a user and the chatbot
  under test, deepeval 4.3.1's `ConversationalTestCase`
  (`test_case/conversational_test_case.py`).

  Where a `DeepEvalEx.TestCase` holds one input and one output, a
  conversational test case holds the whole conversation as a list of
  `DeepEvalEx.Turn`s, and conversational metrics judge it as a whole.

  ## Fields

  - `:turns` - The conversation, a non-empty list of `DeepEvalEx.Turn`s
    (required)
  - `:scenario` - The situation the conversation plays out
  - `:context` - Ideal, ground-truth context for the conversation (strings)
  - `:name` - Optional name identifying the test case
  - `:user_description` - Who the user is
  - `:expected_outcome` - How the conversation should end
  - `:chatbot_role` - The role the chatbot should play
  - `:metadata` - Additional metadata for the test case
  - `:comments` - Free-text comments about the test case
  - `:tags` - Optional list of tags
  - `:flaky` - Whether the test case is known to be flaky (default: `false`)
  - `:expectations` - Required and prohibited behaviour, plain data as
    `DeepEvalEx.Dataset.Expectations` describes
  - `:expected_labels` - The label each classifier should give the test
    case, a map of classifier name to label (both strings)
  - `:call_recording_path` - Path of the conversation's recording, for a
    voice conversation. deepeval excludes it from serialisation
  - `:multimodal` - Whether the conversation holds images (see below)
  - `:images` - The images the conversation's placeholders name, a map of
    id to `DeepEvalEx.MLLMImage`; `new/1` takes a list (or a map) of
    images or of their attributes, as `DeepEvalEx.TestCase` does
  - `:voice` - Whether the conversation holds audio (see below)
  - `:dataset_rank` - The test case's position in the dataset it was added
    to, deepeval's private `_dataset_rank`; `nil` outside a dataset, and
    `new/1` never sets it

  deepeval's `mcp_servers` is not ported, as for `DeepEvalEx.TestCase`.

  ## Modality flags

  As deepeval's `set_is_voice` and `set_is_multimodal` validators, `new/1`
  sets `:voice` when a turn has `:audio`, and `:multimodal` when a
  `[DEEPEVAL:IMAGE:<id>]` or `[DEEPEVAL:PDF:<id>]` placeholder appears in
  the `:scenario`, `:expected_outcome`, `:user_description`, a turn's
  `:content` or a turn's `:retrieval_context`. Either flag given as `true`
  is kept. Like deepeval, `:context` and `:chatbot_role` are not searched.

  The images a placeholder names are looked up in `:images` (deepeval's
  process-wide image registry), and exported as the test case's
  `imagesMapping` (see `images_mapping/1`).

  ## deepeval keys

  `new/1` accepts the keys deepeval's `ConversationalTestCase` validates, as
  atoms or strings: each field name and deepeval's aliases
  `userDescription`, `expectedOutcome`, `chatbotRole`, `expectedLabels`,
  `additionalMetadata` and `additional_metadata`. When several keys name one
  field, the one deepeval lists first wins (the camelCase alias, or
  `metadata`). Any other key is dropped, as deepeval's `extra="ignore"`.

  ## Examples

      iex> alias DeepEvalEx.ConversationalTestCase
      iex> {:ok, test_case} =
      ...>   ConversationalTestCase.new(
      ...>     scenario: "A customer asks for a refund",
      ...>     turns: [
      ...>       %{role: "user", content: "I want my money back."},
      ...>       %{role: "assistant", content: "Sorry to hear that. What is your order number?"}
      ...>     ]
      ...>   )
      iex> Enum.map(test_case.turns, & &1.role)
      [:user, :assistant]
  """

  import Peri

  alias DeepEvalEx.Dataset.Expectations
  alias DeepEvalEx.MLLMImage
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.Turn

  @type t :: %__MODULE__{
          turns: [Turn.t(), ...],
          scenario: String.t() | nil,
          context: [String.t()] | nil,
          name: String.t() | nil,
          user_description: String.t() | nil,
          expected_outcome: String.t() | nil,
          chatbot_role: String.t() | nil,
          metadata: map() | nil,
          comments: String.t() | nil,
          tags: [String.t()] | nil,
          flaky: boolean(),
          expectations: Expectations.t() | nil,
          expected_labels: %{optional(String.t()) => String.t()} | nil,
          call_recording_path: String.t() | nil,
          multimodal: boolean(),
          images: %{optional(String.t()) => MLLMImage.t()} | nil,
          voice: boolean(),
          dataset_rank: non_neg_integer() | nil
        }

  defstruct [
    :turns,
    :scenario,
    :context,
    :name,
    :user_description,
    :expected_outcome,
    :chatbot_role,
    :metadata,
    :comments,
    :tags,
    :expectations,
    :expected_labels,
    :call_recording_path,
    :images,
    :dataset_rank,
    flaky: false,
    multimodal: false,
    voice: false
  ]

  # deepeval's multimodal placeholder, as in set_is_multimodal
  @multimodal_pattern ~r/\[DEEPEVAL:(?:IMAGE|PDF):(.*?)\]/

  # deepeval 4.3.1's ConversationalTestCase validation aliases, in its
  # order of precedence. Keys not listed here are dropped, as deepeval's
  # extra="ignore".
  @key_aliases [
    turns: ["turns"],
    call_recording_path: ["call_recording_path"],
    scenario: ["scenario"],
    context: ["context"],
    name: ["name"],
    user_description: ["userDescription", "user_description"],
    expected_outcome: ["expectedOutcome", "expected_outcome"],
    chatbot_role: ["chatbotRole", "chatbot_role"],
    metadata: ["metadata", "additionalMetadata", "additional_metadata"],
    comments: ["comments"],
    tags: ["tags"],
    flaky: ["flaky"],
    expectations: ["expectations"],
    expected_labels: ["expectedLabels", "expected_labels"],
    multimodal: ["multimodal"],
    voice: ["voice"],
    images: ["images", "imagesMapping"]
  ]

  defschema(:conversational_test_case_schema, %{
    turns: {:required, {:custom, {__MODULE__, :cast_turns}}},
    call_recording_path: :string,
    scenario: :string,
    context: {:list, :string},
    name: :string,
    user_description: :string,
    expected_outcome: :string,
    chatbot_role: :string,
    metadata: :map,
    comments: :string,
    tags: {:list, :string},
    flaky: {:boolean, {:default, false}},
    expectations: {:custom, {Expectations, :cast}},
    expected_labels: {:map, :string, :string},
    multimodal: {:boolean, {:default, false}},
    voice: {:boolean, {:default, false}},
    images: {:custom, {MLLMImage, :cast_images}}
  })

  @doc """
  Creates a conversational test case from a keyword list or a map (see
  "deepeval keys" above).

  Each turn may be a `DeepEvalEx.Turn` or a map or keyword list that
  `DeepEvalEx.Turn.new/1` builds one from. As deepeval's `validate_input`,
  empty `:turns` are rejected (`"'turns' must not be empty"`), as is a turn
  that is neither (`"'turns' must be a list of Turn or dict, ..."`) or does
  not build (`"Invalid dict for Turn: ..."`).

  `:voice` and `:multimodal` are then set as "Modality flags" above
  describes.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    case attrs |> normalize_attrs() |> conversational_test_case_schema() do
      {:ok, validated} ->
        {:ok, __MODULE__ |> struct(validated) |> set_voice() |> set_multimodal()}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates a conversational test case, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, test_case} -> test_case
      {:error, errors} -> raise "Invalid conversational test case: #{inspect(errors)}"
    end
  end

  @typedoc """
  Why a conversational test case cannot be measured by a metric, as
  returned by `validate_params/3`.
  """
  @type validation_error ::
          {:missing_conversational_param,
           :expected_outcome | :scenario | :metadata | :tags | :chatbot_role}
          | :empty_turns
          | {:no_turn_with, :provider_transcript | :audio}

  # The case-level params deepeval's check_conversational_test_case_params
  # checks, in its order. Any other required param is not checked.
  @case_params [:expected_outcome, :scenario, :metadata, :tags]

  @doc """
  Validates that the test case has what a conversational metric requiring
  `required_params` needs, as deepeval 4.3.1's
  `check_conversational_test_case_params`. The first failing check, in
  deepeval's order, is returned:

  1. `{:missing_conversational_param, param}` - `:expected_outcome`,
     `:scenario`, `:metadata` or `:tags` is required and `nil`
  2. `{:missing_conversational_param, :chatbot_role}` - the
     `:requires_chatbot_role` option is set and `:chatbot_role` is `nil`
  3. `:empty_turns` - the test case has no turns
  4. `{:no_turn_with, :provider_transcript}` / `{:no_turn_with, :audio}` -
     the param is required and no turn has it

  Like deepeval, it checks no other param: a turn-level param such as
  `:content` or `:retrieval_context`, `:context` and `:user_description`
  are never missing. deepeval's `mcp_servers` check is not ported, nor its
  checks that the judge model accepts multimodal or audio input.

  `DeepEvalEx.Result.error/3` renders each error with deepeval's
  `MissingTestCaseParamsError` message.

  ## Options

  - `:requires_chatbot_role` - also require `:chatbot_role`, deepeval's
    `_requires_chatbot_role` (default: `false`)

  ## Examples

      iex> test_case = DeepEvalEx.ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}])
      iex> DeepEvalEx.ConversationalTestCase.validate_params(test_case, [:content, :scenario])
      {:error, {:missing_conversational_param, :scenario}}
  """
  @spec validate_params(t(), [DeepEvalEx.Params.MultiTurn.t()], keyword()) ::
          :ok | {:error, validation_error()}
  def validate_params(%__MODULE__{} = test_case, required_params, opts \\ []) do
    missing_case_param =
      Enum.find(@case_params, &(&1 in required_params and is_nil(Map.fetch!(test_case, &1))))

    cond do
      missing_case_param ->
        {:error, {:missing_conversational_param, missing_case_param}}

      Keyword.get(opts, :requires_chatbot_role, false) and is_nil(test_case.chatbot_role) ->
        {:error, {:missing_conversational_param, :chatbot_role}}

      test_case.turns == [] ->
        {:error, :empty_turns}

      missing_turn_param?(test_case, required_params, :provider_transcript) ->
        {:error, {:no_turn_with, :provider_transcript}}

      missing_turn_param?(test_case, required_params, :audio) ->
        {:error, {:no_turn_with, :audio}}

      true ->
        :ok
    end
  end

  defp missing_turn_param?(%__MODULE__{turns: turns}, required_params, param),
    do: param in required_params and not Enum.any?(turns, &(not is_nil(Map.fetch!(&1, param))))

  @doc false
  # Peri custom validator for the turns: a non-empty list of turns, each
  # cast by DeepEvalEx.Turn.cast/1.
  @spec cast_turns(term()) :: {:ok, [Turn.t(), ...]} | {:error, String.t(), keyword()}
  def cast_turns([]), do: {:error, "'turns' must not be empty", []}

  def cast_turns(turns) when is_list(turns) do
    Enum.reduce_while(turns, {:ok, []}, fn turn, {:ok, acc} ->
      case Turn.cast(turn) do
        {:ok, turn} -> {:cont, {:ok, [turn | acc]}}
        {:error, _message, _context} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def cast_turns(other),
    do: {:error, "'turns' must be a list of Turn or dict, got %{turns}", [turns: inspect(other)]}

  @doc """
  The images the conversation's placeholders name, deepeval's
  `_get_images_mapping`: a map of id to `DeepEvalEx.MLLMImage` of the
  `:images` named in the `:scenario`, `:expected_outcome`, `:context`,
  `:user_description`, or a turn's `:content` or `:retrieval_context`
  (strings only), or `nil` when there are none.
  """
  @spec images_mapping(t()) :: %{optional(String.t()) => MLLMImage.t()} | nil
  def images_mapping(%__MODULE__{} = test_case) do
    case test_case |> image_texts() |> MLLMImage.mapping(test_case.images) do
      nil -> nil
      pairs -> Map.new(pairs)
    end
  end

  @doc false
  # The images mapping as a test run exports it: each image's dump, in the
  # order the placeholders first appear, or nil.
  @spec images_mapping_dump(t()) :: Jason.OrderedObject.t() | nil
  def images_mapping_dump(%__MODULE__{} = test_case) do
    case test_case |> image_texts() |> MLLMImage.mapping(test_case.images) do
      nil ->
        nil

      pairs ->
        Jason.OrderedObject.new(for {id, image} <- pairs, do: {id, MLLMImage.to_dump(image)})
    end
  end

  # deepeval's _get_images_mapping searches these, in this order.
  defp image_texts(%__MODULE__{} = test_case) do
    [test_case.scenario, test_case.expected_outcome] ++
      List.wrap(test_case.context) ++
      [test_case.user_description] ++
      Enum.flat_map(test_case.turns, &[&1.content | List.wrap(&1.retrieval_context)])
  end

  defp set_voice(%__MODULE__{voice: true} = test_case), do: test_case

  defp set_voice(%__MODULE__{turns: turns} = test_case),
    do: %{test_case | voice: Enum.any?(turns, &(not is_nil(&1.audio)))}

  defp set_multimodal(%__MODULE__{multimodal: true} = test_case), do: test_case

  defp set_multimodal(%__MODULE__{} = test_case) do
    texts =
      [test_case.scenario, test_case.expected_outcome, test_case.user_description] ++
        Enum.flat_map(test_case.turns, &turn_texts/1)

    %{test_case | multimodal: Enum.any?(texts, &placeholder?/1)}
  end

  defp turn_texts(%Turn{content: content, retrieval_context: retrieval_context}),
    do: [content | Enum.map(retrieval_context || [], &RetrievedContextData.context/1)]

  defp placeholder?(nil), do: false
  defp placeholder?(text), do: Regex.match?(@multimodal_pattern, text)

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
