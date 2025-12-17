# Installation

## Requirements

- Elixir 1.15 or later
- Erlang/OTP 26 or later

## Add Dependency

Add `deep_eval_ex` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:deep_eval_ex, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Configuration

### OpenAI (Default)

Set your OpenAI API key:

```bash
export OPENAI_API_KEY="sk-..."
```

Or configure in `config/config.exs`:

```elixir
config :deep_eval_ex,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  default_model: {:openai, "gpt-4o-mini"}
```

### Anthropic

```elixir
config :deep_eval_ex,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  default_model: {:anthropic, "claude-3-haiku-20240307"}
```

### Ollama (Local)

```elixir
config :deep_eval_ex,
  default_model: {:ollama, "llama3.2"}
```

## Verify Installation

```elixir
iex -S mix

iex> test_case = DeepEvalEx.TestCase.new!(
...>   input: "What is 2+2?",
...>   actual_output: "4",
...>   expected_output: "4"
...> )

iex> {:ok, result} = DeepEvalEx.Metrics.ExactMatch.measure(test_case)
iex> result.success
true
```

## Next Steps

- [Quick Start Guide](Quick-Start.md)
- [Configuration Options](Configuration.md)
