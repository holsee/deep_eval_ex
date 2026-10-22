# deepeval golden fixtures

Fixtures written by **deepeval 4.3.1**, in four sets:

- export scenarios (the directories below, except `scripted/`, `prompts/`
  and `system_one/`), used by
  `test/deep_eval_ex/parity_test.exs` to check that DeepEvalEx writes the same
  `test_run_<timestamp>.json` files as deepeval, down to the bytes
- [scripted-judge scenarios](#scripted-judge-scenarios) (`scripted/`), used by
  `test/deep_eval_ex/scripted_parity_test.exs` to check that DeepEvalEx's eight
  metrics send the same prompts, measure the same results and export the same
  test run as deepeval's for the same judge responses
- [prompt goldens](#prompt-goldens) (`prompts/`), used by
  `test/deep_eval_ex/prompt_golden_test.exs` to check that each
  `DeepEvalEx.Prompts` function renders the same prompt as the deepeval
  template it stands for, for the same inputs
- [System One fixtures](#system-one-fixtures) (`system_one/`), recording what
  deepeval asks System One (TypeSafe AI's Jev) and does with its answers under
  the `system_one` and `hybrid` eval modes, for the eval-mode units (P3, P4).
  `test/deep_eval_ex/system_one_fixtures_test.exs` only checks their
  structure for now

## Export scenarios

Each directory is one scenario:

| Scenario          | What it covers                                                                                 |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `exact_match`     | `ExactMatchMetric` passing and failing over 3 test cases, one with name, tags, metadata, comments |
| `llm_metric`      | Two stub metrics emulating LLM judges: reason, evaluation model, cost and token counts         |
| `metric_error`    | A metric that raises, with `ignore_errors=True`: `error` set, no `score`, counted in `errors`  |
| `rag_and_tools`   | `retrieval_context`, `context`, `tools_called` / `expected_tools`, `token_cost`, `completion_time` |
| `ignore_errors_false` | A metric that raises, with deepeval's default `ignore_errors=False`: `evaluate()` re-raises its exception and writes no test run |
| `missing_params_ignore_errors_false` | A test case missing a param, with `ignore_errors=False`: `evaluate()` raises `MissingTestCaseParamsError` and writes no test run |
| `skip_on_missing_params` | `skip_on_missing_params=True`: metrics missing params are left out of `metricsData` and `metricsScores`, and test cases left with no metric out of the run, the others keeping their `order` |
| `missing_params`  | `MissingTestCaseParamsError` messages from ExactMatch, Faithfulness and GEval: `context` not standing in for `retrieval_context` (and a context-only test case exporting no `retrievalContext`), an empty `actual_output`, and two and three missing params |
| `hyperparameters` | `identifier` and `hyperparameters` (string, float, int, bool and dropped `None` values)        |

and holds:

- `input.json` - the scenario's inputs: `test_cases` (keyword arguments of
  deepeval's `LLMTestCase`), `metrics` (`exact_match`, `stub`, `error`,
  `faithfulness` or `g_eval` specs), `identifier`, `hyperparameters` and
  `error_config` (`ErrorConfig`'s `ignore_errors` and
  `skip_on_missing_params`; `ignore_errors` is `true` unless the scenario
  is about it), passed to `DeepEvalEx.evaluate_run/3` as the options of the
  same names
- `test_run.json` - the file deepeval wrote for those inputs, unchanged
- `raised.json` - in place of `test_run.json` when `evaluate()` raised: the
  exception's Python `type` name and `message`. The parity test expects
  DeepEvalEx to raise the matching exception (`ArgumentError` for
  `ValueError`, `DeepEvalEx.MissingTestCaseParamsError` for
  `MissingTestCaseParamsError`) with the same message, and to write nothing

No LLM is called. The `stub` and `error` metrics are custom deepeval
`BaseMetric`s returning fixed values or raising; the parity test mirrors them
with `DeepEvalEx.Test.ParityMetrics.Stub` and `.Failing`
(`test/support/parity_metrics.ex`). The `faithfulness` and `g_eval` metrics
are deepeval's own, judged by a `ScriptedJudge` without responses (any call
would fail the metric) and reporting `judge_model`, `mock-model`, the Mock
adapter's model name: every test case of `missing_params` fails their
parameter check before a call.

## Regenerating

Run the generator inside the devcontainer, where deepeval 4.3.1 is installed,
from the repository root:

```sh
devcontainer exec --workspace-folder . \
  env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_fixtures.py
```

The script refuses any other deepeval version, opts out of telemetry, never
logs in to Confident AI, turns the console output off and runs deepeval in a
temporary working directory so its `.deepeval/` cache stays out of the
repository. It rewrites every scenario directory; scenarios are defined in
`SCENARIOS` at the top of the script. A new scenario also needs its name in
the parity test's "covers every scenario" assertion.

It also rewrites the outputs of every scripted scenario that has a
`script.json`, and every [prompt golden](#prompt-goldens) (defined in
`PROMPT_CASES`). Runs are deterministic: no network, a fixed string hash seed
(deepeval orders some reasons by iterating sets), and only the `runDuration`
values change between runs.

Then run `mix test test/deep_eval_ex/parity_test.exs
test/deep_eval_ex/scripted_parity_test.exs
test/deep_eval_ex/prompt_golden_test.exs`. A difference is a bug to fix in
DeepEvalEx, not something to normalise away.

## What the parity test normalises

Only values that differ between two identical runs:

- the run-level `runDuration` (wall-clock time of the whole run)

Test-case `runDuration` is compared as is: deepeval's async executor records
any test case that took under a second as the integer `0`, which these
metrics always do.

## Scripted-judge scenarios

`scripted/<scenario>/script.json` runs one of deepeval's real metrics on one
test case against a scripted judge, `ScriptedJudge` in the generator: a
`DeepEvalBaseLLM` that answers each call with a canned response instead of
calling an LLM. A script holds:

- `metric` - `kind` (`exact_match`, `g_eval`, `faithfulness`, `hallucination`,
  `answer_relevancy`, `contextual_precision`, `contextual_recall` or
  `tool_correctness`) and the metric's constructor `params`
- `test_case` - keyword arguments of deepeval's `LLMTestCase`
- `judge_model` - the name the judge reports as the evaluation model
- `responses` - the judge's answers, keyed by metric kind, then by step, then
  listed by call index. An answer is an object the judge returns as the
  schema, or a string it returns as its raw text, as a judge without
  structured outputs does; deepeval then loads the string with
  `trimAndLoadJson`, and DeepEvalEx with `DeepEvalEx.LLM.Adapter`. A step is the sorted, comma-separated field names of
  the schema the metric asks for (`truths`, `claims`, `verdicts`, `reason`,
  `statements`, `steps`, `reason,score`; `text` for a call without one), so
  it names the same call in deepeval and DeepEvalEx whatever their prompts say.
  The `raw_response` step answers GEval's `generate_raw_response`: each
  answer is an OpenAI chat completion with `logprobs`, which the judge
  returns as openai's `ChatCompletion` and deepeval weights the score by. A
  script without that step has the judge raise `AttributeError`, as a judge
  without logprobs, so GEval asks for `reason,score` instead; the Mock
  adapter offers logprobs (`supports_log_probs?/1`) under the same condition

Scripts are written by hand and committed; the generator refuses a script with
a missing or an unused response. Next to each script it writes:

- `prompts.json` - every prompt deepeval sent the judge, in order, with its step
- `measure.json` - the metric after `measure()`: `score`, `success`, `reason`,
  `threshold`, `error`, `evaluation_model`, `evaluation_cost`, `input_tokens`,
  `output_tokens` and `verbose_logs`
- `test_run.json` - the file `deepeval.evaluate()` wrote for the same metric
  and test case, unchanged

The generator checks that `measure()` and `evaluate()` sent the same prompts.
When `measure()` raises after setting the metric's `error` (as
`trimAndLoadJson` does), `measure.json` records the metric as it was left.
The Elixir side measures with `ignore_errors: false` likewise and compares
the `:result` of the `DeepEvalEx.MetricError` raised, whose `success` is
`nil` as deepeval's is `None`. `evaluate()` runs with `ignore_errors=True`.

The Elixir test loads the same script into the Mock adapter's scripted mode
(`DeepEvalEx.LLM.Adapters.Mock.script/2`), runs the metric and compares with
`assert_matches_fixture/2` (`test/support/scripted_parity.ex`), in four facets
per scenario: prompts (byte for byte, per step), measure (every field but
`verbose_logs`, integer vs float included), verbose logs, and the test run
(keys, key order, types and values, then bytes; only the run-level
`runDuration` is normalised).

| Metric | Scenarios |
| --- | --- |
| ExactMatch | `exact_match_pass`, `exact_match_fail` |
| GEval | `g_eval_criteria_pass` (steps generated from criteria), `g_eval_steps_fail` (given steps), `g_eval_strict`, `g_eval_logprobs` (a raw response with logprobs: the score weighted by the final score token's top logprobs, the same number earlier in the reason ignored, a 1% and a non-decimal token dropped, `"08"` summed with `"8"`), `g_eval_logprobs_missing` (a raw response without logprobs: the raw score kept) |
| Faithfulness | `faithfulness_pass`, `faithfulness_fail`, `faithfulness_borderline`, `faithfulness_penalize_ambiguous` (`penalize_ambiguous_claims`: the borderline verdict fails and is an `(Ambiguous)` contradiction), `faithfulness_no_claims` (empty list), `faithfulness_strict` |
| Hallucination | `hallucination_pass`, `hallucination_fail` (two contradictions out of three contexts), `hallucination_no_verdicts` (empty list), `hallucination_strict`, `hallucination_messy_json` (raw-text answers: prose, a code fence and trailing commas around the verdicts, a reason missing its closing brace), `hallucination_invalid_json` (a raw-text answer with no JSON: the metric errors) |
| AnswerRelevancy | `answer_relevancy_pass`, `answer_relevancy_fail`, `answer_relevancy_no_statements` (empty list), `answer_relevancy_strict` |
| ContextualPrecision | `contextual_precision_pass`, `contextual_precision_fail`, `contextual_precision_strict` |
| ContextualRecall | `contextual_recall_pass`, `contextual_recall_fail`, `contextual_recall_strict` |
| ToolCorrectness | `tool_correctness_pass`, `tool_correctness_fail`, `tool_correctness_available_tools` (LLM-scored tool selection), `tool_correctness_strict` |

### Not covered

One case needs fixtures of its own, to be added with the unit that needs it:

- **Schema validation errors.** Only `hallucination_invalid_json` makes a
  metric fail, with `trimAndLoadJson`'s invalid JSON error. A scripted
  response that is valid JSON but fails schema validation is not covered.

### Known divergences

Comparisons that fail today because of a documented divergence from 4.3.1 (see
the ROADMAP's "Known divergences") are tagged
`@tag known_divergence: "<unit>"`, naming the ROADMAP unit that removes the tag:
when a comparison fails for several reasons, the last of their units. They are
excluded by default, like `:live`, so the gate stays green; see them fail with

```sh
mix test --only known_divergence
```

A unit that fixes a divergence removes its tags in
`@known_divergences` (`test/deep_eval_ex/scripted_parity_test.exs`) and its
rows here.

None are tagged today. A tagged comparison is listed here by facet,
scenarios, why it fails and its tag.

## Prompt goldens

`prompts/<case>/` holds one prompt deepeval 4.3.1 renders for one of the
seven LLM-judged metrics, for fixed inputs:

- `input.json` - `template`, deepeval's template class key and method (e.g.
  `FaithfulnessMetric.generate_truths`, from
  `deepeval/metrics/faithfulness/templates/generate_truths.txt`), and
  `inputs`, the metric-level values the prompt is built from (a retrieval
  context list, an extraction limit, a score, verdicts, ...)
- `prompt.txt` - the rendered prompt, byte for byte, with no trailing newline
  added

Cases are defined in `PROMPT_CASES` in the generator, which renders each the
way the metric does: the metric's own `_get_prompt` (strict Jinja,
`multimodal=False`) with the arguments its helpers derive from the inputs
(`"\n\n".join` of truths, `format(score, ".2f")`,
`_contextual_precision_verdict_fields`, `print_tools_called`, ...); GEval's
cases call the metric's `_steps_prompt` and `_results_prompt`. The generator
fails if a bundled template of these metrics is neither rendered by a case
nor listed in `UNRENDERED_TEMPLATES`.

The Elixir test turns the same inputs into the options the DeepEvalEx
metric passes its prompt function (`options/2` in the test), calls the
function and compares the strings exactly. It also checks that the cases
render every template in the table below, and that the table names every
public prompt function of `DeepEvalEx.Prompts` (the `format_*` helpers
aside).

### Template map

Which 4.3.1 template each DeepEvalEx prompt function stands for and renders
verbatim, as deepeval renders it for a text-only test case. Templates live in
`deepeval/metrics/<metric>/templates/<method>.txt` and are rendered from the
bundle `deepeval/templates/metrics/templates.json`.

| DeepEvalEx function | deepeval 4.3.1 template | Template arguments (from the metric) | Cases |
| --- | --- | --- | --- |
| `Prompts.GEval.generate_evaluation_steps/1` | `GEval.generate_evaluation_steps` (`g_eval/templates/generate_evaluation_steps.txt`) | `criteria`, `parameters` | `g_eval_generate_evaluation_steps`, `_three_params` |
| `Prompts.GEval.generate_evaluation_results/1` | `GEval.generate_evaluation_results` (`g_eval/templates/generate_evaluation_results.txt`) | `evaluation_steps` (numbered), `test_case_content`, `parameters`, `rubric`, `score_range`, `_additional_context` | `g_eval_generate_evaluation_results`, `_rubric` |
| `Prompts.GEval.generate_strict_evaluation_results/1` | `GEval.generate_strict_evaluation_results` (`g_eval/templates/generate_strict_evaluation_results.txt`) | `evaluation_steps`, `test_case_content`, `parameters`, `_additional_context` | `g_eval_generate_strict_evaluation_results` |
| `Prompts.Faithfulness.generate_claims/1` | `FaithfulnessMetric.generate_claims` (`faithfulness/templates/generate_claims.txt`) | `actual_output`, `multimodal_instruction` | `faithfulness_generate_claims` |
| `Prompts.Faithfulness.generate_truths/1` | `FaithfulnessMetric.generate_truths` (`faithfulness/templates/generate_truths.txt`) | `retrieval_context` (joined with blank lines), `limit` (phrase), `multimodal_instruction` | `faithfulness_generate_truths`, `_limit_1`, `_limit_3` |
| `Prompts.Faithfulness.generate_verdicts/1` | `FaithfulnessMetric.generate_verdicts` (`faithfulness/templates/generate_verdicts.txt`) | `claims` (list), `retrieval_context` (truths joined with blank lines) | `faithfulness_generate_verdicts` |
| `Prompts.Faithfulness.generate_reason/1` | `FaithfulnessMetric.generate_reason` (`faithfulness/templates/generate_reason.txt`) | `contradictions` (list), `score` (`.2f`) | `faithfulness_generate_reason`, `_no_contradictions` |
| `Prompts.Hallucination.generate_verdicts/1` | `HallucinationMetric.generate_verdicts` (`hallucination/templates/generate_verdicts.txt`) | `actual_output`, `contexts` (list), `contexts_count` | `hallucination_generate_verdicts` |
| `Prompts.Hallucination.generate_reason/1` | `HallucinationMetric.generate_reason` (`hallucination/templates/generate_reason.txt`) | `factual_alignments`, `contradictions` (lists), `score` (`.2f`) | `hallucination_generate_reason` |
| `Prompts.AnswerRelevancy.generate_statements/1` | `AnswerRelevancyMetric.generate_statements` (`answer_relevancy/templates/generate_statements.txt`) | `actual_output` | `answer_relevancy_generate_statements` |
| `Prompts.AnswerRelevancy.generate_verdicts/1` | `AnswerRelevancyMetric.generate_verdicts` (`answer_relevancy/templates/generate_verdicts.txt`) | `input`, `statements` (list) | `answer_relevancy_generate_verdicts` |
| `Prompts.AnswerRelevancy.generate_reason/1` | `AnswerRelevancyMetric.generate_reason` (`answer_relevancy/templates/generate_reason.txt`) | `irrelevant_statements` (list), `input`, `score` (`.2f`) | `answer_relevancy_generate_reason` |
| `Prompts.ContextualPrecision.generate_verdicts/1` | `ContextualPrecisionMetric.generate_verdicts` (`contextual_precision/templates/generate_verdicts.txt`) | `input`, `expected_output`, `document_count_str`, `context_to_display` (list), `multimodal_note` | `contextual_precision_generate_verdicts`, `_one_document` |
| `Prompts.ContextualPrecision.generate_reason/1` | `ContextualPrecisionMetric.generate_reason` (`contextual_precision/templates/generate_reason.txt`) | `input`, `verdicts` (list of `verdict`/`reason` dicts), `score` (`.2f`) | `contextual_precision_generate_reason` |
| `Prompts.ContextualRecall.generate_verdicts/1` | `ContextualRecallMetric.generate_verdicts` (`contextual_recall/templates/generate_verdicts.txt`) | `expected_output`, `content_type`, `content_type_plural`, `content_or`, `context_to_display` (list), `node_instruction` | `contextual_recall_generate_verdicts` |
| `Prompts.ContextualRecall.generate_reason/1` | `ContextualRecallMetric.generate_reason` (`contextual_recall/templates/generate_reason.txt`) | `expected_output`, `supportive_reasons`, `unsupportive_reasons` (lists), `score` (`.2f`), `content_type` | `contextual_recall_generate_reason` |
| `Prompts.ToolCorrectness.get_tool_selection_score/1` | `ToolCorrectnessMetric.get_tool_selection_score` (`tool_correctness/templates/get_tool_selection_score.txt`) | `user_input`, `tools_called`, `available_tools` (both `print_tools_called`) | `tool_correctness_get_tool_selection_score` |

Templates of these metrics without a DeepEvalEx counterpart, so without a
case:

- `GEval.generate_trace_evaluation_steps`, `generate_trace_evaluation_results`
  and `generate_strict_trace_evaluation_results`: GEval on a trace (no
  `evaluation_params`), which needs tracing (P9)
- the `_experimental_system_one_*` templates (`_questions`, `_verdict`,
  `_tool_selection_score`): System One eval modes (P3)

`DeepEvalEx.Prompts.GEval.format_evaluation_steps/1`, `format_params/1`,
`format_test_case_content/2` and `format_rubric/1` and
`Prompts.ToolCorrectness.format_tools/1` stand for deepeval's
`number_evaluation_steps`, `construct_g_eval_params_string`,
`construct_test_case_string`, `format_rubrics` and `print_tools_called`.
`DeepEvalEx.Prompts.Python` prints template arguments as Jinja prints them:
lists as Python lists (`repr`) and scores as `format(score, ".2f")`.

The ContextualPrecision reason case renders its verdicts as plain strings
(`'yes'`), as the generator passes them; the metric itself passes deepeval's
`Verdict` members, which print as `<Verdict.YES: 'yes'>`, and DeepEvalEx's
metric does the same with its verdict atoms (checked by the scripted-judge
scenarios).

### Known divergences

None: every case renders deepeval's prompt byte for byte. A divergence
would be tagged in `@known_divergences`
(`test/deep_eval_ex/prompt_golden_test.exs`).

## System One fixtures

deepeval 4.3.1 can route a metric's decisions to a System One model, which
answers typed questions about a JSON state with probabilities rather than
text: a **Noul** (P(true) of a proposition), a **Score** (a level among
ordered levels) or a **Choice** (one of a closed set of options). A metric's
`eval_mode` picks who decides:

- `system_one` - one `decide(state, questions)` request answers the whole
  metric: the state is the test case's fields, the questions come from the
  metric's `_experimental_system_one_questions` template (two Nouls and a
  four-level Score for each of the five RAG metrics). The score is the
  weighted mean of the answers, the reason deterministic text built from
  them, and no LLM is called. A Jev error is not caught.
