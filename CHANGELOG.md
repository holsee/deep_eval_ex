# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Brings DeepEvalEx to output parity with Python deepeval 4.3.1, so a run can be
swapped in for deepeval and produce the same `test_run_<timestamp>.json`.

### Added

- **System One models: the provider contract and question/answer types**
  (ADR-0009), ports of deepeval 4.3.1's `DeepEvalBaseSystemOneModel` and
  `models/system_one/schema.py`. A System One model answers typed questions
  about a JSON state with probabilities instead of text, as TypeSafe AI's
  Jev does. No metric asks one yet; the eval modes come in later units.
  - `DeepEvalEx.SystemOne.Adapter`, the behaviour a provider implements:
    `decide/3` returns `{:ok, answers, usage | nil}` or
    `{:error, exception}`, and `model_name/1` names it. The optional
    `init/1` (check the options before any measure) and `context_budget/1`
    (token limits, by default Jev's 32,000-token state and 64,000-token
    request) get defaults from `use DeepEvalEx.SystemOne.Adapter`.
  - `DeepEvalEx.SystemOne.Model.resolve/1` resolves a model from `nil`
    (the new `:system_one_model` application config, else TypeSafe), a
    TypeSafe model name, the aliases `:typesafe`, `:jev` and `:mock`, a
    module, or `{module, opts}`. `Model.init/1` and `Model.context_budget/1`
    call the optional callbacks.
  - `DeepEvalEx.SystemOne.decide/3`, the facade every System One request
    goes through, plus `noul/3`, `choice/3` and `score/3`, which return the
    answers of one type. The facade wraps each request in a
    `[:deep_eval_ex, :system_one, :request]` telemetry span. It returns
    System One errors as `{:error, exception}`, whether they were returned
    or raised: `DeepEvalEx.SystemOne.Error`, `DeepEvalEx.DeepEvalError`,
    `DeepEvalEx.ContextWindowExceededError`, `Req.TransportError` (as a
    `ConnectionError` or `TimeoutError`) and timeout exits. Any other
    exception propagates, as deepeval catches only its System One error
    types. The facade returns the request's usage stamped `source:
    :system_one` and does not record it.
  - `DeepEvalEx.SystemOne.Question` (`Noul`, `Choice` and `Score`) with
    `to_wire/1` and `to_wire_map/1`, which build the TypeSafe SDK's shape
    (`TypeSafeModel._to_sdk_questions`): a Noul's `criteria` is left out
    when it has neither `true` nor `false`.
  - `DeepEvalEx.SystemOne.Answers` (`Noul`, `Choice` and `Score`) with:
    - `confidence/1`, which is `|2p - 1|` for a Noul;
    - `normalized/1`, which is the score over the highest level index, as
      `ScoreAnswer.normalized`;
    - `min_confidence/1` and `take_prefix/2`;
    - `to_dump/2` and `from_dump/1`, which write and read the
      `SystemOneAnswers.model_dump()` shape.

    The questions and answers of every `decide()` call in the System One
    fixtures round-trip byte for byte.
  - `DeepEvalEx.SystemOne.Error`, the provider error, with `:reason`,
    deepeval's class name as `:type`, the token counts of a context limit,
    and `:permanent?`. `describe/1` gives deepeval's hybrid fallback text
    (`"context limit (N est. tokens > L)"`, `"timeout (...)"`,
    `"ConnectionError: Jev is down"`). `format/1` gives
    `format_error_text`'s `"<type>: <message>"`, and `type_name/1` the
    deepeval class name.
  - `DeepEvalEx.DeepEvalError` and `DeepEvalEx.ContextWindowExceededError`,
    ports of deepeval's exceptions of the same names.
  - `DeepEvalEx.LLM.Usage` has a new `:source` field, `:llm` (the default)
    or `:system_one`.
- **`DeepEvalEx.SystemOne.Mode`, eval-mode resolution** (ADR-0009), a port
  of deepeval 4.3.1's `config/eval_mode.py` and `effective_eval_mode`. No
  metric reads the mode yet.
  - `resolve/1` takes a metric's `:eval_mode` option (`:llm`, `:hybrid` or
    `:system_one`, as an atom or a string, case-insensitive), then the
    `:eval_mode` setting (application config, then `DEEPEVAL_EVAL_MODE`),
    then `:llm`. An unrecognised option raises `ArgumentError` with
    deepeval's "Unsupported eval_mode 'x'. Valid values: llm, hybrid,
    system_one." message; an unrecognised setting is ignored.
  - `for_classifier/1` runs `:hybrid` as `:llm`, as
    `resolve_classifier_eval_mode`.
  - `effective/2` runs `:system_one` as `:hybrid` for a metric module that
    does not export `system_one_eval_spec/2` (deepeval's
    `has_whole_metric_form`).
  - `uses_system_one?/1`, `normalize/1` (deepeval's `normalize_eval_mode`,
    which `DeepEvalEx.Config` now uses for `:eval_mode`) and `modes/0`.
- **`DeepEvalEx.SystemOne.Limits`, the System One context-budget
  pre-check** (ADR-0009), a port of deepeval 4.3.1's
  `models/system_one/limits.py` and the Jev limits in `constants.py`. Nothing
  calls it yet; the whole-metric runner, the batch and the TypeSafe adapter
  will.
  - `check/3` returns `{:error, %DeepEvalEx.SystemOne.Error{reason:
    :context_limit, type: "SystemOneContextLimitError"}}`, with the estimate,
    the limit and deepeval's message, when the state plus the longest
    question exceeds the state budget or the whole request exceeds the
    request budget; otherwise `:ok`. The budget defaults to Jev's
    32,000/64,000 tokens and may be `:unbounded`.
  - `estimate_tokens/1` is deepeval's `ceil(len(text) / 3)`, counting code
    points as Python does: a string as it is, anything else as
    `json.dumps(ensure_ascii=False)` writes it. `question_tokens/1`
    estimates a `DeepEvalEx.SystemOne.Question` as its pydantic
    `model_dump()`, and any other question (such as the SDK's wire shape)
    as it is. Boundary tests use values from CPython.
- **`DeepEvalEx.SystemOne.Adapters.Mock`, a System One model for tests**
  (ADR-0009), a port of deepeval 4.3.1's `FakeSystemOneModel` and
  `ExplodingSystemOneModel` (`tests/test_metrics/system_one_fakes.py`). It
  ships in `lib`, like `DeepEvalEx.LLM.Adapters.Mock`, and is the `:mock`
  System One model.
  - `Mock.new/1` returns a `{Mock, opts}` handle answering with canned
    `:answers` (returned on every call, or a list consumed one per call), or
    an `:answer_fn` of the questions. `:raises` fails every call with an
    exception, returned as `{:error, exception}` or raised with
    `raise?: true`. `:cost` is `nil`, a number, a `DeepEvalEx.LLM.Usage` or
    `{value, input_tokens, output_tokens}` (default `0.0`, as deepeval's
    fake), and `:model` names it (`"fake-jev"`, or `"exploding-jev"` with
    `:raises`).
  - Each handle has its own `Agent`-backed call log, read with
    `Mock.calls/1` as `Mock.Call` structs (state, questions, then answers and
    usage or the error), so concurrently measured metrics and async tests
    never see each other's calls.
  - `Mock.from_fixture/2` builds a handle from a System One fixture's
    `input.json["system_one"]`, answering each question from the canned
    answers of its type and key (with an optional batch `:prefix`) or
    raising its `ConnectionError` or `TimeoutError`. `Mock.dump_calls/1`
    writes the log in `decide.json`'s shape: replaying every recorded call of
    the 24 System One fixtures gives their `decide.json` byte for byte.
  - `Mock.noul_answers/1` and `Mock.answer_everything/2`, ports of the fakes'
    `answer_fn` helpers.
- **`DeepEvalEx.SystemOne.AdapterCase`, a conformance case template for
  System One providers** (ADR-0009). `use DeepEvalEx.SystemOne.AdapterCase,
  model: spec` starts an `ExUnit.Case` that checks a provider's
  `model_name/1`, `init/1`, `context_budget/1` and `decide/3`: every
  question answered under its own type and key and nothing else,
  probabilities and confidences in `0..1`, Score levels integers within
  range, and a `Usage` or `nil` as usage. With `:failing_model` it checks a
  failure is a well-formed System One error, and with `:init_failure` that
  `init/1` rejects options with a well-formed `DeepEvalEx.SystemOne.Error`.
  The model may also come from the test context's `:system_one_model`. The
  checks are public (`assert_answers/2`, `assert_reply/2`, `assert_error/1`,
  `assert_budget/1`). It runs against the Mock, the TypeSafe adapter (on a
  stubbed API) and a toy third-party provider.
- **`DeepEvalEx.SystemOne.Adapters.TypeSafe`, TypeSafe AI's Jev** (ADR-0009),
  a port of deepeval 4.3.1's `TypeSafeModel` on `Req` and the default System
  One model (`:typesafe`, `:jev`, a Jev model name such as `"jev-preview"`,
  or an unset `:system_one_model`).
  - `decide/3` posts the state, the questions in the SDK's shape and the
    model to `POST https://api.typesafe.ai/v1/systemone` with a Bearer key,
    after deepeval's "requires at least one question" check and Jev's
    context-budget pre-check. The reply's Noul, Choice and Score answers
    keep their order, and Score level keys are cast to integers.
  - The API key, model and price come from `:api_key`, `:model` and
    `:cost_per_input_token`, else `TYPESAFE_API_KEY`, `TYPESAFE_MODEL_NAME`
    (default `"jev-latest"`) and `TYPESAFE_COST_PER_INPUT_TOKEN`.
    `model_name/1` is `"<model> (TypeSafe AI)"`. `init/1` fails permanently
    without a key, with deepeval's text, so a metric in `:hybrid` or
    `:system_one` fails before any measure; a negative price raises
    deepeval's `DeepEvalError`.
  - Usage is priced on input tokens only, at 0.042 USD per 1M for
    `jev-1.13.0`, `jev-latest` and `jev-preview` (computed as deepeval does,
    so 1,000 tokens cost `4.2000000000000004e-05`); missing token counts are
    `0`, and another model without a configured price is unpriced (`nil`).
  - Errors: only a reply whose `detail.error_type` is
    `"max_tokens_exceeded"` is a context limit Jev rejected
    (`limit_tokens: nil`); a bare `422` is an HTTP error. `401` and `403`
    are permanent authentication errors, `429` a rate limit, timeouts a
    `TimeoutError` and other transport errors a `ConnectionError`.
  - The request envelope, endpoint, auth header, error body and response
    field names follow the SDK's call shape and are unverified until the
    live check runs against Jev.
- **`DeepEvalEx.LLM.Retry` policy `:typesafe`**, deepeval's TypeSafe retry
  policy: transport errors, `429` and `5xx` are retried; `401`, `403`, other
  client errors (`422` included) and a `max_tokens_exceeded` reply are not.
- **Jev prices in `DeepEvalEx.LLM.Pricing`**: `jev-1.13.0`, `jev-latest`
  and `jev-preview` at 0.042 USD per 1M input tokens, output free, for
  display.
