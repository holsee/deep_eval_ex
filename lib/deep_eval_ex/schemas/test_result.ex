defmodule DeepEvalEx.TestResult do
  @moduledoc """
  One evaluated test case, as deepeval's `TestResult`.

  `DeepEvalEx.evaluate/3` returns one per test case in a
  `DeepEvalEx.EvaluationResult`, built as deepeval's `create_test_result`
  builds them for `evaluate()`.

  ## Fields

  - `:name` - The test case's `:name`, or `"test_case_<index>"` as in deepeval
  - `:success` - Whether the test case passed: `false` when a non-flaky
    metric (or a classification) failed, else `true`; `nil` when nothing
    gave a verdict (see `new/4`)
  - `:metrics_data` - One `DeepEvalEx.Result` per metric that ran, in the
    order of the metrics (DeepEvalEx's counterpart of deepeval's
    `MetricData`). Skipped results are left out, as deepeval leaves out
    skipped metrics; `[]` where deepeval has `None`
  - `:conversational` - Always `false`: DeepEvalEx has no conversational
    test cases yet
  - `:index` - The test case's position in the evaluated list (deepeval's
    `order`)
  - `:input`, `:actual_output`, `:expected_output`, `:context`,
    `:retrieval_context`, `:metadata` - The test case's own fields; of a
    `DeepEvalEx.Schemas.RetrievedContextData` in `:retrieval_context` only
    its `:context` is kept, as deepeval does
  - `:classifications` - Classifier results, maps with a `:success` of
    `true`, `false` or `nil`; `[]` where deepeval has `None`. DeepEvalEx has
    no classifiers yet, so `DeepEvalEx.evaluate/3` always leaves this empty

  deepeval's `multimodal`, `turns` and `expectations` are not modelled.
  """

  alias DeepEvalEx.{Result, TestCase}
  alias DeepEvalEx.Schemas.RetrievedContextData

  @type classification :: %{required(:success) => boolean() | nil, optional(atom()) => term()}

  @type t :: %__MODULE__{
          name: String.t(),
          success: boolean() | nil,
          metrics_data: [Result.t()],
          conversational: boolean(),
          index: non_neg_integer() | nil,
          input: String.t() | nil,
          actual_output: String.t() | nil,
          expected_output: String.t() | nil,
          context: [String.t()] | nil,
          retrieval_context: [String.t()] | nil,
          metadata: map() | nil,
          classifications: [classification()]
        }

  @enforce_keys [:name, :success]
  defstruct [
    :name,
    :success,
    :index,
    :input,
    :actual_output,
    :expected_output,
    :context,
    :retrieval_context,
    :metadata,
    metrics_data: [],
    conversational: false,
    classifications: []
  ]

  @doc """
  Builds the test result of `test_case`, evaluated at position `index`
  with `results`, as deepeval's `create_test_result`.

  The test case starts successful, as deepeval's API test case does, and
  fails when a non-flaky result failed; score-only results (`success: nil`)
  and flaky ones never decide it. `classifications` are then folded in as
  deepeval's `_local_success` does: a failed classification fails the test
  case, one without a verdict leaves it as it is, and when no metric ran the
  classifications alone decide, so the success is `nil` if none of them has
  a verdict.
  """
  @spec new(TestCase.t(), [Result.t()], non_neg_integer(), [classification()]) :: t()
  def new(%TestCase{} = test_case, results, index, classifications \\ []) do
    metrics_data = Enum.reject(results, & &1.skipped)

    %__MODULE__{
      name: test_case.name || "test_case_#{index}",
      success: local_success(metrics_success(metrics_data), metrics_data, classifications),
      metrics_data: metrics_data,
      index: index,
      input: test_case.input,
      actual_output: test_case.actual_output,
      expected_output: test_case.expected_output,
      context: test_case.context,
      retrieval_context: contexts(test_case.retrieval_context),
      metadata: test_case.metadata,
      classifications: classifications
    }
  end

  # deepeval's create_api_test_case keeps only a RetrievedContextData's context
  defp contexts(nil), do: nil

  defp contexts(retrieval_context),
    do: Enum.map(retrieval_context, &RetrievedContextData.context/1)

  # deepeval's LLMApiTestCase starts with success=True; update_metric_data
  # sets it to False when a non-flaky metric's success is False.
  defp metrics_success(metrics_data) do
    not Enum.any?(metrics_data, &(not &1.flaky and &1.success == false))
  end

  # deepeval's _local_success.
  defp local_success(success, _metrics_data, []), do: success

  defp local_success(success, metrics_data, classifications) do
    start = if metrics_data == [], do: nil, else: success

    Enum.reduce_while(classifications, start, fn
      %{success: false}, _success -> {:halt, false}
      %{success: true}, nil -> {:cont, true}
      _classification, success -> {:cont, success}
    end)
  end
end