- `hybrid` - the LLM extracts and writes the reason; Jev takes the decisions,
  one Noul per claim (`claim_<i>`), statement, node, sentence or context. A
  Jev call that fails hands that decision to the LLM and is recorded in
  `system_one_fallback_reason` (`"ConnectionError: Jev is down"`).

ToolCorrectness has no whole-metric form, so under `system_one` it runs as
`hybrid`; its only Jev decision is the tool-selection Score (five levels,
`verdict`) when `available_tools` is given. GEval never asks Jev (its score
is LLM-only by design in 4.3.1), so it has no fixture here. `JevEval` asks
the user's own Noul / Score / Choice questions (`q_<i>`) and always decides
with Jev; classifiers ask one Choice over their labels (`label`). Under
`evaluate()`, two or more `system_one` metrics on a test case are merged into
one request (`system_one_batch`): each metric's question keys are prefixed
`m<j>.`, the states merged, and the cost split by question count.

### Generating

`scripts/parity/generate_system_one_fixtures.py` writes them, from the
scenarios in its `SCENARIOS`. It needs deepeval's source at `_ref/deepeval`
(tag `v4.3.1`, not committed): the System One models are deepeval's own test
doubles from `_ref/deepeval/tests/test_metrics/system_one_fakes.py`,
imported from there rather than copied, `FakeSystemOneModel` (canned answers)
and `ExplodingSystemOneModel` (raises on every call). Where a mode needs an
LLM, it is the scripted-judge generator's `ScriptedJudge`; elsewhere it is
the fakes' `ExplodingLLM`, so an unexpected LLM call fails the run.

