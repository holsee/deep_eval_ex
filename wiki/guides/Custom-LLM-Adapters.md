# Custom LLM Adapters

Build adapters for custom LLM providers.

## Overview

DeepEvalEx uses the `DeepEvalEx.LLM.Adapter` behaviour to communicate with LLM providers. You can implement this behaviour to add support for any LLM API.

## Quick Start

```elixir
defmodule MyApp.LLM.CustomAdapter do
  @behaviour DeepEvalEx.LLM.Adapter

  @impl true
  def generate(prompt, opts) do
    model = Keyword.get(opts, :model, "custom-model")

    case call_api(prompt, model) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts) do
    full_prompt = "#{prompt}\n\nRespond with JSON matching: #{Jason.encode!(schema)}"

    case generate(full_prompt, opts) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, :invalid_json}
        end
      error -> error
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, "custom-model")

  @impl true
  def supports_structured_outputs?, do: false

  @impl true
  def supports_log_probs?, do: false

  defp call_api(prompt, model) do
    # Your API implementation
  end
end
```

## Adapter Behaviour

### Required Callbacks

```elixir
@callback generate(prompt, opts) :: {:ok, String.t()} | {:error, term()}
@callback generate_with_schema(prompt, schema, opts) :: {:ok, map()} | {:error, term()}
@callback model_name(opts) :: String.t()
@callback supports_structured_outputs?() :: boolean()
@callback supports_log_probs?() :: boolean()
```

### Optional Callbacks

```elixir
@callback supports_multimodal?() :: boolean()  # Default: false
```

## Using the `__using__` Macro

For convenience, you can use the macro for default implementations:

```elixir
defmodule MyApp.LLM.CustomAdapter do
  use DeepEvalEx.LLM.Adapter

  @impl true
  def generate(prompt, opts) do
    # Your implementation
  end

  @impl true
  def generate_with_schema(prompt, schema, opts) do
    # Your implementation
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, "default")

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: false
end
```

The macro provides a default `supports_multimodal?/0` returning `false`.

## Complete Example: Ollama Adapter

```elixir
defmodule MyApp.LLM.Adapters.Ollama do
  use DeepEvalEx.LLM.Adapter

  @default_base_url "http://localhost:11434"

  @impl true
  def generate(prompt, opts) do
    model = Keyword.get(opts, :model, "llama2")
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    body = %{
      model: model,
      prompt: prompt,
      stream: false
    }

    case Req.post("#{base_url}/api/generate", json: body) do
      {:ok, %{status: 200, body: %{"response" => response}}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts) do
    # Ollama doesn't have native structured outputs,
    # so we instruct via prompt and parse JSON
    schema_instruction = """

    Respond with valid JSON matching this schema:
    #{Jason.encode!(schema, pretty: true)}

    Only output the JSON, no other text.
    """

    case generate(prompt <> schema_instruction, opts) do
      {:ok, response} ->
        parse_json_response(response)

      error ->
        error
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, "llama2")

  @impl true
  def supports_structured_outputs?, do: false

  @impl true
  def supports_log_probs?, do: false

  defp parse_json_response(response) do
    # Try to extract JSON from response
    response
    |> String.trim()
    |> extract_json()
    |> case do
      {:ok, json_str} -> Jason.decode(json_str)
      error -> error
    end
  end

  defp extract_json(text) do
    # Handle responses wrapped in markdown code blocks
    case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, text) do
      [_, json] -> {:ok, String.trim(json)}
      nil -> {:ok, text}
    end
  end
end
```

## Complete Example: Anthropic Adapter

```elixir
defmodule MyApp.LLM.Adapters.Anthropic do
  use DeepEvalEx.LLM.Adapter

  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def generate(prompt, opts) do
    model = Keyword.get(opts, :model, "claude-3-haiku-20240307")
    api_key = Keyword.get(opts, :api_key, api_key_from_config())
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        content = get_in(body, ["content", Access.at(0), "text"])
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts) do
    # Use Anthropic's tool use for structured outputs
    model = Keyword.get(opts, :model, "claude-3-haiku-20240307")
    api_key = Keyword.get(opts, :api_key, api_key_from_config())

    tool = %{
      name: "structured_response",
      description: "Return the structured response",
      input_schema: schema
    }

    body = %{
      model: model,
      max_tokens: 4096,
      tools: [tool],
      tool_choice: %{type: "tool", name: "structured_response"},
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        tool_use = Enum.find(body["content"], & &1["type"] == "tool_use")
        {:ok, tool_use["input"]}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, "claude-3-haiku-20240307")

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: false

  @impl true
  def supports_multimodal?, do: true

  defp api_key_from_config do
    Application.get_env(:deep_eval_ex, :anthropic_api_key)
  end
end
```

## Registering Your Adapter

### Option 1: Use Directly

```elixir
{:ok, result} = Faithfulness.measure(test_case,
  adapter: MyApp.LLM.Adapters.Ollama,
  model: "llama2"
)
```

### Option 2: Configure as Default

```elixir
# config/config.exs
config :deep_eval_ex,
  default_adapter: MyApp.LLM.Adapters.Ollama,
  default_model: "llama2"
```

### Option 3: Extend `get_adapter/1`

Fork the library or use a wrapper:

```elixir
defmodule MyApp.LLM.Adapter do
  def get_adapter(:ollama), do: MyApp.LLM.Adapters.Ollama
  def get_adapter(:anthropic), do: MyApp.LLM.Adapters.Anthropic
  def get_adapter(other), do: DeepEvalEx.LLM.Adapter.get_adapter(other)
end
```

## Testing Your Adapter

```elixir
defmodule MyApp.LLM.Adapters.OllamaTest do
  use ExUnit.Case

  alias MyApp.LLM.Adapters.Ollama

  @tag :integration
  test "generate returns response" do
    {:ok, response} = Ollama.generate("Say hello", model: "llama2")
    assert is_binary(response)
    assert String.length(response) > 0
  end

  @tag :integration
  test "generate_with_schema returns structured data" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "greeting" => %{"type" => "string"}
      }
    }

    {:ok, response} = Ollama.generate_with_schema(
      "Generate a greeting",
      schema,
      model: "llama2"
    )

    assert is_map(response)
    assert Map.has_key?(response, "greeting")
  end
end
```

## Best Practices

1. **Handle rate limits** - Implement retry logic with exponential backoff
2. **Validate responses** - Check for expected structure before returning
3. **Log errors** - Include request/response details for debugging
4. **Configure timeouts** - Set appropriate timeouts for your API
5. **Support streaming** - Consider adding streaming support for long responses

## See Also

- [LLM Adapters API](../api/LLM-Adapters.md) - Built-in adapters
- [Configuration](Configuration.md) - Global adapter configuration
- [Custom Metrics](Custom-Metrics.md) - Using adapters in metrics
