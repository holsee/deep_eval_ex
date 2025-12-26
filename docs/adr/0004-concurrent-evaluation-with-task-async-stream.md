# ADR-0004: Concurrent Evaluation with Task.async_stream

## Status

Accepted

## Date

2024-12-25

## Context

LLM evaluation is I/O-bound with significant latency:

- Each metric evaluation may require 1-5 LLM API calls
- API calls typically take 1-10 seconds each
- Batch evaluations may include hundreds of test cases
- Sequential evaluation would be prohibitively slow

DeepEvalEx needs to evaluate multiple test cases concurrently while:
- Respecting rate limits (configurable concurrency)
- Handling timeouts gracefully
- Returning structured results even for failures
- Not blocking the caller unnecessarily

## Decision

Use `Task.async_stream` for concurrent evaluation of test cases.

```elixir
def evaluate(test_cases, metrics, opts) do
  max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online() * 2)
  timeout = Keyword.get(opts, :timeout, 120_000)

  test_cases
  |> Task.async_stream(
    fn test_case -> evaluate_single(test_case, metrics, opts) end,
    max_concurrency: max_concurrency,
    timeout: timeout,
    on_timeout: :kill_task
  )
  |> Enum.map(fn
    {:ok, results} -> results
    {:exit, :timeout} -> [Result.error("Evaluation timed out")]
  end)
end
```

## Consequences

### Positive

- **Simple API**: No process management or GenServer pools
- **Built-in timeout**: `:kill_task` terminates stuck evaluations cleanly
- **Configurable concurrency**: Easy to tune for different rate limits
- **BEAM-native**: Leverages lightweight processes efficiently
- **Backpressure**: `max_concurrency` prevents overwhelming LLM APIs
- **Ordered results**: Stream maintains input order

### Negative

- **Memory pressure**: All results held in memory until stream completes
- **No persistence**: Failed evaluations lost if process crashes
- **Limited retry logic**: Must implement retries at metric level

### Neutral

- Default concurrency of `schedulers * 2` balances throughput and rate limits
- Caller blocks until all evaluations complete (use Task.async for non-blocking)
- Each test case evaluated independently (no cross-case dependencies)

## Alternatives Considered

### GenServer pool (poolboy/nimble_pool)

- **Rejected**: Adds complexity for stateless operations. Task.async_stream provides equivalent functionality without persistent workers.

### Flow/GenStage

- **Rejected**: Designed for data pipelines, not request-response patterns. Overkill for evaluation workloads.

### Sequential evaluation

- **Rejected**: Far too slow for batch evaluations. A 100-case batch at 5s/case would take 8+ minutes sequentially vs ~25 seconds with 20 concurrent workers.

### spawn_link with manual coordination

- **Rejected**: Task.async_stream handles coordination, timeout, and error handling. Reimplementing would be error-prone.

## References

- [Task.async_stream/3](https://hexdocs.pm/elixir/Task.html#async_stream/3)
- [Elixir Task Documentation](https://hexdocs.pm/elixir/Task.html)
- [BEAM Scheduler Documentation](https://www.erlang.org/doc/man/erl.html#emulator-flags)
