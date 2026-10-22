defmodule DeepEvalEx.SystemOne.Spec do
  @moduledoc """
  What a metric asks a System One model at one of its `:hybrid` decision
  points, ports of deepeval 4.3.1's `SystemOneBinarySpec`,
  `SystemOneChoiceSpec` and `SystemOneScoreSpec`
  (`deepeval/metrics/utils/decision.py`).

  A metric builds a spec next to the LLM prompt the decision would
  otherwise take, and hands it to `DeepEvalEx.SystemOne.Decision`:

  - `DeepEvalEx.SystemOne.Spec.Binary` - one yes/no decision, asked as a
    Noul (`DeepEvalEx.SystemOne.Decision.probability/2`)
  - `DeepEvalEx.SystemOne.Spec.Choice` - one option out of `options`
    (`DeepEvalEx.SystemOne.Decision.choice/2`)
  - `DeepEvalEx.SystemOne.Spec.Score` - one of the ordered `levels`
    (`DeepEvalEx.SystemOne.Decision.score/2`)

  ## State

  `state` is what the model judges, sent as the request's JSON object: a
  list of `{key, value}` pairs (a keyword list included), sent in order
  with its keys as strings, a map, or a `Jason.OrderedObject`. Values must
  be JSON-encodable.

  ## Examples

      %DeepEvalEx.SystemOne.Spec.Score{
        instructions: "How well do the tools in `tools_called` match what `input` asks for?",
        levels: ["Misaligned", "Poor selection", "Mixed selection", "Mostly appropriate",
                 "Fully appropriate"],
        state: [input: "What's the weather in Paris?", tools_called: [%{"name" => "get_weather"}]]
      }
  """

  @typedoc "The state a spec's request is about, see the moduledoc."
  @type state :: [{atom() | String.t(), term()}] | map()

  defmodule Binary do
    @moduledoc """
    A yes/no decision, deepeval's `SystemOneBinarySpec`: asked as one Noul
    whose `instructions` state the proposition that means "yes".
    """

    @type t :: %__MODULE__{
            instructions: term(),
            state: DeepEvalEx.SystemOne.Spec.state()
          }

    defstruct [:instructions, state: []]
  end

  defmodule Choice do
    @moduledoc """
    A decision between options, deepeval's `SystemOneChoiceSpec`: asked as
    one Choice over `options`, a list of option names, in order.
    """

    @type t :: %__MODULE__{
            instructions: term(),
            options: [String.t()],
            state: DeepEvalEx.SystemOne.Spec.state()
          }

    defstruct [:instructions, :options, state: []]
  end

  defmodule Score do
    @moduledoc """
    A graded decision, deepeval's `SystemOneScoreSpec`: asked as one Score
    over `levels`, lowest first (2 to 10 of them).
    """

    @type t :: %__MODULE__{
            instructions: term(),
            levels: [term()],
            state: DeepEvalEx.SystemOne.Spec.state()
          }

    defstruct [:instructions, :levels, state: []]
  end
end
