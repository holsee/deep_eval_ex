# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Brings DeepEvalEx to output parity with Python deepeval 4.3.1, so a run can be
swapped in for deepeval and produce the same `test_run_<timestamp>.json`.

### Added

- **`DeepEvalEx.Result.format_error_text/2`**, a port of deepeval 4.3.1's
  `format_error_text`: `"<type>: <message>"` with the exception's unqualified
  module name, plus `" (Run with LOG_LEVEL=DEBUG for stack trace.)"` in
  verbose mode or the formatted stack trace with `with_stack: true`. It is
  the error text of deepeval's synchronous executor; the evaluator records
  the message alone, as deepeval's default asynchronous executor does.
- **`DeepEvalEx.EvaluationResult` and `DeepEvalEx.TestResult`**, ports of
  deepeval 4.3.1's `EvaluationResult` and `TestResult`. A `TestResult` is built
  as deepeval's `create_test_result` builds one: the test case's name (or
  `"test_case_<index>"`), `success`, its metrics' `DeepEvalEx.Result`s as
  `metrics_data` (skipped ones left out), `conversational: false`, `index`,
  the test case's input, outputs, contexts and metadata, and
  `classifications: []`. `success` is `false` when a non-flaky metric failed,
  else `true`, and folds in classifications like deepeval's `_local_success`
  (`nil` when no metric ran and no classification gave a verdict).
  `EvaluationResult.from_results/2` builds one from `evaluate_run/3`'s result
  lists; `confident_link` and `test_run_id` are always `nil`.
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
  deepeval 4.3.1 over nine scenarios (exact match, LLM-style metrics, an
  erroring metric, RAG with tool calls, hyperparameters, missing test case
  params, `ignore_errors=False` with a raising metric and with missing
  params, `skip_on_missing_params=True`); the parity suite
  compares DeepEvalEx's export against them key for key and byte for byte,
  and checks that DeepEvalEx raises the same exception with the same
  message where deepeval raised (`raised.json`).
- **Scripted-judge parity fixtures for every metric.** The fixture generator
  also runs deepeval 4.3.1's real ExactMatch, GEval, Faithfulness,
  Hallucination, AnswerRelevancy, ContextualPrecision, ContextualRecall and
  ToolCorrectness (including `available_tools`) against a judge that replays
  committed scripts, over 29 scenarios (pass, fail, empty lists, strict mode).
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
- **Faithfulness `:penalize_ambiguous_claims`**, deepeval 4.3.1's
  `penalize_ambiguous_claims`. When `true`, a `borderline` verdict (a claim
  the retrieval context neither supports nor contradicts) counts against the
  score instead of as faithful, and the reason prompt lists it, in verdict
  order, as an `(Ambiguous) <reason>` contradiction. It defaults to `false`,
  which keeps the current scoring. A new scripted-judge scenario,
  `faithfulness_penalize_ambiguous`, checks it against deepeval byte for byte.
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
- **Verbose logs on every result, exported as `verboseLogs`.**
  `DeepEvalEx.Result` and `DeepEvalEx.TestRun.MetricData` gain `:verbose_logs`,
  the metric's intermediate steps as deepeval 4.3.1 writes them (truths,
  claims, statements, verdicts, GEval's criteria, evaluation steps, rubric and
  score, ToolCorrectness's tools and tool selection score), byte for byte. The
  test run export writes them as each metric's `verboseLogs`, and
  `TestRun.load/1` reads them back, so a deepeval file round-trips with them.
  As in deepeval, the logs are computed whether or not the metric is in
  verbose mode, except by ExactMatch, which only builds them in verbose mode.
  Every metric takes `:verbose_mode` (`GEval.new/1` too), which prints the
  logs with the score and reason after measuring, as deepeval's
  `print_verbose_logs`; ExUnit assertions default it from the
  `DEEPEVAL_VERBOSE_MODE` environment variable, as deepeval's `assert_test`
  does. The helpers live in `DeepEvalEx.Metrics.Utils.Verbose`.
