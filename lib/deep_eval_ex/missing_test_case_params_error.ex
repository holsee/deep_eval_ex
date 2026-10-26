defmodule DeepEvalEx.MissingTestCaseParamsError do
  @moduledoc """
  A test case lacks parameters a metric requires, and the metric was
  neither skipped nor its error ignored.

  The counterpart of deepeval's `MissingTestCaseParamsError`, raised by
  `DeepEvalEx.Evaluator` for a metric returning `{:error, {:missing_params,
  params}}` or `{:error, {:empty_param, param}}` (see
  `DeepEvalEx.TestCase.validate_params/2`), or one of the errors of
  `DeepEvalEx.ConversationalTestCase.validate_params/3`, unless
  `:skip_on_missing_params` or `:ignore_errors` is set. Its message is
  deepeval's, e.g. `"'expected_output' cannot be None for the 'Exact Match'
  metric"`.

  Has the fields of `DeepEvalEx.MetricError`.
  """

  @type t :: %__MODULE__{
          message: String.t(),
          metric: String.t() | nil,
          reason: term(),
          result: DeepEvalEx.Result.t() | nil
        }

  defexception [:message, :metric, :reason, :result]
end