- **`DeepEvalEx.Prompts.Python.format_g/1` and `round/2`**, Python's
  `format(x, "g")` and `round(x, ndigits)` (ADR-0009), which deepeval 4.3.1's
  System One reasons and verbose logs use (`f"weight={weight:g}"`,
  `round(p, 3)` before printing the probabilities). Both round from the exact
  binary value, ties to even, as CPython does; `round/2` returns the float
  nearest the rounded decimal (so `repr/1` prints what Python prints), keeps
  the sign of a value rounded to zero, keeps integers integers and raises
  `ArgumentError` where Python raises `OverflowError`. They, and
  `format_fixed/2`, are checked against tables generated by CPython
  (`test/fixtures/python_format/generate.py`).
- **Metrics take `:eval_mode` and `:system_one_model`, and carry System One
  state** (ADR-0009), ports of deepeval 4.3.1's `BaseMetric` System One
  fields, `initialize_model`/`initialize_system_one_model` and
  `reset_system_one_state`. No built-in metric asks System One yet; the
  decision points and the whole-metric runner come in later units.
  - `DeepEvalEx.SystemOne.Context.resolve!/2` resolves a metric's effective
    eval mode, its initialised System One model (none under `:llm`, so a
    missing TypeSafe key is not an error) and whether it has an LLM (not
    under `:system_one`, so no LLM adapter or key is needed). A model whose
    `init/1` fails raises `DeepEvalEx.DeepEvalError` with deepeval's
    "DEEPEVAL_EVAL_MODE=hybrid routes metric decisions to ..., but it is not
    usable: ..." text. `BaseMetric.measure/2` passes the context to
    `do_measure/2` as `opts[:system_one]`, and `DeepEvalEx.Evaluator`
    resolves every metric's context once, before any test case starts, as
    deepeval fails when the metric is built; it raises even with
    `ignore_errors: true`. The Evaluator documents `:eval_mode` and
    `:system_one_model` as run-level defaults.
  - The optional `BaseMetric` callback `system_one_eval_spec/2`, deepeval's
    `_system_one_eval_spec`. Exporting it is what lets a metric run
    `:system_one`; any other metric runs it as `:hybrid`.
  - `DeepEvalEx.SystemOne.Ledger`, the per-measure confidence (the minimum
    over every System One answer), fallback reasons and disabled flag.
    `BaseMetric.measure/2` opens a fresh one for every measure and sets its
    confidence and fallback reasons (joined with `"; "`) on the result.
    `DeepEvalEx.LLM.Usage.async/1` and `await/2` carry it into tasks and
    back.
  - `DeepEvalEx.Result` has new in-memory fields `:confidence`,
    `:system_one_fallback_reason` and `:strict_applied`. None is exported, so
    `test_run.json` is unchanged. A result with `strict_applied: true` keeps
    its score through strict mode, so a System One `0.0` is not turned into
    the integer `0`. `:score_breakdown` may also be a list, as System One's
    is.
  - `DeepEvalEx.SystemOne.AdapterCase`'s `:init_failure` check also checks
    that `Context.resolve!/2` raises the failure as a `DeepEvalError`.
- **`DeepEvalEx.SystemOne.Decision`, the `:hybrid` decision points**
  (ADR-0009), a port of the System One helpers of deepeval 4.3.1's
  `metrics/utils/decision.py`. No built-in metric calls them yet.
  - `DeepEvalEx.SystemOne.Spec.Binary`, `Spec.Choice` and `Spec.Score`
    (deepeval's `SystemOneBinarySpec`, `SystemOneChoiceSpec` and
    `SystemOneScoreSpec`) describe one decision: its instructions, its
    options or levels, and the state it is about.
  - `Decision.probability/2` (P(yes) of one Noul), `choice/2` (the answer
    to one Choice) and `score/2` (one Score on `0..1`) return
    `{:ok, value}`, or `:llm` when the metric should run its LLM branch:
    under `:llm`, without a spec, or once a permanent failure disabled
    System One for the measure. They ask one question keyed `"verdict"`,
    book the request's usage (an unpriced request voids the summed cost)
    and fold its confidence into the measure's minimum. As in deepeval,
    they do not pre-check the context budget, and a mode that uses System
    One with no model raises deepeval's "routes decisions to a System One
    model, but ... has none configured" `DeepEvalError`.
  - `Decision.handle_failure/2`, deepeval's `handle_system_one_failure`:
    under `:hybrid` a failed request falls back to the LLM and adds
    deepeval's text (`"ConnectionError: Jev is down"`, `"timeout (...)"`,
    `"context limit (N est. tokens > L)"`) to the measure's
    `system_one_fallback_reason`, joined with `"; "`; a permanent failure
    (a rejected or missing key, a missing SDK) keeps the rest of the measure
    on the LLM. Under `:system_one` a context overflow raises
    `DeepEvalEx.ContextWindowExceededError` with deepeval's "could not run
    on System One ... Switch this metric back to the LLM" text
    (`Decision.context_limit_error/2`), and any other error is re-raised.
    An exception that is not a System One error always propagates.
  - `Decision.format_reason/3`, deepeval's `format_decision_reason`:
    `"Decided by fake-jev: tool selection 0.75, confidence 0.25."`.
- **QAG verdicts via System One** (ADR-0009), a port of the System One
  section of deepeval 4.3.1's `metrics/utils/qag.py`. No built-in metric
  calls it yet.
  - `DeepEvalEx.SystemOne.Spec.Verdicts` (deepeval's `SystemOneVerdictSpec`)
    describes one verdict per item: the question, the items and their
    `item_key`, the rest of the state, optional `{true, false}` criteria and
    an optional `build_verdict` function.
  - `Decision.verdicts/3` asks one Noul per item, keyed `"<item_key>_<i>"`
    with instructions `{item_key: item, "question": ...}`, about the state
    plus `"<item_key>s"`: the items. It returns `{:ok, verdicts}` with
    `%{verdict: verdict, reason: "P(yes)=0.91"}` per item, `{:ok, []}` with
    no request for no items, or `:llm` as the other helpers do. An item
    with no answer raises deepeval's "System One model returned no answer
    for claim 1." `DeepEvalError`.
  - `Decision.verdict_from_probability/2`: with `:borderline` in the
    vocabulary, above `0.65` is `:yes`, below `0.35` is `:no` and anything
    between is `:borderline`; without it, `0.5` and above is `:yes`.
  - `Decision.split_sentences/1`, deepeval's `split_sentences`: splits after
    `.`, `!` or `?` and whitespace, trimming and dropping empty sentences.
- **`DeepEvalEx.SystemOne.Scored`, the Noul, Score and Choice question
  primitives** (ADR-0009), ports of deepeval 4.3.1's
  `metrics/jev_eval/questions.py` and `parse_questions`. Nothing builds a
  whole-metric System One request from them yet.
  - `Scored.Noul` (a statement, optional `true` / `false` criteria),
    `Scored.Score` (a question over 2 to 10 unique levels, worst first) and
    `Scored.Choice` (a question over ordered `{name, credit}` options,
    credits in `0..1` or `nil` for not applicable, at least one credited),
    each with a `weight` greater than 0, `1.0` by default. Their `new!/1`
    raises `ArgumentError` with deepeval's messages, such as
    `"Score levels must be unique."`; weights and credits become floats.
    `Choice.applicable_options/1` and `not_applicable_options/1` split the
    options.
  - `Scored.to_question/1` builds the wire question a provider is sent; a
    Choice sends its option names only, never credits. `Scored.text/1`
    gives the question's text.
  - `Scored.parse!/1` parses a rendered `_experimental_system_one_questions`
    JSON array discriminated on `"type"`, keeping option order and ignoring
    unknown keys. Anything else raises deepeval's
    `"_experimental_system_one_questions must render to a JSON array of
    Noul / Score / Choice questions: ..."` `DeepEvalError`.
  - `Scored.Outcome`, deepeval's `QuestionOutcome` (one `score_breakdown`
    entry), with `to_dump/1` in `model_dump()` key order. Every
    `score_breakdown` of the System One fixtures dumps byte for byte, and
    the `jev_eval` fixtures' questions parse and go on the wire as deepeval
    sent them.
- **`DeepEvalEx.SystemOne.Runner`, the whole-chain `:system_one` path**
  (ADR-0009), a port of deepeval 4.3.1's `run_system_one_eval`
  (`metrics/utils/system_one.py`) and `metrics/jev_eval/utils.py`. No
  built-in metric calls it yet; they gain their specs in later units.
  - `DeepEvalEx.SystemOne.EvalSpec`, deepeval's `SystemOneEvalSpec`: the
    test case fields to send (`evaluation_params`), the `Scored` questions
    and any `extra_state`. `c:BaseMetric.system_one_eval_spec/2` now returns
    one (or `nil`).
  - `Runner.run/3`, which a metric calls from its `do_measure/2`. It
    returns `:continue` unless the metric's eval mode is `:system_one`, or
    when the spec is `nil` and the metric has an LLM; a `nil` spec without
    an LLM raises deepeval's "... which cannot judge this test case"
    `DeepEvalError`. Otherwise one request asks every question, keyed
    `q_<i>`, after the context-budget check. An overflow, from the check
    or reported by the model, raises `ContextWindowExceededError` with
    deepeval's switch-back-to-llm text, and any other error is raised
    unchanged: nothing falls back. A batch prefetch's answers and usage
    share (`opts[:system_one_prefetched]`) are used in place of the
    request. The result has the weighted-mean score (`1.0` / `0.0` under
    strict mode, kept as a float), deepeval's deterministic reason,
    `score_breakdown`, the minimum confidence, the System One model as
    `evaluation_model` and the `"Decided by System One (<model>); no LLM
    call was made."` verbose logs.
  - `DeepEvalEx.SystemOne.State`, deepeval's `construct_single_turn_state`:
    `{"test_case": {...}}` with the populated params in the spec's order,
    then the non-nil `extra_state`. Structs are sent through the new
    `DeepEvalEx.SystemOne.Dumpable` protocol, pydantic's
    `model_dump(mode="json", exclude_none=True)`, which `ToolCall`
    implements (`"type": "FUNCTION"`); other structs are sent as text.
  - `DeepEvalEx.SystemOne.Scoring`: answers to values (a Noul's P(true), a
    Score's `score / (levels - 1)`, a Choice's credit-weighted mean, not
    applicable from `0.5` not-applicable mass), `aggregate/1`,
    `mark_strict/2`, `aggregate_strict/1`, `min_confidence/1`, the
    verbalised bands with the `0.15` runner-up margin, `reason/3`,
    `format_for_logs/1` and `classification_reason/2`.

  The `<metric>_system_one`, `faithfulness_system_one_strict` and `jev_eval`
  fixtures replayed through the runner send deepeval's requests and reach
  its scores, reasons, confidences and score breakdowns byte for byte.