- **deepeval settings from application config and environment variables.**
  `DeepEvalEx.Config.get/1` resolves deepeval 4.3.1's settings under their
  `config/settings.py` names, so a `.env` shared with a deepeval project
  configures both: `DEEPEVAL_RESULTS_FOLDER`, `DEEPEVAL_IDENTIFIER`,
  `IGNORE_DEEPEVAL_ERRORS`, `SKIP_DEEPEVAL_MISSING_PARAMS`,
  `DEEPEVAL_VERBOSE_MODE`, `ENABLE_DEEPEVAL_CACHE`,
  `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE`, `DEEPEVAL_RETRY_MAX_ATTEMPTS`,
  `DEEPEVAL_RETRY_INITIAL_SECONDS`, `DEEPEVAL_RETRY_EXP_BASE`,
  `DEEPEVAL_RETRY_JITTER`, `DEEPEVAL_RETRY_CAP_SECONDS`, `DEEPEVAL_EVAL_MODE`,
  `TYPESAFE_API_KEY`, `TYPESAFE_MODEL_NAME` and
  `TYPESAFE_COST_PER_INPUT_TOKEN`. Each also has a `config :deep_eval_ex` key
  (`:results_folder`, `:verbose_mode`, `:retry_max_attempts`, ...), which
  takes precedence over the variable; blank values in either are unset.
  Values get deepeval's types, defaults and parsing: booleans with
  `parse_bool` (`DeepEvalEx.Config.parse_bool/2`), numbers with pydantic's
  rules and bounds (an invalid value raises an `ArgumentError` naming the
  variable), and `DEEPEVAL_EVAL_MODE` case-insensitively, unrecognised
  values counting as unset. The test run writer now also takes the results
  folder from `config :deep_eval_ex, results_folder:` and treats a
  whitespace-only `DEEPEVAL_RESULTS_FOLDER` as unset; ExUnit assertions take
  verbose mode from `config :deep_eval_ex, verbose_mode:` before
  `DEEPEVAL_VERBOSE_MODE`. The other settings are read by later parity work
  (error handling, timeouts, retries, eval modes). `Adapter.env/1` and
  `config/1` now delegate to `DeepEvalEx.Config.env/1` and `config/1`.
  Documented in the Configuration guide.
- `DeepEvalEx.Config.per_task_timeout_seconds/0`, deepeval's computed
  `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS`: the
  `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` setting when set and not `0`,
  else 180 seconds. It is the evaluator's default `:timeout`.
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
  deepeval's `format_rubrics` (`"0-3: ..."`, or `"5: ..."` for a single
  score).
- **GEval rubric score ranges.** `DeepEvalEx.Metrics.GEval.Rubric` ports
  deepeval 4.3.1's `Rubric`: `Rubric.new!/1` (and `new/1`) takes a
  `:score_range` `{start, end}` of integers from 0 to 10 and an
  `:expected_outcome`, rejecting other ranges with deepeval's messages.
  `GEval.new/1` sorts its rubric by range start and raises `ArgumentError`
  on overlapping ranges (`"Overlapping score ranges: (0, 5) and (5, 8)"`) as
  `validate_and_sort_rubrics` does, and the judge scores in the range the
  rubric spans (`Rubric.score_range/1`, deepeval's `get_score_range`; 0-10
  without a rubric), named in the prompt and used to normalise the score.
- **JSON fallback for judges without structured outputs.**
  `DeepEvalEx.LLM.Adapter.generate_with_schema/3` loads a judge's text answer
  as deepeval's `trimAndLoadJson` does (from the first `{` to the last `}`,
  adding a missing closing `}`, stripping trailing commas when a direct parse
  fails), both when an adapter's `generate_with_schema/3` returns a string and
  when its `supports_structured_outputs?/0` is `false`, in which case it is
  asked with `generate/2`. Text holding no valid JSON fails the metric with
  `{:error, %DeepEvalEx.LLM.InvalidJSONError{}}` and deepeval's message,
  "Evaluation LLM outputted an invalid JSON. Please use a better evaluation
  model." The loader is `DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json/1`.
