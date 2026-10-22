# LLM Adapters

`DeepEvalEx.LLM.Adapter` is the behaviour for LLM providers.

## Overview

DeepEvalEx uses adapters to abstract away differences between LLM providers. The adapter layer handles API communication, structured outputs, and provider-specific features.

## Available Adapters

| Adapter | Module | Status |
|---------|--------|--------|
| OpenAI | `DeepEvalEx.LLM.Adapters.OpenAI` | Implemented |
| Anthropic | `DeepEvalEx.LLM.Adapters.Anthropic` | Planned |
| Ollama | `DeepEvalEx.LLM.Adapters.Ollama` | Planned |
| Mock | `DeepEvalEx.LLM.Adapters.Mock` | For testing |

## Using Adapters

### Default Configuration

Configure in `config/config.exs`:

```elixir
config :deep_eval_ex,
  default_model: {:openai, "gpt-4o-mini"},
  openai_api_key: System.get_env("OPENAI_API_KEY")
```

### Per-Evaluation Override

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :openai,
  model: "gpt-4o"
)
```

### Using Adapter Tuples

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: {:openai, "gpt-4o"}
)
```

## Adapter Behaviour

All adapters implement the `DeepEvalEx.LLM.Adapter` behaviour:

```elixir
@callback generate(prompt, opts) :: {:ok, String.t()} | {:error, term()}
@callback generate_with_schema(prompt, schema, opts) :: {:ok, map()} | {:error, term()}
@callback model_name(opts) :: String.t()
@callback supports_structured_outputs?() :: boolean()
@callback supports_log_probs?() :: boolean()
@callback supports_multimodal?() :: boolean()
```

## OpenAI Adapter

### Configuration

```elixir
config :deep_eval_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  openai_base_url: "https://api.openai.com/v1",  # optional
  openai_temperature: 0.0                         # optional
```

### Base URL

To use a proxy, gateway or any OpenAI-compatible API, set a base URL. It is
resolved in this order, with a trailing slash stripped:

1. `:base_url` option
2. `:openai_base_url` application config
3. `OPENAI_BASE_URL` environment variable
4. `"https://api.openai.com/v1"`

```elixir
{:ok, response} = Adapter.generate(prompt,
  adapter: :openai,
  base_url: "https://gateway.example.com/v1"
)
```

### Request Parameters

- The token limit is sent as `max_completion_tokens` (default `4096`);
  OpenAI deprecated `max_tokens`, which is still accepted as an option alias.
- `temperature` is sent only when given via `:temperature` or the
  `:openai_temperature` config, and never for reasoning models (`o1`, `o3`,
  `o4`, `gpt-5`, ...), which reject it.

### Testing

Extra `Req` options can be passed with `:req_options`, which makes the adapter
easy to stub with `Req.Test` (requires `:plug` in your test dependencies):

```elixir
Req.Test.stub(DeepEvalEx.LLM.Adapters.OpenAI, fn conn ->
  Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "4"}}]})
end)

{:ok, "4"} =
  DeepEvalEx.LLM.Adapters.OpenAI.generate("What is 2+2?",
    api_key: "sk-test",
    req_options: [plug: {Req.Test, DeepEvalEx.LLM.Adapters.OpenAI}]
  )
```

### Supported Models

- `gpt-4o` - Most capable
- `gpt-4o-mini` - Fast and cost-effective (default)
- `gpt-4-turbo` - Previous generation
- `gpt-3.5-turbo` - Legacy

### Features

| Feature | Supported |
|---------|-----------|
| Structured Outputs | Yes |
| Log Probabilities | Yes |
| Multimodal | Yes |

### Usage

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :openai,
  model: "gpt-4o-mini"
)
```

## Mock Adapter

For testing without API calls:

```elixir
alias DeepEvalEx.LLM.Adapters.Mock

# Set up mock response
Mock.set_schema_response(
  ~r/extract.*claims/i,
  %{"claims" => ["Claim 1", "Claim 2"]}
)

# Run evaluation with mock
{:ok, result} = Faithfulness.measure(test_case, adapter: :mock)

# Clear mocks
Mock.clear_responses()
```

### Pattern Matching

Mock responses are matched by regex against the prompt:

```elixir
# Match any prompt containing "verdicts"
Mock.set_schema_response(~r/verdicts/i, %{"verdicts" => [...]})

# Match specific prompt pattern
Mock.set_schema_response(
  ~r/determine whether.*faithful/i,
  %{"verdicts" => [%{"verdict" => "yes", "reason" => "Supported"}]}
)
```

## Helper Functions

### `Adapter.get_adapter/1`

Resolve adapter module from atom:

```elixir
Adapter.get_adapter(:openai)
# => DeepEvalEx.LLM.Adapters.OpenAI

Adapter.get_adapter(:mock)
# => DeepEvalEx.LLM.Adapters.Mock
```

### `Adapter.default_adapter/0`

Get the configured default:

```elixir
{adapter_module, model} = Adapter.default_adapter()
# => {DeepEvalEx.LLM.Adapters.OpenAI, "gpt-4o-mini"}
```

### `Adapter.generate/2`

Generate text response:

```elixir
{:ok, response} = Adapter.generate("What is 2+2?", adapter: :openai)
# => {:ok, "4"}
```

### `Adapter.generate_with_schema/3`

Generate structured response:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "answer" => %{"type" => "string"}
  }
}

{:ok, response} = Adapter.generate_with_schema("What is 2+2?", schema, adapter: :openai)
# => {:ok, %{"answer" => "4"}}
```

## Options

Options passed to adapter functions:

| Option | Description |
|--------|-------------|
| `:model` | Model name/identifier |
| `:temperature` | Sampling temperature (0.0-2.0); omitted when not set |
| `:max_completion_tokens` | Maximum tokens in response (`:max_tokens` is an alias) |
| `:api_key` | API key (overrides config) |
| `:base_url` | API base URL (OpenAI adapter) |
| `:req_options` | Extra `Req` options (OpenAI adapter) |

```elixir
{:ok, response} = Adapter.generate(prompt,
  adapter: :openai,
  model: "gpt-4o",
  temperature: 0.0,
  max_completion_tokens: 1000
)
```

## See Also

- [Custom LLM Adapters](../guides/Custom-LLM-Adapters.md) - Building your own adapter
- [Configuration](../guides/Configuration.md) - Global configuration
