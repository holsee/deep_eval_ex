defmodule DeepEvalEx.SystemOne.EvalSpec do
  @moduledoc """
  What a metric sends to a System One model under the `:system_one` eval
  mode, deepeval 4.3.1's `SystemOneEvalSpec`
  (`deepeval/metrics/utils/system_one.py`).

  A metric describes itself as one System One request by returning a spec
  from `c:DeepEvalEx.Metrics.BaseMetric.system_one_eval_spec/2`, and
  `DeepEvalEx.SystemOne.Runner.run/3` decides the whole measure from it:

  - `evaluation_params` - the test case fields sent as the state's
    `"test_case"`, in order (e.g. `[:actual_output, :retrieval_context]`);
    unset and empty fields are left out
  - `questions` - the decision points, `DeepEvalEx.SystemOne.Scored`
    questions. Each maps onto `0..1` (see `DeepEvalEx.SystemOne.Scoring`)
    and the score is their weighted mean. There is no reason prompt: the
    reason is built from the answers
  - `extra_state` - what is not a test case field (the available tools, a
    metric argument), as `{key, value}` pairs (a keyword list included),
    each sent under its own top-level state key the questions can name;
    `nil` values are left out

  ## Examples

      @impl true
      def system_one_eval_spec(_test_case, _opts) do
        %DeepEvalEx.SystemOne.EvalSpec{
          evaluation_params: [:actual_output, :retrieval_context],
          questions: DeepEvalEx.SystemOne.Scored.parse!(questions_template())
        }
      end
  """

  alias DeepEvalEx.SystemOne.Scored

  @type t :: %__MODULE__{
          evaluation_params: [atom() | String.t()],
          questions: [Scored.t()],
          extra_state: [{atom() | String.t(), term()}]
        }

  defstruct evaluation_params: [], questions: [], extra_state: []
end