- Adapter capability callbacks `supports_temperature?/1` (default `true`) and
  `supports_json_mode?/0` (default `false`), deepeval's `supports_temperature()`
  and `supports_json_mode()`, with `DeepEvalEx.LLM.Adapter.supports_temperature?/2`
  and `supports_json_mode?/1` for adapters that do not implement them. The
  OpenAI, Anthropic and Ollama adapters report JSON mode, and OpenAI and
  Anthropic report the models that reject a temperature.
- The Mock adapter's scripted mode returns a string response to a schema step
  as the judge's raw text, and the scripted parity fixtures gain
  `hallucination_messy_json` and `hallucination_invalid_json`.
- **GEval logprob-weighted scoring**, as in deepeval 4.3.1. A judge that
  returns log probabilities is asked for a raw chat completion instead of the
  score schema, and its score is replaced by the probability-weighted average
  of the score tokens it considered: the last token equal to the score, its
  top logprobs under 1% probability and non-decimal tokens dropped, falling
  back to the raw score when no token is left or the completion carries no
  logprobs (`GEval.calculate_weighted_summed_score/2`). Strict mode keeps the
  judge's score. `GEval.new/1` takes `:top_logprobs` (default `20`). Judges
  without logprobs (Anthropic, Ollama, Mock, custom adapters) still get the
  schema call and keep their score.
