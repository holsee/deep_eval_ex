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
| `ANTHROPIC_BASE_URL` | Anthropic API base URL | `https://gateway.example.com/anthropic` |
| `OLLAMA_HOST` | Ollama server address | `http://localhost:11434` |
| `DEEP_EVAL_DEFAULT_MODEL` | Override default model | `gpt-4o` |

A variable set to an empty or whitespace-only value is treated as unset, as is
a blank application config value (such as
`openai_api_key: System.get_env("OPENAI_API_KEY")` when the variable is empty),
so resolution falls through to the next source.

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
sent for them. They are recognised by the model name after any gateway
provider prefix and `@region` suffix: `aws-bedrock-runtime/openai/gpt-5@global`
counts as `gpt-5`.

### Anthropic

```elixir
config :deep_eval_ex,
  default_model: {:anthropic, "claude-haiku-4-5"},
  anthropic_api_key: "sk-ant-..."
```

The API key is taken from the `api_key:` option, then `:anthropic_api_key`,
then `ANTHROPIC_API_KEY`. Without a model the adapter uses deepeval's default,
`claude-opus-5`. Any model in deepeval's Anthropic registry is priced, e.g.:
- `claude-opus-5` - Most capable (deepeval's default)
- `claude-sonnet-4-6` - Balanced
- `claude-haiku-4-5` - Fast and cost-effective

#### Base URL

The first one set wins (a trailing slash is stripped; requests go to
`{base_url}/v1/messages`):

1. `base_url:` runtime option
2. `config :deep_eval_ex, anthropic_base_url: "..."`
3. `ANTHROPIC_BASE_URL` environment variable
4. `https://api.anthropic.com`

A base URL ending in `/v1` (as some gateways publish it) also works; the
adapter does not add a second `/v1`. Python deepeval and the Anthropic SDK
expect the bare host, so use that form if both read the same
`ANTHROPIC_BASE_URL`.

#### Temperature and Token Limit

As in deepeval's `AnthropicModel`, `temperature` is only sent when set with
the `temperature:` option or `config :deep_eval_ex, anthropic_temperature:
0.0` (the option wins), and never to models that reject it (`claude-opus-4-7`
and later Opus models, `claude-sonnet-5`, `claude-fable-5`). `max_tokens`
defaults to `8192`, or `4096` for Claude 3 models; override it with
`max_tokens:`.

### Ollama (Local)

```elixir
config :deep_eval_ex,
  default_model: {:ollama, "llama3.2"}
```

Requires an Ollama server with the model pulled (`ollama pull llama3.2`). No
API key is needed, and calls report an `evaluation_cost` of `0.0`, as in
deepeval.

#### Server URL

The first one set wins (a trailing slash is stripped; requests go to
`{base_url}/api/chat`):

1. `base_url:` runtime option
2. `config :deep_eval_ex, ollama_base_url: "..."`
3. `OLLAMA_HOST` environment variable (`host` or `host:port` is read as
   `http`, on port `11434` when none is given)
4. `http://localhost:11434`

#### Model and Temperature

There is no default model, as in deepeval: give one in `default_model`, the
`model:` option or `config :deep_eval_ex, ollama_model: "llama3.2"`.
`temperature` comes from the `temperature:` option, then `config
:deep_eval_ex, ollama_temperature: 0.0`, and defaults to `0.0`. Other model
options can be passed with `options: %{num_ctx: 8192}`.

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
tokens). DeepEvalEx ships deepeval's OpenAI and Anthropic price tables; models it does not
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
