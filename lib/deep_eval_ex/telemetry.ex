defmodule DeepEvalEx.Telemetry do
  @moduledoc """
  Telemetry events for DeepEvalEx.

  DeepEvalEx emits telemetry events that you can attach to for
  logging, metrics, and monitoring.

  ## Events

  ### Metric Events

  - `[:deep_eval_ex, :metric, :start]` - Metric evaluation started
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{metric: String.t(), test_case_id: String.t() | nil}`

  - `[:deep_eval_ex, :metric, :stop]` - Metric evaluation completed
    - Measurements: `%{duration: integer(), score: float() | nil}` (`nil` for an errored result),
      plus `input_tokens: integer()`, `output_tokens: integer()` and `cost: float()`
      (USD) when the metric's LLM calls reported them (see `DeepEvalEx.LLM.Usage`)
    - Metadata: `%{metric: String.t(), test_case_id: String.t() | nil}`

  - `[:deep_eval_ex, :metric, :exception]` - Metric evaluation failed
    - Measurements: `%{duration: integer()}`, plus `input_tokens`,
      `output_tokens` and `cost` when LLM calls made before the error reported them
    - Metadata: `%{metric: String.t(), error: term()}`

  - `[:deep_eval_ex, :metric, :cache_hit]` - A metric reused its cached
    result instead of measuring (see "Cache" in `DeepEvalEx.Evaluator`)
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{metric: String.t(), test_case: String.t() | nil}`

  ### Evaluation Events

  - `[:deep_eval_ex, :evaluation, :start]` - Batch evaluation started
    - Measurements: `%{test_case_count: integer(), metric_count: integer()}`
    - Metadata: `%{}`

  - `[:deep_eval_ex, :evaluation, :stop]` - Batch evaluation completed
    - Measurements: `%{duration: integer(), test_case_count: integer()}`
    - Metadata: `%{}`

  ### LLM Events

  - `[:deep_eval_ex, :llm, :request]` - LLM API request made
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{adapter: atom(), model: String.t()}`

  ### System One Events

  `DeepEvalEx.SystemOne.decide/3` wraps every System One request in a
  `:telemetry.span/3`:

  - `[:deep_eval_ex, :system_one, :request, :start]` - Request sent
    - Measurements: `%{system_time: integer(), monotonic_time: integer()}`
    - Metadata: `%{model: String.t(), mode: atom() | nil, metrics: [String.t()],
      question_count: integer(), batched?: boolean()}`

  - `[:deep_eval_ex, :system_one, :request, :stop]` - Request answered, or
    failed with a System One error
    - Measurements: `%{duration: integer(), monotonic_time: integer()}`, plus
      `input_tokens`, `output_tokens` and `cost` when the request reported them
    - Metadata: the start metadata, plus `error: Exception.t()` for a
      System One error

  - `[:deep_eval_ex, :system_one, :request, :exception]` - The request raised
    an error that is not a System One error
    - Measurements: `%{duration: integer(), monotonic_time: integer()}`
    - Metadata: the start metadata, plus `kind`, `reason` and `stacktrace`

  `metrics` names every metric the request decides for: one for an
  unbatched request, each metric of a packed request (`batched?: true`)
  from `DeepEvalEx.Evaluator`'s batching. Every request is spanned, whether
  it comes from a `:hybrid` decision, a whole-chain measure, `JevEval` or a
  batch.

  - `[:deep_eval_ex, :system_one, :fallback]` - A `:hybrid` decision fell
    back to the LLM after a System One error
    (`DeepEvalEx.SystemOne.Decision.handle_failure/2`)
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{metric: String.t() | nil, reason: String.t()}`, where
      `reason` is the text added to the result's `:system_one_fallback_reason`

  Together these replace deepeval's Jev progress indicator; the default
  logger logs each request and fallback.

  ## Example: Logging Handler

      :telemetry.attach_many(
        "deep-eval-logger",
        [
          [:deep_eval_ex, :metric, :start],
          [:deep_eval_ex, :metric, :stop],
          [:deep_eval_ex, :metric, :exception]
        ],
        &DeepEvalEx.Telemetry.handle_event/4,
        nil
      )

  ## Example: Custom Handler

      defmodule MyApp.DeepEvalHandler do
        require Logger

        def handle_event([:deep_eval_ex, :metric, :stop], measurements, metadata, _config) do
          Logger.info("Metric \#{metadata.metric} completed",
            score: measurements.score,
            duration_ms: measurements.duration
          )
        end
      end

      :telemetry.attach(
        "my-handler",
        [:deep_eval_ex, :metric, :stop],
        &MyApp.DeepEvalHandler.handle_event/4,
        nil
      )
  """

  alias DeepEvalEx.SystemOne.Error

  require Logger

  @doc """
  Default telemetry event handler for logging.

  Attach this to log all DeepEvalEx events:

      DeepEvalEx.Telemetry.attach_default_logger()
  """
  def handle_event([:deep_eval_ex, :metric, :start], _measurements, metadata, _config) do
    Logger.debug("Starting metric: #{metadata.metric}")
  end

  def handle_event([:deep_eval_ex, :metric, :stop], measurements, metadata, _config) do
    Logger.debug(
      "Completed metric: #{metadata.metric}, score: #{format_score(measurements.score)}, duration: #{measurements.duration}ms"
    )
  end

  def handle_event([:deep_eval_ex, :metric, :exception], measurements, metadata, _config) do
    Logger.warning(
      "Metric failed: #{metadata.metric}, error: #{inspect(metadata.error)}, duration: #{measurements.duration}ms"
    )
  end

  def handle_event([:deep_eval_ex, :evaluation, :start], measurements, _metadata, _config) do
    Logger.info(
      "Starting evaluation: #{measurements.test_case_count} test cases, #{measurements.metric_count} metrics"
    )
  end

  def handle_event([:deep_eval_ex, :evaluation, :stop], measurements, _metadata, _config) do
    Logger.info(
      "Evaluation completed: #{measurements.test_case_count} test cases in #{measurements.duration}ms"
    )
  end

  def handle_event(
        [:deep_eval_ex, :system_one, :request, :stop],
        measurements,
        %{error: error} = metadata,
        _config
      ) do
    Logger.warning(
      "System One request failed: #{metadata.model}, #{Enum.join(metadata.metrics, ", ")}, " <>
        "#{Error.format(error)}, duration: #{milliseconds(measurements.duration)}ms"
    )
  end

  def handle_event([:deep_eval_ex, :system_one, :request, :stop], measurements, metadata, _config) do
    Logger.debug(
      "System One request: #{metadata.model}, #{metadata.question_count} questions for " <>
        "#{Enum.join(metadata.metrics, ", ")}, duration: #{milliseconds(measurements.duration)}ms"
    )
  end

  def handle_event(
        [:deep_eval_ex, :system_one, :request, :exception],
        measurements,
        metadata,
        _config
      ) do
    Logger.warning(
      "System One request raised: #{metadata.model}, #{Enum.join(metadata.metrics, ", ")}, " <>
        "#{inspect(metadata.reason)}, duration: #{milliseconds(measurements.duration)}ms"
    )
  end

  def handle_event([:deep_eval_ex, :system_one, :fallback], _measurements, metadata, _config) do
    Logger.info("#{metadata.metric || "A metric"} fell back to the LLM: #{metadata.reason}")
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Attaches the default logging handler to all DeepEvalEx events.
  """
  @spec attach_default_logger() :: :ok
  def attach_default_logger do
    events = [
      [:deep_eval_ex, :metric, :start],
      [:deep_eval_ex, :metric, :stop],
      [:deep_eval_ex, :metric, :exception],
      [:deep_eval_ex, :evaluation, :start],
      [:deep_eval_ex, :evaluation, :stop],
      [:deep_eval_ex, :system_one, :request, :stop],
      [:deep_eval_ex, :system_one, :request, :exception],
      [:deep_eval_ex, :system_one, :fallback]
    ]

    :telemetry.attach_many(
      "deep-eval-ex-default-logger",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc """
  Detaches the default logging handler.
  """
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger do
    :telemetry.detach("deep-eval-ex-default-logger")
  end

  defp milliseconds(duration), do: System.convert_time_unit(duration, :native, :millisecond)

  defp format_score(score) when is_number(score), do: Float.round(score / 1, 3)
  defp format_score(nil), do: "none (errored)"
end
