# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Brings DeepEvalEx to output parity with Python deepeval 4.3.1, so a run can be
swapped in for deepeval and produce the same `test_run_<timestamp>.json`.

### Added

- **deepeval-compatible test run export.** `DeepEvalEx.evaluate_run/3` evaluates
  test cases and returns `{results, %DeepEvalEx.TestRun{}, path}`. With
  `:results_folder` (or the `DEEPEVAL_RESULTS_FOLDER` environment variable) it
  writes `test_run_<YYYYMMDD_HHMMSS>.json` the way deepeval does: same file
  naming and collision suffixes, same camelCase keys and key order, nulls
  omitted, and JSON encoded byte for byte like Python's `json.dump`. Also
  accepts `:results_subfolder`, `:identifier` and `:hyperparameters`.
- **Loading deepeval test runs.** `DeepEvalEx.TestRun.load/1` and `from_map/1`
  read a deepeval-produced test run; `to_results/1` turns it back into
  `DeepEvalEx.TestCase` data and `%DeepEvalEx.Result{}` entries. Every fixture
  round-trips byte for byte.
- **Golden parity fixtures.** `scripts/parity/generate_fixtures.py` runs real
  deepeval 4.3.1 over five scenarios (exact match, LLM-style metrics, an
  erroring metric, RAG with tool calls, hyperparameters); the parity suite
  compares DeepEvalEx's export against them key for key and byte for byte.
- **Anthropic adapter** (`DeepEvalEx.LLM.Adapters.Anthropic`), using the
  Messages API with a forced tool call for structured output. Defaults follow
  deepeval's `AnthropicModel`, including its price table.
- **Ollama adapter** (`DeepEvalEx.LLM.Adapters.Ollama`), using the native
  `/api/chat` endpoint with JSON-schema `format` for structured output.
  Like deepeval, a model is required and evaluation cost is reported as 0.
- **OpenAI-compatible endpoints.** The OpenAI adapter takes `:base_url`
  (or `config :deep_eval_ex, openai_base_url:` or `OPENAI_BASE_URL`), so it can
  target gateways and proxies. The Anthropic and Ollama adapters resolve
  `ANTHROPIC_BASE_URL` and `OLLAMA_HOST` the same way.
- **Token usage, cost and judge model on every result.** `DeepEvalEx.Result`
  gains `:evaluation_model`, `:input_tokens` and `:output_tokens`, and
  `:evaluation_cost` is now filled in, matching deepeval's `MetricData`.
  Usage is tracked across all LLM calls a metric makes (`DeepEvalEx.LLM.Usage`)
  and priced with deepeval's OpenAI and Anthropic tables
  (`DeepEvalEx.LLM.Pricing`). Unknown models get a `nil` cost rather than a
  guess; set prices with `config :deep_eval_ex, model_pricing: %{...}`.
  Telemetry `:stop` and `:exception` events carry `input_tokens`,
  `output_tokens` and `cost`.
- **Errored results.** `DeepEvalEx.Result` gains `:error`, `Result.error/3` and
  `Result.errored?/1`, so a metric that failed to run is distinguishable from
  one that scored low. ExUnit assertions report "metric errored: ..." instead
  of a low score.
- `DeepEvalEx.TestCase` fields from deepeval's `LLMTestCase`: `:comments`,
  `:token_cost`, `:input_token_count`, `:output_token_count`,
  `:completion_time` and `:flaky`. `DeepEvalEx.ToolCall` gains `:type`
  (`:function` or `:mcp`), accepts any JSON value as `:output`, and accepts
  deepeval's camelCase `inputParameters`.
- Evaluator options `:metric_concurrency` and `:metric_timeout`.
- Optional `BaseMetric` callbacks `metric_name/1` (a display name that depends
  on the metric's configuration) and `evaluation_model/1` (the judge model a
  metric reports even when no call was made).
- `DeepEvalEx.LLM.StrictSchema`, which rewrites a JSON schema into the form
  OpenAI strict structured outputs require, as pydantic does for deepeval.
- `DeepEvalEx.LLM.Adapter.env/1`, `config/1` and `model_name/1` helpers.
- The `:req_options` adapter option, for injecting `Req.Test` stubs or other
  Req settings.
- An opt-in live suite (`mix test --only live`) that runs real judge calls
  through each configured provider and checks the exported JSON. Judge models
  are selected with `DEEP_EVAL_LIVE_OPENAI_MODEL` and
  `DEEP_EVAL_LIVE_ANTHROPIC_MODEL`.
- **ToolCorrectness metric** with full deepeval parity: exact, non-exact and
  ordered (weighted LCS) matching, parameter and output comparison, and
  LLM-scored tool selection when `available_tools` are given. Includes wiki
  documentation.
