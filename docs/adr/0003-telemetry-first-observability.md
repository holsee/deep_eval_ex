# ADR-0003: Telemetry-First Observability

## Status

Accepted

## Date

2024-12-25

## Context

DeepEvalEx evaluates LLM outputs, which involves:

- Multiple API calls to LLM providers (potentially expensive)
- Variable latency per evaluation (seconds to minutes)
- Potential for failures and exceptions
- Need for cost tracking and performance monitoring

Users need visibility into:
- Which metrics are being evaluated
- How long each evaluation takes
- Token usage and estimated costs
- Error rates and failure patterns

## Decision

Emit telemetry events at every measurement and evaluation level. No Logger calls inside core metrics/evaluator code.

**Events emitted:**

```elixir
# Metric-level events
[:deep_eval_ex, :metric, :start]
[:deep_eval_ex, :metric, :stop]
[:deep_eval_ex, :metric, :exception]

# Batch evaluation events
[:deep_eval_ex, :evaluation, :start]
[:deep_eval_ex, :evaluation, :stop]
```

**Event metadata includes:**

```elixir
%{
  metric: "Faithfulness",
  test_case_id: "uuid",
  duration: 1_234_567,  # nanoseconds
  result: %Result{},
  token_usage: %{prompt: 100, completion: 50}
}
```

## Consequences

### Positive

- **Decoupled observability**: Handlers are optional and user-defined
- **Composable**: Works with Logger, StatsD, Prometheus, Phoenix.LiveDashboard
- **Non-invasive**: Zero overhead when no handlers attached
- **Standard**: Follows Elixir ecosystem conventions (Phoenix, Ecto, Oban)
- **Flexible**: Users choose what to log, measure, or alert on

### Negative

- **Handler setup required**: Users must attach handlers to see any output
- **More complex**: Simple `Logger.info` would be easier for basic debugging
- **Event discovery**: Users must know which events exist and their metadata

### Neutral

- Default telemetry handler provided for basic logging (opt-in)
- Metrics are automatically instrumented via BaseMetric macro
- No changes needed to metric implementations for observability

## Alternatives Considered

### Direct Logger calls

- **Rejected**: Hardcodes logging decisions. Users can't easily change log levels, formats, or destinations without code changes.

### Callback-based hooks

- **Rejected**: Would require custom callback registration mechanism. Telemetry already provides this with better tooling.

### OpenTelemetry integration

- **Rejected for now**: OpenTelemetry is more complex and not yet standard in Elixir ecosystem. Can be added later via telemetry handlers.

## References

- [Telemetry Library](https://hexdocs.pm/telemetry/readme.html)
- [Telemetry Best Practices](https://hexdocs.pm/telemetry/writing_code_with_telemetry.html)
- [Phoenix Telemetry Events](https://hexdocs.pm/phoenix/telemetry.html)
