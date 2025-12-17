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
    - Measurements: `%{duration: integer(), score: float()}`
    - Metadata: `%{metric: String.t(), test_case_id: String.t() | nil}`

  - `[:deep_eval_ex, :metric, :exception]` - Metric evaluation failed
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{metric: String.t(), error: term()}`

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
      "Completed metric: #{metadata.metric}, score: #{Float.round(measurements.score, 3)}, duration: #{measurements.duration}ms"
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
      [:deep_eval_ex, :evaluation, :stop]
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
end
