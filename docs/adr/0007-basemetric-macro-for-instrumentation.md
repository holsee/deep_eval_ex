# ADR-0007: BaseMetric Macro for Automatic Instrumentation

## Status

Accepted

## Date

2024-12-25

## Context

Every metric in DeepEvalEx needs:

1. Test case validation (required params present)
2. Telemetry event emission (start, stop, exception)
3. Error handling and wrapping
4. Default threshold management
5. Consistent public API (`measure/2`)

Implementing these concerns in each metric creates:
- Code duplication across 7+ metrics
- Risk of inconsistent behavior
- Missed instrumentation in new metrics
- More code to test and maintain

## Decision

Use a `__using__` macro in `BaseMetric` to inject shared functionality into all metrics.

```elixir
defmodule DeepEvalEx.Metrics.BaseMetric do
  defmacro __using__(opts \\ []) do
    quote do
      @behaviour DeepEvalEx.Metrics.BaseMetric

      @default_threshold unquote(Keyword.get(opts, :default_threshold, 0.5))

      def default_threshold, do: @default_threshold

      def measure(test_case, opts \\ []) do
        # 1. Validate test case
        with :ok <- validate_test_case(test_case) do
          # 2. Emit start telemetry
          start_time = System.monotonic_time()
          :telemetry.execute([:deep_eval_ex, :metric, :start], %{}, %{metric: metric_name()})

          try do
            # 3. Call implementation
            result = do_measure(test_case, opts)

            # 4. Emit stop telemetry
            duration = System.monotonic_time() - start_time
            :telemetry.execute([:deep_eval_ex, :metric, :stop], %{duration: duration}, %{...})

            result
          rescue
            e ->
              # 5. Emit exception telemetry
              :telemetry.execute([:deep_eval_ex, :metric, :exception], %{}, %{error: e})
              reraise e, __STACKTRACE__
          end
        end
      end

      defp validate_test_case(test_case) do
        # Check required_params/0 are present in test_case
      end
    end
  end
end
```

Metric implementations only define:

```elixir
defmodule DeepEvalEx.Metrics.Faithfulness do
  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  @impl true
  def metric_name, do: "Faithfulness"

  @impl true
  def required_params, do: [:input, :actual_output, :retrieval_context]

  @impl true
  def do_measure(test_case, opts) do
    # Implementation-specific logic only
  end
end
```

## Consequences

### Positive

- **DRY**: Shared logic in one place
- **Consistent instrumentation**: All metrics emit same telemetry events
- **Reduced errors**: Developers can't forget validation or telemetry
- **Clear separation**: `measure/2` (wrapper) vs `do_measure/2` (implementation)
- **Easy testing**: Metrics only test their specific logic

### Negative

- **Macro complexity**: Debugging macros is harder than plain functions
- **Hidden behavior**: New developers may not realize what `use BaseMetric` provides
- **Inflexibility**: Metrics with unusual needs may fight the macro

### Neutral

- Follows Phoenix/Ecto patterns (e.g., `use Ecto.Schema`)
- Macro can be extended with optional features via opts
- Generated code is visible with `mix compile --verbose`

## Alternatives Considered

### Manual implementation in each metric

- **Rejected**: Too much duplication. Telemetry was inconsistent across metrics during prototyping.

### Module composition with `defdelegate`

- **Rejected**: Doesn't allow injecting wrapper behavior around the delegated function.

### Middleware/pipeline pattern

- **Rejected**: Overengineered for this use case. Macros are simpler and more common in Elixir.

### Behaviour with default implementations

- **Rejected**: Elixir behaviours don't support default implementations. Would need separate mixin module anyway.

## References

- [Elixir Metaprogramming Guide](https://hexdocs.pm/elixir/macros.html)
- [Phoenix Schema Pattern](https://hexdocs.pm/ecto/Ecto.Schema.html)
- [Understanding __using__](https://elixir-lang.org/getting-started/alias-require-and-import.html#use)
