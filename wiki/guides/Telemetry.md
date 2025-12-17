# Telemetry & Observability

Monitor DeepEvalEx evaluations with telemetry events.

## Overview

DeepEvalEx emits `:telemetry` events that you can attach to for logging, metrics collection, and monitoring. This integrates with the standard Elixir/Erlang observability ecosystem.

## Events

### Metric Events

#### `[:deep_eval_ex, :metric, :start]`

Emitted when a metric evaluation begins.

| Measurement | Type | Description |
|-------------|------|-------------|
| `system_time` | integer | System time at start |

| Metadata | Type | Description |
|----------|------|-------------|
| `metric` | string | Metric name |
| `test_case_id` | string | Test case name (if set) |

#### `[:deep_eval_ex, :metric, :stop]`

Emitted when a metric evaluation completes successfully.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Duration in milliseconds |
| `score` | float | Evaluation score (0.0-1.0) |

| Metadata | Type | Description |
|----------|------|-------------|
| `metric` | string | Metric name |
| `test_case_id` | string | Test case name (if set) |

#### `[:deep_eval_ex, :metric, :exception]`

Emitted when a metric evaluation fails.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Duration in milliseconds |

| Metadata | Type | Description |
|----------|------|-------------|
| `metric` | string | Metric name |
| `error` | term | Error reason |

### Evaluation Events

#### `[:deep_eval_ex, :evaluation, :start]`

Emitted when batch evaluation begins.

| Measurement | Type | Description |
|-------------|------|-------------|
| `test_case_count` | integer | Number of test cases |
| `metric_count` | integer | Number of metrics |

#### `[:deep_eval_ex, :evaluation, :stop]`

Emitted when batch evaluation completes.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Total duration in ms |
| `test_case_count` | integer | Number of test cases |

### LLM Events

#### `[:deep_eval_ex, :llm, :request]`

Emitted for each LLM API request.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Request duration in ms |

| Metadata | Type | Description |
|----------|------|-------------|
| `adapter` | atom | Adapter used |
| `model` | string | Model name |

## Attaching Handlers

### Basic Handler

```elixir
:telemetry.attach(
  "my-handler",
  [:deep_eval_ex, :metric, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("#{metadata.metric}: #{measurements.score} in #{measurements.duration}ms")
  end,
  nil
)
```

### Multiple Events

```elixir
:telemetry.attach_many(
  "deep-eval-logger",
  [
    [:deep_eval_ex, :metric, :start],
    [:deep_eval_ex, :metric, :stop],
    [:deep_eval_ex, :metric, :exception],
    [:deep_eval_ex, :evaluation, :start],
    [:deep_eval_ex, :evaluation, :stop]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

### Handler Module

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def handle_event([:deep_eval_ex, :metric, :start], _measurements, metadata, _config) do
    Logger.debug("Starting metric: #{metadata.metric}")
  end

  def handle_event([:deep_eval_ex, :metric, :stop], measurements, metadata, _config) do
    Logger.info("Metric completed",
      metric: metadata.metric,
      score: measurements.score,
      duration_ms: measurements.duration
    )
  end

  def handle_event([:deep_eval_ex, :metric, :exception], measurements, metadata, _config) do
    Logger.error("Metric failed",
      metric: metadata.metric,
      error: inspect(metadata.error),
      duration_ms: measurements.duration
    )
  end

  def handle_event([:deep_eval_ex, :evaluation, :start], measurements, _metadata, _config) do
    Logger.info("Starting batch evaluation",
      test_cases: measurements.test_case_count,
      metrics: measurements.metric_count
    )
  end

  def handle_event([:deep_eval_ex, :evaluation, :stop], measurements, _metadata, _config) do
    Logger.info("Batch evaluation completed",
      test_cases: measurements.test_case_count,
      duration_ms: measurements.duration
    )
  end
end
```

## Default Logger

DeepEvalEx includes a default logging handler:

```elixir
# Enable default logging
DeepEvalEx.Telemetry.attach_default_logger()

# Disable it
DeepEvalEx.Telemetry.detach_default_logger()
```

## Integration with Telemetry Metrics

### Using telemetry_metrics

```elixir
# In your application supervision tree
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Metric evaluation latency
      summary("deep_eval_ex.metric.stop.duration",
        unit: {:native, :millisecond},
        tags: [:metric]
      ),

      # Metric scores distribution
      summary("deep_eval_ex.metric.stop.score",
        tags: [:metric]
      ),

      # Count of metric evaluations
      counter("deep_eval_ex.metric.stop.duration",
        tags: [:metric]
      ),

      # Count of failures
      counter("deep_eval_ex.metric.exception.duration",
        tags: [:metric]
      ),

      # Batch evaluation latency
      summary("deep_eval_ex.evaluation.stop.duration",
        unit: {:native, :millisecond}
      )
    ]
  end
end
```

### Using telemetry_poller

```elixir
# Poll for custom metrics periodically
:telemetry_poller.start_link(
  measurements: [
    {MyApp.Metrics, :dispatch_evaluation_stats, []}
  ],
  period: :timer.seconds(10)
)
```

## Phoenix LiveDashboard Integration

Add DeepEvalEx metrics to LiveDashboard:

```elixir
# lib/my_app_web/telemetry.ex
defmodule MyAppWeb.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      # ... your existing metrics ...

      # DeepEvalEx metrics
      summary("deep_eval_ex.metric.stop.duration",
        unit: {:native, :millisecond},
        tags: [:metric],
        description: "Metric evaluation latency"
      ),

      summary("deep_eval_ex.metric.stop.score",
        tags: [:metric],
        description: "Metric scores"
      ),

      counter("deep_eval_ex.metric.exception.duration",
        tags: [:metric],
        description: "Failed metric evaluations"
      )
    ]
  end
end
```

## Custom Metrics Collection

Track evaluation results over time:

```elixir
defmodule MyApp.EvaluationTracker do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :telemetry.attach_many(
      "evaluation-tracker",
      [
        [:deep_eval_ex, :metric, :stop],
        [:deep_eval_ex, :metric, :exception]
      ],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, state}
  end

  def handle_telemetry([:deep_eval_ex, :metric, :stop], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:record, metadata.metric, measurements.score})
  end

  def handle_telemetry([:deep_eval_ex, :metric, :exception], _measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:record_failure, metadata.metric, metadata.error})
  end

  def handle_cast({:record, metric, score}, state) do
    scores = Map.get(state, metric, [])
    {:noreply, Map.put(state, metric, [score | scores])}
  end

  def handle_cast({:record_failure, metric, _error}, state) do
    failures = Map.get(state, {:failures, metric}, 0)
    {:noreply, Map.put(state, {:failures, metric}, failures + 1)}
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def handle_call(:get_stats, _from, state) do
    stats =
      state
      |> Enum.filter(fn {k, _} -> is_binary(k) end)
      |> Enum.map(fn {metric, scores} ->
        {metric, %{
          count: length(scores),
          avg: Enum.sum(scores) / length(scores),
          min: Enum.min(scores),
          max: Enum.max(scores)
        }}
      end)
      |> Map.new()

    {:reply, stats, state}
  end
end
```

## See Also

- [Evaluator API](../api/Evaluator.md) - Batch evaluation
- [Phoenix Integration](Phoenix-Integration.md) - LiveView integration
- [:telemetry documentation](https://hexdocs.pm/telemetry/) - Telemetry library