- **Export semantics under the System One eval modes** (ADR-0009), as
  deepeval 4.3.1's `prepare_measure`, `_accrue_cost` and
  `(self.model or self.system_one_model).get_model_name()`:
  - Every measure of a metric with a judge (one that implements
    `c:BaseMetric.evaluation_model/1`) or under `:system_one` now starts
    from a seed usage (`DeepEvalEx.LLM.Usage.seed/1`, source `:seed`),
    recorded once the test case is validated: zero cost and token counts
    when the judge is native or there is no LLM (`:system_one`), `nil`
    for a custom judge. System One requests add to it, so a `:system_one`
    measure exports Jev's input-token cost and token counts (`0.0`, `0`
    and `0` when no request was priced or made), while a `:hybrid` measure
    with a custom judge exports System One's token counts and no cost.
  - `DeepEvalEx.LLM.Usage.summarize/1` takes the evaluation model from
    `:llm` usages only. Without one, the result names the metric's LLM
    judge, or under `:system_one` its System One model (`"fake-jev"`,
    `"jev-latest (TypeSafe AI)"`), errored results included. A `:hybrid`
    measure therefore names its LLM judge even when only System One was
    asked.
  - The optional `DeepEvalEx.LLM.Adapter` callback `native?/0` (default
    `false`, `true` for the OpenAI, Anthropic and Ollama adapters, as
    deepeval's native models) and `DeepEvalEx.LLM.Adapter.native?/1`,
    which resolves the judge from the options.
  - `DeepEvalEx.LLM.Usage`'s `:source` gains `:seed`.

  The `<metric>_system_one`, `faithfulness_system_one_strict`, `jev_eval`
  and `jev_eval_strict_not_applicable` fixtures, and every `<metric>_hybrid`
  and `<metric>_hybrid_fallback` fixture (System One requests replayed by a
  stand-in metric until the built-in metrics gain their hybrid paths),
  export deepeval's `test_run.json` byte for byte. Confidence, the
  fallback reason and the score breakdown are not exported.
- **Faithfulness and AnswerRelevancy run on System One** (ADR-0009), as
  deepeval 4.3.1's `FaithfulnessMetric` and `AnswerRelevancyMetric` do with
  `eval_mode`:
  - `:hybrid`: the LLM still extracts (truths and claims, or statements)
    and writes the reason, but the System One model judges each claim
    against the truths, or each statement against the input, one Noul per
    item in one request (`claim_<i>`, `statement_<i>`). Each P(yes) becomes
    a `yes` / `borderline` / `no` verdict with the reason `"P(yes)=0.91"`.
    When the request fails, the LLM judges instead and the result's
    `:system_one_fallback_reason` says why (`"ConnectionError: Jev is
    down"`). No items means no request.
  - `:system_one`: each metric implements
    `c:BaseMetric.system_one_eval_spec/2` and calls
    `DeepEvalEx.SystemOne.Runner.run/3`, so one request about
    `actual_output` and `retrieval_context` (Faithfulness) or `input` and
    `actual_output` (AnswerRelevancy) answers the whole metric, with no LLM
    call.
  - `system_one_verdict/0` and `system_one_questions/0` on
    `DeepEvalEx.Prompts.Faithfulness` and `DeepEvalEx.Prompts.AnswerRelevancy`
    render deepeval's `_experimental_system_one_verdict` and
    `_experimental_system_one_questions` templates. Four new prompt goldens
    check them byte for byte.

  A new parity test measures the `faithfulness_*` and `answer_relevancy_*`
  System One fixtures (`system_one`, `system_one_strict`, `hybrid` and
  `hybrid_fallback`) with the real metrics. The System One requests, the
  measured state (including confidence, fallback reason and score
  breakdown), the judge's prompts and the exported test run all match
  deepeval byte for byte.
- **ContextualPrecision and ContextualRecall run on System One**
  (ADR-0009), as deepeval 4.3.1's `ContextualPrecisionMetric` and
  `ContextualRecallMetric` do with `eval_mode`:
  - `:hybrid`: the System One model judges each retrieval context node
    against `input` and `expected_output` (`node_<i>`), or each sentence of
    `expected_output`, split as deepeval's `split_sentences` does, against
    `retrieval_context` (`sentence_<i>`), one Noul per item in one request.
    Each P(yes) becomes a `yes` (`0.5` and above) or `no` verdict, never
    `borderline`, with the reason `"P(yes)=0.91"`; the LLM still writes the
    metric's reason. When the request fails, the LLM judges instead and the
    result's `:system_one_fallback_reason` says why.
  - `:system_one`: each metric implements
    `c:BaseMetric.system_one_eval_spec/2` and calls
    `DeepEvalEx.SystemOne.Runner.run/3`, so one request about `input`,
    `retrieval_context` and `expected_output` (ContextualPrecision) or
    `expected_output` and `retrieval_context` (ContextualRecall) answers the
    whole metric, with no LLM call.
  - `system_one_verdict/0` and `system_one_questions/0` on
    `DeepEvalEx.Prompts.ContextualPrecision` and
    `DeepEvalEx.Prompts.ContextualRecall` render deepeval's
    `_experimental_system_one_verdict` and
    `_experimental_system_one_questions` templates. Four new prompt goldens
    check them byte for byte.

  The System One parity test now also measures the `contextual_precision_*`
  and `contextual_recall_*` fixtures (`system_one`, `hybrid` and
  `hybrid_fallback`), which match deepeval byte for byte.
- **Hallucination runs on System One** (ADR-0009), as deepeval 4.3.1's
  `HallucinationMetric` does with `eval_mode`:
  - `:hybrid`: the System One model judges whether `actual_output` agrees
    with each document of `context` (`context_<i>`), one Noul per context
    in one request. Each P(yes) becomes a `yes` (aligned, `0.5` and above)
    or `no` verdict, never `borderline`, with the reason `"P(yes)=0.91"`;
    the LLM still writes the metric's reason. When the request fails, the
    LLM judges instead and the result's `:system_one_fallback_reason` says
    why.
  - `:system_one`: the metric implements
    `c:BaseMetric.system_one_eval_spec/2` and calls
    `DeepEvalEx.SystemOne.Runner.run/3`, so one request about
    `actual_output` and `context` answers the whole metric, with no LLM
    call. The score keeps deepeval 4.3.1's direction (higher is better).
  - `system_one_verdict/0` and `system_one_questions/0` on
    `DeepEvalEx.Prompts.Hallucination` render deepeval's
    `_experimental_system_one_verdict` and
    `_experimental_system_one_questions` templates. Two new prompt goldens
    check them byte for byte.

  The System One parity test now also measures the `hallucination_*`
  fixtures (`system_one`, `hybrid` and `hybrid_fallback`), which match
  deepeval byte for byte.
- **ToolCorrectness scores tool selection on System One** (ADR-0009), as
  deepeval 4.3.1's `ToolCorrectnessMetric` does with `eval_mode`:
  - `:hybrid` and `:system_one`: when `:available_tools` are given, one
    Score over deepeval's five tool selection levels (`"Misaligned"`,
    `"Poor selection"`, `"Mixed selection"`, `"Mostly appropriate"`,
    `"Fully appropriate"`) about `input`, the tools called and the
    available tools replaces the LLM's tool selection score. The score is
    the chosen level over the highest (`0.75` for `"Mostly appropriate"`)
    and the tool selection reason is `"Decided by fake-jev: tool selection
    0.75, confidence 0.25."`. Without `:available_tools` nothing is asked.
  - Under `:hybrid`, when the request fails, the LLM scores tool selection
    and the result's `:system_one_fallback_reason` says why.
  - The tool calling score is still decided in code, so the metric has no
    whole-metric request: `system_one_eval_spec/2` returns `nil`, which
    keeps it on `:system_one` with no LLM, its tool selection Score as its
    only request and the System One model as its `evaluation_model`.
  - `DeepEvalEx.Prompts.ToolCorrectness.system_one_tool_selection_score/0`
    renders deepeval's `_experimental_system_one_tool_selection_score`
    template. A new prompt golden checks it byte for byte.

  The System One parity test now also measures the `tool_correctness_*`
  fixtures (`system_one`, `hybrid` and `hybrid_fallback`), which match
  deepeval byte for byte.
- **GEval and ExactMatch take no part in System One** (ADR-0009), as deepeval
  4.3.1's `GEval` and `ExactMatchMetric`, which never build a System One
  model. Under `DEEPEVAL_EVAL_MODE=hybrid` or `system_one` (or the
  `:eval_mode` option) GEval is still judged by its LLM and ExactMatch
  measures as before; neither builds nor calls a System One model, so a
  missing TypeSafe key no longer makes them raise `DeepEvalEx.DeepEvalError`
  ("... routes metric decisions to TypeSafe AI Jev, but it is not usable").
  - The optional `BaseMetric` callback `system_one?/0`: a metric that
    returns `false` gets the `:llm` `DeepEvalEx.SystemOne.Context` in every
    mode. An unrecognised `:eval_mode` option still raises `ArgumentError`.
- **`DeepEvalEx.Metrics.JevEval`, a custom metric decided by System One**
  (ADR-0009), a port of deepeval 4.3.1's `JevEval`. You write weighted
  `DeepEvalEx.SystemOne.Scored` Noul, Score and Choice questions about the
  test case fields in `:evaluation_params`. One System One request answers
  them all (keyed `q_<i>`). The score is the weighted mean of the answers
  that applied, and the reason is deterministic text built from the answers.
  - Results are named `"<name> [JevEval]"` (`include_jev_eval_suffix:
    false` drops the suffix). The threshold defaults to `0.5`. In strict
    mode the score is `1.0` only when every applicable question is answered
    at its best, and `0.0` otherwise. Results carry `:score_breakdown` (one
    outcome per question) and `:confidence` (the least decisive answer).
  - JevEval is always decided by System One, whatever the eval mode, and
    needs no LLM or LLM key. It is seeded as a metric without an LLM: zero
    cost and tokens, plus the request's usage. An unpriced request leaves
    the cost `nil`. A System One error is raised, never caught, and the
    metric is not batched with others.
  - `JevEval.new/1` resolves and initialises the System One model, as
    deepeval's constructor does, and raises `DeepEvalEx.DeepEvalError`
    ("JevEval needs Jev to score, but it is not usable: ...") when the model
    cannot be used. It raises `ArgumentError` with deepeval's messages for an
    empty `:evaluation_params` list, no questions, or a question that is not
    a Noul, Score or Choice. `JevEval.evaluate/3` measures with a struct, and
    `DeepEvalEx.evaluate/3` takes the struct like any other metric.
  - Before asking, the test case is checked as deepeval does. A multimodal
    test case (one with a `[DEEPEVAL:IMAGE:...]` or `[DEEPEVAL:PDF:...]`
    marker) raises `ArgumentError`. A missing evaluation param returns
    `{:error, {:missing_params, params}}`. Without `:evaluation_params`,
    deepeval asks about the agent's trace. DeepEvalEx test cases carry no
    trace yet, so such a metric raises `DeepEvalEx.MissingTestCaseParamsError`
    with deepeval's message. The trace state and `ConversationalJevEval` come
    later.

  The System One parity test now also measures the `jev_eval` and
  `jev_eval_strict_not_applicable` fixtures, which match deepeval byte for
  byte: the request, the measured state, the verbose logs and the exported
  test run.
