# Phoenix LiveView Integration

Real-time LLM evaluation with Phoenix LiveView.

## Overview

DeepEvalEx integrates with Phoenix LiveView to provide real-time evaluation progress, results visualization, and interactive evaluation interfaces.

> **Note**: Phoenix/LiveView integration is planned for a future release. This guide documents the intended API and patterns.

## Quick Start

### 1. Add Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:deep_eval_ex, "~> 0.1.0"},
    {:phoenix_live_view, "~> 0.20"}
  ]
end
```

### 2. Basic LiveView

```elixir
defmodule MyAppWeb.EvaluationLive do
  use MyAppWeb, :live_view

  alias DeepEvalEx.{TestCase, Evaluator, Metrics}

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      test_cases: [],
      results: [],
      running: false,
      progress: 0
    )}
  end

  def render(assigns) do
    ~H"""
    <div class="evaluation-container">
      <h1>LLM Evaluation</h1>

      <form phx-submit="run_evaluation">
        <textarea name="test_cases" placeholder="Enter test cases (JSON)"></textarea>
        <button type="submit" disabled={@running}>
          <%= if @running, do: "Running...", else: "Run Evaluation" %>
        </button>
      </form>

      <%= if @running do %>
        <div class="progress-bar">
          <div class="progress" style={"width: #{@progress}%"}></div>
        </div>
      <% end %>

      <div class="results">
        <%= for result <- @results do %>
          <div class={"result #{if result.success, do: "pass", else: "fail"}"}>
            <span class="metric"><%= result.metric %></span>
            <span class="score"><%= Float.round(result.score * 100, 1) %>%</span>
            <%= if result.reason do %>
              <p class="reason"><%= result.reason %></p>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("run_evaluation", %{"test_cases" => json}, socket) do
    test_cases = parse_test_cases(json)

    # Run evaluation in background task
    parent = self()
    Task.start(fn ->
      run_evaluation_with_progress(test_cases, parent)
    end)

    {:noreply, assign(socket, running: true, progress: 0, results: [])}
  end

  def handle_info({:progress, progress}, socket) do
    {:noreply, assign(socket, progress: progress)}
  end

  def handle_info({:result, result}, socket) do
    {:noreply, update(socket, :results, &[result | &1])}
  end

  def handle_info(:complete, socket) do
    {:noreply, assign(socket, running: false, progress: 100)}
  end

  defp run_evaluation_with_progress(test_cases, parent) do
    total = length(test_cases)
    metrics = [Metrics.Faithfulness, Metrics.AnswerRelevancy]

    test_cases
    |> Enum.with_index(1)
    |> Enum.each(fn {test_case, index} ->
      results = Evaluator.evaluate_single(test_case, metrics)

      Enum.each(results, fn result ->
        send(parent, {:result, result})
      end)

      send(parent, {:progress, round(index / total * 100)})
    end)

    send(parent, :complete)
  end

  defp parse_test_cases(json) do
    json
    |> Jason.decode!()
    |> Enum.map(&TestCase.new!/1)
  end
end
```

## PubSub Integration

For multi-user real-time updates:

```elixir
defmodule MyAppWeb.EvaluationLive do
  use MyAppWeb, :live_view

  @topic "evaluations"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    end

    {:ok, assign(socket, results: [])}
  end

  def handle_event("run_evaluation", params, socket) do
    # Start evaluation in supervised task
    {:ok, _pid} = Task.Supervisor.start_child(
      MyApp.TaskSupervisor,
      fn -> run_and_broadcast(params) end
    )

    {:noreply, socket}
  end

  def handle_info({:evaluation_result, result}, socket) do
    {:noreply, update(socket, :results, &[result | &1])}
  end

  defp run_and_broadcast(params) do
    test_case = build_test_case(params)

    {:ok, result} = Metrics.Faithfulness.measure(test_case)

    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      @topic,
      {:evaluation_result, result}
    )
  end
end
```

## Results Table Component

```elixir
defmodule MyAppWeb.Components.ResultsTable do
  use Phoenix.Component

  def results_table(assigns) do
    ~H"""
    <table class="results-table">
      <thead>
        <tr>
          <th>Metric</th>
          <th>Score</th>
          <th>Status</th>
          <th>Latency</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
        <%= for result <- @results do %>
          <tr class={result_class(result)}>
            <td><%= result.metric %></td>
            <td><%= format_score(result.score) %></td>
            <td><%= status_badge(result) %></td>
            <td><%= result.latency_ms %>ms</td>
            <td>
              <button phx-click="show_details" phx-value-id={result.id}>
                View
              </button>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  defp result_class(result) do
    if result.success, do: "pass", else: "fail"
  end

  defp format_score(score) do
    "#{Float.round(score * 100, 1)}%"
  end

  defp status_badge(result) do
    assigns = %{result: result}
    ~H"""
    <span class={"badge #{if @result.success, do: "success", else: "danger"}"}>
      <%= if @result.success, do: "PASS", else: "FAIL" %>
    </span>
    """
  end