- **Raw responses with logprobs from adapters.** The adapter behaviour gains
  optional `generate_raw_response/2` (deepeval's `generate_raw_response`: the
  whole chat completion, in OpenAI's shape) and `supports_log_probs?/1` (per
  model), with `DeepEvalEx.LLM.Adapter.generate_raw_response/2` and
  `supports_log_probs?/1`. The OpenAI adapter implements both: it sends
  `logprobs: true` and `top_logprobs` (`:top_logprobs`, default `5`, capped
  at the model's maximum) for the models deepeval 4.3.1's registry lists with
  logprobs, and returns `{:error, {:log_probs_unsupported, model}}` for the
  rest, reasoning models included. The Mock adapter's scripted mode replays
  a `"raw_response"` step, and offers logprobs only when its script has one.
  The scripted parity fixtures gain `g_eval_logprobs` and
  `g_eval_logprobs_missing`, recorded with a scripted judge that answers
  deepeval's `generate_raw_response`.
- **deepeval's `AsyncConfig` evaluation options.** `DeepEvalEx.evaluate/3`,
  `evaluate_run/3` and `DeepEvalEx.Evaluator` take `:max_concurrent` (test
  cases evaluated at once, default `20`), `:throttle_value` (seconds to wait
  between launching test cases, default `0`) and `:run_async` (`false`
  evaluates test cases and their metrics one at a time, unthrottled, as
  deepeval's synchronous executor). A `:max_concurrent` below `1` or a
  `:throttle_value` below `0` raises `ArgumentError` with deepeval's
  `ValueError` message (`"'max_concurrent' must be at least 1"`,
  `"'throttle_value' must be at least 0"`). `:concurrency` stays as an alias
  of `:max_concurrent`, and `:metric_concurrency` still bounds the metrics
  of a test case.

### Changed

- **The OpenAI, Anthropic and Ollama adapters retry as deepeval's
  `retry_policy`.** A shared `DeepEvalEx.LLM.Retry`, a port of deepeval
  4.3.1's `models/retry_policy.py`, now supplies every adapter's `Req` retry
  options. Calls make `DEEPEVAL_RETRY_MAX_ATTEMPTS` attempts (default `2`,
  the first call included) instead of 4, and back off as Tenacity's
  `wait_exponential_jitter` with `DEEPEVAL_RETRY_INITIAL_SECONDS` (`1.0`),
  `DEEPEVAL_RETRY_EXP_BASE` (`2.0`), `DEEPEVAL_RETRY_JITTER` (`2.0`) and
  `DEEPEVAL_RETRY_CAP_SECONDS` (`5.0`, where `0` means no sleeps) instead of
  a fixed 1s, 2s, 4s; each is also a `config :deep_eval_ex` key (`:retry_*`)
  and is read at call time. What is retried follows deepeval's per-provider
  policy rather than Req's `:transient` list (`408`, `429`, `500`, `502`,
  `503`, `504` and three transport errors): OpenAI retries any transport
  error, `429` unless the quota is exhausted (`insufficient_quota`, by error
  code or message) and any `5xx`; Anthropic retries any transport error,
  `429` and any `5xx`, now including `529` Overloaded; Ollama retries
  transport errors only, no longer any HTTP status. No adapter retries `408`
  any more; authentication errors (`401`) stay unretried. Retries are logged at
  `:info`, deepeval's level, rather than `:warning`. `:req_options` still
  overrides all of this, e.g. `retry: false`.
- **BREAKING: timeouts follow deepeval's per-task timeout and messages.** The
  default `:timeout` is now deepeval's per-task timeout,
  `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` (or
  `config :deep_eval_ex, per_task_timeout_seconds_override:`) when set and
  not `0`, else 180 seconds, instead of 60 seconds. A metric that times out
  now errors with deepeval 4.3.1's message instead of `"Metric timed out"` or
  `"Evaluation timed out"`: `"Timed out/cancelled while evaluating metric.
  Increase DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set
  DEEPEVAL_LOG_STACK_TRACES=1 for full traceback."`, as deepeval's
  asynchronous executor records it. With `run_async: false`, as deepeval's
  synchronous executor, `:timeout` now bounds the whole test case rather
  than each metric: the metric running when it elapses errors with
  `"Timed out after <seconds>s while evaluating metric. Increase
  DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set DEEPEVAL_LOG_STACK_TRACES=1
  for full traceback."` (seconds to two decimals) and the metrics after it
  with `"Skipped due to case timeout."`. Without `ignore_errors: true` the
  first of them raises a `DeepEvalEx.MetricError` with that message.
- **The default number of test cases evaluated at once is now 20**, deepeval's
  `AsyncConfig.max_concurrent` default, instead of twice the number of
  schedulers. Pass `max_concurrent:` (or `concurrency:`) to choose another.
- **BREAKING: metric errors raise by default, as deepeval's `ErrorConfig()`.**
  `DeepEvalEx.evaluate/3`, `evaluate_run/3` and `DeepEvalEx.Evaluator` take
  deepeval's `ErrorConfig` as `:ignore_errors` and `:skip_on_missing_params`,
  both `false` by default. A metric that raises, returns `{:error, reason}`,
  times out or crashes now makes the evaluation raise, as deepeval's
  `evaluate()` re-raises the metric's exception: the exception the metric
  raised, or the new `DeepEvalEx.MetricError` (`DeepEvalEx.MissingTestCaseParamsError`
  for missing test case params, with deepeval's message) carrying the
  metric's name, its `reason` and its state as `:result` (`success: nil`, as
  deepeval's `measure()` leaves it). Nothing is saved for the run. It used to
  be recorded as an errored result: pass `ignore_errors: true` to keep that,
  with deepeval's semantics (the error message, `str(exception)`, on the
  result and in `MetricData`'s `error`, and `success: false`, `nil` for a
  score-only metric). `skip_on_missing_params: true` skips a metric missing
  its params instead, whatever `:ignore_errors`: its `DeepEvalEx.Result.skipped/2`
  result is left out of `metricsData` and `metricsScores`, and a test case
  with no metric left is left out of the run. As in deepeval, `evaluate()`
  does not read the `IGNORE_DEEPEVAL_ERRORS` and `SKIP_DEEPEVAL_MISSING_PARAMS`
  settings.
- **BREAKING: `DeepEvalEx.ExUnit` assertions raise metric errors unless
  `IGNORE_DEEPEVAL_ERRORS` is set**, as deepeval's `assert_test` reads its
  `ErrorConfig` from the `:ignore_errors` and `:skip_on_missing_params`
  settings (`config :deep_eval_ex` or `IGNORE_DEEPEVAL_ERRORS` and
  `SKIP_DEEPEVAL_MISSING_PARAMS`, see `DeepEvalEx.Config`); an
  `ignore_errors:` or `skip_on_missing_params:` option wins over both. With
  `:ignore_errors` an errored metric flunks with `"metric errored: ..."` as
  before. A skipped metric passes `assert_passes` and `assert_evaluation`,
  which return its skipped result, and flunks `assert_fails` and
  `assert_score`, which have no score to check. The assertions now measure
  through `DeepEvalEx.Evaluator.evaluate_metric/3`.

- **BREAKING: `DeepEvalEx.evaluate/3` takes a list of test cases and returns
  `{:ok, %DeepEvalEx.EvaluationResult{}}`**, with one `DeepEvalEx.TestResult`
  per test case in input order, as deepeval's `evaluate()` returns an
  `EvaluationResult`. It takes all of `evaluate_batch/3`'s options
  (`:concurrency`, `:metric_concurrency`, `:metric_timeout`, ...). Passing a
  single test case still returns the old `{:ok, [%DeepEvalEx.Result{}]}` for
  one release, through a compatibility clause that warns (see Deprecated).
  `evaluate_run/3` is unchanged and stays the way to get the result lists
  together with the `DeepEvalEx.TestRun` and saved path.
- **GEval scores from OpenAI judges are logprob-weighted.** With the default
  judge (`gpt-4o-mini`) or any OpenAI model deepeval lists with logprobs,
  GEval scores are now fractional averages (e.g. `0.783` rather than `0.8`),
  matching deepeval 4.3.1; scores from reasoning models and other providers
  are unchanged.
- **BREAKING: GEval rubrics are lists of `GEval.Rubric` entries.** A rubric
  entry is now `%DeepEvalEx.Metrics.GEval.Rubric{score_range: {lo, hi},
  expected_outcome: ...}` rather than `{score, description}`, ranges may not
  overlap, and the rubric sets the score range. `{score, description}`
  entries still work for one release (see Deprecated), as the single-score
  range `{score, score}`.
- **BREAKING: GEval strict mode scores the judge's 0 or 1 itself.** As in
  deepeval 4.3.1 (`int(g_score)`), a strict GEval's score is the judge's
  score truncated to an integer, so a judge's `1` scores `1` and passes. It
  used to be normalised over the 0-10 range (`0.1`) and then clamped to `0`,
  so a strict GEval could never pass. The `g_eval_strict` parity scenario
  now matches deepeval's score, verbose logs and test run export.
- **BREAKING: `GEval.new/1` validates as deepeval's constructor.** It raises
  `ArgumentError` with deepeval's messages for an empty
  `:evaluation_params` list, a blank `:criteria` and an empty
  `:evaluation_steps` list.

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

### Deprecated

- Passing a single `DeepEvalEx.TestCase` to `DeepEvalEx.evaluate/3`: wrap it
  in a list. It still returns `{:ok, [%DeepEvalEx.Result{}]}`, with a warning,
  and will be removed in the next release.
- `DeepEvalEx.evaluate_batch/3`: use `DeepEvalEx.evaluate/3`, or
  `DeepEvalEx.evaluate_run/3` for the same result lists. It still works, with
  a warning, and will be removed in the next release.
- `{score, description}` GEval rubric entries. `GEval.new/1` converts each to
  `Rubric.new!(score_range: {score, score}, expected_outcome: description)`
  and warns; they will be removed in the next release.
- GEval's `:score_range` option, which deepeval 4.3.1 does not have: give a
  rubric, whose ranges set the score range. Without a rubric it is still
  honoured, with a warning, for one release; with a rubric it raises
  `ArgumentError`.

### Removed

- The `ecto` dependency.
- **BREAKING:** `DeepEvalEx.TestCase.get_retrieval_context/1`, which fell
  back to `:context`. Read `test_case.retrieval_context` instead.

### Fixed

- A tool call whose `output` is a `Jason.OrderedObject` (as loaded from JSON
  with ordered objects) printed it as a Python dict in reasons and verbose
  logs; it now prints as indented JSON, like any other map, as deepeval's
  `ToolCall.__repr__` does.
- Every LLM metric now works against the real OpenAI API. Five of the seven
  (Answer Relevancy, Contextual Precision, Contextual Recall, Faithfulness,
  Hallucination) sent schemas that OpenAI's strict mode rejects with a 400.
- A test case that timed out returned a nested list of results instead of a
  flat one.
- A test case that times out keeps the results of the metrics that finished
  before its deadline, as deepeval does, instead of erroring every metric.
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