```sh
devcontainer exec --workspace-folder . \
  env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_system_one_fixtures.py
```

`typesafe-sdk` is not installed and is not needed: deepeval imports it only
when a `TypeSafeModel` builds its client. The generator never builds one; to
record the questions in the SDK's wire shape it calls
`TypeSafeModel._to_sdk_questions` on an instance created without `__init__`
(constructing one would load the client). No stub module is involved.

The generator refuses a question without a canned answer and a canned answer
no question used, checks that `evaluate()` sent the same `decide()` calls
and judge prompts as `measure()` (or exactly one call for a batched
scenario), and is deterministic but for the run-level `runDuration`.

### Files

Each `system_one/<scenario>/` holds:

- `input.json` - the scenario: `description`; `metrics` (each with `kind`,
  `eval_mode` and constructor `params`) or `classifier`; one `test_case`;
  `system_one`, the fake: its `model` name and either the `cost` it reports
  (a float, `null`, or `{value, input_tokens, output_tokens}` for an
  `EvaluationCost`) and its canned `answers` (by type - `nouls`, `scores`,
  `choices` - then question key), or the error it `raises`; `batched` when
  `evaluate()` merges the metrics; and, when an LLM is involved,
  `judge_model` and the scripted judge's `responses`, as in `scripted/`
