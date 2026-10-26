defmodule DeepEvalEx.DeepEvalError do
  @moduledoc """
  A framework-originated error, deepeval 4.3.1's `DeepEvalError`.

  Raised for failures deepeval reports with its own base error, such as a
  System One model that is not configured, has no API key, or was asked no
  questions. `DeepEvalEx.SystemOne.decide/3` counts it as a System One
  error: under the `hybrid` eval mode it hands the decision back to the LLM
  rather than crashing the metric.

  deepeval's `ContextWindowExceededError` subclasses `DeepEvalError`; in
  DeepEvalEx it is the separate `DeepEvalEx.ContextWindowExceededError`,
  handled alongside this one.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]
end
