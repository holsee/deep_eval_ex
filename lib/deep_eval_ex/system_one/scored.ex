defmodule DeepEvalEx.SystemOne.Scored do
  @moduledoc """
  The scored question primitives a whole metric is decided from, ports of
  deepeval 4.3.1's `Noul`, `Score`, `Choice` and `QuestionOutcome`
  (`deepeval/metrics/jev_eval/questions.py`) and of `parse_questions`
  (`deepeval/metrics/utils/system_one.py`).

  Each question is answered by a System One model with probabilities, never
  text, and maps onto a value in `0..1`:

  - `DeepEvalEx.SystemOne.Scored.Noul` - one proposition about the test
    case, valued P(true)
  - `DeepEvalEx.SystemOne.Scored.Score` - one holistic judgement over 2 to
    10 ordered descriptive levels, worst first, valued
    `expected level index / (levels - 1)`
  - `DeepEvalEx.SystemOne.Scored.Choice` - one selection from a closed set
    whose options each carry a credit in `0..1`, or `nil` when the option
    means the question does not apply to the test case

  Every question has a `weight` greater than 0 (`1.0` by default); a
  metric's score is the weighted mean of its applicable questions' values.
  Weights and credits stay in DeepEvalEx: `to_question/1` builds the wire
  question a provider is sent (`DeepEvalEx.SystemOne.Question`), which
  carries neither.

  `DeepEvalEx.SystemOne.Scored.Outcome` is how one question was answered,
  one entry of a metric's `score_breakdown`.

  ## Validation

  `new!/1` on each question validates it with deepeval's messages, raising
  `ArgumentError`, e.g. `"Score levels must be unique."`.

  ## Examples

      iex> alias DeepEvalEx.SystemOne.Scored
      iex> question = Scored.Noul.new!(statement: "`actual_output` answers `input`.", weight: 2)
      iex> question.weight
      2.0
      iex> Scored.to_question(question)
      %DeepEvalEx.SystemOne.Question.Noul{instructions: "`actual_output` answers `input`."}
  """

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.Question

  # A Score question accepts this many ordered levels (Jev's limit).
  @min_score_levels 2
  @max_score_levels 10

  defmodule Noul do
    @moduledoc """
    A proposition the model judges true or false about the state,
    deepeval's `Noul`. `true` and `false` optionally say what each outcome
    means; they are sent as the wire question's criteria.
    """

    alias DeepEvalEx.SystemOne.Scored

    @type t :: %__MODULE__{
            statement: String.t(),
            weight: float(),
            true: term(),
            false: term()
          }

    defstruct [:statement, weight: 1.0, true: nil, false: nil]

    @doc """
    Builds a validated Noul from a keyword list or map of its fields.
    Raises `ArgumentError` with deepeval's message when it is invalid, and
    `KeyError` for an unknown field.
    """
    @spec new!(keyword() | map()) :: t()
    def new!(fields), do: Scored.build!(__MODULE__, fields)
  end

  defmodule Score do
    @moduledoc """
    A holistic judgement over ordered descriptive `levels`, worst first,
    deepeval's `Score`: 2 to 10 unique, non-empty strings.
    """

    alias DeepEvalEx.SystemOne.Scored

    @type t :: %__MODULE__{question: String.t(), levels: [String.t()], weight: float()}

    defstruct [:question, levels: [], weight: 1.0]

    @doc """
    Builds a validated Score from a keyword list or map of its fields.
    Raises `ArgumentError` with deepeval's message when it is invalid, and
    `KeyError` for an unknown field.
    """
    @spec new!(keyword() | map()) :: t()
    def new!(fields), do: Scored.build!(__MODULE__, fields)
  end

  defmodule Choice do
    @moduledoc """
    A selection from a closed set, deepeval's `Choice`. `options` is an
    ordered list of `{name, credit}`: the credit an option earns, in `0..1`,
    or `nil` for an option meaning the question does not apply to the test
    case. At least two options, and at least one with a credit.

    The model is sent the option names only.
    """

    alias DeepEvalEx.SystemOne.Scored

    @type t :: %__MODULE__{
            question: String.t(),
            options: [{String.t(), float() | nil}],
            weight: float()
          }

    defstruct [:question, options: [], weight: 1.0]

    @doc """
    Builds a validated Choice from a keyword list or map of its fields.

    `options` is a list of `{name, credit}` pairs (a keyword list included),
    or a map, taken in its iteration order. Names become strings and
    credits floats. Raises `ArgumentError` with deepeval's message when it
    is invalid, and `KeyError` for an unknown field.
    """
    @spec new!(keyword() | map()) :: t()
    def new!(fields), do: Scored.build!(__MODULE__, fields)

    @doc "The options with a credit, `{name, credit}` in order."
    @spec applicable_options(t()) :: [{String.t(), float()}]
    def applicable_options(%__MODULE__{options: options}),
      do: for({name, credit} <- options, credit != nil, do: {name, credit})

    @doc "The names of the not-applicable options (credit `nil`), in order."
    @spec not_applicable_options(t()) :: [String.t()]
    def not_applicable_options(%__MODULE__{options: options}),
      do: for({name, nil} <- options, do: name)
  end

  defmodule Outcome do
    @moduledoc """
    How one scored question was answered, deepeval's `QuestionOutcome`:
    one entry of a metric's `score_breakdown`.

    - `question` - the question's text (`DeepEvalEx.SystemOne.Scored.text/1`)
    - `type` - `:noul`, `:score` or `:choice`
    - `weight` - the question's weight
    - `value` - its value in `0..1`, `nil` when it did not apply
    - `applicable` - `false` when a not-applicable Choice option won
    - `probabilities` - `{outcome, p}` in order: `"true"` / `"false"` for a
      Noul, levels for a Score, options for a Choice
    - `confidence` - the answer's confidence
    - `passed` - under strict mode, whether the question met the strict bar
    """

    @type t :: %__MODULE__{
            question: String.t(),
            type: :noul | :score | :choice,
            weight: float(),
            value: float() | nil,
            applicable: boolean(),
            probabilities: [{String.t(), float()}],
            confidence: float() | nil,
            passed: boolean() | nil
          }

    defstruct [
      :question,
      :type,
      :weight,
      :value,
      :applicable,
      probabilities: [],
      confidence: nil,
      passed: nil
    ]

    @doc """
    The outcome as `QuestionOutcome.model_dump()`: its fields in deepeval's
    order, with `type` and the probability keys as strings.
    """
    @spec to_dump(t()) :: Jason.OrderedObject.t()
    def to_dump(%__MODULE__{} = outcome) do
      Jason.OrderedObject.new([
        {"question", outcome.question},
        {"type", Atom.to_string(outcome.type)},
        {"weight", outcome.weight},
        {"value", outcome.value},
        {"applicable", outcome.applicable},
        {"probabilities", Jason.OrderedObject.new(outcome.probabilities)},
        {"confidence", outcome.confidence},
        {"passed", outcome.passed}
      ])
    end
  end

  @type t :: Noul.t() | Score.t() | Choice.t()

  @doc """
  The question's text: a Noul's statement, a Score's or Choice's question.
  """
  @spec text(t()) :: String.t()
  def text(%Noul{statement: statement}), do: statement
  def text(%Score{question: question}), do: question
  def text(%Choice{question: question}), do: question

  @doc """
  The wire question a provider is sent for a scored question. A Choice
  sends its option names only: credits stay in DeepEvalEx.
  """
  @spec to_question(t()) :: Question.t()
  def to_question(%Noul{} = noul),
    do: %Question.Noul{instructions: noul.statement, true: noul.true, false: noul.false}

  def to_question(%Score{} = score),
    do: %Question.Score{instructions: score.question, levels: score.levels}

  def to_question(%Choice{} = choice),
    do: %Question.Choice{
      instructions: choice.question,
      options: for({name, _credit} <- choice.options, do: {name, nil})
    }

  @doc """
  Parses a rendered `_experimental_system_one_questions` template, a JSON
  array of questions discriminated on `"type"` (`"noul"`, `"score"` or
  `"choice"`), deepeval's `parse_questions`. Unknown keys are ignored and a
  Choice's options keep their JSON order.

  Raises `DeepEvalEx.DeepEvalError` with deepeval's message when the text
  is not such an array.

  ## Examples

      iex> DeepEvalEx.SystemOne.Scored.parse!(~s([{"type": "noul", "statement": "Grounded.", "weight": 2}]))
      [%DeepEvalEx.SystemOne.Scored.Noul{statement: "Grounded.", weight: 2.0}]
  """
  @spec parse!(String.t()) :: [t()]
  def parse!(rendered) when is_binary(rendered) do
    case Jason.decode(rendered, objects: :ordered_objects) do
      {:ok, items} when is_list(items) ->
        items |> Enum.with_index() |> Enum.map(&parse_item!/1)

      {:ok, _other} ->
        parse_error!("Input should be a valid list")

      {:error, %Jason.DecodeError{} = error} ->
        parse_error!(Exception.message(error))
    end
  end

  @tags %{"noul" => Noul, "score" => Score, "choice" => Choice}

  defp parse_item!({%Jason.OrderedObject{values: values}, index}) do
    # A repeated key keeps its last value, as in `json.loads`.
    fields = Map.new(values)

    case Map.fetch(fields, "type") do
      {:ok, tag} when is_map_key(@tags, tag) ->
        module = Map.fetch!(@tags, tag)

        case validate(module, known_fields(module, fields)) do
          {:ok, question} -> question
          {:error, field, message} -> parse_error!("#{index}.#{tag}.#{field}: #{message}")
        end

      {:ok, tag} ->
        parse_error!(
          "#{index}: Input tag #{Python.repr(tag)} found using 'type' does not match any " <>
            "of the expected tags: 'noul', 'score', 'choice'"
        )

      :error ->
        parse_error!("#{index}: Unable to extract tag using discriminator 'type'")
    end
  end

  defp parse_item!({_other, index}),
    do: parse_error!("#{index}: Unable to extract tag using discriminator 'type'")

  defp parse_error!(detail) do
    raise DeepEvalError,
      message:
        "_experimental_system_one_questions must render to a JSON array of " <>
          "Noul / Score / Choice questions: #{detail}"
  end

  # The fields of a JSON object the question's struct declares, as atoms.
  defp known_fields(module, fields) do
    for key <- module |> struct() |> Map.keys(),
        key != :__struct__,
        Map.has_key?(fields, Atom.to_string(key)),
        into: %{},
        do: {key, convert(key, Map.fetch!(fields, Atom.to_string(key)))}
  end

  defp convert(:options, %Jason.OrderedObject{values: values}), do: python_pairs(values)
  defp convert(_key, value), do: value

  # A JSON object as `json.loads` reads it: a repeated key keeps its first
  # position and its last value.
  defp python_pairs(values) do
    last = Map.new(values)

    {pairs, _seen} =
      Enum.flat_map_reduce(values, MapSet.new(), fn {key, _value}, seen ->
        if MapSet.member?(seen, key),
          do: {[], seen},
          else: {[{key, Map.fetch!(last, key)}], MapSet.put(seen, key)}
      end)

    pairs
  end

  @doc false
  @spec build!(module(), keyword() | map()) :: t()
  def build!(module, fields) do
    fields = Map.new(fields)

    case module |> struct() |> Map.keys() |> then(&Map.drop(fields, &1)) |> Map.keys() do
      [] -> :ok
      [key | _] -> raise KeyError, key: key, term: module
    end

    case validate(module, fields) do
      {:ok, question} -> question
      {:error, _field, message} -> raise ArgumentError, message
    end
  end

  # Fields are checked in pydantic's order: the weight, then the text,
  # then the levels or options.
  defp validate(module, fields) do
    name = module |> Module.split() |> List.last()

    with {:ok, weight} <- weight(name, Map.get(fields, :weight, 1.0)),
         {:ok, {key, text}} <- text(module, name, fields),
         {:ok, rest} <- rest(module, fields) do
      {:ok,
       struct!(module, fields |> Map.merge(rest) |> Map.merge(%{:weight => weight, key => text}))}
    end
  end

  defp weight(_name, weight) when is_number(weight) and weight > 0, do: {:ok, weight * 1.0}

  defp weight(name, weight) when is_number(weight),
    do: {:error, :weight, "#{name} weight must be greater than 0; got #{Python.repr(weight)}."}

  defp weight(name, weight),
    do: {:error, :weight, "#{name} weight must be a number; got #{inspect(weight)}."}

  defp text(module, name, fields) do
    key = if module == Noul, do: :statement, else: :question
    value = Map.get(fields, key)

    cond do
      not is_binary(value) ->
        {:error, key, "#{name} #{key} must be a string; got #{inspect(value)}."}

      String.trim(value) == "" ->
        {:error, key, "#{name} #{key} cannot be empty."}

      true ->
        {:ok, {key, value}}
    end
  end

  defp rest(Noul, _fields), do: {:ok, %{}}

  defp rest(Score, fields) do
    levels = Map.get(fields, :levels)

    cond do
      not is_list(levels) or not Enum.all?(levels, &is_binary/1) ->
        {:error, :levels, "Score levels must be a list of strings; got #{inspect(levels)}."}

      length(levels) not in @min_score_levels..@max_score_levels ->
        {:error, :levels,
         "Score needs between #{@min_score_levels} and #{@max_score_levels} levels; " <>
           "got #{length(levels)}."}

      Enum.any?(levels, &(String.trim(&1) == "")) ->
        {:error, :levels, "Score levels cannot be empty."}

      Enum.uniq(levels) != levels ->
        {:error, :levels, "Score levels must be unique."}

      true ->
        {:ok, %{levels: levels}}
    end
  end

  defp rest(Choice, fields) do
    with {:ok, options} <- options(Map.get(fields, :options)),
         :ok <- check_options(options) do
      {:ok, %{options: options}}
    end
  end

  defp options(options) when is_map(options), do: options(Enum.to_list(options))

  defp options(options) when is_list(options) do
    Enum.reduce_while(options, {:ok, []}, fn
      {name, credit}, {:ok, acc}
      when (is_binary(name) or is_atom(name)) and (is_number(credit) or is_nil(credit)) ->
        {:cont, {:ok, [{option_name(name), credit && credit * 1.0} | acc]}}

      option, _acc ->
        {:halt,
         {:error, :options,
          "Choice options must be {name, credit | nil} pairs; got #{inspect(option)}."}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp options(options),
    do: {:error, :options, "Choice options must be a list or map; got #{inspect(options)}."}

  defp option_name(name) when is_binary(name), do: name
  defp option_name(nil), do: ""
  defp option_name(name), do: Atom.to_string(name)

  defp check_options(options) do
    names = Enum.map(options, &elem(&1, 0))

    cond do
      length(options) < 2 ->
        {:error, :options, "Choice needs at least 2 options."}

      Enum.any?(names, &(String.trim(&1) == "")) ->
        {:error, :options, "Choice option names cannot be empty."}

      Enum.uniq(names) != names ->
        {:error, :options, "Choice option names must be unique."}

      bad = Enum.find(options, &out_of_range?/1) ->
        bad_credit(bad)

      Enum.all?(options, &(elem(&1, 1) == nil)) ->
        {:error, :options,
         "Choice needs at least one option with a credit; every option is None (not applicable)."}

      true ->
        :ok
    end
  end

  defp out_of_range?({_name, nil}), do: false
  defp out_of_range?({_name, credit}), do: credit < 0.0 or credit > 1.0

  defp bad_credit({name, credit}) do
    {:error, :options,
     "Choice option '#{name}' has credit #{Python.repr(credit)}; credits must be between " <>
       "0 and 1, or None for not applicable."}
  end
end