- `decide.json` - every `decide()` call: `measure` holds one list per
  metric, each measured alone; `evaluate` the calls of the `evaluate()` run.
  A call has the `state` sent, the `questions` in the SDK's shape (`type`,
  `instructions`, and `criteria`: a Noul's `{true, false}` when it has any,
  a Choice's options, a Score's levels; question weights and Choice credits
  stay in deepeval and are not sent), then either the `answers` returned
  (`nouls`, `choices`, `scores`, as `SystemOneAnswers` dumps them, Score
  probabilities keyed by the level index as a string) with the `cost`
  reported, or the `error` raised
- `measure.json` - per metric, its state after `measure()`, as in
  `scripted/` plus `confidence` (the least decisive answer),
  `system_one_fallback_reason`, `score_breakdown` (one outcome per question,
  `system_one` and `JevEval` only) and `raised`, the error `measure()` raised
  (under `system_one`, Jev errors are not caught). For a classifier, its
  state after `classify()`: `label`, `reason`, `error`, evaluation model,
  cost, tokens, `confidence` and `system_one_fallback_reason`
- `prompts.json` - per metric, the prompts the scripted judge received during
  `measure()`, with their steps (only for scenarios with `responses`)
- `test_run.json` - the file `deepeval.evaluate()` wrote, unchanged. A
  classifiers-only run writes none (classifications are local-only), so the
  classifier scenario has `classifications.json` instead: the
  `Classification`s `evaluate()` returned, with their export aliases