- **Batched System One requests in `evaluate()`** (ADR-0009), a port of
  deepeval 4.3.1's `system_one_batch.py`. When two or more of a test case's
  metrics run under the `:system_one` eval mode, `DeepEvalEx.Evaluator` now
  asks System One about the test case in as few requests as the context
  budget allows, instead of one request per metric, before the metrics run
  (`DeepEvalEx.SystemOne.Batch.prefetch/3`).
  - Candidates are counted as deepeval counts them: a metric whose spec
    declines the test case (ToolCorrectness) counts towards the two, then
    makes its own request. A single `:system_one` metric is not batched.
  - Requests are packed greedily in metric order: a metric joins the first
    request for a model of the same name whose state merges with its own
    (the new `DeepEvalEx.SystemOne.State.merge/2`) and that still fits the
    model's context budget. Question keys are prefixed `m<j>.`. Requests run
    concurrently within the test case's timeout.
  - A request's cost is split among its metrics by their share of its
    questions, and its token counts are apportioned with Python's
    round-half-even so that they add up (`Batch.split_usage/2`,
    `Batch.apportion/2`): 3,001 input tokens over three metrics are
    1000/1001/1000.
  - Each metric still runs its own `measure/2` with its answers, so scores,
    reasons, strict mode, usage, telemetry and timeouts are unchanged. The
    request's telemetry span carries every batched metric's name and
    `batched?: true`.
  - Nothing falls back to the LLM. A failed request fails each of its
    metrics: with `ignore_errors: true` the recorded error is deepeval's
    `format_error_text` (`"ConnectionError: Jev is down"`, not the bare
    message), otherwise the request's error is raised as it is. A context
    overflow of a request for one metric is that metric's
    `DeepEvalEx.ContextWindowExceededError`. A metric whose test case lacks
    its params errors with `"MissingTestCaseParamsError: ..."`, is skipped
    with `skip_on_missing_params: true`, or raises
    `DeepEvalEx.MissingTestCaseParamsError`.
  - `DeepEvalEx.SystemOne.Runner.request_for/3` exposes the whole-chain
    request a metric would send.

  The System One parity test now also runs the `batch_system_one` and
  `batch_system_one_down` fixtures: each metric measured alone, and the
  `evaluate()` run's single batched request and exported test run (cost
  4.2e-05 and 1000/1001/1000 tokens per metric), byte for byte.
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
- **Every key of deepeval's `TestRun` export, and lossless loading of
  richer files.** `DeepEvalEx.TestRun` gains `:test_file`, `:dataset_alias`,
  `:dataset_id`, `:dataset_version` and `:official`, exported as `testFile`,
  `datasetAlias`, `datasetId`, `datasetVersion` and `official` in the field
  order of deepeval 4.3.1's `TestRun` and left out when `nil`, as
  `exclude_none` does; `from_results/3` takes options of the same names.
  `TestRun.load/1` and `from_map/1` now keep what DeepEvalEx does not
  interpret as raw decoded JSON and write it back where deepeval declares it:
  `traceMetricsScores` and `prompts` on the run (`:trace_metrics_scores`,
  `:prompts`), `expectationsData`, `imagesMapping` and `trace` on each test
  case, and `expectationsData` on each metric (conversational test cases are
  read into structs, see below); keys deepeval does not model either are
  kept in each struct's `:extra` and written after the others. A deepeval file
  with traces, prompts and a dataset now round-trips byte for byte, checked
  against a new `round_trip/traced_dataset` fixture generated with
  `evals_iterator()` over an `@observe`d app.
- **Latest-run snapshots in `.deepeval/`.** Every `evaluate/3` and
  `evaluate_run/3` run with at least one test case now overwrites
  `.deepeval/.latest_run_full.json` (the same bytes as the timestamped
  `test_run_*.json`) and `.deepeval/.latest_test_run.json`
  (`{"testRunData": <the run>}`), as deepeval 4.3.1's
  `write_rolling_test_run` and `wrap_up_test_run` do, whether or not a
  results folder is set. The folder is the new `:cache_folder` setting
  (`DEEPEVAL_CACHE_FOLDER`, default `.deepeval` in the working directory).
  With the new `:file_system` setting `DEEPEVAL_FILE_SYSTEM=READ_ONLY`
  (aliases `READ-ONLY`, `READONLY`, `RO`; see `DeepEvalEx.Config.read_only?/0`)
  neither snapshot is written, while the results folder still is, as in
  deepeval; any other value raises `ArgumentError` before evaluating. A
  snapshot that cannot be written logs a warning and never fails the run.
  Also exposed as `DeepEvalEx.TestRun.LocalStore.write_rolling/2` and
  `write_latest/2`; `.deepeval/` is now git-ignored.
- **System One request and fallback telemetry** (ADR-0009), standing in for
  deepeval 4.3.1's Jev progress indicator.
  - New: a `:hybrid` decision that falls back to the LLM after a System One
    error emits `[:deep_eval_ex, :system_one, :fallback]` with the metric
    and the reason added to its `system_one_fallback_reason`.
  - The `[:deep_eval_ex, :system_one, :request, :start | :stop |
    :exception]` span that `DeepEvalEx.SystemOne.decide/3` already emits
    (above) is unchanged; its metadata and measurements, including the
    metrics each path names (a `:hybrid` decision, a whole-chain measure,
    `JevEval`, or a packed batch with several metrics and `batched?: true`),
    are now documented in `DeepEvalEx.Telemetry`.
  - `DeepEvalEx.Telemetry.attach_default_logger/0` now also logs each
    request (debug), each failed or raising request (warning) and each
    fallback (info).
- **`DeepEvalEx.Metrics.ContextualRelevancy`**, a port of deepeval 4.3.1's
  `ContextualRelevancyMetric` and the last of its five RAG metrics: how much
  of the retrieval context is relevant to the input. Named
  `"Contextual Relevancy"`, threshold `0.5`, it requires `input` and
  `retrieval_context`.
  - The judge extracts the statements of each retrieval context node in a
    prompt of its own and calls each relevant (`yes`) or not (`no`, with a
    reason). The score is the share of `yes` verdicts over every node,
    higher is better, the integer `0` when there are none, and `0` below
    the threshold in strict mode. The reason prompt lists the `no`
    verdicts' reasons (`None` where the judge gave none) and the relevant
    statements. `metadata.verdicts` holds one list of
    `%{statement, verdict, reason}` per node, and the verbose logs dump
    them as deepeval's `ContextualRelevancyVerdicts`.
  - `:hybrid`: each node is split into sentences and the System One model
    judges them against `input`, one request per node (`statement_<i>`).
    P(yes) of `0.5` and above is `yes` with the reason `"P(yes)=0.97"`,
    below is `no` with `"'<sentence>' is not relevant to the input
    (P(yes)=0.04)."`, as deepeval's `_system_one_relevancy_verdict`; the
    LLM still writes the reason, and a failed request hands that node to
    the LLM.
  - `:system_one`: one request about `input` and `retrieval_context`
    answers the whole metric with no LLM call, and can be batched with the
    test case's other `system_one` metrics.
  - `DeepEvalEx.Prompts.ContextualRelevancy` renders deepeval's
    `generate_verdicts`, `generate_reason`,
    `_experimental_system_one_verdict` and
    `_experimental_system_one_questions` templates byte for byte (four new
    prompt goldens), and `DeepEvalEx.Schemas.MetricOutputs.ContextualRelevancy`
    holds its response schemas.

  New parity fixtures generated by deepeval 4.3.1 cover it: scripted-judge
  scenarios `contextual_relevancy_pass`, `_fail`, `_no_statements` and
  `_strict`, System One scenarios `contextual_relevancy_system_one`,
  `_hybrid` and `_hybrid_fallback`, and `batch_system_one_retrieval`
  (ContextualRelevancy batched with ContextualPrecision). DeepEvalEx matches
  each byte for byte.
- **`DeepEvalEx.Metrics.Bias`** and **`DeepEvalEx.Metrics.Toxicity`**,
  ports of deepeval 4.3.1's `BiasMetric` and `ToxicityMetric`: how free the
  opinions in `actual_output` are of gender, political, racial/ethnic and
  geographical bias, and of personal attacks, mockery, hate, dismissive
  statements and threats. Named `"Bias"` and `"Toxicity"`, threshold `0.5`,
  they require `input` and `actual_output`.
  - The judge extracts the output's opinions, then calls each biased (toxic)
    (`yes`, with a reason) or not (`no`). The score is the share of `no`
    verdicts, higher is better as in deepeval 4.x, the integer `1` when
    there are no opinions (no verdicts are asked for then), and `0` below
    the threshold in strict mode. The reason prompt lists the `yes`
    verdicts' reasons (`None` where the judge gave none).
    `metadata.opinions` and `metadata.verdicts` hold them, and the verbose
    logs list the opinions and verdicts as deepeval's do.
  - Like Hallucination, each logs deepeval's score direction warning on its
    first measurement on a node: deepeval before 4.x scored the share of
    biased (toxic) opinions and passed at or below the threshold.
  - `:hybrid`: the System One model is asked whether each opinion is biased
    (toxic), one Noul per opinion (`opinion_<i>`) in one request; P(yes) of
    `0.5` and above is `yes`, with the reason `"P(yes)=0.88"`. The LLM still
    extracts the opinions and writes the reason, and takes the verdicts when
    the request fails.
  - `:system_one`: one request about `actual_output` (a Noul and a
    four-level Score, higher meaning less bias or toxicity) answers the
    whole metric with no LLM call, and can be batched with the test case's
    other `system_one` metrics.
  - `DeepEvalEx.Prompts.Bias` and `DeepEvalEx.Prompts.Toxicity` render
    deepeval's `generate_opinions`, `generate_verdicts`, `generate_reason`,
    `_experimental_system_one_verdict` and
    `_experimental_system_one_questions` templates byte for byte (ten new
    prompt goldens; Toxicity's opinions and verdicts prompts carry the
    multimodal input rules, as deepeval's do for every test case), and
    `DeepEvalEx.Schemas.MetricOutputs.Bias` and `.Toxicity` hold their
    response schemas.

  New parity fixtures generated by deepeval 4.3.1 cover them: scripted-judge
  scenarios `bias_pass`, `_fail`, `_no_opinions` and `_strict` and the same
  four for `toxicity`, System One scenarios `bias_system_one`, `_hybrid` and
  `_hybrid_fallback` and the same three for `toxicity`, and
  `batch_system_one_safety` (Bias batched with Toxicity). DeepEvalEx matches
  each byte for byte. The metrics have wiki pages and a Safety Metrics
  section in the metrics overview.
- **`DeepEvalEx.Metrics.PIILeakage`**, a port of deepeval 4.3.1's
  `PIILeakageMetric`: how free `actual_output` is of personally
  identifiable information and other privacy-sensitive data. Named
  `"PII Leakage"`, threshold `0.5`, it requires `input` and
  `actual_output`.
  - The judge extracts the statements that could hold PII, then calls each
    a leak (`yes`) or not (`no`), with a reason either way. The score is
    the share of `no` verdicts, higher is better, the integer `1` when
    nothing is extracted (no verdicts are asked for then), and `0` below
    the threshold in strict mode. The reason prompt lists the `yes`
    verdicts' reasons. `metadata.extracted_pii` and `metadata.verdicts`
    hold them, and the verbose logs list them as deepeval's do. As in
    deepeval, it logs no score direction warning.
  - `:hybrid`: the System One model is asked whether each statement holds
    PII, one Noul per statement (`statement_<i>`) in one request; P(yes) of
    `0.5` and above is `yes`. The LLM still extracts the statements and
    writes the reason, and takes the verdicts when the request fails.
  - `:system_one`: one request about `actual_output` (a Noul and a
    four-level Score, higher meaning less leakage) answers the whole metric
    with no LLM call, and can be batched with the test case's other
    `system_one` metrics.
- **`DeepEvalEx.Metrics.PromptAlignment`**, a port of deepeval 4.3.1's
  `PromptAlignmentMetric`: whether `actual_output` follows each of the
  prompt template's instructions, given as `:prompt_instructions`. Named
  `"Prompt Alignment"`, threshold `0.5`, it requires `input` and
  `actual_output`; measuring without instructions, or with none, raises
  `ArgumentError`, as deepeval's constructor raises `ValueError`.
  - The judge calls each instruction followed (`yes`) or not (`no`, with a
    reason). The score is the share of `yes` verdicts, the integer `1` when
    the judge returns none, and `0` below the threshold in strict mode. The
    reason prompt lists the `no` verdicts' reasons (`None` where the judge
    gave none) with the input and output. `metadata.prompt_instructions`
    and `metadata.verdicts` hold them, and the verbose logs list them as
    deepeval's do.
  - `PromptAlignment.new/1` builds the metric as a struct holding its
    instructions, as deepeval's constructor does, so `DeepEvalEx.evaluate/3`
    can run it alongside other metrics.
  - `:hybrid`: the System One model is asked whether the output follows
    each instruction, one Noul per instruction (`instruction_<i>`) in one
    request about `input` and `actual_output`; P(yes) of `0.5` and above is
    `yes`. The LLM writes the reason, and takes the verdicts when the
    request fails.
  - `:system_one`: one request about `input` and `actual_output`, one Noul
    per instruction, answers the whole metric with no LLM call, and can be
    batched with the test case's other `system_one` metrics.
