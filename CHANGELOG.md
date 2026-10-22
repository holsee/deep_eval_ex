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
  deepeval 4.3.1 over six scenarios (exact match, LLM-style metrics, an
  erroring metric, RAG with tool calls, hyperparameters, missing test case
  params); the parity suite
  compares DeepEvalEx's export against them key for key and byte for byte.
- **Scripted-judge parity fixtures for every metric.** The fixture generator
  also runs deepeval 4.3.1's real ExactMatch, GEval, Faithfulness,
  Hallucination, AnswerRelevancy, ContextualPrecision, ContextualRecall and
  ToolCorrectness (including `available_tools`) against a judge that replays
  committed scripts, over 28 scenarios (pass, fail, empty lists, strict mode).
  It records the prompts deepeval sent, the metric's state after `measure()`
  and the exported test run. A new parity suite replays the same scripts
  through DeepEvalEx and compares prompts and exports byte for byte. Known
  divergences from 4.3.1 are tagged `known_divergence` with the roadmap unit
  that fixes them and excluded by default; run them with
  `mix test --only known_divergence`.
- **Prompt template goldens.** The fixture generator also renders every
  prompt template deepeval 4.3.1's seven LLM-judged metrics use, the way each
  metric renders it, for 23 fixed inputs (including Faithfulness extraction
  limits, a GEval rubric and strict mode). A new test renders the same inputs
  with the matching `DeepEvalEx.Prompts` function and compares the strings
  exactly; the fixtures' README maps each prompt function to its 4.3.1
  template. Every case matches byte for byte.
- **System One (Jev) fixtures.** A second generator,
  `scripts/parity/generate_system_one_fixtures.py`, records what deepeval
  4.3.1 sends System One and does with its answers, using deepeval's own
  fake Jev models (no `typesafe-sdk`, no network): 24 scenarios covering
  Faithfulness, Hallucination, AnswerRelevancy, ContextualPrecision,
  ContextualRecall and ToolCorrectness in the `system_one` and `hybrid` eval
  modes and with Jev down (LLM fallback), JevEval with Noul, Score and Choice
  questions, `evaluate()` batching several metrics into one request, and
  RefusalClassifier. Each records the `decide()` payloads in the SDK's wire
  shape, the answers, the measured state (including `confidence` and
  `system_one_fallback_reason`) and the exported test run. A new test checks
  their structure; DeepEvalEx does not implement eval modes yet.
- **Shared QAG verdict handling.** `DeepEvalEx.Metrics.QAG` ports deepeval
  4.3.1's `normalize_qag_verdict` and `score_qag_verdicts`:
  `normalize_qag_verdict/2` coerces a judge's reply into `:yes`, `:no` or
  `:borderline` within a vocabulary (`yes_no/0`, `yes_no_borderline/0`) or
  `nil`, `parse_verdicts/2` parses a verdicts response and drops unknown
  verdicts, and `score_qag_verdicts/2` scores the fraction in a `:passing`
  set with deepeval's `:empty_score` and `strict_mode` clamp. The five
  verdict metrics parse their verdicts through it, and Faithfulness,
  AnswerRelevancy, Hallucination and ContextualRecall score through it.
