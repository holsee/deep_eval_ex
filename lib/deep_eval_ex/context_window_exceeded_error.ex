defmodule DeepEvalEx.ContextWindowExceededError do
  @moduledoc """
  A metric's request does not fit in the evaluation model's context window,
  deepeval 4.3.1's `ContextWindowExceededError`.

  A metric under the `system_one` eval mode raises it when its test case is
  too large for its System One model to judge in one request, with
  deepeval's "could not run on System One: ... Switch this metric back to
  the LLM ..." message. A provider reports the overflow itself as a
  `DeepEvalEx.SystemOne.Error` with `reason: :context_limit` (deepeval's
  `SystemOneContextLimitError`).

  In deepeval it subclasses `DeepEvalError`; `DeepEvalEx.SystemOne.decide/3`
  handles it as it handles `DeepEvalEx.DeepEvalError`.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]
end
