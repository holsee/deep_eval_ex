defmodule DeepEvalEx.MetricError do
  @moduledoc """
  A metric could not produce a score and errors were not ignored.

  deepeval's `evaluate()` re-raises a metric's exception unless
  `ErrorConfig(ignore_errors=True)`. DeepEvalEx's evaluator does the same
  (`ignore_errors: false`, the default, see `DeepEvalEx.Evaluator`): an
  exception the metric raised is re-raised as it is, and a metric returning
  `{:error, reason}`, which has no exception to re-raise, raises this one
  (or `DeepEvalEx.MissingTestCaseParamsError` for missing test case
  params).

  ## Fields

  - `:message` - The error as an errored result would record it (see
    `DeepEvalEx.Result.error/3`), deepeval's `str(exception)`
  - `:metric` - The metric's name
  - `:reason` - The `reason` the metric returned
  - `:result` - The metric's state when it errored, as deepeval's metric is
    left after `measure()` raises: an errored `DeepEvalEx.Result` with the
    threshold, judge model and LLM usage, and `success: nil`, since only
    `ignore_errors` sets it to `false`
  """

  @type t :: %__MODULE__{
          message: String.t(),
          metric: String.t() | nil,
          reason: term(),
          result: DeepEvalEx.Result.t() | nil
        }

  defexception [:message, :metric, :reason, :result]
end
