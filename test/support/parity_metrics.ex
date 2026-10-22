defmodule DeepEvalEx.Test.ParityMetrics do
  @moduledoc """
  Metrics mirroring the deepeval `BaseMetric` stubs in
  `scripts/parity/generate_fixtures.py`, so the parity test can run the
  same scenarios through DeepEvalEx without calling an LLM.
  """

  defmodule Stub do
    @moduledoc """
    Emulates an LLM-judged metric, as the fixture script's `StubMetric`:
    returns a fixed score and reason with a fixed judge model, cost and
    token counts. Passes when the score reaches the threshold.
    """

    use DeepEvalEx.Metrics.BaseMetric

    defstruct [
      :name,
      :score,
      :reason,
      :threshold,
      :evaluation_model,
      :evaluation_cost,
      :input_tokens,
      :output_tokens,
      strict_mode: false
    ]

    @impl true
    def metric_name, do: "Stub"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:input]

    def do_measure(_test_case, opts) do
      {:ok,
       Result.new(
         metric: Keyword.fetch!(opts, :name),
         score: Keyword.fetch!(opts, :score),
         threshold: Keyword.fetch!(opts, :threshold),
         reason: Keyword.fetch!(opts, :reason),
         evaluation_model: Keyword.fetch!(opts, :evaluation_model),
         evaluation_cost: Keyword.fetch!(opts, :evaluation_cost),
         input_tokens: Keyword.fetch!(opts, :input_tokens),
         output_tokens: Keyword.fetch!(opts, :output_tokens)
       )}
    end
  end

  defmodule Failing do
    @moduledoc """
    Always fails, as the fixture script's `ErrorMetric` always raises.
    deepeval's async executor records the exception's message as the
    metric's error; this returns the same message as `{:error, message}`.
    """

    use DeepEvalEx.Metrics.BaseMetric

    defstruct [:name, :threshold, :message, strict_mode: false]

    @impl true
    def metric_name, do: "Failing"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:input]

    def do_measure(_test_case, opts), do: {:error, Keyword.fetch!(opts, :message)}
  end
end