- **`strict_mode`, score-only and `flaky` on every metric**, with deepeval
  4.3.1's `BaseMetric` semantics. Every metric, built-in or `use
  DeepEvalEx.Metrics.BaseMetric`, takes `:strict_mode` (the threshold is forced
  to the integer `1`, as deepeval's constructors force it, and a score below
  it becomes the integer `0`; the QAG metrics, ContextualPrecision and
  ToolCorrectness clamp before writing their reason, as deepeval does),
  `threshold: nil` (score-only: `success` is `nil`, as `is_successful()`
  returns `None`) and `:flaky` (reported, but never deciding its test case's
  success, as `update_status` ignores flaky metrics). `DeepEvalEx.Result`
  gains `:strict_mode`, `:flaky`, `:score_breakdown` and `:skipped`, with
  `Result.skipped/2` and `Result.successful?/2`; `BaseMetric.threshold/2` and
  `BaseMetric.strict_score/2` share the strict rules, and GEval takes
  `:flaky`. The export writes each metric's own `strictMode` and `flaky`,
  leaves out a score-only metric's `threshold` and `success`, counts it under
  `errors` in `metricsScores`, and leaves skipped results out of
  `metricsData`, all as deepeval does.
- **`evaluate` refuses runs that cannot pass or fail.** As deepeval's
  `check_at_least_one_metric_has_threshold`, `DeepEvalEx.evaluate/3`,
  `evaluate_batch/3`, `evaluate_run/3` and ExUnit's `assert_evaluation` raise
  `ArgumentError` ("You must provide at least one non-flaky metric with a
  'threshold', ...") before evaluating when no non-flaky metric has a
  threshold (`DeepEvalEx.Evaluator.check_at_least_one_metric_has_threshold!/2`).
  `assert_evaluation` does not count a score-only result as a failure, and
  `assert_passes`/`assert_fails` report that a score-only metric has no
  threshold.
- **deepeval test case keys.** `DeepEvalEx.TestCase.new/1` accepts the keys
  deepeval 4.3.1's `LLMTestCase` accepts, as atoms or strings: the camelCase
  aliases (`actualOutput`, `expectedOutput`, `retrievalContext`,
  `toolsCalled`, `expectedTools`, `tokenCost`, `inputTokenCount`,
  `outputTokenCount`, `completionTime`, `customColumnKeyValues`,
  `expectedLabels`) and `additionalMetadata` / `additional_metadata` for
  `:metadata`, with deepeval's precedence when several name one field. Any
  other key is dropped, as deepeval's `extra="ignore"`, so a deepeval-shaped
  JSON test case loads as it is.
- **`custom_column_key_values` and `expected_labels` on `DeepEvalEx.TestCase`**,
  string-to-string maps as in deepeval's `LLMTestCase`. Like deepeval, the
  test run export leaves them out.
- **`DeepEvalEx.Params.SingleTurn`**, deepeval's `SingleTurnParams`: `all/0`
  lists its thirteen members (including `:metadata`, `:tags` and the MCP
  params) in deepeval's order, `member?/1` checks one, and `display_name/1`
  gives deepeval's GEval name for it (`G_EVAL_PARAMS`).
- **`DeepEvalEx.Schemas.ToolCall.equal?/2`**, deepeval's `ToolCall.__eq__`:
  equal when `name`, `input_parameters` and `output` are, whatever the
  `type`, `description` and `reasoning`.
- **Scripted mode for the Mock adapter.** `Mock.script/2` replays judge
  responses keyed by step (named by the requested schema's fields, see
  `Mock.step_key/1`) and call index, reports the script's judge model and
  records prompts (`Mock.scripted_prompts/0`). Scripts belong to the calling
  process and the processes it starts, so async tests each replay their own.
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
- An opt-in TypeSafe Jev live check scaffold
  (`mix test --only live_system_one`), excluded by default and skipped unless
  `TYPESAFE_API_KEY` is set; `TYPESAFE_MODEL_NAME` defaults to `jev-latest`.
  Both settings, named as in deepeval, are listed in
  `.devcontainer/.env.example`. It only checks the credentials until a
  TypeSafe client lands.
- **ToolCorrectness metric** with full deepeval parity: exact, non-exact and
  ordered (weighted LCS) matching, parameter and output comparison, and
  LLM-scored tool selection when `available_tools` are given. Includes wiki
  documentation.
- A dev container matching the CI toolchain (Elixir 1.19.5, OTP 28.4), bundling
  the reference Python deepeval used to generate parity fixtures. Provider
  credentials come from a gitignored `.devcontainer/.env`, which may hold
  1Password `op://` references resolved on the host with `op inject`.
- ADR 0008 (Peri replacing Ecto) and this changelog.
- `DeepEvalEx.Prompts.Python`, which formats values as deepeval's Jinja
  templates and f-strings print them: `repr/1` (Python lists, dicts,
  strings with Python's quoting and escapes, `None`, `True`, deepeval
  `ToolCall` reprs and enum members such as `<Verdict.YES: 'yes'>`) and
  `format_fixed/2` (`format(x, ".2f")`, rounding exact ties to even).
