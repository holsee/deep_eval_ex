defmodule DeepEvalEx.LLM.InvalidJSONError do
  @moduledoc """
  The judge's answer holds no JSON that `trimAndLoadJson` can load.

  Returned as `{:error, %DeepEvalEx.LLM.InvalidJSONError{}}` by
  `DeepEvalEx.LLM.Adapter.generate_with_schema/3` (see
  `DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json/1`). Its message is
  deepeval 4.3.1's, which an erroring metric's result and its exported
  `MetricData` carry as their `error`.
  """

  @message "Evaluation LLM outputted an invalid JSON. Please use a better evaluation model."

  @type t :: %__MODULE__{message: String.t()}

  defexception message: @message
end