end
```

## Score Visualization

```elixir
defmodule MyAppWeb.Components.ScoreChart do
  use Phoenix.Component

  def score_gauge(assigns) do
    ~H"""
    <div class="score-gauge">
      <svg viewBox="0 0 100 50" class="gauge">
        <path
          d="M 10 50 A 40 40 0 0 1 90 50"
          fill="none"
          stroke="#e5e7eb"
          stroke-width="8"
        />
        <path
          d="M 10 50 A 40 40 0 0 1 90 50"
          fill="none"
          stroke={gauge_color(@score)}
          stroke-width="8"
          stroke-dasharray={"#{@score * 126} 126"}
        />
      </svg>
      <div class="score-value"><%= Float.round(@score * 100, 1) %>%</div>
    </div>
    """
  end

  defp gauge_color(score) when score >= 0.7, do: "#22c55e"
  defp gauge_color(score) when score >= 0.5, do: "#eab308"
  defp gauge_color(_score), do: "#ef4444"
end
```

## Streaming Results

For long-running evaluations with streaming updates:

```elixir
defmodule MyAppWeb.StreamingEvaluationLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, stream(socket, :results, [])}
  end

  def handle_event("evaluate", _params, socket) do
    parent = self()

    Task.start(fn ->
      test_cases
      |> Stream.map(&evaluate_and_send(&1, parent))
      |> Stream.run()

      send(parent, :done)
    end)

    {:noreply, socket}
  end

  def handle_info({:result, result}, socket) do
    {:noreply, stream_insert(socket, :results, result)}
  end

  def render(assigns) do
    ~H"""
    <div id="results" phx-update="stream">
      <div :for={{dom_id, result} <- @streams.results} id={dom_id}>
        <.result_card result={result} />
      </div>
    </div>
    """
  end

  defp evaluate_and_send(test_case, parent) do
    {:ok, result} = Metrics.Faithfulness.measure(test_case)
    send(parent, {:result, %{id: System.unique_integer(), result: result}})
  end
end
```

## Telemetry Integration

Connect telemetry to LiveView:

```elixir
defmodule MyAppWeb.EvaluationDashboardLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      attach_telemetry()
    end

    {:ok, assign(socket, stats: %{
      total: 0,
      passed: 0,
      failed: 0,
      avg_latency: 0
    })}
  end

  defp attach_telemetry do
    :telemetry.attach(
      "live-dashboard-#{inspect(self())}",
      [:deep_eval_ex, :metric, :stop],
      fn _event, measurements, metadata, _config ->
        send(self(), {:telemetry, measurements, metadata})
      end,
      nil
    )
  end

  def handle_info({:telemetry, measurements, metadata}, socket) do
    stats = socket.assigns.stats

    new_stats = %{
      total: stats.total + 1,
      passed: stats.passed + if(measurements.score >= 0.5, do: 1, else: 0),
      failed: stats.failed + if(measurements.score < 0.5, do: 1, else: 0),
      avg_latency: running_avg(stats.avg_latency, measurements.duration, stats.total)
    }

    {:noreply, assign(socket, stats: new_stats)}
  end

  defp running_avg(current_avg, new_value, count) do
    (current_avg * count + new_value) / (count + 1)
  end
end
```

## Example: Complete Evaluation Interface

```elixir
defmodule MyAppWeb.EvaluationSuiteLive do
  use MyAppWeb, :live_view

  alias DeepEvalEx.{TestCase, Evaluator, Metrics}

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      test_cases: [],
      selected_metrics: [:faithfulness, :answer_relevancy],
      results: [],
      running: false,
      current_index: 0,
      total: 0
    )}
  end

  def handle_event("add_test_case", params, socket) do
    test_case = TestCase.new!(params)
    {:noreply, update(socket, :test_cases, &[test_case | &1])}
  end

  def handle_event("toggle_metric", %{"metric" => metric}, socket) do
    metric = String.to_existing_atom(metric)
    metrics = socket.assigns.selected_metrics

    new_metrics = if metric in metrics do
      List.delete(metrics, metric)
    else
      [metric | metrics]
    end

    {:noreply, assign(socket, selected_metrics: new_metrics)}
  end

  def handle_event("run_suite", _params, socket) do
    test_cases = socket.assigns.test_cases
    metrics = get_metric_modules(socket.assigns.selected_metrics)

    # Run in background with progress updates
    parent = self()
    Task.start(fn ->
      run_suite(test_cases, metrics, parent)
    end)

    {:noreply, assign(socket,
      running: true,
      current_index: 0,
      total: length(test_cases),
      results: []
    )}
  end

  defp run_suite(test_cases, metrics, parent) do
    test_cases
    |> Enum.with_index(1)
    |> Enum.each(fn {test_case, index} ->
      results = Evaluator.evaluate_single(test_case, metrics)
      send(parent, {:batch_result, index, results})
    end)

    send(parent, :suite_complete)
  end

  def handle_info({:batch_result, index, results}, socket) do
    {:noreply, socket
      |> assign(current_index: index)
      |> update(:results, &(&1 ++ results))}
  end

  def handle_info(:suite_complete, socket) do
    {:noreply, assign(socket, running: false)}
  end

  defp get_metric_modules(selected) do
    mapping = %{
      faithfulness: Metrics.Faithfulness,
      answer_relevancy: Metrics.AnswerRelevancy,
      hallucination: Metrics.Hallucination,
      contextual_precision: Metrics.ContextualPrecision,
      contextual_recall: Metrics.ContextualRecall
    }

    Enum.map(selected, &Map.fetch!(mapping, &1))
  end
end
```

## See Also

- [Evaluator API](../api/Evaluator.md) - Batch evaluation
- [Telemetry Guide](Telemetry.md) - Monitoring events
- [Quick Start](Quick-Start.md) - Getting started
