defmodule DeepEvalEx.TestRun.ExpectationsData do
  @moduledoc """
  How a test case's expectations were judged, deepeval 4.3.1's
  `ExpectationsData` (`tracing/api.py`), built as its
  `create_expectations_data` builds it (`evaluate/utils.py`).

  The expectations of a test case (see `DeepEvalEx.Dataset.Expectations`)
  are judged after its metrics, as a result named `"Expectations"`. That
  result carries this as its `:expectations_data`, and
  `DeepEvalEx.TestRun.from_results/3` exports it as the test case's
  `expectationsData`, not as one of its `metricsData`, and leaves it out of
  `metricsScores`. It still decides the test case's success and adds to its
  cost, as deepeval's `update_metric_data`.

  ## Fields

  - `:success`, `:score`, `:reason`, `:evaluation_model`,
    `:evaluation_cost` and `:error` - the result's, as deepeval's
    `MetricData`: an errored result has no score or reason
  - `:verdicts` - one `DeepEvalEx.TestRun.ExpectationsData.Verdict` per
    condition the judge answered, `must` conditions first, in order. Empty
    under System One, which answers with probabilities, and when the judge
    failed before answering

  ## Examples

      iex> alias DeepEvalEx.TestRun.ExpectationsData
      iex> data = %ExpectationsData{
      ...>   success: true,
      ...>   score: 1.0,
      ...>   verdicts: [
      ...>     %ExpectationsData.Verdict{
      ...>       kind: "MUST",
      ...>       condition: "Cites a source",
      ...>       status: "pass",
      ...>       reason: "It links the policy.",
      ...>       evidence: "See /refunds."
      ...>     }
      ...>   ],
      ...>   evaluation_model: "gpt-4.1"
      ...> }
      iex> data |> ExpectationsData.to_map() |> DeepEvalEx.TestRun.JSON.encode!()
      ~s({"success": true, "score": 1.0, "verdicts": [{"kind": "MUST", "condition": "Cites a source", ) <>
        ~s("status": "pass", "reason": "It links the policy.", "evidence": "See /refunds."}], ) <>
        ~s("evaluationModel": "gpt-4.1"})
  """

  alias DeepEvalEx.Result
  alias Jason.OrderedObject

  defmodule Verdict do
    @moduledoc """
    How the judge answered one condition, deepeval's `ExpectationVerdict`:
    its `kind` (`"MUST"` or `"MUST_NOT"`), the `condition`, the `status`
    (`"pass"`, `"fail"` or `"unable_to_evaluate"`) and the judge's
    `reason` and supporting `evidence` (`""` when it had none).
    """

    @type t :: %__MODULE__{
            kind: String.t(),
            condition: String.t(),
            status: String.t(),
            reason: String.t(),
            evidence: String.t()
          }

    defstruct [:kind, :condition, :status, :reason, :evidence]
  end

  @type t :: %__MODULE__{
          success: boolean() | nil,
          score: number() | nil,
          reason: String.t() | nil,
          verdicts: [Verdict.t()],
          evaluation_model: String.t() | nil,
          evaluation_cost: float() | nil,
          error: String.t() | nil
        }

  defstruct [:success, :score, :reason, :evaluation_model, :evaluation_cost, :error, verdicts: []]

  @doc """
  Builds the expectations data of `result`, the Expectations result of a
  test case with `expectations`, deepeval's `create_expectations_data`.

  `verdicts` are the judge's answers in the order of the conditions, each a
  map with `:status`, `:reason` and `:evidence`; they are paired with the
  `must` then `must_not` conditions, as deepeval zips them.
  """
  @spec new(Result.t(), DeepEvalEx.Dataset.Expectations.t(), [map()]) :: t()
  def new(%Result{} = result, expectations, verdicts) do
    errored? = Result.errored?(result)

    conditions =
      Enum.map(expectations.must, &{"MUST", &1}) ++
        Enum.map(expectations.must_not, &{"MUST_NOT", &1})

    %__MODULE__{
      success: result.success,
      score: if(errored?, do: nil, else: result.score),
      reason: if(errored?, do: nil, else: result.reason),
      verdicts:
        Enum.zip_with(conditions, verdicts, fn {kind, condition}, verdict ->
          %Verdict{
            kind: kind,
            condition: condition,
            status: verdict.status,
            reason: verdict.reason,
            evidence: verdict.evidence
          }
        end),
      evaluation_model: result.evaluation_model,
      evaluation_cost: result.evaluation_cost,
      error: result.error
    }
  end

  @doc """
  The expectations data as deepeval exports it,
  `model_dump(by_alias=True, exclude_none=True)`: its camelCase keys in
  deepeval's order, `nil`s left out, the score and cost as floats.
  """
  @spec to_map(t()) :: OrderedObject.t()
  def to_map(%__MODULE__{} = data) do
    [
      {"success", data.success},
      {"score", to_float(data.score)},
      {"reason", data.reason},
      {"verdicts", Enum.map(data.verdicts, &verdict_map/1)},
      {"evaluationModel", data.evaluation_model},
      {"evaluationCost", to_float(data.evaluation_cost)},
      {"error", data.error}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> OrderedObject.new()
  end

  @doc false
  # The expectations data of a decoded `expectationsData` object (as
  # to_map/1 writes it), as DeepEvalEx.TestRun.Cache reads it back.
  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      success: map["success"],
      score: map["score"],
      reason: map["reason"],
      verdicts:
        Enum.map(map["verdicts"] || [], fn verdict ->
          %Verdict{
            kind: verdict["kind"],
            condition: verdict["condition"],
            status: verdict["status"],
            reason: verdict["reason"],
            evidence: verdict["evidence"]
          }
        end),
      evaluation_model: map["evaluationModel"],
      evaluation_cost: map["evaluationCost"],
      error: map["error"]
    }
  end

  defp verdict_map(%Verdict{} = verdict) do
    OrderedObject.new([
      {"kind", verdict.kind},
      {"condition", verdict.condition},
      {"status", verdict.status},
      {"reason", verdict.reason},
      {"evidence", verdict.evidence}
    ])
  end

  defp to_float(nil), do: nil
  defp to_float(number), do: number / 1
end
