# ADR-0001: Behaviour-Based Plugin Architecture

## Status

Accepted

## Date

2024-12-25

## Context

DeepEvalEx needs extensibility for two core abstractions:

1. **Metrics** - Different evaluation strategies (exact match, G-Eval, faithfulness, etc.)
2. **LLM Adapters** - Different LLM providers (OpenAI, Anthropic, Ollama, etc.)

Users should be able to implement custom metrics and adapters that integrate seamlessly with the framework, including automatic telemetry instrumentation, validation, and error handling.

Elixir offers two main polymorphism mechanisms: protocols and behaviours.

## Decision

Use Elixir behaviours for both metrics and LLM adapters.

**Metrics implement `DeepEvalEx.Metrics.BaseMetric`:**

```elixir
defmodule DeepEvalEx.Metrics.BaseMetric do
  @callback metric_name() :: String.t()
  @callback required_params() :: [atom()]
  @callback do_measure(TestCase.t(), keyword()) :: Result.t()
end
```

**LLM adapters implement `DeepEvalEx.LLM.Adapter`:**

```elixir
defmodule DeepEvalEx.LLM.Adapter do
  @callback generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback generate_with_schema(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback supports_structured_outputs?() :: boolean()
  @callback model_name(keyword()) :: String.t()
end
```

## Consequences

### Positive

- **Clear contracts**: Behaviours enforce explicit callback definitions with typespecs
- **Compile-time checks**: Missing callbacks generate warnings/errors at compile time
- **Macro integration**: `__using__` macros can inject shared functionality (validation, telemetry)
- **Documentation**: Behaviour modules serve as authoritative interface documentation
- **Discoverability**: IDE autocompletion and documentation tools understand behaviours

### Negative

- **Less dynamic dispatch**: Unlike protocols, behaviours require knowing the module at compile time or passing it explicitly
- **No data-driven dispatch**: Protocols dispatch on data type; behaviours require explicit module references
- **More boilerplate**: Each implementation requires `@behaviour` declaration

### Neutral

- Custom metrics/adapters have full feature parity with built-in ones
- Configuration must specify adapter modules explicitly (e.g., `adapter: DeepEvalEx.LLM.Adapters.OpenAI`)

## Alternatives Considered

### Protocols

- **Rejected**: Protocols dispatch on data types, but metrics and adapters are module-based, not data-based. There's no natural "data type" to dispatch on.

### Simple function contracts (no behaviour)

- **Rejected**: Loses compile-time checking and documentation benefits. No enforcement of required callbacks.

### GenServer-based plugins

- **Rejected**: Adds unnecessary process overhead for stateless operations. Metrics and adapters don't need to maintain state between calls.

## References

- [Elixir Behaviours Documentation](https://hexdocs.pm/elixir/behaviours.html)
- [Protocol vs Behaviour](https://elixir-lang.org/getting-started/protocols.html)
- [DeepEval Python BaseMetric](https://github.com/confident-ai/deepeval)
