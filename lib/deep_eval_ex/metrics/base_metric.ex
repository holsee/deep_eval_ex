defmodule DeepEvalEx.Metrics.BaseMetric do
  @moduledoc """
  Behaviour for evaluation metrics.

  All metrics in DeepEvalEx implement this behaviour, which defines
  the interface for measuring test cases against evaluation criteria.

  ## Implementing a Custom Metric

      defmodule MyApp.CustomMetric do
        use DeepEvalEx.Metrics.BaseMetric

        @impl true
        def metric_name, do: "CustomMetric"

        @impl true
        def required_params, do: [:input, :actual_output]

        @impl true
        def measure(test_case, opts) do
          # Your evaluation logic
          score = calculate_score(test_case)
          threshold = Keyword.get(opts, :threshold, 0.5)

          {:ok, DeepEvalEx.Result.new(
            metric: metric_name(),
            score: score,
            threshold: threshold,
            reason: "Explanation..."
          )}
        end
      end

  ## Using the __using__ Macro

  The `use DeepEvalEx.Metrics.BaseMetric` macro provides:

  - Default implementation of `validate_test_case/2`
  - Telemetry instrumentation around `measure/2`
  - Consistent error handling

  You can override any of these defaults.
  """

  alias DeepEvalEx.{TestCase, Result}

  @type test_case :: TestCase.t()
  @type opts :: keyword()
  @type measure_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Returns the name of this metric.
  """
  @callback metric_name() :: String.t()

  @doc """
  Returns the list of required test case parameters for this metric.

  These are validated before `measure/2` is called.

  Common parameters:
  - `:input` - The input prompt
  - `:actual_output` - The LLM's response
  - `:expected_output` - Expected response (for comparison)
  - `:retrieval_context` - Retrieved context (for RAG metrics)
  """
  @callback required_params() :: [atom()]

  @doc """
  Measures a test case and returns a result.

  ## Parameters

  - `test_case` - The test case to evaluate
  - `opts` - Options including:
    - `:threshold` - Pass/fail threshold (0.0 - 1.0)
    - `:model` - LLM model for LLM-based metrics
    - `:adapter` - LLM adapter to use
    - `:include_reason` - Whether to include reasoning (default: true)

  ## Returns

  - `{:ok, result}` - Successful evaluation with result struct
  - `{:error, reason}` - Evaluation failed
  """
  @callback measure(test_case(), opts()) :: measure_result()

  @doc """
  Optional callback to provide default options for the metric.
  """
  @callback default_opts() :: keyword()

  @optional_callbacks [default_opts: 0]

  defmacro __using__(opts \\ []) do
    default_threshold = Keyword.get(opts, :default_threshold, 0.5)

    quote do
      @behaviour DeepEvalEx.Metrics.BaseMetric

      alias DeepEvalEx.{TestCase, Result}

      @default_threshold unquote(default_threshold)

      @doc """
      Returns the default threshold for this metric.
      """
      @spec default_threshold() :: float()
      def default_threshold, do: @default_threshold

      @doc """
      Validates that a test case has all required parameters.
      """
      @spec validate_test_case(TestCase.t()) ::
              :ok | {:error, {:missing_params, [atom()]}}
      def validate_test_case(test_case) do
        TestCase.validate_params(test_case, required_params())
      end

      @doc """
      Measures a test case with validation and telemetry.

      This wraps the underlying `do_measure/2` implementation with:
      - Parameter validation
      - Telemetry events
      - Error handling
      """
      @spec measure(TestCase.t(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
      def measure(test_case, opts \\ []) do
        start_time = System.monotonic_time(:millisecond)

        metadata = %{
          metric: metric_name(),
          test_case_id: Map.get(test_case, :name)
        }

        :telemetry.execute(
          [:deep_eval_ex, :metric, :start],
          %{system_time: System.system_time()},
          metadata
        )

        result =
          with :ok <- validate_test_case(test_case),
               {:ok, result} <- do_measure(test_case, opts) do
            latency = System.monotonic_time(:millisecond) - start_time
            result = %{result | latency_ms: latency}

            :telemetry.execute(
              [:deep_eval_ex, :metric, :stop],
              %{duration: latency, score: result.score},
              metadata
            )

            {:ok, result}
          else
            {:error, reason} = error ->
              :telemetry.execute(
                [:deep_eval_ex, :metric, :exception],
                %{duration: System.monotonic_time(:millisecond) - start_time},
                Map.put(metadata, :error, reason)
              )

              error
          end

        result
      end

      @doc """
      Implement this function with your metric logic.

      The `measure/2` callback wraps this with validation and telemetry.
      """
      @spec do_measure(TestCase.t(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
      def do_measure(_test_case, _opts) do
        raise "do_measure/2 not implemented for #{__MODULE__}"
      end

      defoverridable measure: 2, do_measure: 2, validate_test_case: 1
    end
  end
end