| Scenario | Covers |
| --- | --- |
| `<metric>_system_one` | Faithfulness, Hallucination, AnswerRelevancy, ContextualPrecision, ContextualRecall: the whole metric in one request; ToolCorrectness: runs as `hybrid`, Jev scores tool selection |
| `faithfulness_system_one_strict` | Strict mode on Jev: one question misses the strict bar, score 0 |
| `<metric>_hybrid` | The same six metrics in `hybrid`: the LLM extracts and explains (`prompts.json`), Jev decides each item |
| `<metric>_hybrid_fallback` | `hybrid` with `ExplodingSystemOneModel`: each Jev call fails, the scripted judge takes the decisions, `system_one_fallback_reason` set |
| `jev_eval` | `JevEval` with a weighted Noul, a Score and a Choice (credits and a not-applicable option) |
| `jev_eval_strict_not_applicable` | `JevEval` in strict mode without the `[JevEval]` suffix, a Noul with `true` / `false` criteria, a Choice judged not applicable |
| `batch_system_one` | Faithfulness, AnswerRelevancy and ContextualRecall batched into one request by `evaluate()`; cost and tokens split by question count |
| `batch_system_one_down` | Two batched metrics with Jev down: no fallback, `measure()` raises and `evaluate()` records the error on each metric |
| `refusal_classifier_system_one` | `RefusalClassifier` on Jev: one Choice over its labels, deterministic reason |

The Elixir test checks that every scenario has its files, that each call's
questions are well formed and answered under their own type and nothing
else, that a batched request prefixes its keys per metric (and an unbatched
`evaluate()` repeats `measure()`'s calls), that fallbacks, raised errors and
confidence appear exactly when Jev failed or answered, and that the export
agrees with `measure()` on evaluation model and reason.
