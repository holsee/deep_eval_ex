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
          threshold = Keyword.get(opts, :threshold, default_threshold())

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
  - `default_threshold/0`, set with `use DeepEvalEx.Metrics.BaseMetric,
    default_threshold: 0.7` (default: `0.5`; `nil` makes the metric
    score-only by default)
  - deepeval's `strict_mode`, score-only and `flaky` semantics (see below)
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

  ## Strict mode, score-only and flaky

  Every metric accepts these options, with the semantics of deepeval's
  `BaseMetric`:

  - `:strict_mode` - Forces the threshold to the integer `1`, as deepeval's
    metric constructors do (`self.threshold = 1 if strict_mode else
    threshold`), whatever `:threshold` says. A score below it becomes the
    integer `0`. `measure/2` puts the forced threshold in the options
    `do_measure/2` gets, and clamps the score it returns; metrics whose
    reason depends on the score clamp it themselves first, with
    `strict_score/2`
  - `:threshold` - `nil` makes the metric score-only: its result has no
    `:success` (`nil`), as deepeval's `is_successful()` returns `None`, and
    it neither passes nor fails its test case
  - `:flaky` - The result is reported but never decides its test case's
    success (deepeval's `update_status`)

  The result's `:strict_mode` and `:flaky` are set from these options, and
  exported per metric as deepeval's `strictMode` and `flaky`.

  A metric that applies strict mode to its score itself, as System One's
  whole-metric scoring does, sets the result's `:strict_applied`, and its
  score is then left as it is (a float `0.0` is not turned into the integer
  `0`).

  ## System One

  Every metric accepts deepeval's System One options:

  - `:eval_mode` - who decides: `:llm`, `:hybrid` or `:system_one` (see
    `DeepEvalEx.SystemOne.Mode`; default: the `:eval_mode` setting, else
    `:llm`)
  - `:system_one_model` - the System One model `:hybrid` and `:system_one`
    decide with, anything `DeepEvalEx.SystemOne.Model.resolve/1` accepts
    (default: the `:system_one_model` application config, else Jev)

  `measure/2` resolves them into a `DeepEvalEx.SystemOne.Context`, deepeval's
  `initialize_model` and `initialize_system_one_model`, and passes it to
  `do_measure/2` as `opts[:system_one]`. Under `:system_one` the context has
  no LLM, so no LLM key is needed. A metric runs as one System One request
  under `:system_one` only when it implements the optional
  `c:system_one_eval_spec/2`; any other metric runs `:system_one` as
  `:hybrid`. A System One model whose `init/1` fails raises
  `DeepEvalEx.DeepEvalError` before `do_measure/2` runs.

  Each measure also gets a fresh `DeepEvalEx.SystemOne.Ledger` (deepeval's
  `reset_system_one_state`). Its confidence and fallback reason are set on
  the result as `:confidence` and `:system_one_fallback_reason`; a
  confidence the metric put on the result itself is kept when the ledger
  has none. Neither is exported.

  You can override any of these defaults.
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.{Result, TestCase}
  alias DeepEvalEx.SystemOne.{Context, Ledger}

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

  These are validated before `measure/2` is called, as deepeval's
  `check_llm_test_case_params` (see `DeepEvalEx.TestCase.validate_params/2`).

  Common parameters:
  - `:input` - The input prompt
  - `:actual_output` - The LLM's response
  - `:expected_output` - Expected response (for comparison)
  - `:retrieval_context` - Retrieved context (for RAG metrics)
  - `:context` - Ground-truth context (for Hallucination); it does not stand
    in for `:retrieval_context`, nor the other way round
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

  @doc """
  Optional callback describing how the metric runs as one System One
  request under the `:system_one` eval mode, deepeval's
  `_system_one_eval_spec`: the test case fields to send and the questions
  to ask, or `nil` when it has no such form for `test_case`.

  Implementing it is what lets the metric run `:system_one` at all
  (deepeval's `has_whole_metric_form`); a metric without it runs
  `:system_one` as `:hybrid` (see `DeepEvalEx.SystemOne.Mode.effective/2`).
  It counts even when it returns `nil` for every test case, as for a metric
  that makes its own System One decisions without a whole-chain form.

  A metric that returns a spec calls `DeepEvalEx.SystemOne.Runner.run/3`
  from its `do_measure/2`, which decides the whole measure from it.
  """
  @callback system_one_eval_spec(test_case(), opts()) :: DeepEvalEx.SystemOne.EvalSpec.t() | nil

  @optional_callbacks [
    default_opts: 0,
    metric_name: 1,
    evaluation_model: 1,
    system_one_eval_spec: 2
  ]

  defmacro __using__(opts \\ []) do
    default_threshold = Keyword.get(opts, :default_threshold, 0.5)

    quote do
      @behaviour DeepEvalEx.Metrics.BaseMetric

      alias DeepEvalEx.{Result, TestCase}

      @default_threshold unquote(default_threshold)

      @doc """
      Returns the default threshold for this metric.
      """
      @spec default_threshold() :: number() | nil
      def default_threshold, do: @default_threshold

      @doc """
      Validates that a test case has all required parameters.
      """
      @spec validate_test_case(TestCase.t()) ::
              :ok | {:error, {:missing_params, [atom()]} | {:empty_param, :actual_output}}
      def validate_test_case(test_case) do
        TestCase.validate_params(test_case, required_params())
      end

      @doc """
      Measures a test case with validation and telemetry.

      This wraps the underlying `do_measure/2` implementation with:
      - Parameter validation
      - System One: `do_measure/2` gets the metric's
        `DeepEvalEx.SystemOne.Context` as `opts[:system_one]` and runs with a
        fresh `DeepEvalEx.SystemOne.Ledger`, whose confidence and fallback
        reason are set on the result
      - Strict mode: `do_measure/2` gets `threshold: 1` when
        `:strict_mode` is set, and a returned score below the threshold
        becomes `0`. The result carries `:strict_mode` and `:flaky`
      - Telemetry events
      - Error handling: an exception raised by `do_measure/2` is re-raised
        after the `:exception` telemetry event and after its LLM usage has
        been passed on to the caller's scope; `DeepEvalEx.Evaluator` turns
        it into an errored result
      - LLM usage tracking: the judge model, token counts and cost of every
        LLM call made by `do_measure/2` are set on the result
        (see `DeepEvalEx.LLM.Usage`)
      """
      @spec measure(TestCase.t(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}
      def measure(test_case, opts \\ []) do
        start_time = System.monotonic_time(:millisecond)

        opts =
          opts
          |> unquote(__MODULE__).strict_opts(default_threshold())
          |> unquote(__MODULE__).system_one_opts(__MODULE__)

        metadata = %{
          metric: metric_name(),
          test_case_id: Map.get(test_case, :name)
        }

        :telemetry.execute(
          [:deep_eval_ex, :metric, :start],
          %{system_time: System.system_time()},
          metadata
        )

        {outcome, usages, ledger} =
          unquote(__MODULE__).track_measure(fn ->
            with :ok <- validate_test_case(test_case), do: do_measure(test_case, opts)
          end)

        case outcome do
          {:ok, result} ->
            latency = System.monotonic_time(:millisecond) - start_time

            result =
              result
              |> unquote(__MODULE__).apply_metric_semantics(opts)
              |> Map.put(:latency_ms, latency)
              |> unquote(__MODULE__).put_usage(
                unquote(__MODULE__).usage_fields(__MODULE__, opts, usages)
              )
              |> unquote(__MODULE__).put_system_one_state(ledger)

            :telemetry.execute(
              [:deep_eval_ex, :metric, :stop],
              unquote(__MODULE__).stop_measurements(result),
              metadata
            )

            {:ok, result}

          {:error, reason} = error ->
            unquote(__MODULE__).emit_exception(start_time, usages, metadata, reason)
            error

          {:raised, exception, stacktrace} ->
            unquote(__MODULE__).emit_exception(start_time, usages, metadata, exception)
            reraise exception, stacktrace
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

  @doc """
  The threshold a metric configured with `opts` uses, given its `default`.

  The integer `1` when `:strict_mode` is set, as deepeval's constructors
  force it; otherwise `:threshold` when given, `nil` (score-only) included,
  else `default`.

  ## Examples

      iex> DeepEvalEx.Metrics.BaseMetric.threshold([strict_mode: true, threshold: 0.3], 0.5)
      1

      iex> DeepEvalEx.Metrics.BaseMetric.threshold([threshold: nil], 0.5)
      nil
  """
  @spec threshold(keyword(), number() | nil) :: number() | nil
  def threshold(opts, default) do
    if Keyword.get(opts, :strict_mode, false),
      do: 1,
      else: Keyword.get(opts, :threshold, default)
  end

  @doc """
  Clamps `score` to the integer `0` when `opts` has `:strict_mode` set and
  the score is below `opts[:threshold]`, as deepeval's metrics do
  (`0 if self.strict_mode and score < self.threshold else score`).

  Any other score, including a `nil` one or one without a threshold, is
  returned unchanged.

  ## Examples

      iex> DeepEvalEx.Metrics.BaseMetric.strict_score(0.5, strict_mode: true, threshold: 1)
      0

      iex> DeepEvalEx.Metrics.BaseMetric.strict_score(0.5, threshold: 1)
      0.5
  """
  @spec strict_score(number() | nil, keyword()) :: number() | nil
  def strict_score(score, opts) do
    threshold = Keyword.get(opts, :threshold)

    if Keyword.get(opts, :strict_mode, false) and is_number(score) and is_number(threshold) and
         score < threshold,
       do: 0,
       else: score
  end

  @doc false
  # The options `do_measure/2` gets: in strict mode `:threshold` is forced
  # to 1 (see `threshold/2`).
  @spec strict_opts(keyword(), number() | nil) :: keyword()
  def strict_opts(opts, default) do
    if Keyword.get(opts, :strict_mode, false),
      do: Keyword.put(opts, :threshold, threshold(opts, default)),
      else: opts
  end

  @doc false
  # The options `do_measure/2` gets: `:system_one` is the metric's resolved
  # System One context (see `DeepEvalEx.SystemOne.Context.resolve!/2`).
  @spec system_one_opts(keyword(), module()) :: keyword()
  def system_one_opts(opts, module),
    do: Keyword.put(opts, :system_one, Context.resolve!(module, opts))

  @doc false
  # Applies strict mode to a measured result and records the metric's strict
  # mode and flakiness on it. A clamped score cannot meet the threshold, so
  # success is recomputed only then. A result whose metric applied strict
  # mode itself (`:strict_applied`) keeps its score.
  @spec apply_metric_semantics(Result.t(), keyword()) :: Result.t()
  def apply_metric_semantics(%Result{} = result, opts) do
    strict_opts = [
      strict_mode: Keyword.get(opts, :strict_mode, false),
      threshold: result.threshold
    ]

    result =
      case strict_score(result.score, strict_opts) do
        _score when result.strict_applied -> result
        score when score === result.score -> result
        score -> %{result | score: score, success: Result.successful?(score, result.threshold)}
      end

    %{
      result
      | strict_mode: Keyword.get(opts, :strict_mode, false),
        flaky: Keyword.get(opts, :flaky, false)
    }
  end

  @doc false
  # Runs a measurement with a fresh System One ledger (deepeval's
  # `reset_system_one_state`) in its own usage scope (see `track_usage/1`),
  # and returns `{outcome, usages, ledger}`.
  @spec track_measure((-> outcome)) ::
          {outcome | {:raised, Exception.t(), Exception.stacktrace()}, [Usage.t()], Ledger.t()}
        when outcome: term()
  def track_measure(fun) do
    {{outcome, usages}, ledger} = Ledger.track(fn -> track_usage(fun) end)
    {outcome, usages, ledger}
  end

  @doc false
  # Runs a measurement in its own usage scope and returns `{outcome, usages}`.
  # The usages are also passed on to any enclosing scope, so a metric measured
  # inside another one adds to the outer metric's usage. An exception raised
  # by `fun` is returned as `{:raised, exception, stacktrace}`, so the usage
  # spent before it is not lost; the caller decides whether to re-raise.
  @spec track_usage((-> outcome)) ::
          {outcome | {:raised, Exception.t(), Exception.stacktrace()}, [Usage.t()]}
        when outcome: term()
  def track_usage(fun) do
    {outcome, usages} =
      Usage.track(fn ->
        try do
          fun.()
        rescue
          exception -> {:raised, exception, __STACKTRACE__}
        end
      end)

    Usage.record_all(usages)
    {outcome, usages}
  end

  @doc false
  # Emits `[:deep_eval_ex, :metric, :exception]` for a measurement started at
  # `start_time` (monotonic milliseconds) that failed with `error`.
  @spec emit_exception(integer(), [Usage.t()], map(), term()) :: :ok
  def emit_exception(start_time, usages, metadata, error) do
    :telemetry.execute(
      [:deep_eval_ex, :metric, :exception],
      exception_measurements(System.monotonic_time(:millisecond) - start_time, usages),
      Map.put(metadata, :error, error)
    )
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

  @doc false
  # Sets the measure's System One confidence and fallback reason from its
  # ledger. A confidence the metric set itself is kept when the ledger has
  # none.
  @spec put_system_one_state(Result.t(), Ledger.t()) :: Result.t()
  def put_system_one_state(%Result{} = result, %Ledger{} = ledger) do
    %{
      result
      | confidence: ledger.confidence || result.confidence,
        system_one_fallback_reason:
          Ledger.fallback_reason(ledger) || result.system_one_fallback_reason
    }
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
