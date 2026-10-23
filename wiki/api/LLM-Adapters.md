# LLM Adapters

`DeepEvalEx.LLM.Adapter` is the behaviour for LLM providers.

## Overview

DeepEvalEx uses adapters to abstract away differences between LLM providers. The adapter layer handles API communication, structured outputs, and provider-specific features.

## Available Adapters

| Adapter | Module | Status |
|---------|--------|--------|
| OpenAI | `DeepEvalEx.LLM.Adapters.OpenAI` | Implemented |
| Anthropic | `DeepEvalEx.LLM.Adapters.Anthropic` | Implemented |
| Ollama | `DeepEvalEx.LLM.Adapters.Ollama` | Implemented |
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

# Optional: logprobs, which GEval weights its score by
@callback supports_log_probs?(opts) :: boolean()
@callback generate_raw_response(prompt, opts) :: {:ok, map()} | {:error, term()}
```

## Tracing

Inside a trace, every call through `DeepEvalEx.LLM.Adapter` is an `:llm`
span with the model, prompt, answer and token counts, whatever the
adapter; the OpenAI and Anthropic adapters also set the span's
`integration` and `provider`. Calls outside a trace, and a metric's judge
calls, record nothing. See the [Tracing](../guides/Tracing.md) guide.

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
  Reasoning models are recognised by the model name after any gateway provider
  prefix and `@region` suffix, so `"aws-bedrock-runtime/openai/gpt-5@global"`
  is treated as `gpt-5`.

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
| Log Probabilities | Yes, for the models deepeval lists with them (not reasoning models) |
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
`ANTHROPIC_API_KEY` environment variable. Blank config values and environment
variables are treated as unset, for every adapter.

### Base URL

Requests go to `{base_url}/v1/messages`. The base URL is resolved in this
order, with a trailing slash stripped:

1. `:base_url` option
2. `:anthropic_base_url` application config
3. `ANTHROPIC_BASE_URL` environment variable
4. `"https://api.anthropic.com"`

A base URL that already ends in `/v1`, as some gateways publish it, is
accepted and not doubled. Python deepeval and the Anthropic SDK expect the
bare host (no `/v1`), so prefer that form when sharing one
`ANTHROPIC_BASE_URL` between the two.

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

## Ollama Adapter

Runs judges on local models through Ollama's native `/api/chat` endpoint,
mirroring deepeval's `OllamaModel`. No API key is needed.

### Configuration

```elixir
config :deep_eval_ex,
  default_model: {:ollama, "llama3.2"},
  ollama_base_url: "http://localhost:11434",  # optional
  ollama_temperature: 0.0                     # optional, default 0.0
```

There is no default model, as in deepeval: pass `:model`, use a
`{:ollama, model}` adapter tuple or `default_model`, or set `:ollama_model`.
The model must already be pulled on the server (`ollama pull llama3.2`).

### Base URL

Requests go to `{base_url}/api/chat`. The base URL is resolved in this order,
with a trailing slash stripped:

1. `:base_url` option
2. `:ollama_base_url` application config
3. `OLLAMA_HOST` environment variable
4. `"http://localhost:11434"`

As in the Ollama clients, a value without a scheme (e.g. `OLLAMA_HOST=gpu-box`
or `gpu-box:11434`) is read as `http`, on port `11434` when none is given.

### Request Parameters

Requests are sent with `stream: false`. `temperature` comes from
`:temperature`, then the `:ollama_temperature` config, then defaults to `0.0`
as in deepeval, and is always sent in the request's `options`. Further model
options (deepeval's `generation_kwargs`) can be passed as a map with
`:options`, e.g. `options: %{num_ctx: 8192}`; a `temperature` in it is
ignored in favour of `:temperature`. The receive timeout (`:timeout`) defaults
to `120_000` ms, as local models can be slow.

### Structured Outputs

`generate_with_schema/3` sends the JSON schema as the request's `format`
(Ollama structured outputs) and decodes the message content into a map with
string keys. Content that is not valid JSON returns
`{:error, {:json_parse_error, error, content}}`.

### Usage and Cost

`prompt_eval_count` and `eval_count` are recorded as input and output tokens.
Local models cost nothing: deepeval reports a cost of `0` for every Ollama
call, so results report an `evaluation_cost` of `0.0` rather than `nil`.

### Testing

```elixir
Req.Test.stub(DeepEvalEx.LLM.Adapters.Ollama, fn conn ->
  Req.Test.json(conn, %{"message" => %{"role" => "assistant", "content" => "4"}})
end)

{:ok, "4"} =
  DeepEvalEx.LLM.Adapters.Ollama.generate("What is 2+2?",
    model: "llama3.2",
    req_options: [plug: {Req.Test, DeepEvalEx.LLM.Adapters.Ollama}]
  )
```

### Features

| Feature | Supported |
|---------|-----------|
| Structured Outputs | Yes (`format` JSON schema) |
| Log Probabilities | No |
| Multimodal | No |

### Usage

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: :ollama,
  model: "llama3.2"
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
| `:temperature` | Sampling temperature (0.0-2.0); OpenAI and Ollama adapters default to `0.0`, Anthropic omits it unless set |
| `:max_completion_tokens` | Maximum tokens in response, OpenAI (`:max_tokens` is an alias) |
| `:max_tokens` | Maximum tokens in response, Anthropic |
| `:api_key` | API key (overrides config; not used by Ollama) |
| `:options` | Extra model options map, Ollama |
| `:base_url` | API base URL (OpenAI, Anthropic and Ollama adapters) |
| `:req_options` | Extra `Req` options (OpenAI, Anthropic and Ollama adapters) |

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