- `DeepEvalEx.Prompts.PIILeakage` and `DeepEvalEx.Prompts.PromptAlignment`
  render deepeval's `extract_pii`, `generate_verdicts`, `generate_reason`,
  `_experimental_system_one_verdict` and `_experimental_system_one_questions`
  templates byte for byte (nine new prompt goldens; every LLM prompt but
  PIILeakage's reason carries the multimodal input rules, as deepeval's do
  for every test case), and `DeepEvalEx.Schemas.MetricOutputs.PIILeakage`
  and `.PromptAlignment` hold their response schemas. The new
  `DeepEvalEx.Prompts.Python.tojson/1` writes a string as Jinja's `tojson`
  filter does, which PromptAlignment's System One questions embed each
  instruction with.

  New parity fixtures generated by deepeval 4.3.1 cover them: scripted-judge
  scenarios `pii_leakage_pass`, `_fail`, `_no_pii` and `_strict` and
  `prompt_alignment_pass`, `_fail`, `_no_verdicts` and `_strict`, System One
  scenarios `pii_leakage_system_one`, `_hybrid` and `_hybrid_fallback` and
  the same three for `prompt_alignment`, and
  `batch_system_one_pii_alignment` (PIILeakage batched with
  PromptAlignment). DeepEvalEx matches each byte for byte. The metrics have
  wiki pages, and the metrics overview an Instruction Metrics section.
- **`DeepEvalEx.Metrics.ArgumentCorrectness`**, a port of deepeval 4.3.1's
  `ArgumentCorrectnessMetric`: whether the input parameters of each of an
  agent's tool calls relevantly and correctly address the input. Named
  `"Argument Correctness"`, threshold `0.5`, it requires `input` and
  `tools_called`, and needs no expected tools.
  - The judge sees each tool call as deepeval's `ToolCall.__repr__` and
    calls its arguments correct (`yes`) or not (`no`, with a reason; a call
    without input parameters is `no`). The score is the share of `yes`
    verdicts, the integer `1` when the judge returns none, and `0` below the
    threshold in strict mode. The reason prompt lists the `no` verdicts'
    reasons (`None` where the judge gave none) with the input.
    `metadata.verdicts` holds them, and the verbose logs list them as
    deepeval's do.
  - A test case with no tool calls (`tools_called: []`) scores the float
    `1.0` with the reason `"No tool calls provided"` and verbose logs
    `"Verdicts:\n[]"`, as deepeval: no judge or System One model is asked,
    whatever the eval mode.
  - `:hybrid`: the System One model is asked about each tool call, one Noul
    per call (`tool_call_<i>`, holding the call's `__repr__`) in one request
    about `input`; P(yes) of `0.5` and above is `yes`. The LLM writes the
    reason, and takes the verdicts when the request fails.
  - `:system_one`: one request about `input` and the structured
    `tools_called` (two Nouls and a four-level Score) answers the whole
    metric with no LLM call, and can be batched with the test case's other
    `system_one` metrics.
- `DeepEvalEx.Prompts.ArgumentCorrectness` renders deepeval's
  `generate_verdicts`, `generate_reason`, `_experimental_system_one_verdict`
  and `_experimental_system_one_questions` templates byte for byte (four new
  prompt goldens; the multimodal input rules are left out, as deepeval does
  for a text-only test case), and
  `DeepEvalEx.Schemas.MetricOutputs.ArgumentCorrectness` holds its response
  schemas.

  New parity fixtures generated by deepeval 4.3.1 cover it: scripted-judge
  scenarios `argument_correctness_pass`, `_fail`, `_no_tool_calls` and
  `_strict`, System One scenarios `argument_correctness_system_one`,
  `_hybrid` and `_hybrid_fallback`, and `batch_system_one_agent`
  (ArgumentCorrectness batched with AnswerRelevancy). DeepEvalEx matches
  each byte for byte. The metric has a wiki page and a row in the metrics
  overview's Agent Metrics.
- **`DeepEvalEx.Metrics.PatternMatch`**, a port of deepeval 4.3.1's
  `PatternMatchMetric`: whether the whole actual output matches a regular
  expression, with no LLM. Named `"Pattern Match"`, threshold the float
  `1.0`, it requires `input` and `actual_output` and takes the `:pattern`
  (required) and `:ignore_case` options.
  - The pattern and the output are trimmed, and the pattern must match all
    of the output, as Python's `re.fullmatch`: it is anchored as
    `\A(?:pattern)\z`, so every alternative is anchored. It is
    Unicode-aware, as Python's `str` patterns (`\w` matches `é`). The score
    is `1.0` or `0.0`, with deepeval's reasons.
  - A missing or invalid pattern raises `ArgumentError`
    (`"Invalid regex pattern: <pattern> — <error>"`), as deepeval's
    constructor raises `ValueError`; a pattern valid only once wrapped in
    the anchoring group (`"a)(b"`) is rejected too.
  - As deepeval's, it has verbose logs only in verbose mode (the pattern,
    the trimmed output and the score to two decimals), and ignores the eval
    mode (`system_one?/0` is `false`).
  - `PatternMatch.new/1` builds a configured metric, so `evaluate/3` can run
    several patterns, or one beside other metrics.
- **`DeepEvalEx.Metrics.ToolPermission`**, a port of deepeval 4.3.1's
  `ToolPermissionMetric`: whether an agent only called the tools a
  permission policy authorizes, with no LLM. Named `"Tool Permission"`,
  threshold the float `1.0`, it requires `tools_called`.
  - `:allowed_tools` is an allowlist (a tool not in it is unauthorized;
    `[]` authorizes nothing) and `:denied_tools` a denylist; a denial
    always wins over an allow. Neither given raises `ArgumentError`, as
    deepeval's constructor raises `ValueError`.
  - The score is the share of authorized calls, the float `1.0` when no
    tools were called (`tools_called: []`), and the integer `0` below the
    threshold in strict mode, whose threshold is the float `1.0` as
    deepeval's. The reason names the unauthorized calls and the sorted
    policy (`Allowed=ANY` without an allowlist), or is `nil` with
    `include_reason: false`; the verbose logs, always written as
    deepeval's, list the policy, the calls and the unauthorized calls.
    `metadata` holds the policy and the unauthorized tool names.
  - It ignores the eval mode (`system_one?/0` is `false`), and
    `ToolPermission.new/1` builds a configured metric for `evaluate/3`.

  New parity fixtures generated by deepeval 4.3.1 cover both: scripted
  scenarios `pattern_match_pass` (trimming, a non-ASCII `\w`), `_fail` (a
  partial match) and `_ignore_case` (with an alternation and verbose mode),
  and `tool_permission_pass`, `_fail` (a denied tool also allowed),
  `_no_tool_calls`, `_denylist_only` (a repeated denied call, a lower
  threshold, no reason) and `_strict`. DeepEvalEx matches each byte for
  byte. The scripted parity harness captures what a metric in verbose mode
  prints. The metrics have wiki pages, and rows in the metrics overview's
  Non-LLM Metrics and Agent Metrics.
- **`DeepEvalEx.Metrics.JsonCorrectness`**, a port of deepeval 4.3.1's
  `JsonCorrectnessMetric`: whether the actual output is JSON matching an
  expected schema. Named `"Json Correctness"`, it requires `input` and
  `actual_output` and takes `:expected_schema` (required).
  - deepeval's schema is a pydantic model; DeepEvalEx takes the model's
    JSON Schema (`model_json_schema()`, what deepeval shows the judge) as
    a JSON string, decoded keeping its key order, a `Jason.OrderedObject`,
    or a map with string or atom keys. A missing schema, or one that is
    not a JSON object, raises `ArgumentError`.
  - The score is the integer `1` for a match, else `0`. The metric is
    strict by default, as deepeval's (`strict_mode: true`, threshold the
    integer `1`); `strict_mode: false` gives the `0.5` default threshold.
  - A match gets deepeval's fixed reason with no judge call; a failure is
    explained by the judge with deepeval's `generate_reason` prompt
    (`DeepEvalEx.Prompts.JsonCorrectness`), which prints the schema as
    `json.dumps(indent=4)`. `include_reason: false` makes no call. The
    verbose logs are deepeval's `"LLM outputed Json:\n<output>"`, and
    `metadata.validation_error` holds the validation error.
  - The score is decided in code in every mode, so, as in deepeval,
    `system_one_eval_spec/2` is `nil` and no System One model is built or
    asked. Under `:system_one` there is no LLM: a failure's reason is the
    validation error, and the result has no evaluation model and a zero
    cost. It counts towards batching a test case's `:system_one` metrics
    but asks nothing in the batch.
  - `JsonCorrectness.new/1` builds a configured metric, so `evaluate/3` can
    run several schemas, or one beside other metrics.
- **`DeepEvalEx.Metrics.Utils.JSONSchema`**, a JSON Schema validator with
  no new dependency, for JsonCorrectness: `type`, `enum`, `const`, object,
  array, string and number keywords, `anyOf`, `oneOf`, `allOf`, `not`,
  boolean schemas and `$ref` within the schema (`#/$defs/...`).
  `validate_json/2` lays errors out as pydantic's `ValidationError`
  (`"2 validation errors for Person\nage\n  Input should be a valid
  integer..."`), pydantic's messages without its `[type=...]` details.
  Validation follows JSON Schema rather than pydantic's lax mode, which
  also accepts numeric strings for numbers and `"yes"` or `1` for booleans.
- **`c:DeepEvalEx.Metrics.BaseMetric.system_one_model?/0`**, an optional
  callback for a metric that follows its eval mode but never builds a
  System One model (JsonCorrectness): its
  `DeepEvalEx.SystemOne.Context` has no model in any mode, so no TypeSafe
  key is needed, and under `:system_one` it reports no evaluation model.
- **Parity fixtures for JsonCorrectness**, written by deepeval 4.3.1:
  scripted-judge scenarios `json_correctness_pass` (an empty list, an
  omitted optional field and an undeclared key), `_fail` (valid JSON
  failing a nested `$defs` model), `_invalid_json` and `_not_strict`
  (`strict_mode: false`, `include_reason: false`, verbose mode); the
  `json_correctness_generate_reason` prompt golden; and the System One
  fixtures `json_correctness_system_one`, `json_correctness_hybrid` and
  `batch_system_one_json` (Bias batched alone while JsonCorrectness counts
  as a candidate). The scripted generator rebuilds each script's pydantic
  model from its JSON Schema and checks that the model's own schema is the
  same, key order included. DeepEvalEx matches every facet byte for byte.
  The metric has a wiki page and rows in the README and metrics overview.
