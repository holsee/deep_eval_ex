defmodule DeepEvalEx.EvaluationResult do
  @moduledoc """
  The outcome of `DeepEvalEx.evaluate/3`, as deepeval's `EvaluationResult`.

  ## Fields

  - `:test_results` - One `DeepEvalEx.TestResult` per evaluated test case,
    in the order the test cases were given
  - `:confident_link` - Link to the run on Confident AI; always `nil`, as
    DeepEvalEx does not upload runs
  - `:test_run_id` - Confident AI's id for the run; always `nil`

  ## Example

      {:ok, %DeepEvalEx.EvaluationResult{test_results: test_results}} =
        DeepEvalEx.evaluate(test_cases, [metric])

      Enum.all?(test_results, & &1.success)
  """

  alias DeepEvalEx.{Classification, Result, TestCase, TestResult}

  @type t :: %__MODULE__{
          test_results: [TestResult.t()],
          confident_link: String.t() | nil,
          test_run_id: String.t() | nil
        }

  defstruct test_results: [], confident_link: nil, test_run_id: nil

  @doc """
  Builds an evaluation result from test cases and their results.

  `results` holds one result list per test case, as `DeepEvalEx.evaluate_run/3`
  returns them, and `classifications`, when given, one list of
  `DeepEvalEx.Classification`s per test case; each test case becomes a
  `DeepEvalEx.TestResult` (see `DeepEvalEx.TestResult.new/4`) with its
  position as `:index`.
  """
  @spec from_results(
          [TestCase.t() | DeepEvalEx.ConversationalTestCase.t()],
          [[Result.t()]],
          [[Classification.t()]] | nil
        ) :: t()
  def from_results(test_cases, results, classifications \\ nil) do
    classifications = classifications || Enum.map(test_cases, fn _ -> [] end)

    test_results =
      [test_cases, results, classifications]
      |> Enum.zip()
      |> Enum.with_index(fn {test_case, case_results, case_classifications}, index ->
        TestResult.new(test_case, case_results, index, case_classifications)
      end)

    %__MODULE__{test_results: test_results}
  end
end
