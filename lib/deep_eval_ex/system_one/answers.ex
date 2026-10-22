defmodule DeepEvalEx.SystemOne.Answers do
  @moduledoc """
  A System One model's answers to one request, a port of deepeval 4.3.1's
  `SystemOneAnswers` (`deepeval/models/system_one/schema.py`).

  Answers are kept by question type, then by question key:

  - `nouls` - `DeepEvalEx.SystemOne.Answers.Noul`, P(true) of the
    proposition
  - `choices` - `DeepEvalEx.SystemOne.Answers.Choice`, the chosen option,
    the probability of every option and a confidence
  - `scores` - `DeepEvalEx.SystemOne.Answers.Score`, the score on the level
    indices, the probability of every level index and a confidence

  Probabilities are ordered lists of pairs (`[{name, p}]`, `[{level, p}]`),
  as deepeval iterates them in order when it builds reasons and logs.

  ## Examples

      %DeepEvalEx.SystemOne.Answers{
        nouls: %{"q_0" => %DeepEvalEx.SystemOne.Answers.Noul{probability: 0.88}},
        scores: %{
          "q_1" => %DeepEvalEx.SystemOne.Answers.Score{
            score: 1.6,
            probabilities: [{0, 0.05}, {1, 0.3}, {2, 0.65}],
            confidence: 0.48
          }
        }
      }
  """

  alias DeepEvalEx.SystemOne.Question
  alias Jason.OrderedObject

  defmodule Noul do
    @moduledoc """
    The answer to a Noul question, deepeval's `NoulAnswer`: the probability
    that the proposition holds. Its confidence is derived, see
    `DeepEvalEx.SystemOne.Answers.confidence/1`.
    """

    @type t :: %__MODULE__{probability: number()}

    defstruct [:probability]
  end

  defmodule Choice do
    @moduledoc """
    The answer to a Choice question, deepeval's `ChoiceAnswer`: the chosen
    option's name, every option's probability as an ordered
    `[{name, probability}]`, and the provider's confidence in `0..1`.
    """

    @type t :: %__MODULE__{
            choice: String.t(),
            probabilities: [{String.t(), number()}],
            confidence: number()
          }

    defstruct [:choice, :confidence, probabilities: []]
  end

  defmodule Score do
    @moduledoc """
    The answer to a Score question, deepeval's `ScoreAnswer`: the score on
    the level indices (`0` for the lowest level; it may fall between two),
    every level's probability as an ordered `[{level_index, probability}]`,
    and the provider's confidence in `0..1`.
    """

    @type t :: %__MODULE__{
            score: number(),
            probabilities: [{non_neg_integer(), number()}],
            confidence: number()
          }

    defstruct [:score, :confidence, probabilities: []]
  end

  @type answer :: Noul.t() | Choice.t() | Score.t()

  @type t :: %__MODULE__{
          nouls: %{String.t() => Noul.t()},
          choices: %{String.t() => Choice.t()},
          scores: %{String.t() => Score.t()}
        }

  defstruct nouls: %{}, choices: %{}, scores: %{}

  @kinds [:nouls, :choices, :scores]

  @doc """
  How decisive an answer is, from `0.0` (undecided) to `1.0`.

  A Choice or Score answer carries the confidence its provider gave. A Noul
  has none of its own, so it is `|2p - 1|`, deepeval's
  `NoulAnswer.confidence`, computed with the same float operations
  (`abs(2.0 * 0.6 - 1.0)` is `0.19999999999999996`).

  ## Examples

      iex> DeepEvalEx.SystemOne.Answers.confidence(%DeepEvalEx.SystemOne.Answers.Noul{probability: 0.9})
      0.8
  """
  @spec confidence(answer()) :: number()
  def confidence(%Noul{probability: probability}), do: abs(2.0 * probability - 1.0)
  def confidence(%Choice{confidence: confidence}), do: confidence
  def confidence(%Score{confidence: confidence}), do: confidence

  @doc """
  A Score answer on `0..1`, deepeval's `ScoreAnswer.normalized`: the score
  divided by the highest level index among its probabilities, or `0.0`
  when there is none above `0`.

  ## Examples

      iex> score = %DeepEvalEx.SystemOne.Answers.Score{score: 2, probabilities: [{0, 0.1}, {1, 0.2}, {2, 0.3}, {3, 0.4}]}
      iex> DeepEvalEx.SystemOne.Answers.normalized(score)
      0.6666666666666666
  """
  @spec normalized(Score.t()) :: float()
  def normalized(%Score{score: score, probabilities: probabilities}) do
    case probabilities |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end) do
      top when top > 0 -> score / top
      _ -> 0.0
    end
  end

  @doc """
  The least decisive answer of the request (see `confidence/1`), or `nil`
  when there are no answers, deepeval's `SystemOneAnswers.min_confidence`.

  One question near the fence is enough to make an aggregate over the
  request untrustworthy, so the minimum rather than the mean is what a
  confidence gate looks at.
  """
  @spec min_confidence(t()) :: number() | nil
  def min_confidence(%__MODULE__{} = answers) do
    answers
    |> all()
    |> Enum.map(&confidence/1)
    |> Enum.min(fn -> nil end)
  end

  defp all(answers), do: Enum.flat_map(@kinds, &Map.values(Map.fetch!(answers, &1)))

  @doc """
  The answers whose keys start with `prefix`, with the prefix removed: one
  metric's share of a batched request, whose keys deepeval prefixes per
  metric (`"m1.q_0"` becomes `"q_0"` for `"m1."`).
  """
  @spec take_prefix(t(), String.t()) :: t()
  def take_prefix(%__MODULE__{} = answers, prefix) do
    size = byte_size(prefix)

    taken =
      Map.new(@kinds, fn kind ->
        kept =
          for {<<^prefix::binary-size(size), key::binary>>, answer} <- Map.fetch!(answers, kind),
              into: %{},
              do: {key, answer}

        {kind, kept}
      end)

    struct!(__MODULE__, taken)
  end

  @doc """
  The answers as deepeval's `SystemOneAnswers.model_dump()`: `nouls`,
  `choices` and `scores`, every number a float, Score probabilities keyed by
  the level index as a string. Encode it with `DeepEvalEx.TestRun.JSON` for
  deepeval's bytes.

  Answers are dumped in the order of `keys` - question keys, or the
  questions of the request (`{key, question}`), which is the order deepeval
  receives them in - and any others after them in natural order (`"q_2"`
  before `"q_10"`).

  ## Examples

      iex> answers = %DeepEvalEx.SystemOne.Answers{nouls: %{"q_0" => %DeepEvalEx.SystemOne.Answers.Noul{probability: 1}}}
      iex> DeepEvalEx.TestRun.JSON.encode!(DeepEvalEx.SystemOne.Answers.to_dump(answers))
      ~s({"nouls": {"q_0": {"probability": 1.0}}, "choices": {}, "scores": {}})
  """
  @spec to_dump(t(), [String.t() | {String.t(), Question.t()}]) :: OrderedObject.t()
  def to_dump(%__MODULE__{} = answers, keys \\ []) do
    rank = keys |> Enum.map(&key/1) |> Enum.with_index() |> Map.new()

    OrderedObject.new(
      for kind <- @kinds do
        dumped =
          answers
          |> Map.fetch!(kind)
          |> Enum.sort_by(fn {key, _} -> {Map.get(rank, key, map_size(rank)), natural(key)} end)
          |> Enum.map(fn {key, answer} -> {key, dump(answer)} end)

        {Atom.to_string(kind), OrderedObject.new(dumped)}
      end
    )
  end

  defp key({key, _question}), do: key
  defp key(key) when is_binary(key), do: key

  defp natural(key) do
    ~r/\d+|\D+/
    |> Regex.scan(key)
    |> Enum.map(fn [chunk] ->
      case Integer.parse(chunk) do
        {int, ""} -> {0, int}
        _ -> {1, chunk}
      end
    end)
  end

  defp dump(%Noul{probability: probability}),
    do: OrderedObject.new([{"probability", float(probability)}])

  defp dump(%Choice{} = answer) do
    OrderedObject.new([
      {"choice", answer.choice},
      {"probabilities",
       OrderedObject.new(for {name, p} <- answer.probabilities, do: {name, float(p)})},
      {"confidence", float(answer.confidence)}
    ])
  end

  defp dump(%Score{} = answer) do
    probabilities =
      for {level, p} <- answer.probabilities, do: {Integer.to_string(level), float(p)}

    OrderedObject.new([
      {"score", float(answer.score)},
      {"probabilities", OrderedObject.new(probabilities)},
      {"confidence", float(answer.confidence)}
    ])
  end

  defp float(number) when is_number(number), do: number * 1.0

  @doc """
  Reads answers back from the shape `to_dump/2` writes, decoded from JSON:
  a map or `Jason.OrderedObject` of `nouls`, `choices` and `scores` (any of
  them may be missing), level keys given as strings or integers.

  Probabilities keep the order of an ordered object; a plain map's level
  probabilities are sorted by level.
  """
  @spec from_dump(map() | OrderedObject.t()) :: t()
  def from_dump(dump) do
    %__MODULE__{
      nouls: read(dump, "nouls", &%Noul{probability: &1["probability"]}),
      choices:
        read(dump, "choices", fn answer ->
          %Choice{
            choice: answer["choice"],
            probabilities: Enum.to_list(answer["probabilities"] || []),
            confidence: answer["confidence"]
          }
        end),
      scores:
        read(dump, "scores", fn answer ->
          %Score{
            score: answer["score"],
            probabilities: levels(answer["probabilities"] || []),
            confidence: answer["confidence"]
          }
        end)
    }
  end

  defp read(dump, kind, build) do
    for {key, answer} <- dump[kind] || %{}, into: %{}, do: {key, build.(answer)}
  end

  defp levels(probabilities) do
    levels = for {level, p} <- probabilities, do: {level(level), p}
    if is_map(probabilities) and not is_struct(probabilities), do: Enum.sort(levels), else: levels
  end

  defp level(level) when is_integer(level), do: level
  defp level(level) when is_binary(level), do: String.to_integer(level)
end