- `DeepEvalEx.TestRun.JSON.encode!/2` takes `:indent` and `:ensure_ascii`,
  formatting like Python's `json.dumps(indent=n, ensure_ascii=...)`.
- `DeepEvalEx.Prompts.GEval.format_rubric/1`, formatting a rubric as
  deepeval's `format_rubrics`.

### Changed

- **BREAKING: Hallucination scores aligned contexts, higher is better.** As in
  deepeval 4.3.1 (PR #3102), the score is the fraction of contexts the output
  agrees with (`1.0` when the judge returns no verdicts) and a result passes
  when `score >= threshold`; it used to be the fraction contradicted, passing
  when `score <= threshold`. The default threshold stays 0.5. Review any
  `:threshold` you pass and any code reading `result.score`: a threshold of
  0.2 that meant "at most 20% contradicted" is now 0.8. The first Hallucination
  measurement on a node logs a warning saying so, as deepeval warns once per
  process, and the reason prompt tells the judge that higher is better.
- **BREAKING: QAG verdicts are normalised as in deepeval 4.3.1.**
  Faithfulness and AnswerRelevancy ask the judge for `yes`/`no`/`borderline`
  (prompt and JSON schema enum) instead of `yes`/`no`/`idk`, and their
  `result.metadata.verdicts` carry `:borderline` instead of `:idk`; a judge
  that still replies `idk` is read as `borderline`. In all five verdict
  metrics (also Hallucination, ContextualRecall and ContextualPrecision) a
  reply is lower-cased and read by its first word (`"No, it's off-topic"` is
  `no`), and a verdict outside the metric's vocabulary is now dropped from
  scoring. It used to be counted: as irrelevant in AnswerRelevancy, as
  faithful in Faithfulness, and as `no` in the others, so such responses now
  score differently.
- **Empty verdict lists score deepeval's integers.** With no verdicts,
  Faithfulness, AnswerRelevancy and Hallucination score the integer `1` and
  ContextualRecall the integer `0`, where they returned `1.0` and `0.0`, as
  deepeval's `measure()` does (the test run export still writes `1.0`, as
  deepeval's does). `DeepEvalEx.Result`'s `:score` is typed `number()`, and
  `Result.summary/1` accepts an integer score.
- **BREAKING: thresholds, success and strict mode follow deepeval's
  `BaseMetric`.** `strict_mode: true` now forces the threshold to the integer
  `1` and clamps lower scores to `0` in every metric (Faithfulness,
  AnswerRelevancy, Hallucination, ContextualPrecision and ContextualRecall
  ignored it; ToolCorrectness used the floats `1.0` and `0.0`). ExactMatch's
  default threshold is the integer `1` instead of `1.0`. ToolCorrectness
  reports its configured judge as `evaluation_model` even without
  `:available_tools`, as deepeval does.
- **BREAKING: a `nil` threshold means score-only.** A metric struct's
  `threshold: nil` is now its configuration, as deepeval's `threshold=None`,
  rather than unset: run-level `:threshold` no longer fills it in. Such
  results, and errored results given `threshold: nil`, have `success: nil`
  (typed `boolean() | nil`), so a test case no longer fails because of them.
- **BREAKING: per-metric `strictMode` in the export.**
  `DeepEvalEx.TestRun.from_results/3` no longer takes the `:strict_mode` and
  `:metrics` options, and `MetricData.from_result/2` is now `from_result/1`:
  each metric's `strictMode` and `flaky` come from its result.
  `MetricData.to_result/1` keeps them. Loading a deepeval file reads a metric
  without `success` as `nil` (deepeval's default) instead of `false`.
- **BREAKING: `context` and `retrieval_context` are separate.** As in
  deepeval 4.3.1, `DeepEvalEx.TestCase.new/1` no longer copies `:context`
  into `:retrieval_context`, and neither satisfies a metric that requires
  the other: Faithfulness, ContextualPrecision and ContextualRecall read
  `:retrieval_context` only, Hallucination `:context` only. A context-only
  test case now errors on Faithfulness with `'retrieval_context' cannot be
  None for the 'Faithfulness' metric`, and is exported without
  `retrievalContext`. Set the field each metric reads: `:retrieval_context`
  for what your retriever returned, `:context` for the ground truth.
- **BREAKING: required test case params are checked as deepeval's
  `check_llm_test_case_params`.** Only `nil` counts as missing, so an empty
  list or string (other than `actual_output`) no longer fails validation: a
  Hallucination test case with `context: []` is scored, not rejected. A
  required `actual_output` of `""` is reported before any missing param, as
  `{:error, {:empty_param, :actual_output}}`. GEval and ToolCorrectness
  validate the same way, and ToolCorrectness requires `:input` too, as in
  deepeval. Errored results and the exported `error` carry deepeval's
  `MissingTestCaseParamsError` message (`'actual_output' and
  'expected_output' cannot be None for the 'Exact Match' metric`,
  `'actual_output' cannot be empty for the 'Exact Match' metric`) instead of
  `Missing required parameters: ...`.
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
- **Judge prompts are deepeval 4.3.1's templates, verbatim.** The prompt
  modules of GEval, Faithfulness, Hallucination, AnswerRelevancy,
  ContextualPrecision, ContextualRecall and ToolCorrectness now render the
  same bytes as 4.3.1's Jinja templates (and shared fragments) for a
  text-only test case, instead of paraphrases of older templates, so a judge
  sees exactly the prompt deepeval would send. Template arguments are
  formatted as deepeval formats them: lists as Python lists
  (`['a', "it's"]`) rather than numbered lines, `[]` rather than `(none)`,
  scores as `0.50` rather than `0.5`, no trailing newline. GEval names three
  or more params as `Input, Actual Output, and Expected Output`, prints each
  test case field followed by a space and a blank line (lists as Python
  lists, `nil` as `None`), and its rubric as `<score>: <description>` lines,
  lowest score first. ToolCorrectness prints tools with every field
  (`"type": "FUNCTION"`, `null` when unset) and an empty tool list as an
  empty string. Hallucination's prompts include 4.3.1's multimodal input
  rules, which its templates carry unconditionally. Mock responses keyed on
  prompt text may need updating.
- **ToolCorrectness reasons print tools as deepeval does.** Tool names print
  as Python lists (`['get_weather']`) rather than JSON (`["get_weather"]`),
  and the missing tool calls of the default mode as deepeval's `ToolCall`
  reprs rather than names, matched by name, input parameters and output.
  The missing and out-of-order name sets of the ordering mode are sorted,
  where deepeval prints them in Python's hash order.
- Module docs describe only what has shipped. The roadmap sets out the phased
  plan to deepeval 4.3.1 parity, including System One (Jev) support, and links
  to this changelog for shipped work.

### Removed

- The `ecto` dependency.
- **BREAKING:** `DeepEvalEx.TestCase.get_retrieval_context/1`, which fell
  back to `:context`. Read `test_case.retrieval_context` instead.

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
  JSON-encoded string is decoded, instead of failing the metric, including
  when the debris after it repeats its closing bracket (`{...}}`).
- Blank environment variables and blank config values (common when tooling
  forwards unset variables as empty strings) are treated as unset, instead of
  producing an empty base URL or API key.
- A malformed `:model_pricing` entry raises a clear `ArgumentError` instead of
  a match error mid-evaluation.
- The OpenAI adapter's retry backoff was 1s, 1s, 2s under Req's zero-based
  retry count; it is now 1s, 2s, 4s.
- Test cases that finish in under a second export `runDuration` as `0`, as
  deepeval does.
- `DeepEvalEx.TestCase.new/1` no longer stops normalising a test case when a
  string key is not an existing atom: it used to skip normalisation
  altogether, so tool calls' `inputParameters` and `"FUNCTION"` / `"MCP"`
  types and integer `token_cost` / `completion_time` were left unconverted.
  Unknown keys are now dropped and the rest normalised.
- GEval prompts name `:tools_called`, `:expected_tools`, `:metadata` and
  `:tags` as deepeval does (`Tools Called`, `Expected Tools`, `Metadata`,
  `Tags`), instead of `Tools_called` and `Expected_tools`.

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
