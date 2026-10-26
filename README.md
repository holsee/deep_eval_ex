<p align="center">
  <img src="deepevalex_text.png" alt="DeepEvalEx Logo" width="400">
</p>

<p align="center">
  <a href="https://github.com/holsee/deep_eval_ex/actions/workflows/ci.yml"><img src="https://github.com/holsee/deep_eval_ex/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://hex.pm/packages/deep_eval_ex"><img src="https://img.shields.io/hexpm/v/deep_eval_ex.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/deep_eval_ex"><img src="https://img.shields.io/badge/hex-docs-blue.svg" alt="Documentation"></a>
  <a href="https://github.com/holsee/deep_eval_ex/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-blue.svg" alt="License"></a>
</p>

# DeepEvalEx

LLM evaluation framework for Elixir - Idiomatic + Compatible Elixir port of [DeepEval](https://github.com/confident-ai/deepeval).

> **Attribution**: This project is a derivative work of [DeepEval](https://github.com/confident-ai/deepeval)
> by [Confident AI](https://confident-ai.com), licensed under Apache 2.0. The core evaluation
> algorithms, metrics, and prompt templates are derived from the original Python implementation.

## Installation

Add `deep_eval_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:deep_eval_ex, "~> 0.2"}
  ]
end
```

## Quick Start

```elixir
# Create a test case
test_case = DeepEvalEx.TestCase.new!(
  input: "What is the capital of France?",
  actual_output: "The capital of France is Paris.",
  expected_output: "Paris"
)

# Evaluate with ExactMatch metric
{:ok, result} = DeepEvalEx.Metrics.ExactMatch.measure(test_case)

# Check result
result.score      # => 0.0 (not an exact match)
result.success    # => false
result.reason     # => "The actual and expected outputs are different."
```

## Configuration

Configure your LLM provider in `config/config.exs`:

```elixir
config :deep_eval_ex,
  default_model: {:openai, "gpt-4o-mini"},
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  default_threshold: 0.5
```

## Available Metrics

| Metric | Purpose |
|--------|---------|
| **ExactMatch** | Simple string comparison |
| **PatternMatch** | Whole output matches a regular expression |
| **JsonCorrectness** | Output is JSON matching an expected JSON Schema |
| **GEval** | Flexible criteria-based evaluation using LLM-as-judge |
| **ConversationalGEval** | GEval for multi-turn conversations (`ConversationalTestCase`) |
| **TurnRelevancy** | Whether each assistant turn of a conversation is relevant to the turns before it |
| **ConversationCompleteness** | Whether the assistant satisfies every intention the user expresses in a conversation |
| **KnowledgeRetention** | Whether the assistant remembers the facts the user gave earlier in a conversation |
| **RoleAdherence** | Whether the assistant stays in the character of the conversation's `chatbot_role` |
| **GoalAccuracy** | Whether the assistant achieves each goal the user sets in a conversation, with a sound plan it follows |
| **ToolUse** | Whether the assistant of a conversation picks the right available tools and calls them with correct arguments |
| **Faithfulness** | RAG: claims supported by retrieval context |
| **Hallucination** | Detects unsupported statements |
| **AnswerRelevancy** | Response relevance to input question |
| **ContextualPrecision** | RAG retrieval ranking quality |
| **ContextualRecall** | RAG coverage of ground truth |
| **ContextualRelevancy** | RAG relevance of the retrieved context to the input |
| **TurnFaithfulness** | Multi-turn RAG: each window's claims supported by its turns' retrieval context |
| **TurnContextualPrecision** | Multi-turn RAG retrieval ranking quality towards the `expected_outcome` |
| **TurnContextualRecall** | Multi-turn RAG coverage of the `expected_outcome` |
| **TurnContextualRelevancy** | Multi-turn RAG relevance of each window's retrieved context to the user |
| **Bias** | Gender, political, racial/ethnic and geographical bias in the output |
| **Toxicity** | Personal attacks, mockery, hate and threats in the output |
| **PIILeakage** | Personally identifiable information and privacy-sensitive data in the output |
| **PromptAlignment** | Whether the output follows the prompt template's instructions |
| **Summarization** | Whether a summary is faithful to, and covers, its original text |
| **ToolCorrectness** | Agent tool calls against the expected tools |
| **ArgumentCorrectness** | Whether each agent tool call's arguments address the input |
| **ToolPermission** | Agent tool calls against an allowlist and denylist |
| **TaskCompletion** | Whether a traced agent accomplished the task it was given, judged from its trace |
| **StepEfficiency** | Whether a traced agent took only the steps its task needed, judged from its trace |
| **PlanQuality** | Whether the plan a traced agent stated is complete, ordered and specific enough for its task |
| **PlanAdherence** | Whether a traced agent followed the plan it stated, step by step and nothing more |
| **AgentLoopDetection** | Whether a traced agent looped: repeated tool calls, stagnating reasoning or recursive cycles (no LLM) |
| **JevEval** | Your own weighted Noul, Score and Choice questions, decided by a System One model (Jev) |
| **ConversationalJevEval** | JevEval for multi-turn conversations: your own questions about the turns, decided by a System One model (Jev) |

See the [Metrics Overview](wiki/metrics/Overview.md) for detailed documentation on each metric.

## Documentation

| Guide | Description |
|-------|-------------|
| [Quick Start](wiki/guides/Quick-Start.md) | Get up and running in 5 minutes |
| [Configuration](wiki/guides/Configuration.md) | LLM provider setup and options |
| [Metrics Overview](wiki/metrics/Overview.md) | All available metrics explained |
| [ExUnit Integration](wiki/guides/ExUnit-Integration.md) | Test assertions for CI/CD |
| [Custom Metrics](wiki/guides/Custom-Metrics.md) | Build your own evaluation metrics |
| [Telemetry](wiki/guides/Telemetry.md) | Observability and monitoring |
| [Tracing](wiki/guides/Tracing.md) | Record an agent's steps as spans |
| [Datasets](wiki/guides/Datasets.md) | Goldens and evaluation datasets |

### API Reference

- [TestCase](wiki/api/TestCase.md) - Test case structure
- [Result](wiki/api/Result.md) - Evaluation results
- [EvaluationResult](wiki/api/EvaluationResult.md) - What `evaluate/3` returns
- [Evaluator](wiki/api/Evaluator.md) - Batch evaluation
- [TestRun](wiki/api/TestRun.md) - deepeval-compatible test run export and import
- [LLM Adapters](wiki/api/LLM-Adapters.md) - Provider adapters

### Architecture

- [Architecture Decision Records](docs/adr/README.md) - Design decisions and rationale

## LLM Adapters

DeepEvalEx supports multiple LLM providers:

- **OpenAI** (`:openai`) - GPT-4o, GPT-4o-mini, reasoning models; any
  OpenAI-compatible gateway via `:base_url`, `openai_base_url` config or
  `OPENAI_BASE_URL`
- **Anthropic** (`:anthropic`) - Claude Opus, Sonnet and Haiku via the Messages API
- **Ollama** (`:ollama`) - Local models via Ollama's `/api/chat`
- **ReqLLM** (`:req_llm`) - Gemini, Azure, Bedrock, Groq, OpenRouter and the
  other providers [ReqLLM](https://hexdocs.pm/req_llm) supports, with the
  optional `{:req_llm, "~> 1.29"}` dependency
- **Mock** (`:mock`) - Canned responses for tests, no network

Every adapter records token usage and cost on the results.

See [LLM Adapters](wiki/api/LLM-Adapters.md) and [Custom LLM Adapters](wiki/guides/Custom-LLM-Adapters.md) for details.

## Usage with ExUnit

```elixir
defmodule MyApp.LLMTest do
  use ExUnit.Case

  alias DeepEvalEx.{TestCase, Metrics}

  test "LLM generates accurate responses" do
    test_case = TestCase.new!(
      input: "What is 2 + 2?",
      actual_output: get_llm_response("What is 2 + 2?"),
      expected_output: "4"
    )

    {:ok, result} = Metrics.ExactMatch.measure(test_case)
    assert result.success, result.reason
  end
end
```

## Concurrent Evaluation

Evaluate multiple test cases concurrently:

```elixir
test_cases = [
  TestCase.new!(input: "Q1", actual_output: "A1", expected_output: "A1"),
  TestCase.new!(input: "Q2", actual_output: "A2", expected_output: "A2")
]

{:ok, %DeepEvalEx.EvaluationResult{test_results: test_results}} =
  DeepEvalEx.evaluate(test_cases, [Metrics.ExactMatch], max_concurrent: 10)

# One DeepEvalEx.TestResult per test case, in order
Enum.map(test_results, &{&1.name, &1.success})
#=> [{"test_case_0", true}, {"test_case_1", true}]
```

## Telemetry

DeepEvalEx emits telemetry events for observability:

```elixir
:telemetry.attach("my-handler", [:deep_eval_ex, :metric, :stop], fn _event, measurements, metadata, _config ->
  IO.puts("Metric #{metadata.metric} completed with score #{measurements.score}")
end, nil)
```

See [Telemetry Guide](wiki/guides/Telemetry.md) for all events and integration patterns.

## Migrating from deepeval

DeepEvalEx writes and reads deepeval's `test_run_<timestamp>.json` files, so
existing runs and the tools that read them carry over:

```elixir
# Read a run saved by deepeval's evaluate() (or by DeepEvalEx)
{:ok, test_run} = DeepEvalEx.TestRun.load("eval_results/test_run_20261022_101500.json")
{test_cases, results} = DeepEvalEx.TestRun.to_results(test_run)

# Save new runs in the same format and folder
DeepEvalEx.evaluate_run(test_cases, [DeepEvalEx.Metrics.ExactMatch],
  results_folder: "eval_results"
)
```

`DEEPEVAL_RESULTS_FOLDER` is honoured as in deepeval. Names map directly:
`LLMTestCase` is `DeepEvalEx.TestCase` (snake_case fields, same names),
`MetricData` is `DeepEvalEx.Result`, `evaluate()` is `DeepEvalEx.evaluate/3`
(returning a `DeepEvalEx.EvaluationResult` of `DeepEvalEx.TestResult`s) and
`DeepEvalEx.evaluate_run/3` also returns the saved run. See [TestRun](wiki/api/TestRun.md) for what is
kept on import.

## Development

All tooling runs in the dev container (`.devcontainer/`), which matches the CI
toolchain and has the reference Python deepeval 4.3.1 installed. With the
[Dev Container CLI](https://github.com/devcontainers/cli):

```sh
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . mix test
```

Provider credentials for live checks go in `.devcontainer/.env` (gitignored;
copy `.devcontainer/.env.example`), which the container loads at creation:
`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`,
`OLLAMA_HOST`, `TYPESAFE_API_KEY` and `TYPESAFE_MODEL_NAME`, and the live
checks' `DEEP_EVAL_LIVE_*` settings below. Values may be 1Password secret references
(`op://vault/item/field`); `.devcontainer/resolve-env.sh` resolves them with
`op inject` on the host into the gitignored `.devcontainer/.env.resolved`,
which is what the container loads. Recreate the container after editing it
(`devcontainer up --workspace-folder . --remove-existing-container`). The
default test suite never calls a real LLM (it uses the Mock adapter and
`Req.Test` stubs); only the opt-in live checks below do.

Test modules run in parallel. The Mock adapter's configured responses
(`Mock.set_response/2`, `Mock.set_schema_response/2` and the functions that
clear or read them) are shared by the whole node, so a module that uses them
must be `async: false`; an `async: true` module scripts its judge with
`Mock.script/2` instead. `mock_async_guard_test.exs` fails the suite when an
async module calls the shared API.

### Live checks

`test/deep_eval_ex/live_test.exs` runs structured output and a full
deepeval-compatible export against the real OpenAI and Anthropic APIs, and
optionally through the ReqLLM adapter and a local Ollama server (below). It
is tagged `:live` and excluded by default; run it explicitly:

```sh
devcontainer exec --workspace-folder . mix test --only live
```

Credentials come from `.devcontainer/.env` as above, as literals or `op://`
references. Each provider runs only when its API key is set; otherwise its
tests are reported as skipped, so a run with one key checks one provider. The
judge model defaults to each adapter's default model; set
`DEEP_EVAL_LIVE_OPENAI_MODEL` and `DEEP_EVAL_LIVE_ANTHROPIC_MODEL` to pick
another, for example the provider-prefixed model IDs a gateway publishes
(`OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL` pointing at the gateway). Live
checks cost real tokens and are not part of the gate.

The same suite has two optional cases. The ReqLLM adapter runs when
`DEEP_EVAL_LIVE_REQLLM_MODEL` names a ReqLLM model spec; through an
OpenAI-compatible gateway, set it to `openai:` followed by the gateway's model
ID, `DEEP_EVAL_LIVE_REQLLM_BASE_URL` to the gateway's base URL and
`DEEP_EVAL_LIVE_REQLLM_WIRE` to `openai_responses` (or `openai_chat`), with the
key in `OPENAI_API_KEY`. The Ollama adapter runs when both `OLLAMA_HOST` and
`DEEP_EVAL_LIVE_OLLAMA_MODEL` are set; it checks structured output and free
usage end to end rather than scores, so a very small model will do. A local
server in Docker on the host serves it to the container:

```sh
docker run -d --name deepeval-ollama -p 11435:11434 ollama/ollama
docker exec deepeval-ollama ollama pull qwen2.5:0.5b
# .devcontainer/.env:
#   OLLAMA_HOST=http://host.docker.internal:11435
#   DEEP_EVAL_LIVE_OLLAMA_MODEL=qwen2.5:0.5b
docker rm -f deepeval-ollama   # when done
```

`test/deep_eval_ex/live_system_one_test.exs` is the matching check for
TypeSafe's System One model, Jev. It is tagged `:live_system_one`, excluded by
default, and skipped unless `TYPESAFE_API_KEY` is set (a blank value counts as
unset); `TYPESAFE_MODEL_NAME` picks the model and defaults to `jev-latest`, as
in deepeval:

```sh
devcontainer exec --workspace-folder . mix test --only live_system_one
```

It asks Jev a Noul, a Choice and a Score directly, then evaluates every System
One fixture scenario Jev decides alone with the real TypeSafe adapter,
checking each test run's shape, score range, model name and cost, and prints
each scenario's token count and cost. Costs are checked at the price the
adapter resolves (`TYPESAFE_COST_PER_INPUT_TOKEN`, else Jev's for a
registered model); a model with no price, such as a pinned `jev-1.14.0`, is
checked as unpriced. It also sends Jev a state of about 70,000 estimated tokens
with the adapter's pre-check lifted (`context_budget: :unbounded`), checking
Jev's own `max_tokens_exceeded` rejection comes back as a context-limit error.
When `OPENAI_API_KEY` is set too, it runs Faithfulness in the `:hybrid` eval
mode with Jev and the OpenAI judge (`OPENAI_BASE_URL`,
`DEEP_EVAL_LIVE_OPENAI_MODEL`): once with Jev judging the claims, and once with
Jev failing on a rejected key, checking the LLM's verdicts take over and the
result's `:system_one_fallback_reason` says why.

### Gate

Every change must pass the same checks as CI, inside the container:

```sh
devcontainer exec --workspace-folder . mix hex.audit
devcontainer exec --workspace-folder . mix format --check-formatted
devcontainer exec --workspace-folder . \
  env MIX_BUILD_ROOT=/tmp/noopt mix compile --no-optional-deps --warnings-as-errors
devcontainer exec --workspace-folder . mix compile --warnings-as-errors
devcontainer exec --workspace-folder . mix credo --strict
devcontainer exec --workspace-folder . mix test --warnings-as-errors
devcontainer exec --workspace-folder . mix dialyzer
devcontainer exec --workspace-folder . env MIX_ENV=dev mix docs --warnings-as-errors
```

`mix hex.audit` fails on retired packages and security advisories. The
separate build root keeps the build without optional dependencies (here
`req_llm`) from replacing the full one; CI uses `--force` instead.

### deepeval parity fixtures

`test/deep_eval_ex/parity_test.exs` compares DeepEvalEx's test run exports
with golden files written by deepeval 4.3.1 under `test/fixtures/deepeval`.
To regenerate them after adding or changing a scenario in
`scripts/parity/generate_fixtures.py`:

```sh
devcontainer exec --workspace-folder . \
  env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_fixtures.py
devcontainer exec --workspace-folder . mix test test/deep_eval_ex/parity_test.exs
```

A difference is a bug to fix in DeepEvalEx, not something to normalise away;
see the [fixtures README](test/fixtures/deepeval/README.md).

### Changelog

Every user-visible change adds an entry under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), in the same commit as the change, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) (Added, Changed,
Deprecated, Removed, Fixed, Security). On release, `[Unreleased]` becomes the
new version section.

See the [Roadmap](ROADMAP.md) for the plan to deepeval 4.3.1 parity and the
[Changelog](CHANGELOG.md) for what has shipped.

## License

Apache 2.0 - See [LICENSE](LICENSE) and [NOTICE](NOTICE) for details.

This project is a derivative work of [DeepEval](https://github.com/confident-ai/deepeval)
by Confident AI, also licensed under Apache 2.0.
