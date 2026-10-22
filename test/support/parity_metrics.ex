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

  defmodule ConversationalStub do
    @moduledoc """
    `Stub` for conversational test cases, as the fixture script's
    `ConversationalStubMetric`: the same fixed values from a
    `DeepEvalEx.Metrics.BaseConversationalMetric`.
    """

    use DeepEvalEx.Metrics.BaseConversationalMetric

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
    def metric_name, do: "Conversational Stub"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:role, :content]

    def do_measure(test_case, opts), do: Stub.do_measure(test_case, opts)
  end

  defmodule Failing do
    @moduledoc """
    Always raises, as the fixture script's `ErrorMetric` does. deepeval's
    async executor records `str(exception)`, just the message, as the
    metric's error; DeepEvalEx's evaluator records `Exception.message/1`.
    Python's `ValueError` maps to `ArgumentError`, `RuntimeError` to
    `RuntimeError`.
    """

    use DeepEvalEx.Metrics.BaseMetric

    defstruct [:name, :threshold, :message, exception: "ValueError", strict_mode: false]

    @exceptions %{"ValueError" => ArgumentError, "RuntimeError" => RuntimeError}

    @impl true
    def metric_name, do: "Failing"

    @impl true
    def metric_name(%__MODULE__{name: name}), do: name

    @impl true
    def required_params, do: [:input]

    # Raising is the point, so do_measure/2 never returns the result
    # BaseMetric's @spec promises.
    @dialyzer {:nowarn_function, do_measure: 2}
    def do_measure(_test_case, opts) do
      exception = Map.fetch!(@exceptions, Keyword.fetch!(opts, :exception))
      raise exception, Keyword.fetch!(opts, :message)
    end
  end
end
