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
  - The result's `:evaluation_model`, `:input_tokens`, `:output_tokens` and
    `:evaluation_cost`, collected from the LLM calls made while measuring.
    Calls made from tasks the metric spawns are only counted when the tasks
    are started with `DeepEvalEx.LLM.Usage.async/1`. The usage of a
    measurement that errors is passed on to the caller's usage scope, where
    `DeepEvalEx.Evaluator` puts it on the errored result

  ## LLM-judged metrics

  Implement the optional `c:evaluation_model/1` callback to report the judge
  model a metric is configured with. Like deepeval's `evaluation_model`,
  which is set when the metric is created, it is reported even when no LLM
  call was made, including on errored results:

      @impl true
      defdelegate evaluation_model(opts), to: DeepEvalEx.LLM.Adapter, as: :model_name

  You can override any of these defaults.
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.{Result, TestCase}

  @type test_case :: TestCase.t()
  @type opts :: keyword()
  @type measure_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Returns the name of this metric.

  The name keys results in reports and exports, so built-in metrics return
  the same name as deepeval's `__name__` (e.g. `"Exact Match"`).
  """
  @callback metric_name() :: String.t()

  @doc """
  Optional callback returning the name of a configured metric struct.

  Implement it when the name depends on configuration, as with
  `DeepEvalEx.Metrics.GEval` (`"<name> [GEval]"`). The evaluator prefers it
  over `c:metric_name/0` when given a metric struct, so even errored results
  carry the configured name.
  """
  @callback metric_name(metric :: struct()) :: String.t()

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

  @doc """
  Optional callback returning the name of the judge model the metric calls
  with `opts`, or `nil` when it calls none.

  Used as the result's `:evaluation_model` when the measurement recorded no
  LLM usage, so that LLM metrics name their judge even when they decide
  without a call or error first. Metrics that never call an LLM, such as
  `DeepEvalEx.Metrics.ExactMatch`, leave it unimplemented.
  """
  @callback evaluation_model(opts()) :: String.t() | nil

  @optional_callbacks [default_opts: 0, metric_name: 1, evaluation_model: 1]

  defmacro __using__(opts \\ []) do
    default_threshold = Keyword.get(opts, :default_threshold, 0.5)

    quote do
      @behaviour DeepEvalEx.Metrics.BaseMetric

      alias DeepEvalEx.{Result, TestCase}

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
      - LLM usage tracking: the judge model, token counts and cost of every
        LLM call made by `do_measure/2` are set on the result
        (see `DeepEvalEx.LLM.Usage`)
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

        {outcome, usages} =
          unquote(__MODULE__).track_usage(fn ->
            with :ok <- validate_test_case(test_case), do: do_measure(test_case, opts)
          end)

        case outcome do
          {:ok, result} ->
            latency = System.monotonic_time(:millisecond) - start_time

            result =
              unquote(__MODULE__).put_usage(
                %{result | latency_ms: latency},
                unquote(__MODULE__).usage_fields(__MODULE__, opts, usages)
              )

            :telemetry.execute(
              [:deep_eval_ex, :metric, :stop],
              unquote(__MODULE__).stop_measurements(result),
              metadata
            )

            {:ok, result}

          {:error, reason} = error ->
            :telemetry.execute(
              [:deep_eval_ex, :metric, :exception],
              unquote(__MODULE__).exception_measurements(
                System.monotonic_time(:millisecond) - start_time,
                usages
              ),
              Map.put(metadata, :error, reason)
            )

            error
        end
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

  @doc false
  # Runs a measurement in its own usage scope and returns `{outcome, usages}`.
  # The usages are also passed on to any enclosing scope, so a metric measured
  # inside another one adds to the outer metric's usage.
  @spec track_usage((-> outcome)) :: {outcome, [Usage.t()]} when outcome: term()
  def track_usage(fun) do
    {outcome, usages} = Usage.track(fun)
    Usage.record_all(usages)
    {outcome, usages}
  end

  @doc false
  # The evaluation model, token counts and cost to report for a measurement
  # of `module` with `opts` that recorded `usages`, as `DeepEvalEx.Result`
  # fields. Without recorded usage the model is the metric's configured judge
  # (`c:evaluation_model/1`), as deepeval reports it for every LLM metric; it
  # stays nil for metrics that call no LLM.
  @spec usage_fields(module(), keyword(), [Usage.t()]) :: Usage.summary()
  def usage_fields(module, opts, usages) do
    summary =
      Usage.summarize(usages) ||
        %{evaluation_model: nil, input_tokens: nil, output_tokens: nil, evaluation_cost: nil}

    Map.update!(summary, :evaluation_model, &(&1 || evaluation_model(module, opts)))
  end

  @doc false
  # Sets the usage fields on a result. Fields the metric set itself are kept
  # when nothing was recorded for them.
  @spec put_usage(Result.t(), Usage.summary()) :: Result.t()
  def put_usage(result, fields) do
    Enum.reduce(fields, result, fn
      {_key, nil}, result -> result
      {key, value}, result -> Map.put(result, key, value)
    end)
  end

  defp evaluation_model(module, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :evaluation_model, 1) do
      module.evaluation_model(opts)
    end
  end

  @doc false
  # Measurements of the `[:deep_eval_ex, :metric, :exception]` event: the
  # tokens and cost spent before the error, when known.
  @spec exception_measurements(integer(), [Usage.t()]) :: map()
  def exception_measurements(duration, usages) do
    usages
    |> Usage.summarize()
    |> Kernel.||(%{})
    |> Map.take([:input_tokens, :output_tokens, :evaluation_cost])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {:evaluation_cost, cost} -> {:cost, cost}
      pair -> pair
    end)
    |> Map.put(:duration, duration)
  end

  @doc false
  # Measurements of the `[:deep_eval_ex, :metric, :stop]` event; usage keys
  # are only present when known.
  @spec stop_measurements(Result.t()) :: map()
  def stop_measurements(result) do
    [
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      cost: result.evaluation_cost
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(%{duration: result.latency_ms, score: result.score})
  end
end
