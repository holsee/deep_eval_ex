# Configuration

DeepEvalEx can be configured via application config, environment variables, or runtime options.

## Application Config

In `config/config.exs`:

```elixir
config :deep_eval_ex,
  # Default LLM provider and model
  default_model: {:openai, "gpt-4o-mini"},

  # API keys
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),

  # Evaluation defaults
  default_threshold: 0.5,
  max_concurrency: 10,
  default_timeout: 60_000
```

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `OPENAI_API_KEY` | OpenAI API key | `sk-...` |
| `OPENAI_BASE_URL` | OpenAI-compatible API base URL | `https://gateway.example.com/v1` |
| `ANTHROPIC_API_KEY` | Anthropic API key | `sk-ant-...` |
| `DEEP_EVAL_DEFAULT_MODEL` | Override default model | `gpt-4o` |

## LLM Providers

### OpenAI (Default)

```elixir
config :deep_eval_ex,
  default_model: {:openai, "gpt-4o-mini"},
  openai_api_key: "sk-..."
```

Available models:
- `gpt-4o` - Most capable
- `gpt-4o-mini` - Fast and cost-effective (recommended)
- `gpt-4-turbo` - Previous generation
- `gpt-3.5-turbo` - Fastest, cheapest

#### OpenAI-Compatible Endpoints

Point the OpenAI adapter at a proxy, gateway or any OpenAI-compatible API by
setting a base URL. The first one set wins (a trailing slash is stripped):

1. `base_url:` runtime option
2. `config :deep_eval_ex, openai_base_url: "..."`
3. `OPENAI_BASE_URL` environment variable
4. `https://api.openai.com/v1`

```elixir
config :deep_eval_ex,
  openai_base_url: "https://gateway.example.com/v1"
```

#### Temperature

The adapter sends `temperature: 0.0` by default, as deepeval's `GPTModel` does,
so judge calls are deterministic instead of running at OpenAI's default of
`1.0`. Override it with the `temperature:` option or
`config :deep_eval_ex, openai_temperature: 0.3` (the option wins). Reasoning
models (`o1`, `o3`, `o4`, `gpt-5`, ...) reject the parameter, so it is never
sent for them.

### Anthropic

```elixir
config :deep_eval_ex,
  default_model: {:anthropic, "claude-3-haiku-20240307"},
  anthropic_api_key: "sk-ant-..."
```

Available models:
- `claude-3-opus-20240229` - Most capable
- `claude-3-sonnet-20240229` - Balanced
- `claude-3-haiku-20240307` - Fast and efficient

### Ollama (Local)

```elixir
config :deep_eval_ex,
  default_model: {:ollama, "llama3.2"}
```

Requires Ollama running locally on port 11434.

## Runtime Options

Override configuration at evaluation time:

```elixir
# Use a different model
{:ok, result} = GEval.evaluate(metric, test_case,
  adapter: :openai,
  model: "gpt-4o"
)

# Custom API key
{:ok, result} = GEval.evaluate(metric, test_case,
  api_key: "sk-different-key"
)

# Adjust timeout
{:ok, result} = GEval.evaluate(metric, test_case,
  timeout: 120_000  # 2 minutes
)
```

## Model Pricing

Results report `evaluation_cost` from per-model token prices (USD per 1M
tokens). DeepEvalEx ships deepeval's OpenAI price table; models it does not
know get a `nil` cost rather than a guess. Price other models, or override a
built-in price, with `:model_pricing`:

```elixir
config :deep_eval_ex,
  model_pricing: %{
    "my-finetuned-model" => %{input: 0.30, output: 1.20},
    "llama3.1" => %{input: 0.0, output: 0.0}
  }
```

Each entry must be `%{input: number, output: number}` with non-negative
prices. A malformed entry raises an `ArgumentError` naming the model as soon
as that model is priced.

## Concurrency Settings

Control parallel evaluation:

```elixir
# In config
config :deep_eval_ex,
  max_concurrency: 20

# At runtime
results = DeepEvalEx.evaluate_batch(test_cases, metrics,
  concurrency: 50
)
```

## Environment-Specific Config

### Development

`config/dev.exs`:
```elixir
config :deep_eval_ex,
  default_model: {:openai, "gpt-4o-mini"}  # Cheaper model
```

### Test

`config/test.exs`:
```elixir
config :deep_eval_ex,
  default_model: {:mock, "test"},  # Mock adapter
  default_timeout: 5_000
```

### Production

`config/runtime.exs`:
```elixir
config :deep_eval_ex,
  openai_api_key: System.fetch_env!("OPENAI_API_KEY"),
  default_model: {:openai, "gpt-4o"}
```

## Telemetry

Enable logging:

```elixir
# In application.ex
def start(_type, _args) do
  DeepEvalEx.Telemetry.attach_default_logger()
  # ...
end
```

Or custom handler:

```elixir
:telemetry.attach(
  "my-handler",
  [:deep_eval_ex, :metric, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("#{metadata.metric}: #{measurements.score}")
  end,
  nil
)
```

## Configuration Priority

1. Runtime options (highest)
2. Environment variables
3. Application config
4. Default values (lowest)
