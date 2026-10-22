# LLM Adapters

`DeepEvalEx.LLM.Adapter` is the behaviour for LLM providers.

## Overview

DeepEvalEx uses adapters to abstract away differences between LLM providers. The adapter layer handles API communication, structured outputs, and provider-specific features.

## Available Adapters

| Adapter | Module | Status |
|---------|--------|--------|
| OpenAI | `DeepEvalEx.LLM.Adapters.OpenAI` | Implemented |
| Anthropic | `DeepEvalEx.LLM.Adapters.Anthropic` | Implemented |
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
  openai_temperature: 0.0                         # optional, default 0.0
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
- `temperature` comes from `:temperature`, then the `:openai_temperature`
  config, then defaults to `0.0` as in deepeval's `GPTModel`; it is never sent
  for reasoning models (`o1`, `o3`, `o4`, `gpt-5`, ...), which reject it.

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

## Anthropic Adapter

### Configuration

```elixir
config :deep_eval_ex,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_base_url: "https://api.anthropic.com",  # optional
  anthropic_temperature: 0.0                         # optional, unset by default
```

The API key comes from `:api_key`, then `:anthropic_api_key`, then the
`ANTHROPIC_API_KEY` environment variable.

### Base URL

Requests go to `{base_url}/v1/messages`. The base URL is resolved in this
order, with a trailing slash stripped:

1. `:base_url` option
2. `:anthropic_base_url` application config
3. `ANTHROPIC_BASE_URL` environment variable
4. `"https://api.anthropic.com"`

### Request Parameters

Defaults mirror deepeval's `AnthropicModel`:

- `model` defaults to `"claude-opus-5"`.
- `max_tokens` defaults to `8192`, or `4096` for Claude 3 models
  (`claude-3-opus`, `claude-3-sonnet`, `claude-3-haiku`), which reject more.
- `temperature` comes from `:temperature`, then the `:anthropic_temperature`
  config, and is otherwise omitted (Anthropic's own default applies). It is
  never sent to models that reject it (`claude-opus-4-7`, `claude-opus-4-8`,
  `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-5`, `claude-fable-5`,
  `claude-fable-5-1`).
- Models that support extended thinking get `thinking: %{type: "disabled"}`.

### Structured Outputs

`generate_with_schema/3` sends the JSON schema as the `input_schema` of a
single `"response"` tool and forces it with
`tool_choice: %{type: "tool", name: "response"}`. The `tool_use` block's
`input` is returned as a map with string keys, the same shape the OpenAI
adapter returns.

### Testing

```elixir
Req.Test.stub(DeepEvalEx.LLM.Adapters.Anthropic, fn conn ->
  Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "4"}]})
end)

{:ok, "4"} =
  DeepEvalEx.LLM.Adapters.Anthropic.generate("What is 2+2?",
    api_key: "sk-ant-test",
    req_options: [plug: {Req.Test, DeepEvalEx.LLM.Adapters.Anthropic}]
  )
```

### Features

| Feature | Supported |
|---------|-----------|
| Structured Outputs | Yes (forced tool use) |
| Log Probabilities | No |
| Multimodal | No |

### Usage

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :anthropic,
  model: "claude-haiku-4-5"
)
```

Token usage (`usage.input_tokens` / `usage.output_tokens`) is recorded and
priced with deepeval's Anthropic price table.

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
| `:temperature` | Sampling temperature (0.0-2.0); OpenAI adapter defaults to `0.0`, Anthropic omits it unless set |
| `:max_completion_tokens` | Maximum tokens in response, OpenAI (`:max_tokens` is an alias) |
| `:max_tokens` | Maximum tokens in response, Anthropic |
| `:api_key` | API key (overrides config) |
| `:base_url` | API base URL (OpenAI and Anthropic adapters) |
| `:req_options` | Extra `Req` options (OpenAI and Anthropic adapters) |

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
