defmodule DeepEvalEx.SystemOne.Question do
  @moduledoc """
  The questions a System One model answers, ports of deepeval 4.3.1's
  `NoulQuestion`, `ChoiceQuestion` and `ScoreQuestion`
  (`deepeval/models/system_one/schema.py`).

  - `DeepEvalEx.SystemOne.Question.Noul` - P(true) of a proposition, with
    optional `true` / `false` criteria saying what each outcome means
  - `DeepEvalEx.SystemOne.Question.Choice` - one option out of a closed set:
    `options` is an ordered list of `{name, description | nil}`
  - `DeepEvalEx.SystemOne.Question.Score` - one of 2 to 10 ordered `levels`,
    lowest first

  These are wire questions, what a provider is sent. Weights, Choice credits
  and not-applicable options belong to the scored questions built on top of
  them and never reach the provider.

  `instructions` is any JSON-encodable term: a string, or for instance
  `%{"claim" => claim, "question" => question}` for a per-claim verdict.

  A request asks several questions at once, as an ordered list of
  `{key, question}` (deepeval's question dict): the order is the order
  deepeval iterates them in, and the keys are opaque to the provider.

  ## Examples

      [
        {"q_0", %DeepEvalEx.SystemOne.Question.Noul{
           instructions: "Every claim in `actual_output` is supported by `retrieval_context`."}},
        {"q_1", %DeepEvalEx.SystemOne.Question.Score{
           instructions: "How grounded is `actual_output`?",
           levels: ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]}}
      ]
  """

  alias Jason.OrderedObject

  defmodule Noul do
    @moduledoc """
    A Noul question, deepeval's `NoulQuestion`: how likely `instructions`
    holds of the state. `true` and `false` optionally describe what each
    outcome means.
    """

    @type t :: %__MODULE__{instructions: term(), true: term(), false: term()}

    defstruct [:instructions, true: nil, false: nil]
  end

  defmodule Choice do
    @moduledoc """
    A Choice question, deepeval's `ChoiceQuestion`: which of `options`
    best answers `instructions`. `options` is an ordered list of
    `{name, description}` pairs; a `nil` description sends the bare name.
    """

    @type t :: %__MODULE__{instructions: term(), options: [{String.t(), term()}]}

    defstruct [:instructions, options: []]
  end

  defmodule Score do
    @moduledoc """
    A Score question, deepeval's `ScoreQuestion`: which of the ordered
    `levels` (lowest first) answers `instructions`. Its answer is a level
    index, `0` for the first level.
    """

    @type t :: %__MODULE__{instructions: term(), levels: [term()]}

    defstruct [:instructions, levels: []]
  end

  @type t :: Noul.t() | Choice.t() | Score.t()

  @typedoc "The questions of one request, keyed and in order."
  @type questions :: [{String.t(), t()}]

  @doc """
  The question in the TypeSafe SDK's shape, deepeval's
  `TypeSafeModel._to_sdk_questions`: `type`, `instructions` and `criteria`,
  in that order.

  - a Noul's criteria are `{"true": ..., "false": ...}`, left out when
    both are `nil`
  - a Choice's are its options, `{name: description}` in order
  - a Score's are its levels

  ## Examples

      iex> question = %DeepEvalEx.SystemOne.Question.Score{instructions: "How?", levels: ["Low", "High"]}
      iex> DeepEvalEx.TestRun.JSON.encode!(DeepEvalEx.SystemOne.Question.to_wire(question))
      ~s({"type": "score", "instructions": "How?", "criteria": ["Low", "High"]})
  """
  @spec to_wire(t()) :: OrderedObject.t()
  def to_wire(%Noul{true: nil, false: nil} = question), do: wire("noul", question, [])

  def to_wire(%Noul{} = question) do
    wire("noul", question,
      criteria: OrderedObject.new([{"true", question.true}, {"false", question.false}])
    )
  end

  def to_wire(%Choice{options: options} = question),
    do: wire("choice", question, criteria: OrderedObject.new(options))

  def to_wire(%Score{levels: levels} = question), do: wire("score", question, criteria: levels)

  defp wire(type, question, criteria) do
    OrderedObject.new(
      [{"type", type}, {"instructions", question.instructions}] ++
        Enum.map(criteria, fn {:criteria, value} -> {"criteria", value} end)
    )
  end

  @doc """
  The questions of a request in the SDK's shape, `to_wire/1` of each under
  its key, in order.
  """
  @spec to_wire_map(questions()) :: OrderedObject.t()
  def to_wire_map(questions) do
    OrderedObject.new(for {key, question} <- questions, do: {key, to_wire(question)})
  end
end