- A dev container matching the CI toolchain (Elixir 1.19.5, OTP 28.4), bundling
  the reference Python deepeval used to generate parity fixtures. Provider
  credentials come from a gitignored `.devcontainer/.env`, which may hold
  1Password `op://` references resolved on the host with `op inject`.
- ADR 0008 (Peri replacing Ecto) and this changelog.

### Changed

- **Metric names now match deepeval**, because they key the exported
  `metricsData` and `metricsScores`: `ExactMatch` is reported as
  `"Exact Match"`, and GEval as `"<name> [GEval]"`.
- An errored metric now has `score: nil`, keeps its configured threshold and
  carries the error message, instead of `score: 0.0` and `threshold: 0.0`.
  Errored results keep the judge model, tokens and cost spent before the error.
- A metric's own configuration (for example a GEval threshold) now takes
  precedence over run-level options, which act as defaults.
- Metrics for a test case run concurrently, each with its own timeout, so one
  slow metric errors on its own rather than timing out the whole case.
- The OpenAI adapter sends `max_completion_tokens` instead of the deprecated
  `max_tokens` (`:max_tokens` is still accepted as an alias). It sends
  `temperature: 0.0` by default, as deepeval does, and omits temperature for
  reasoning models, including behind gateway prefixes such as
  `openai/gpt-6-luna` or `@region` suffixes.
- Schema validation uses Peri and plain structs instead of Ecto changesets.
  Each schema module exports `json_schema/0`.
- `req` now requires `~> 0.7`.
- CI runs Elixir 1.19.5 and OTP 28.4, matching `.tool-versions`.
- The roadmap and module docs describe what has shipped and what is planned.

### Removed

- The `ecto` dependency.

### Fixed

- Every LLM metric now works against the real OpenAI API. Five of the seven
  (Answer Relevancy, Contextual Precision, Contextual Recall, Faithfulness,
  Hallucination) sent schemas that OpenAI's strict mode rejects with a 400.
- A test case that timed out returned a nested list of results instead of a
  flat one.
- `nil` fields on a metric struct no longer hide the defaults they should fall
  back to.
- A metric that raises an exception becomes an errored result with the
  exception's message, as in deepeval, instead of crashing the evaluation.
- Anthropic: a base URL that already ends in `/v1` no longer produces
  `/v1/v1/messages`.
- Anthropic: a nested array or object that Claude returns in tool input as a
  JSON-encoded string is decoded, instead of failing the metric.
- Blank environment variables and blank config values (common when tooling
  forwards unset variables as empty strings) are treated as unset, instead of
  producing an empty base URL or API key.
- A malformed `:model_pricing` entry raises a clear `ArgumentError` instead of
  a match error mid-evaluation.
- The OpenAI adapter's retry backoff was 1s, 1s, 2s under Req's zero-based
  retry count; it is now 1s, 2s, 4s.
- Test cases that finish in under a second export `runDuration` as `0`, as
  deepeval does.

### Security

- Updated `hpax` (EEF-CVE-2026-58226), `mint`, `finch` and `req` to versions
  without known advisories, and dropped stale `ecto` and `decimal` lock
  entries. `mix hex.audit` is clean.
- The dev container's resolved credentials file is written with mode 600 and
  gitignored, along with its temp files, and is cleaned up if resolution is
  interrupted.

## [0.1.0] - 2025-12-26

Initial release: a pure Elixir port of DeepEval's core LLM evaluation.

### Added

- Metrics: ExactMatch, GEval (criteria, evaluation steps, rubrics and score
  ranges), Faithfulness, Hallucination, Answer Relevancy, Contextual Precision
  and Contextual Recall, with the multi-step prompts of their deepeval
  counterparts.
- `DeepEvalEx.TestCase`, `DeepEvalEx.Result` and `DeepEvalEx.ToolCall`.
- `DeepEvalEx.evaluate/3` and `evaluate_batch/3`, backed by a concurrent
  evaluator built on `Task.async_stream`.
- An LLM adapter behaviour, with an OpenAI adapter using structured outputs and
  a Mock adapter for tests.
- `DeepEvalEx.Metrics.BaseMetric`, a behaviour and `use` macro adding parameter
  validation and telemetry to custom metrics.
- Telemetry events for metric and evaluation start, stop and exception, and an
  optional default logger.
- ExUnit assertions: `assert_passes`, `assert_fails`, `assert_score` and
  `assert_evaluation`.
- Wiki guides, metric and API reference, and Architecture Decision Records
  0001 to 0007.
- ExDoc configuration with logo, guides and grouped modules.
- GitHub Actions CI running format, compile with warnings as errors, Credo and
  tests.

[Unreleased]: https://github.com/holsee/deep_eval_ex/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/holsee/deep_eval_ex/releases/tag/v0.1.0