- **`DeepEvalEx.Metrics.Summarization`**, a port of deepeval 4.3.1's
  `SummarizationMetric`: how good a summary (`actual_output`) of an
  original text (`input`) is. Named `"Summarization"`, threshold `0.5`, it
  requires `input` and `actual_output`.
  - Alignment: the judge extracts the original's truths and the summary's
    claims (with the Faithfulness prompts, as deepeval borrows them) and
    calls each claim `yes`, `no` (a contradiction) or `borderline` (extra
    information). The alignment score is the share of `yes` verdicts, so
    unlike Faithfulness a borderline claim fails; the integer `0` when the
    summary has no claims.
  - Coverage: the judge writes `:n` (default `5`) closed-ended questions
    the original answers "yes", or takes `:assessment_questions` (an empty
    list counts as none, as in deepeval), then answers each from the
    original and from the summary. The coverage score is the share of the
    questions the original answers "yes" that the summary also answers
    "yes" (answers trimmed and lower-cased), the integer `0` when the
    original answers none. Answer lists of different lengths fail the
    metric with deepeval's "Number of verdicts generated does not equal."
  - The score is the lower of the two (the alignment score on a tie, as
    Python's `min`), and `result.score_breakdown` holds both,
    `%{"Alignment" => ..., "Coverage" => ...}`; strict mode clamps each.
    The reason prompt lists the contradictions and extra claims (`None`
    where the judge gave no reason), then the questions the summary cannot
    answer, laid out as deepeval appends them. `:truths_extraction_limit`
    caps the truths (a negative limit is `0`). The metadata and verbose
    logs hold the truths, claims, questions and both kinds of verdicts.
  - `Summarization.new/1` builds a configured metric, so `evaluate/3` can
    run it beside other metrics without its options reaching them.
  - `:hybrid`: the System One model judges each claim against the truths,
    one Noul per claim (`summary_claim_<i>`) in one request; P(yes) above
    `0.65` is `yes`, below `0.35` `no`, else `borderline`. The LLM still
    extracts, scores coverage and writes the reason, and takes the
    alignment verdicts when the request fails.
  - `:system_one`: one request about `input` and `actual_output` (two
    Nouls and a four-level Score, then one Noul per given assessment
    question) answers the whole metric with no LLM call, and can be batched
    with the test case's other `system_one` metrics.
- `DeepEvalEx.Prompts.Summarization` renders deepeval's
  `generate_questions`, `generate_answers`, `generate_alignment_verdicts`,
  `generate_reason`, `_experimental_system_one_verdict` and
  `_experimental_system_one_questions` templates byte for byte (eight new
  prompt goldens), and `DeepEvalEx.Schemas.MetricOutputs.Summarization`
  holds their response schemas. New parity fixtures generated by deepeval
  4.3.1 cover the metric: scripted-judge scenarios `summarization_pass`,
  `_fail`, `_no_claims` and `_strict`, System One scenarios
  `summarization_system_one`, `_hybrid` and `_hybrid_fallback`, and
  `batch_system_one_summarization` (batched with AnswerRelevancy).
  DeepEvalEx matches each byte for byte. The metric has a wiki page, and
  the metrics overview a Summarization Metrics section.
- **Per-metric prompt overrides, deepeval's `evaluation_template`**, a port
  of 4.3.1's `PromptMixin._get_prompt` and generated template classes.
  Every LLM-judged metric (AnswerRelevancy, ArgumentCorrectness, Bias,
  ContextualPrecision, ContextualRecall, ContextualRelevancy, Faithfulness,
  GEval, Hallucination, JsonCorrectness, PIILeakage, PromptAlignment,
  Summarization, ToolCorrectness and Toxicity) takes an
  `:evaluation_template` module, also a field of the structs `GEval.new/1`,
  `JsonCorrectness.new/1`, `PromptAlignment.new/1` and
  `Summarization.new/1` build.
  - Each `DeepEvalEx.Prompts.<Metric>` module is now a behaviour whose
    optional callbacks are its templates, including the System One ones
    (deepeval's `_experimental_system_one_*`, here `system_one_verdict/0`,
    `system_one_questions` and `system_one_tool_selection_score/0`). An
    override defines only the templates it changes; every other template
    falls back to the default one at a time, as deepeval falls back when
    the class has no such method. Formatting helpers such as
    `GEval.format_params/1` are not templates.
  - `DeepEvalEx.Prompts.EvaluationTemplate.render/3,4` picks the override's
    template or the default, and raises `ArgumentError` when the option is
    not a loadable module.
  - Templates a metric borrows from another are never overridden, as
    deepeval's explicit `template_class` bypasses the override:
    Summarization always extracts claims and truths with the Faithfulness
    prompts.
  - The metrics overview has a Custom Prompts section.
- **`RetrievedContextData` in `retrieval_context`**, a port of deepeval
  4.3.1's `RetrievedContextData`: `DeepEvalEx.Schemas.RetrievedContextData`
  is a retrieved chunk with its `:context` and `:source`, and a test case's
  `:retrieval_context` may mix them with strings. `TestCase.new/1` also
  builds one from a map with `context` and `source` keys and rejects any
  other item; `:context` stays strings only. Each place treats one as
  deepeval does:
  - the test run export and `DeepEvalEx.TestResult` keep only its
    `:context`, so `retrievalContext` stays a list of strings
  - ContextualPrecision groups the chunks of one source into a single
    `"Source: <source>"` document at the source's first position
    (`ContextualPrecision.group_retrieval_contexts/1`), and judges and ranks
    those documents
  - ContextualRecall's verdicts prompt and GEval's test case content print
    it as its pydantic repr, `RetrievedContextData(context='...',
    source='...')` (`DeepEvalEx.Prompts.Python.repr/1`), and ContextualRecall
    sends it to System One under `:hybrid` as pydantic's `str()`
    (the new `DeepEvalEx.Prompts.Python.str/1`)
  - a System One state of the whole test case sends it as its serialised
    `"source: context"`, its `to_string/1`
  - deepeval 4.3.1's Faithfulness and ContextualRelevancy raise a
    `TypeError` on one; DeepEvalEx renders it as `"source: context"` there
    instead
  - JevEval's multimodal check reads its `:context`
  - three scripted-judge parity scenarios written by deepeval
    (`contextual_precision_`, `contextual_recall_` and
    `g_eval_retrieved_context_data`) check the prompts, results and exports
    byte for byte
- **`DeepEvalEx.Dataset.Golden`, single-turn goldens**, a port of deepeval
  4.3.1's `Golden` (`dataset/golden.py`): the input of a test case and what
  it should produce, with `:source_file`, `:custom_column_key_values`,
  `:expectations` and `:expected_labels`. The modules are grouped under
  Datasets in the docs.
  - `Golden.new/1` and `new!/1` accept the keys deepeval's `Golden`
    validates: the field names and the camelCase aliases `tokenCost`,
    `inputTokenCount`, `outputTokenCount` and `expectedLabels`, which win
    over the field name. Like deepeval, they drop `actualOutput` and the
    other serialisation-only camelCase names, and any unknown key.
  - `Golden.to_test_case/1` and `from_test_case/1`, with the list forms
    `convert_goldens_to_test_cases/1` and `convert_test_cases_to_goldens/1`,
    carry the fields deepeval's conversions carry: `:additional_metadata`
    becomes `:metadata` and back; a test case does not get the golden's
    `:source_file` or `:custom_column_key_values`, and a golden does not
    get the test case's `:name`, `:comments`, `:tags`, `:completion_time`,
    `:flaky`, `:expected_labels` or `:custom_column_key_values`.
  - `DeepEvalEx.Dataset.Expectations.cast/1` validates expectations as
    deepeval's `Expectations` model and returns them as a plain map of
    `:model`, `:eval_mode` (`:llm` or `:system_one`), `:must` and
    `:must_not`, conditions stripped (`mustNot` is accepted; blank
    conditions and unknown keys are errors). No metric judges them yet.
  - `DeepEvalEx.TestCase` gains `:expectations`, as deepeval's
    `LLMTestCase`, so they survive the conversions. Like deepeval, the test
    run export leaves them out.
- **`DeepEvalEx.Dataset.EvaluationDataset`, an immutable port of deepeval
  4.3.1's `EvaluationDataset`** core (`dataset/dataset.py`), with a Datasets
  guide.
  - `new/2` (goldens, plus the dataset's `:alias`, `:id` and `:version`),
    `add_golden/2`, `put_goldens/2`, `add_test_case/2` and
    `put_test_cases/2` return a new dataset. Anything but a
    `DeepEvalEx.Dataset.Golden` raises `ArgumentError`, as deepeval raises
    `TypeError`; like deepeval's `test_cases` setter, `put_test_cases/2`
    skips items that are not `DeepEvalEx.TestCase`s. Datasets are
    single-turn until conversational goldens and test cases are ported.
  - A dataset implements `Enumerable` over its goldens.
  - `DeepEvalEx.TestCase` gains `:dataset_rank`, deepeval's private
    `_dataset_rank`: a dataset sets it to each test case's position, and so
    does `Golden.convert_goldens_to_test_cases/1`, as deepeval's does.
    `new/1` never sets it.
- **Dataset loaders: goldens and test cases from CSV, JSON and JSONL
  files**, ports of deepeval 4.3.1's `add_goldens_from_csv_file`,
  `add_goldens_from_json_file`, `add_goldens_from_jsonl_file`,
  `add_test_cases_from_csv_file` and `add_test_cases_from_json_file` on
  `DeepEvalEx.Dataset.EvaluationDataset`. Each returns the dataset with the
  loaded goldens or test cases appended (test cases ranked as
  `add_test_case/2` ranks them).
  - Options take deepeval's argument names and defaults (column and key
    names, `"|"` context delimiters, `";"` tool delimiters); a `nil` name
    leaves the field unset. Tool calls, metadata, custom columns and
    expectations are read from JSON cells, trailing commas tolerated;
    retrieval context markers become `RetrievedContextData`.
  - CSV files are read as pandas reads them for deepeval: its missing-value
    markers (`NA`, `null`, `None`, an empty cell, ...) are `nil`, a present
    but empty context or tool column is `[]` while an absent one is `nil`,
    and the token columns are numbers.
  - Files written by deepeval's `save_as`, and files of other shapes, load
    as deepeval loads them, checked against fixtures generated by deepeval
    (`scripts/parity/generate_dataset_fixtures.py`, under
    `test/fixtures/deepeval/datasets/`), including deepeval's
    quirks: `add_test_cases_from_json_file` ignores metadata and defaults
    tool calls to `[]`.
  - Errors raise: `File.Error` for a missing file, `ArgumentError` where
    deepeval raises `ValueError`, `TypeError` or a validation error, with
    deepeval's message for its own `ValueError`s. A golden with a scenario
    raises, as conversational goldens are not supported yet.
  - Differences: a text cell of digits stays a string (pandas makes it a
    number, which deepeval's `Golden` then rejects); metadata cells must be
    JSON, where deepeval also reads Python literals (and, for test cases,
    only Python literals, so it cannot read `true`, `false` or `null`); the
    `encoding_type` option and the multi-turn column options other than
    `scenario` are not ported.
  - `DeepEvalEx.Dataset.Utils`, deepeval's `dataset/utils.py`:
    `delimiter/0`, `tools_delimiter/0`, `serialize_retrieval_context/1`,
    `join_retrieval_context/2`, `join_context/2`,
    `reconstruct_retrieval_context/1` and `trim_and_load_json/1`.
  - New dependency: `nimble_csv`, for RFC 4180 CSV parsing (quoted cells
    with commas, quotes and newlines), rather than an in-house parser.
- **`EvaluationDataset.save_as/4`: save datasets as CSV, JSON or JSONL**, a
  port of deepeval 4.3.1's `save_as`. It writes the goldens, and with
  `include_test_cases: true` the test cases converted to goldens, to
  `<directory>/<file_name>.<type>`, creating the directory, and returns the
  path; without `:file_name` the file is named after the local time
  (`20261022_142501.json`). The file type is `:csv`, `:json` or `:jsonl`
  (or deepeval's strings).
  - deepeval's keys, column order and cell formats: JSON indented by four
    spaces, JSONL with joined context strings, CSV quoted as Python's `csv`
    module with CRLF rows, tool calls and expectations dumped as pydantic
    dumps them, floats as Python writes them, non-ASCII kept. Checked byte
    for byte against files written by deepeval (a new `save_as_edges`
    case in `scripts/parity/generate_dataset_fixtures.py`), and deepeval's
    loaders load DeepEvalEx's files as they load deepeval's own.
  - As deepeval, a golden's token cost and counts are not written (a test
    case's are); expected labels are not written.
  - An unknown file type, or nothing to write, raises `ArgumentError` with
    deepeval's `ValueError` message.
  - Difference: map keys (metadata, custom columns, tool call parameters)
    are written in Elixir map order, sorted for up to 32 keys, rather than
    insertion order; the files decode and load the same.
- **`EvaluationDataset.evaluate/4` and `evaluate_run/4`: evaluate a task
  over a dataset's goldens**, the Elixir equivalent of deepeval 4.3.1's
  `evals_iterator`, without its tracing (which comes later). The task is
  called with each golden through `Task.async_stream`, up to
  `:max_concurrent` at once (one at a time with `run_async: false`), and
  returns the actual output, a map or keyword list of test case fields, or a
  `DeepEvalEx.TestCase`. Each golden's test case is ranked by the golden's
  position (`test_case_<position>` unless named) and evaluated as
  `DeepEvalEx.evaluate_run/3` evaluates it, taking its options; the run
  records the dataset's alias, id and version as `datasetAlias`,
  `datasetId` and `datasetVersion`. `evaluate/4` returns
  `{:ok, %DeepEvalEx.EvaluationResult{}}`, `evaluate_run/4` the test cases,
  results, test run and path.
  - A dataset without goldens raises `ArgumentError` with deepeval's
    message; concurrency options, thresholds and hyperparameters are
    validated before the task runs.
  - When the task raises for a golden, the first such golden's error is
    raised again and nothing is evaluated.
- **`DeepEvalEx.evaluate_run/3` takes `:dataset_alias`, `:dataset_id` and
  `:dataset_version`**, written to the test run as `datasetAlias`,
  `datasetId` and `datasetVersion` (deepeval takes them from its test
  cases); like the other export options, they are not passed to metrics.
- **Multi-turn test cases: `DeepEvalEx.ConversationalTestCase` and
  `DeepEvalEx.Turn`**, ports of deepeval 4.3.1's `ConversationalTestCase`
  and `Turn`. No metric evaluates them yet.
  - `DeepEvalEx.Turn.new/1` builds a turn: a `:user` or `:assistant` role
    (atom or string), its content, and the optional `:user_id`,
    `:retrieval_context` (strings or `RetrievedContextData`),
    `:tools_called` and `:metadata`. The voice fields `:audio` (deepeval's
    `Audio`, as a plain map), `:latency_ms` (an integer is cast to a float),
    `:interrupted` and `:provider_transcript` are kept as plain data.
    `model_dump_for_prompt/1` returns deepeval's `model_dump_for_prompt()`
    as a `Jason.OrderedObject`: every field in deepeval's order (the
    unported MCP fields as `nil`), without `audio` and
    `provider_transcript`.
  - `DeepEvalEx.ConversationalTestCase.new/1` takes the turns (`Turn`s, or
    maps that build them) with `:scenario`, `:context`, `:name`,
    `:user_description`, `:expected_outcome`, `:chatbot_role`, `:metadata`,
    `:comments`, `:tags`, `:flaky`, `:expectations`, `:expected_labels`,
    `:call_recording_path`, `:multimodal` and `:voice`. It rejects empty
    turns and invalid turns with deepeval's messages, and sets `:voice`
    when a turn has audio and `:multimodal` when a `[DEEPEVAL:IMAGE:...]`
    or `[DEEPEVAL:PDF:...]` placeholder appears where deepeval looks for
    one.
  - Both accept deepeval's camelCase aliases (`userId`, `latencyMs`,
    `providerTranscript`, `userDescription`, `expectedOutcome`,
    `chatbotRole`, ...) and `additionalMetadata`, and drop unknown keys.
- **`DeepEvalEx.Params.MultiTurn`**, deepeval's `MultiTurnParams`: `all/0`
  lists its sixteen members in deepeval's order, `member?/1` checks one,
  and `display_name/1` gives deepeval's conversational G-Eval name for it
  (`CONVERSATIONAL_G_EVAL_PARAMS`).
- **`DeepEvalEx.Metrics.Utils.Turns`**, deepeval 4.3.1's
  `metrics/utils/turns.py`, the turn helpers the conversational metrics
  share:
  - `convert_turn_to_dict/2` returns a turn's given multi-turn params
    (by default `[:content, :role]`) as a `Jason.OrderedObject` in the
    params' order, skipping the case-level params and `nil` fields;
  - `format_turns/2` returns each `DeepEvalEx.TestCase`'s given
    single-turn params, keeping only Python-truthy values;
  - `get_turns_in_sliding_window/2` returns the window of at most
    `window_size` turns ending at each turn (a list, where deepeval yields
    them);
  - `get_unit_interactions/1` splits a conversation into user/assistant
    exchanges, dropping a trailing run without a user turn or an assistant
    reply, as deepeval.

  Both dict helpers raise `ArgumentError` for a param of the wrong kind.
- **`DeepEvalEx.Metrics.BaseConversationalMetric`**, deepeval 4.3.1's
  `BaseConversationalMetric`, the behaviour conversational metrics
  implement. No built-in metric uses it yet.
  - `use` gives a conversational metric `BaseMetric`'s `measure/2`
    wrapper (strict mode, score-only thresholds, flakiness, telemetry,
    usage tracking and cost seeding) and the same System One hooks: the
    `:eval_mode` and `:system_one_model` options, the optional
    `system_one_eval_spec/2`, `system_one?/0` and `system_one_model?/0`
    callbacks, and the measure's confidence and fallback reason on the
    result.
  - The `use` option `requires_chatbot_role: true` sets
    `requires_chatbot_role?/0`, deepeval's `_requires_chatbot_role`.
  - Its `validate_test_case/1` checks `required_params/0` (multi-turn
    params) with the new
    **`DeepEvalEx.ConversationalTestCase.validate_params/3`**, deepeval's
    `check_conversational_test_case_params`: in deepeval's order, a
    required `:expected_outcome`, `:scenario`, `:metadata` or `:tags` that
    is `nil`, a missing `:chatbot_role` when required, empty turns, and a
    required `:provider_transcript` or `:audio` that no turn has. A test
    case that is not conversational returns
    `{:error, :not_conversational_test_case}`.
  - `DeepEvalEx.Result.error/3` renders these errors with deepeval's
    messages (e.g. `"'scenario' in a conversational test case cannot be
    empty for the 'Role Adherence' metric."`), and `DeepEvalEx.Evaluator`
    treats all but the last as missing params: raised as
    `DeepEvalEx.MissingTestCaseParamsError`, or skipped with
    `skip_on_missing_params`.
- **`DeepEvalEx.Evaluator.check_valid_test_cases_type!/1`**, deepeval's
  `check_valid_test_cases_type`: raises `ArgumentError` with deepeval's
  message when a list mixes `DeepEvalEx.TestCase`s and conversational test
  cases.
- **Conversational test cases in the test run export**, deepeval 4.3.1's
  `ConversationalApiTestCase` and `TurnApi` with `create_api_test_case` and
  `create_api_turn`, as `DeepEvalEx.TestRun.ConversationalTestCase` and
  `DeepEvalEx.TestRun.Turn`.
  - `DeepEvalEx.TestRun.from_results/3` and `DeepEvalEx.evaluate_run/3`
    take `DeepEvalEx.ConversationalTestCase`s and export them as
    `conversationalTestCases`, in deepeval's key order. An unnamed one is
    named `conversational_test_case_<order>`. The order is its dataset
    rank, else its position among the conversational test cases, as
    deepeval counts the two kinds apart. They are sorted and renumbered as
    `testCases` are.
  - Each turn is exported with its role, content and position. Its
    retrieval context is flattened to strings (`RetrievedContextData`
    becomes its context) and left out when empty, and its tool calls are
    exported as a test case's. A turn's `user_id` is never exported, as in
    deepeval: `create_api_turn` passes it by field name, which `TurnApi`
    ignores.
  - A conversational test case's `runDuration` is a float even when its
    metrics are instantaneous, as deepeval adds their time to `0.0`. It
    succeeds unless a non-flaky metric failed, and its cost is the sum of
    its metrics' costs. Its metric data follows the single-turn test cases'
    in `metricsScores`, and its success counts towards `testPassed` and
    `testFailed`.
  - `evaluate_run/3` writes a run that has only conversational test cases,
    as deepeval does.
  - `TestRun.load/1` and `from_map/1` read `conversationalTestCases` into
    these structs, keeping `expectationsData`, `imagesMapping` and unknown
    keys as raw JSON. A missing `order` defaults to the test case's
    position, and a turn's to its position in `turns`. deepeval's files
    round-trip byte for byte.
  - `to_results/1` returns the conversational test cases after the
    single-turn ones, as `DeepEvalEx.ConversationalTestCase`s with their
    results.
  - A new `conversational` parity scenario checks the export byte for byte
    against deepeval's file.
- **`DeepEvalEx.Metrics.ConversationalGEval`**, deepeval 4.3.1's
  `ConversationalGEval`: an LLM judges a whole
  `DeepEvalEx.ConversationalTestCase` against custom criteria or evaluation
  steps, with an optional `DeepEvalEx.Metrics.GEval.Rubric`. Results are
  named `"<name> [Conversational GEval]"`. It is LLM-only, as deepeval's:
  under `:hybrid` and `:system_one` it still calls its LLM.
  - `:content` and `:role` are appended to `:evaluation_params` when
    missing. Per-turn params (`:content`, `:role`, `:retrieval_context`,
    `:tools_called`) are printed for each turn; conversation-level ones
    (`:scenario`, `:expected_outcome`, `:metadata`, `:tags`) once, and must
    be set on the test case. `:audio`, and params deepeval cannot name in
    its prompt (`:context`, `:user_description`, `:chatbot_role`, ...),
    raise `ArgumentError` in `new/1`.
  - The judge scores from 0 to 10 and the score is divided by 10, a
    fractional score kept; strict mode clamps a score below 1 to `0`.
  - A judge with logprobs gets GEval's weighted score, with deepeval's
    conversational differences: the first token equal to the score is
    weighted, and a weighting left with no token errors the metric with
    `"float division by zero"`
    (`ConversationalGEval.calculate_weighted_summed_score/2`).
  - Its prompts are `DeepEvalEx.Prompts.ConversationalGEval`
    (`generate_evaluation_steps/1`, `generate_evaluation_results/1`),
    overridable with `:evaluation_template`.
  - New prompt goldens and scripted-judge scenarios check its prompts,
    scores, verbose logs and exported test run byte for byte against
    deepeval's, including the `conversationalTestCases` block.
- **Metric copies, as deepeval's asynchronous `evaluate()` makes them.**
  deepeval measures copies of its metrics rebuilt from their attributes,
  and a `ConversationalGEval` copy reports its evaluation model as
  `"<judge> (audio: <judge>)"`. Conversational metrics may implement the new
  optional `copy_metric/1` and `describe_evaluation_model/2` callbacks of
  `DeepEvalEx.Metrics.BaseConversationalMetric`; `DeepEvalEx.Evaluator`
  measures `copy_metric(metric)` unless `run_async: false`, and a result
  reports the evaluation model `describe_evaluation_model/2` gives.
- **`DeepEvalEx.Metrics.TurnRelevancy`**, deepeval 4.3.1's
  `TurnRelevancyMetric`: for each unit interaction of a
  `DeepEvalEx.ConversationalTestCase`, the judge decides whether the last
  assistant turn of a sliding window of at most `:window_size` (default 10)
  unit interactions is relevant to the turns before it; the score is the
  share of relevant windows, `1` when there are none. Results are named
  `"Turn Relevancy"`. Its prompts are `DeepEvalEx.Prompts.TurnRelevancy`,
  which, as deepeval's, always print the multimodal input rules and the
  score unformatted.
- **`DeepEvalEx.Metrics.ConversationCompleteness`**, deepeval 4.3.1's
  `ConversationCompletenessMetric`: the judge extracts the user's
  intentions, then decides for each whether the conversation satisfies it;
  the score is the share satisfied, `1` when there are none. Results are
  named `"Conversation Completeness"`. As in deepeval, `:window_size`
  (default 3) is taken but unused. Its prompts are
  `DeepEvalEx.Prompts.ConversationCompleteness`, which print deepeval's
  multimodal input rules for a multimodal test case.
- **System One for conversational metrics** (ADR-0009). Both new metrics
  run under every eval mode, as deepeval's:
  - `:hybrid` asks one `DeepEvalEx.SystemOne.Spec.Binary` Noul per sliding
    window (its `turns`) or per user intention (the `turns` and the
    `intention`) through the new `DeepEvalEx.SystemOne.Decision.verdict/3`,
    deepeval's `generate_qag_verdict`: P(yes) of `0.5` and above is `yes`,
    with the reason `"P(yes)=0.91"`; a failed request falls back to the LLM
    for that decision.
  - `:system_one` answers the whole metric from one request about the
    turns (two Nouls and a four-level Score each). `DeepEvalEx.SystemOne.Runner`
    and `DeepEvalEx.SystemOne.State.build/2` now take a
    `DeepEvalEx.ConversationalTestCase`, whose state is built by the new
    `State.multi_turn/2`, deepeval's `construct_multi_turn_state`
    (`{"turns": [...], "test_case": {...}}`).
  - `DeepEvalEx.SystemOne.Batch.prefetch/3` now batches the `:system_one`
    conversational metrics of a conversational test case into one request,
    their turns merged, as deepeval does; single-turn metrics are never
    batched on a conversational test case, nor conversational metrics on a
    single-turn one, and a multimodal conversation is not batched.
  - A multimodal conversation has no System One form: both metrics judge it
    with the LLM.
- `DeepEvalEx.Metrics.QAG.verdict_from_json/2`, deepeval's
  `verdict_from_json`, parses a single verdict, `nil` when it is outside the
  vocabulary; `DeepEvalEx.Turn.model_dump/1` dumps every field of a turn, as
  deepeval's `model_dump()`; and `DeepEvalEx.Prompts.Python.repr/1` prints
  a `DeepEvalEx.Turn` as deepeval's `Turn.__repr__`. The metrics' verbose
  logs use them, matching deepeval's.
- New prompt goldens for every template of both metrics (their System One
  templates included), eight scripted-judge scenarios and eight System One
  scenarios (`system_one`, strict, `hybrid`, `hybrid` fallback and a batched
  pair) check their prompts, decisions, scores, verbose logs and exported
  `conversationalTestCases` byte for byte against deepeval's.

### Changed

- A test case's `:dataset_rank`, when set, is its `order` and default
  `"test_case_<order>"` name in `DeepEvalEx.TestRun.from_results/3` and its
  `:index` and name in `DeepEvalEx.TestResult.new/4`, in place of its
  position in the evaluated list, as deepeval's `create_api_test_case`.
  The test run's `testCases` are sorted by order, and duplicate orders
  (test cases ranked by different datasets) renumbered from 0 with their
  names kept, as deepeval's `sort_test_cases`. Test cases without a rank
  are unaffected.
- `c:DeepEvalEx.Metrics.BaseMetric.default_opts/0`, until now unused, is
  applied: `measure/2` and `DeepEvalEx.Evaluator` merge a metric's default
  options under the options given (the run's, then a metric struct's
  fields). JsonCorrectness uses it for deepeval's `strict_mode=True`
  default, so the strict mode is exported and errored results carry the
  strict threshold whether the metric is passed as a module or a struct.

- **BREAKING:** `DeepEvalEx.TestCase`'s `:tools_called` and
  `:expected_tools` default to `nil`, deepeval's `None`, instead of `[]`, so
  a test case that does not set them is told apart from one that called no
  tools. A metric requiring them (ToolCorrectness, ArgumentCorrectness, a
  GEval or JevEval naming them) now reports them missing, as deepeval
  raises for `None`, instead of measuring an empty list; ArgumentCorrectness
  would otherwise score a test case without tool calls as `1.0`. The test
  run export keeps an explicitly empty list (`"toolsCalled": []`), as
  deepeval's `exclude_none` does, and leaves out unset ones as before.
  `DeepEvalEx.TestRun.to_results/1` keeps them as they were too: an unset
  list comes back `nil` and an empty one `[]`, so a loaded run without
  `toolsCalled` is still reported missing them and re-exports without the
  key. Code reading the fields must now handle `nil`.
- `TYPESAFE_COST_PER_INPUT_TOKEN` (and `config :deep_eval_ex,
  typesafe_cost_per_input_token:`) accepts `0`, a free Jev, as deepeval's
  `TypeSafeModel` does; only a negative price is rejected.
- **BREAKING:** a custom LLM judge's cost is no longer reported, as in
  deepeval, which seeds a metric's cost with `None` unless its model is native,
  so a custom judge's metric has no `evaluationCost` whatever its calls
  report. DeepEvalEx now does the same: a judge adapter whose
  `c:DeepEvalEx.LLM.Adapter.native?/0` is `false` (the default, the Mock
  adapter included) gives results a `nil` `:evaluation_cost`, though their
  token counts are still reported. A custom adapter that prices its calls
  returns `true` from `native?/0` to keep its cost. A metric with a native
  judge that makes no call now reports a cost of `0.0` and token counts of
  `0` instead of `nil`, as deepeval's.
- **BREAKING:** a test case loaded without `success` keeps `success: nil`,
  as deepeval's `LLMApiTestCase` leaves it `None`, instead of having it
  computed from its metric data; it is not written back, and when the file
  has no `testPassed` / `testFailed` it counts as neither, as deepeval's
  `calculate_test_passes_and_fails` does (conversational test cases'
  `success` is counted too). `DeepEvalEx.TestRun.TestCase`'s `:success` is
  now `boolean() | nil`.
- `DeepEvalEx.TestRun`'s `:prompts` defaults to `nil`, so a hand-built
  `%TestRun{}` exports no `prompts` key, as deepeval's `TestRun()` does;
  `from_results/3` (and so `evaluate_run/3`) still writes `"prompts": []`.
  `conversationalTestCases` and `official` are written from the struct
  instead of always as `[]` and `false`.
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
- **BREAKING: `assert_passes` and `assert_evaluation` are deepeval's
  `assert_test`, failure message included.** They now evaluate the test case
  through `DeepEvalEx.Evaluator.evaluate/3`, so a test case's metrics run
  concurrently (they used to run one after another), under the Evaluator's
  `:timeout` and `:metric_timeout` (they had none) and its `ErrorConfig`, with
  `assert_test`'s `max_concurrent: 100` and `throttle_value: 0` unless given;
  every Evaluator option (`:run_async`, ...) is accepted. A failure flunks with
  deepeval 4.3.1's message instead of the "Metric evaluation failed
  unexpectedly" / "Multiple metric evaluations failed" blocks:
  `"Metrics: <name> (score: <score>, threshold: <threshold>, strict: <strict>,
  error: <error>, reason: <reason>), ... failed."`, listing every errored or
  unsuccessful metric (flaky and score-only ones too) in metric order, each
  field as Python's `str()` (`None`, `True`/`False`, scores and thresholds as
  Python floats, so strict mode's threshold prints `1.0`), with `score: None`
  and `reason: None` for an errored metric. The test case fails as
  `DeepEvalEx.TestResult` does: a failing flaky metric alone no longer fails
  `assert_evaluation`, and a failing test case marked `flaky: true` no longer
  flunks but prints `"Flaky test case failed (no assertion raised): <message>"`
  with `IO.warn/1`, as `assert_test` warns, and returns the results.
  `assert_passes` on a score-only metric, or on a flaky one, now raises
  `ArgumentError` with deepeval's "at least one non-flaky metric with a
  'threshold'" message, as `assert_test` does, instead of flunking.
  `assert_evaluation(test_case, [])` raises `ArgumentError` with the message
  of `assert_test`'s `ValueError` for a test case with no metrics and no
  expectations, `"1 test case is missing expectations. Fill in non-empty
  expectations for these test cases and/or provide at least one metric and/or
  classifier."`, instead of the threshold message.
  `assert_fails` and `assert_score` keep their messages and also evaluate
  through `DeepEvalEx.Evaluator.evaluate/3`, so the timeouts apply to them too.
- **BREAKING: `DeepEvalEx.ExUnit` assertions raise metric errors unless
  `IGNORE_DEEPEVAL_ERRORS` is set**, as deepeval's `assert_test` reads its
  `ErrorConfig` from the `:ignore_errors` and `:skip_on_missing_params`
  settings (`config :deep_eval_ex` or `IGNORE_DEEPEVAL_ERRORS` and
  `SKIP_DEEPEVAL_MISSING_PARAMS`, see `DeepEvalEx.Config`); an
  `ignore_errors:` or `skip_on_missing_params:` option wins over both. With
  `:ignore_errors` an errored metric flunks the assertion (see the
  `assert_test` entry above for `assert_passes` and `assert_evaluation`'s
  message; `assert_fails` and `assert_score` still report `"metric errored:
  ..."`). A skipped metric passes `assert_passes` and `assert_evaluation`,
  which return its skipped result, and flunks `assert_fails` and
  `assert_score`, which have no score to check.

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
- **BREAKING:** `get_retrieval_context/1` (on `DeepEvalEx.TestCase`), which fell
  back to `:context`. Read `test_case.retrieval_context` instead.

### Fixed

- `DeepEvalEx.Prompts.Python.format_fixed/2` printed `-0.0` without its
  sign (`"0.00"`); it now prints `"-0.00"`, as Python's `format(-0.0, ".2f")`
  does.
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
