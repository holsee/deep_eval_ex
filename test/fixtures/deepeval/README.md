# deepeval golden fixtures

Fixtures written by **deepeval 4.3.1**, in six sets:

- export scenarios (the directories below, except `scripted/`, `prompts/`,
  `round_trip/`, `system_one/` and `datasets/`), used by
  `test/deep_eval_ex/parity_test.exs` to check that DeepEvalEx writes the same
  `test_run_<timestamp>.json` files as deepeval, down to the bytes
- [scripted-judge scenarios](#scripted-judge-scenarios) (`scripted/`), used by
  `test/deep_eval_ex/scripted_parity_test.exs` to check that DeepEvalEx's twenty-three
  metrics send the same prompts, measure the same results and export the same
  test run as deepeval's for the same judge responses
- [prompt goldens](#prompt-goldens) (`prompts/`), used by
  `test/deep_eval_ex/prompt_golden_test.exs` to check that each
  `DeepEvalEx.Prompts` function renders the same prompt as the deepeval
  template it stands for, for the same inputs
- [round-trip test runs](#round-trip-test-runs) (`round_trip/`), richer
  files than `evaluate()` writes (traces, prompts, a dataset), used by
  `test/deep_eval_ex/test_run/load_test.exs` to check that
  `DeepEvalEx.TestRun.load/1` and `to_map/1` write them back byte for byte
- [System One fixtures](#system-one-fixtures) (`system_one/`), recording what
  deepeval asks System One (TypeSafe AI's Jev) and does with its answers under
  the `system_one` and `hybrid` eval modes, for the eval-mode units (P3, P4).
  `test/deep_eval_ex/system_one_fixtures_test.exs` only checks their
  structure for now
- [dataset files](#dataset-files) (`datasets/`), CSV, JSON and JSONL datasets
  (some written by deepeval's `save_as`) and what deepeval's loaders load
  from them, used by `test/deep_eval_ex/dataset/loader_parity_test.exs`,
  and by `test/deep_eval_ex/dataset/save_as_parity_test.exs` to check that
  DeepEvalEx's `save_as` writes the same files

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
| `conversational`  | Two `ConversationalTestCase`s and two conversational stub metrics: `conversationalTestCases` with an unnamed (`conversational_test_case_0`) and a named test case, scenario, expected outcome, user description, context, tags, metadata and comments; turns with flattened `RetrievedContextData`, tool calls, an empty `retrieval_context` left out, an empty `tools_called` kept and `user_id` never exported; summed float `runDuration` |

and holds:

- `input.json` - the scenario's inputs: `test_cases` (keyword arguments of
  deepeval's `LLMTestCase`, or of its `ConversationalTestCase` when they
  have `turns`), `metrics` (`exact_match`, `stub`, `conversational_stub`,
  `error`, `faithfulness` or `g_eval` specs), `identifier`, `hyperparameters` and
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
`BaseMetric`s returning fixed values or raising, and `conversational_stub` is
`stub` as a `BaseConversationalMetric`; the parity test mirrors them with
`DeepEvalEx.Test.ParityMetrics.Stub`, `.ConversationalStub` and `.Failing`
(`test/support/parity_metrics.ex`). It normalises the run's `runDuration`
and each conversational test case's, which deepeval sums from wall-clock
time. The `faithfulness` and `g_eval` metrics
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

It also rewrites the [round-trip test runs](#round-trip-test-runs) and the
outputs of every scripted scenario that has a
`script.json`, and every [prompt golden](#prompt-goldens) (defined in
`PROMPT_CASES`). Runs are deterministic: no network, a fixed string hash seed
(deepeval orders some reasons by iterating sets), and only the `runDuration`
values change between runs (and the round-trip runs' uuids and timestamps).

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

## Round-trip test runs

`round_trip/<name>/test_run.json` is a file deepeval wrote, unchanged, with
keys the export scenarios never produce and DeepEvalEx does not model.
DeepEvalEx only loads it and re-encodes it; nothing compares it with a run of
its own. Its uuids and timestamps change with every regeneration.

| Run | What it covers |
| --- | --- |
| `traced_dataset` | `EvaluationDataset.evals_iterator()` over two goldens of a dataset with an alias, id and version (set as `pull()` sets them, without Confident AI), running an `@observe`d agent, retriever and LLM span: each test case's `trace` (with span `metricsData`), the run's `traceMetricsScores`, `prompts` from a text and a messages `Prompt` hyperparameter, `identifier`, `hyperparameters`, `datasetAlias`, `datasetId` and `datasetVersion` |

deepeval 4.3.1 never sets `testFile`, and no local run writes
`conversationalTestCases`, `expectationsData` or `imagesMapping`; those are
covered by hand-written JSON in the load test.

## Scripted-judge scenarios

`scripted/<scenario>/script.json` runs one of deepeval's real metrics on one
test case against a scripted judge, `ScriptedJudge` in the generator: a
`DeepEvalBaseLLM` that answers each call with a canned response instead of
calling an LLM. A script holds:

- `metric` - `kind` (`exact_match`, `g_eval`, `faithfulness`, `hallucination`,
  `answer_relevancy`, `contextual_precision`, `contextual_recall`,
  `contextual_relevancy`, `bias`, `toxicity`, `pii_leakage`, `prompt_alignment`,
  `summarization`, `argument_correctness`, `json_correctness`, `tool_correctness`,
  `pattern_match`, `tool_permission`, `conversational_g_eval`, `turn_relevancy`,
  `conversation_completeness`, `knowledge_retention` or `role_adherence`) and the
  metric's constructor
  `params`. JsonCorrectness's `expected_schema` is a pydantic model's
  `model_json_schema()`: the generator rebuilds the model from it
  (`build_expected_schema`) and fails unless the model's own schema is the
  same, key order included; DeepEvalEx takes the schema as it is
- `test_case` - keyword arguments of deepeval's `LLMTestCase`, or of its
  `ConversationalTestCase` when they have `turns` (each turn built as a
  `Turn`); a `retrieval_context` item written as a `{"context", "source"}` object is a
  `RetrievedContextData` (`DeepEvalEx.Schemas.RetrievedContextData`)
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
`runDuration`, and a conversational test case's, are normalised).

| Metric | Scenarios |
| --- | --- |
| ExactMatch | `exact_match_pass`, `exact_match_fail` |
| GEval | `g_eval_criteria_pass` (steps generated from criteria), `g_eval_steps_fail` (given steps), `g_eval_strict`, `g_eval_logprobs` (a raw response with logprobs: the score weighted by the final score token's top logprobs, the same number earlier in the reason ignored, a 1% and a non-decimal token dropped, `"08"` summed with `"8"`), `g_eval_logprobs_missing` (a raw response without logprobs: the raw score kept), `g_eval_retrieved_context_data` (`retrieval_context` holding a `RetrievedContextData`, printed as its pydantic repr) |
| ConversationalGEval | `conversational_g_eval_criteria_pass` (steps generated from criteria; `:role` appended to `[:content]`), `conversational_g_eval_steps_fail` (given steps, case-level `scenario` and `expected_outcome`, a rubric sorted by range, a fractional `2.5` kept as `0.25`), `conversational_g_eval_strict` (a `7` clamped to the integer `0`, threshold `1`), `conversational_g_eval_logprobs` (per-turn `retrieval_context` and `tools_called`; the score weighted by the *first* token equal to it, in the reason, unlike GEval), `conversational_g_eval_logprobs_missing` (a raw response without logprobs: the raw score kept). deepeval's asynchronous `evaluate()` copies the metric, so the test runs report `"scripted-judge (audio: scripted-judge)"` where `measure()` reports `"scripted-judge"` |
| TurnRelevancy | `turn_relevancy_pass` (one window per unit interaction, the default `window_size` of 10), `turn_relevancy_fail` (`window_size` 2; a raw-text verdict outside yes and no dropped, so `None` in the verbose logs, while the irrelevant window keeps its message number `2`; turns with `retrieval_context`, `tools_called`, `metadata`, `user_id` and `latency_ms` printed as `Turn.__repr__`), `turn_relevancy_strict` (the integer `0`, no reason), `turn_relevancy_no_verdicts` (no answered user turn: no window, the integer score `1`). The reason prompt prints the score unformatted |
| ConversationCompleteness | `conversation_completeness_pass`, `conversation_completeness_fail` (an unmet intention, a raw-text verdict outside yes and no dropped; turns with every field, printed as `model_dump()` JSON in the verbose logs; an unused `window_size`), `conversation_completeness_strict` (an unmet intention without a reason, `None` in the reason prompt), `conversation_completeness_no_intentions` (no verdict, the integer score `1`) |
| KnowledgeRetention | `knowledge_retention_pass`, `knowledge_retention_fail` (an opening assistant turn, and one after a user turn whose facts are `{}`, get no verdict; a forgotten destination fails; a raw-text verdict in a code fence; a dict of several facts, its keys in sorted order), `knowledge_retention_strict` (a forgotten fact without a reason, `None` in the reason prompt, the integer `0`), `knowledge_retention_no_verdicts` (facts `null`: no verdict, the integer score `1`). The reason prompt prints the score to two decimals |
| RoleAdherence | `role_adherence_pass` (turns with `retrieval_context` and `tools_called`, of which the prompt shows `content` and `role`), `role_adherence_fail` (one turn out of character, and a verdict whose index names no turn keeps the judge's `ai_message`: 1 of 3), `role_adherence_strict` (index `-1` counts from the end, `(turn #0)`; non-ASCII escaped in the verbose logs; the integer `0`), `role_adherence_no_assistant_turns` (the integer score `1`). The reason prompt prints the score unformatted |
| Faithfulness | `faithfulness_pass`, `faithfulness_fail`, `faithfulness_borderline`, `faithfulness_penalize_ambiguous` (`penalize_ambiguous_claims`: the borderline verdict fails and is an `(Ambiguous)` contradiction), `faithfulness_no_claims` (empty list), `faithfulness_strict` |
| Hallucination | `hallucination_pass`, `hallucination_fail` (two contradictions out of three contexts), `hallucination_no_verdicts` (empty list), `hallucination_strict`, `hallucination_messy_json` (raw-text answers: prose, a code fence and trailing commas around the verdicts, a reason missing its closing brace), `hallucination_invalid_json` (a raw-text answer with no JSON: the metric errors) |
| AnswerRelevancy | `answer_relevancy_pass`, `answer_relevancy_fail`, `answer_relevancy_no_statements` (empty list), `answer_relevancy_strict` |
| ContextualPrecision | `contextual_precision_pass`, `contextual_precision_fail`, `contextual_precision_strict`, `contextual_precision_retrieved_context_data` (`RetrievedContextData` of one source grouped into one `Source: ...` document at the source's first position, a string between them; the export keeps only each `context`) |
| ContextualRecall | `contextual_recall_pass`, `contextual_recall_fail`, `contextual_recall_strict`, `contextual_recall_retrieved_context_data` (`RetrievedContextData` printed as its pydantic repr in the retrieval context list) |
| ContextualRelevancy | `contextual_relevancy_pass`, `contextual_relevancy_fail` (a `no` verdict without a reason, listed as `None` in the reason prompt), `contextual_relevancy_no_statements` (an empty list for every node: the integer `0`), `contextual_relevancy_strict`; one `verdicts` call per retrieval context node, in order |
| Bias | `bias_pass`, `bias_fail` (a `yes` verdict without a reason, listed as `None` in the reason prompt), `bias_no_opinions` (no opinions: no `verdicts` call, the integer `1`), `bias_strict` |
| Toxicity | `toxicity_pass`, `toxicity_fail` (a `yes` verdict without a reason, listed as `None` in the reason prompt), `toxicity_no_opinions` (no opinions: no `verdicts` call, the integer `1`), `toxicity_strict` |
| PIILeakage | `pii_leakage_pass`, `pii_leakage_fail`, `pii_leakage_no_pii` (nothing extracted: no `verdicts` call, the integer `1`), `pii_leakage_strict`; every verdict has a reason, which deepeval's `PIILeakageVerdict` requires |
| Summarization | `summarization_pass` (`n=3`; alignment `1.0`, coverage `2/3`, the uncovered question listed in the reason prompt after the redundancies), `summarization_fail` (given `assessment_questions`: no `questions` call; a contradiction and a borderline claim without a reason, `None` among the redundancies; answers that need `strip()` and `lower()`; alignment and coverage tie), `summarization_no_claims` (no claims: no `verdicts` call, alignment the integer `0`; no questions: two `answers` calls over `[]`, coverage the integer `0`), `summarization_strict` (`truths_extraction_limit=2`; coverage clamped to `0`, alignment `1.0` kept); the steps run truths, claims, questions, verdicts, answers from the original text, answers from the summary, reason |
| PromptAlignment | `prompt_alignment_pass`, `prompt_alignment_fail` (a `no` verdict without a reason, listed as `None` in the reason prompt), `prompt_alignment_no_verdicts` (an empty list: the integer `1`), `prompt_alignment_strict`; `prompt_instructions` is a constructor param |
| ArgumentCorrectness | `argument_correctness_pass`, `argument_correctness_fail` (an MCP tool call, a call with no input parameters, a `no` verdict without a reason, listed as `None` in the reason prompt), `argument_correctness_no_tool_calls` (`tools_called: []`: no judge call, the float `1.0`, `"No tool calls provided"`, and `toolsCalled: []` in the export), `argument_correctness_strict`; each tool call reaches the verdicts prompt as its `ToolCall.__repr__` |
| ToolCorrectness | `tool_correctness_pass`, `tool_correctness_fail`, `tool_correctness_available_tools` (LLM-scored tool selection), `tool_correctness_strict` |
| PatternMatch | `pattern_match_pass` (a trimmed pattern and output, `\w` matching a non-ASCII letter), `pattern_match_fail` (a match of part of the output only), `pattern_match_ignore_case` (`ignore_case`, an alternation whose first branch matches a prefix only, and `verbose_mode`, whose printed logs the Elixir side captures); no judge |
| JsonCorrectness | `json_correctness_pass` (an empty list, an omitted optional field, a key the schema does not declare; strict by default: the integer `1`, threshold `1`; no judge call), `json_correctness_fail` (valid JSON failing the schema: a string for an integer, a number in a list of strings, a nested `$defs` model missing a field), `json_correctness_invalid_json` (prose around an unterminated object), `json_correctness_not_strict` (`strict_mode=False`: threshold `0.5`; a JSON array for an object; `include_reason=False`: no judge call; `verbose_mode`); the reason prompt prints the schema as `json.dumps(indent=4)`, non-ASCII escaped |
| ToolPermission | `tool_permission_pass`, `tool_permission_fail` (a denied tool that is also allowed, a denied tool, a tool off the allowlist), `tool_permission_no_tool_calls` (`tools_called: []`: the float `1.0`), `tool_permission_denylist_only` (`Allowed=ANY`, a repeated denied call, a lower threshold, `include_reason=False`), `tool_permission_strict` (the integer `0`, threshold the float `1.0`); no judge |

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
twenty LLM-judged metrics, for fixed inputs:

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
cases call the metric's `_steps_prompt` and `_results_prompt`, and
ConversationalGEval's its `_evaluation_prompt`. The generator
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
| `Prompts.ConversationalGEval.generate_evaluation_steps/1` | `ConversationalGEval.generate_evaluation_steps` (`conversational_g_eval/templates/generate_evaluation_steps.txt`) | `criteria`, `parameters` (`:content` and `:role` appended) | `conversational_g_eval_generate_evaluation_steps`, `_case_params` |
| `Prompts.ConversationalGEval.generate_evaluation_results/1` | `ConversationalGEval.generate_evaluation_results` (`conversational_g_eval/templates/generate_evaluation_results.txt`) | `evaluation_steps` (numbered), `turns` (list of `convert_turn_to_dict`), `test_case_content`, `parameters`, `rubric` | `conversational_g_eval_generate_evaluation_results`, `_rubric` |
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
| `Prompts.ContextualRelevancy.generate_verdicts/1` | `ContextualRelevancyMetric.generate_verdicts` (`contextual_relevancy/templates/generate_verdicts.txt`) | `input`, `context` (one node), `context_type`, `statement_or_image`, `extraction_instructions`, `empty_context_instruction` | `contextual_relevancy_generate_verdicts` |
| `Prompts.ContextualRelevancy.generate_reason/1` | `ContextualRelevancyMetric.generate_reason` (`contextual_relevancy/templates/generate_reason.txt`) | `input`, `irrelevant_statements`, `relevant_statements` (lists), `score` (`.2f`) | `contextual_relevancy_generate_reason` |
| `Prompts.Bias.generate_opinions/1` | `BiasMetric.generate_opinions` (`bias/templates/generate_opinions.txt`) | `actual_output`, `multimodal` (`False`: no multimodal rules) | `bias_generate_opinions` |
| `Prompts.Bias.generate_verdicts/1` | `BiasMetric.generate_verdicts` (`bias/templates/generate_verdicts.txt`) | `opinions` (list), `multimodal` (`False`) | `bias_generate_verdicts` |
| `Prompts.Bias.generate_reason/1` | `BiasMetric.generate_reason` (`bias/templates/generate_reason.txt`) | `biases` (list, `None` included), `score` (`.2f`) | `bias_generate_reason` |
| `Prompts.Toxicity.generate_opinions/1` | `ToxicityMetric.generate_opinions` (`toxicity/templates/generate_opinions.txt`) | `actual_output` (the multimodal rules always included) | `toxicity_generate_opinions` |
| `Prompts.Toxicity.generate_verdicts/1` | `ToxicityMetric.generate_verdicts` (`toxicity/templates/generate_verdicts.txt`) | `opinions` (list; the multimodal rules always included) | `toxicity_generate_verdicts` |
| `Prompts.Toxicity.generate_reason/1` | `ToxicityMetric.generate_reason` (`toxicity/templates/generate_reason.txt`) | `toxics` (list, `None` included), `score` (`.2f`) | `toxicity_generate_reason` |
| `Prompts.PIILeakage.extract_pii/1` | `PIILeakageMetric.extract_pii` (`pii_leakage/templates/extract_pii.txt`) | `actual_output` (the multimodal rules always included) | `pii_leakage_extract_pii` |
| `Prompts.PIILeakage.generate_verdicts/1` | `PIILeakageMetric.generate_verdicts` (`pii_leakage/templates/generate_verdicts.txt`) | `extracted_pii` (list; the multimodal rules always included) | `pii_leakage_generate_verdicts` |
| `Prompts.PIILeakage.generate_reason/1` | `PIILeakageMetric.generate_reason` (`pii_leakage/templates/generate_reason.txt`) | `privacy_violations` (list), `score` (`.2f`) | `pii_leakage_generate_reason` |
| `Prompts.PromptAlignment.generate_verdicts/1` | `PromptAlignmentMetric.generate_verdicts` (`prompt_alignment/templates/generate_verdicts.txt`) | `prompt_instructions` (list), `input`, `actual_output` (the multimodal rules always included) | `prompt_alignment_generate_verdicts` |
| `Prompts.PromptAlignment.generate_reason/1` | `PromptAlignmentMetric.generate_reason` (`prompt_alignment/templates/generate_reason.txt`) | `unalignment_reasons` (list, `None` included), `input`, `actual_output`, `score` (`.2f`) | `prompt_alignment_generate_reason` |
| `Prompts.ArgumentCorrectness.generate_verdicts/1` | `ArgumentCorrectnessMetric.generate_verdicts` (`argument_correctness/templates/generate_verdicts.txt`) | `input`, `tools_called` (a Python list of `ToolCall.__repr__`: every set field, `type` always, `input_parameters` and a dict `output` as `json.dumps(indent=4, ensure_ascii=False)`, any other `output` as its `repr()`; the multimodal rules left out for a text-only test case) | `argument_correctness_generate_verdicts` |
| `Prompts.ArgumentCorrectness.generate_reason/1` | `ArgumentCorrectnessMetric.generate_reason` (`argument_correctness/templates/generate_reason.txt`) | `incorrect_tool_calls_reasons` (list, `None` included), `input`, `score` (`.2f`) | `argument_correctness_generate_reason` |
| `Prompts.JsonCorrectness.generate_reason/1` | `JsonCorrectnessMetric.generate_reason` (`json_correctness/templates/generate_reason.txt`) | `actual_output`, `expected_schema` (`serialize_to_json(model_json_schema(), indent=4)`; the case holds the schema, from which the generator rebuilds the pydantic model), `is_valid_json` (a Python bool); the multimodal input rules are included unconditionally | `json_correctness_generate_reason` |
| `Prompts.ToolCorrectness.get_tool_selection_score/1` | `ToolCorrectnessMetric.get_tool_selection_score` (`tool_correctness/templates/get_tool_selection_score.txt`) | `user_input`, `tools_called`, `available_tools` (both `print_tools_called`) | `tool_correctness_get_tool_selection_score` |
| `Prompts.Faithfulness.system_one_questions/0` | `FaithfulnessMetric._experimental_system_one_questions` (`faithfulness/templates/_experimental_system_one_questions.txt`) | none | `faithfulness_experimental_system_one_questions` |
| `Prompts.Faithfulness.system_one_verdict/0` | `FaithfulnessMetric._experimental_system_one_verdict` (`faithfulness/templates/_experimental_system_one_verdict.txt`) | none | `faithfulness_experimental_system_one_verdict` |
| `Prompts.AnswerRelevancy.system_one_questions/0` | `AnswerRelevancyMetric._experimental_system_one_questions` (`answer_relevancy/templates/_experimental_system_one_questions.txt`) | none | `answer_relevancy_experimental_system_one_questions` |
| `Prompts.AnswerRelevancy.system_one_verdict/0` | `AnswerRelevancyMetric._experimental_system_one_verdict` (`answer_relevancy/templates/_experimental_system_one_verdict.txt`) | none | `answer_relevancy_experimental_system_one_verdict` |
| `Prompts.ContextualPrecision.system_one_questions/0` | `ContextualPrecisionMetric._experimental_system_one_questions` (`contextual_precision/templates/_experimental_system_one_questions.txt`) | none | `contextual_precision_experimental_system_one_questions` |
| `Prompts.ContextualPrecision.system_one_verdict/0` | `ContextualPrecisionMetric._experimental_system_one_verdict` (`contextual_precision/templates/_experimental_system_one_verdict.txt`) | none | `contextual_precision_experimental_system_one_verdict` |
| `Prompts.ContextualRecall.system_one_questions/0` | `ContextualRecallMetric._experimental_system_one_questions` (`contextual_recall/templates/_experimental_system_one_questions.txt`) | none | `contextual_recall_experimental_system_one_questions` |
| `Prompts.ContextualRecall.system_one_verdict/0` | `ContextualRecallMetric._experimental_system_one_verdict` (`contextual_recall/templates/_experimental_system_one_verdict.txt`) | none | `contextual_recall_experimental_system_one_verdict` |
| `Prompts.ContextualRelevancy.system_one_questions/0` | `ContextualRelevancyMetric._experimental_system_one_questions` (`contextual_relevancy/templates/_experimental_system_one_questions.txt`) | none | `contextual_relevancy_experimental_system_one_questions` |
| `Prompts.ContextualRelevancy.system_one_verdict/0` | `ContextualRelevancyMetric._experimental_system_one_verdict` (`contextual_relevancy/templates/_experimental_system_one_verdict.txt`) | none | `contextual_relevancy_experimental_system_one_verdict` |
| `Prompts.Bias.system_one_questions/0` | `BiasMetric._experimental_system_one_questions` (`bias/templates/_experimental_system_one_questions.txt`) | none | `bias_experimental_system_one_questions` |
| `Prompts.Bias.system_one_verdict/0` | `BiasMetric._experimental_system_one_verdict` (`bias/templates/_experimental_system_one_verdict.txt`) | none | `bias_experimental_system_one_verdict` |
| `Prompts.Toxicity.system_one_questions/0` | `ToxicityMetric._experimental_system_one_questions` (`toxicity/templates/_experimental_system_one_questions.txt`) | none | `toxicity_experimental_system_one_questions` |
| `Prompts.Toxicity.system_one_verdict/0` | `ToxicityMetric._experimental_system_one_verdict` (`toxicity/templates/_experimental_system_one_verdict.txt`) | none | `toxicity_experimental_system_one_verdict` |
| `Prompts.PIILeakage.system_one_questions/0` | `PIILeakageMetric._experimental_system_one_questions` (`pii_leakage/templates/_experimental_system_one_questions.txt`) | none | `pii_leakage_experimental_system_one_questions` |
| `Prompts.PIILeakage.system_one_verdict/0` | `PIILeakageMetric._experimental_system_one_verdict` (`pii_leakage/templates/_experimental_system_one_verdict.txt`) | none | `pii_leakage_experimental_system_one_verdict` |
| `Prompts.PromptAlignment.system_one_questions/1` | `PromptAlignmentMetric._experimental_system_one_questions` (`prompt_alignment/templates/_experimental_system_one_questions.txt`) | `prompt_instructions` (one Noul each, written with Jinja's `tojson`: non-ASCII, `<`, `>`, `&` and `'` escaped) | `prompt_alignment_experimental_system_one_questions` |
| `Prompts.PromptAlignment.system_one_verdict/0` | `PromptAlignmentMetric._experimental_system_one_verdict` (`prompt_alignment/templates/_experimental_system_one_verdict.txt`) | none | `prompt_alignment_experimental_system_one_verdict` |
| `Prompts.Summarization.generate_questions/1` | `SummarizationMetric.generate_questions` (`summarization/templates/generate_questions.txt`) | `text` (the input), `n` (the multimodal rules always included) | `summarization_generate_questions` |
| `Prompts.Summarization.generate_answers/1` | `SummarizationMetric.generate_answers` (`summarization/templates/generate_answers.txt`) | `questions` (list), `text` (the input or the actual output; the multimodal rules always included) | `summarization_generate_answers` |
| `Prompts.Summarization.generate_alignment_verdicts/1` | `SummarizationMetric.generate_alignment_verdicts` (`summarization/templates/generate_alignment_verdicts.txt`) | `summary_claims` (list), `original_text` (truths joined with blank lines; the multimodal rules always included) | `summarization_generate_alignment_verdicts` |
| `Prompts.Summarization.generate_reason/1` | `SummarizationMetric.generate_reason` (`summarization/templates/generate_reason.txt`) plus what `_generate_reason` appends | `contradictions`, `redundancies` (lists, `None` included), `score` (`.2f`); then, appended with no newline before it, `Questions the original text can answer but not the summary:` and the `questions` list when there are any, and `JSON:` with a newline | `summarization_generate_reason`, `_all_answered` |
| `Prompts.Summarization.system_one_questions/1` | `SummarizationMetric._experimental_system_one_questions` (`summarization/templates/_experimental_system_one_questions.txt`) | `assessment_questions` (one Noul each, written with Jinja's `tojson`; none without them) | `summarization_experimental_system_one_questions`, `_none` |
| `Prompts.Summarization.system_one_verdict/0` | `SummarizationMetric._experimental_system_one_verdict` (`summarization/templates/_experimental_system_one_verdict.txt`) | none | `summarization_experimental_system_one_verdict` |
| `Prompts.ArgumentCorrectness.system_one_questions/0` | `ArgumentCorrectnessMetric._experimental_system_one_questions` (`argument_correctness/templates/_experimental_system_one_questions.txt`) | none | `argument_correctness_experimental_system_one_questions` |
| `Prompts.ArgumentCorrectness.system_one_verdict/0` | `ArgumentCorrectnessMetric._experimental_system_one_verdict` (`argument_correctness/templates/_experimental_system_one_verdict.txt`) | none | `argument_correctness_experimental_system_one_verdict` |
| `Prompts.Hallucination.system_one_questions/0` | `HallucinationMetric._experimental_system_one_questions` (`hallucination/templates/_experimental_system_one_questions.txt`) | none | `hallucination_experimental_system_one_questions` |
| `Prompts.Hallucination.system_one_verdict/0` | `HallucinationMetric._experimental_system_one_verdict` (`hallucination/templates/_experimental_system_one_verdict.txt`) | none | `hallucination_experimental_system_one_verdict` |
| `Prompts.TurnRelevancy.generate_verdicts/1` | `TurnRelevancyMetric.generate_verdicts` (`turn_relevancy/templates/generate_verdicts.txt`) | `sliding_window` (list of `convert_turn_to_dict`; the multimodal rules always included) | `turn_relevancy_generate_verdicts` |
| `Prompts.TurnRelevancy.generate_reason/1` | `TurnRelevancyMetric.generate_reason` (`turn_relevancy/templates/generate_reason.txt`) | `score` (unformatted), `irrelevancies` (list of `message number` / `reason` dicts; the multimodal rules always included) | `turn_relevancy_generate_reason`, `_no_irrelevancies` |
| `Prompts.TurnRelevancy.system_one_questions/0` | `TurnRelevancyMetric._experimental_system_one_questions` (`turn_relevancy/templates/_experimental_system_one_questions.txt`) | none | `turn_relevancy_experimental_system_one_questions` |
| `Prompts.TurnRelevancy.system_one_verdict/0` | `TurnRelevancyMetric._experimental_system_one_verdict` (`turn_relevancy/templates/_experimental_system_one_verdict.txt`) | none | `turn_relevancy_experimental_system_one_verdict` |
| `Prompts.ConversationCompleteness.extract_user_intentions/1` | `ConversationCompletenessMetric.extract_user_intentions` (`conversation_completeness/templates/extract_user_intentions.txt`) | `turns` (list of `convert_turn_to_dict`), `multimodal` | `conversation_completeness_extract_user_intentions` |
| `Prompts.ConversationCompleteness.generate_verdicts/1` | `ConversationCompletenessMetric.generate_verdicts` (`conversation_completeness/templates/generate_verdicts.txt`) | `turns`, `intention`, `multimodal` | `conversation_completeness_generate_verdicts` |
| `Prompts.ConversationCompleteness.generate_reason/1` | `ConversationCompletenessMetric.generate_reason` (`conversation_completeness/templates/generate_reason.txt`) | `score` (unformatted), `incompletenesses` (list, `None` included), `intentions` (list), `multimodal` (the rules included when `true`) | `conversation_completeness_generate_reason`, `_multimodal` |
| `Prompts.ConversationCompleteness.system_one_questions/0` | `ConversationCompletenessMetric._experimental_system_one_questions` (`conversation_completeness/templates/_experimental_system_one_questions.txt`) | none | `conversation_completeness_experimental_system_one_questions` |
| `Prompts.ConversationCompleteness.system_one_verdict/0` | `ConversationCompletenessMetric._experimental_system_one_verdict` (`conversation_completeness/templates/_experimental_system_one_verdict.txt`) | none | `conversation_completeness_experimental_system_one_verdict` |
| `Prompts.KnowledgeRetention.extract_data/1` | `KnowledgeRetentionMetric.extract_data` (`knowledge_retention/templates/extract_data.txt`) | `user_message`, `previous_turns` (list of `convert_turn_to_dict`) | `knowledge_retention_extract_data`, `_first_turn` |
| `Prompts.KnowledgeRetention.generate_verdict/1` | `KnowledgeRetentionMetric.generate_verdict` (`knowledge_retention/templates/generate_verdict.txt`) | `llm_message`, `accumulated_knowledge` (list of dicts; the multimodal rules always included) | `knowledge_retention_generate_verdict` |
| `Prompts.KnowledgeRetention.generate_reason/1` | `KnowledgeRetentionMetric.generate_reason` (`knowledge_retention/templates/generate_reason.txt`) | `attritions` (list, `None` included), `score` (`format(score, ".2f")`; the multimodal rules always included) | `knowledge_retention_generate_reason`, `_no_attritions` |
| `Prompts.KnowledgeRetention.system_one_questions/0` | `KnowledgeRetentionMetric._experimental_system_one_questions` (`knowledge_retention/templates/_experimental_system_one_questions.txt`) | none | `knowledge_retention_experimental_system_one_questions` |
| `Prompts.KnowledgeRetention.system_one_verdict/0` | `KnowledgeRetentionMetric._experimental_system_one_verdict` (`knowledge_retention/templates/_experimental_system_one_verdict.txt`) | none | `knowledge_retention_experimental_system_one_verdict` |
| `Prompts.RoleAdherence.extract_out_of_character_response_verdicts/1` | `RoleAdherenceMetric.extract_out_of_character_response_verdicts` (`role_adherence/templates/extract_out_of_character_response_verdicts.txt`) | `turns` (list of `convert_turn_to_dict`), `role` (the multimodal rules always included) | `role_adherence_extract_out_of_character_response_verdicts` |
| `Prompts.RoleAdherence.generate_reason/1` | `RoleAdherenceMetric.generate_reason` (`role_adherence/templates/generate_reason.txt`) | `score` (unformatted), `role`, `out_of_character_responses` (list, `None` included; the multimodal rules always included) | `role_adherence_generate_reason`, `_in_character` |
| `Prompts.RoleAdherence.system_one_questions/0` | `RoleAdherenceMetric._experimental_system_one_questions` (`role_adherence/templates/_experimental_system_one_questions.txt`) | none | `role_adherence_experimental_system_one_questions` |
| `Prompts.RoleAdherence.system_one_verdict/0` | `RoleAdherenceMetric._experimental_system_one_verdict` (`role_adherence/templates/_experimental_system_one_verdict.txt`) | none | `role_adherence_experimental_system_one_verdict` |
| `Prompts.ToolCorrectness.system_one_tool_selection_score/0` | `ToolCorrectnessMetric._experimental_system_one_tool_selection_score` (`tool_correctness/templates/_experimental_system_one_tool_selection_score.txt`) | none | `tool_correctness_experimental_system_one_tool_selection_score` |

Templates of these metrics without a DeepEvalEx counterpart, so without a
case:

- `GEval.generate_trace_evaluation_steps`, `generate_trace_evaluation_results`
  and `generate_strict_trace_evaluation_results`: GEval on a trace (no
  `evaluation_params`), which needs tracing (P9)

The generator cannot find the private `_experimental_system_one_*`
templates by itself, so each has a case of its own above.

`DeepEvalEx.Prompts.GEval.format_evaluation_steps/1`, `format_params/1`,
`format_test_case_content/2` and `format_rubric/1` and
`Prompts.ToolCorrectness.format_tools/1` stand for deepeval's
`number_evaluation_steps`, `construct_g_eval_params_string`,
`construct_test_case_string`, `format_rubrics` and `print_tools_called`;
`Prompts.ConversationalGEval.format_params/1` and
`format_test_case_content/2` for
`construct_conversational_g_eval_turn_params_string` and
`construct_non_turns_test_case_string`.
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

## Dataset files

`scripts/parity/generate_dataset_fixtures.py` writes, for every case in its
`CASES`, `datasets/<case>/` with the case's files and `loads.json`: one
entry per call of a deepeval loader (`add_goldens_from_csv_file`,
`add_goldens_from_json_file`, `add_goldens_from_jsonl_file`,
`add_test_cases_from_csv_file` or `add_test_cases_from_json_file`) on one of
the files, with its arguments and the goldens or test cases it loaded (each
field by its DeepEvalEx name), or the exception it raised.

| Case | What it covers |
| --- | --- |
| `saved` | `save_as("csv" / "json" / "jsonl", include_test_cases=True)` of goldens with every field, a minimal golden, a golden of commas, quotes, newlines and non-ASCII text, and a test case with token cost and counts; loaded back by every loader |
| `save_as_edges` | `save_as` cells in their own formats: empty lists and maps, floats such as `1e-05`, `2.0` and `1e+16`, an emoji, a control character, a carriage return, tool calls without optional fields, expectations with defaults, a golden's token cost (not written); saved with (`saved.*`) and without (`goldens.*`) the test cases. Every map's keys are sorted, so `test/deep_eval_ex/dataset/save_as_parity_test.exs` checks that DeepEvalEx's `save_as` writes these files byte for byte |
| `csv_cells` | pandas' missing-value markers, numbers in the token columns, trailing commas in tool call JSON, JSON metadata with `true` and `null`, `mustNot` expectations, a blank line and a short row |
| `csv_columns` | other column names, a `;` context delimiter and absent columns, for goldens and test cases |
| `jsonl_lines` | JSONL lines with list or delimited-string contexts, tool calls as lists or JSON strings, blank lines, surrounding whitespace, and other key names |
| `json_test_cases` | `add_test_cases_from_json_file` with its own key names (metadata ignored, tool calls `[]` when absent) and a missing required key |
| `invalid` | a JSON file and a JSONL line that are not valid JSON |

deepeval reads CSV with pandas, which the devcontainer does not install.
Install it, then run the generator:

```sh
devcontainer exec --workspace-folder . pip install pandas
devcontainer exec --workspace-folder . \
  env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_dataset_fixtures.py
```

The fixtures were generated with pandas 3.1.0. The test compares deepeval's
own `ValueError` messages; for pydantic's validation errors and Python's
`TypeError`s it checks only that DeepEvalEx raises `ArgumentError`.

## System One fixtures

deepeval 4.3.1 can route a metric's decisions to a System One model, which
answers typed questions about a JSON state with probabilities rather than
text: a **Noul** (P(true) of a proposition), a **Score** (a level among
ordered levels) or a **Choice** (one of a closed set of options). A metric's
`eval_mode` picks who decides:

- `system_one` - one `decide(state, questions)` request answers the whole
  metric: the state is the test case's fields, the questions come from the
  metric's `_experimental_system_one_questions` template (two Nouls and a
  four-level Score for each of the six RAG metrics, one Noul and a
  four-level Score about `actual_output` for Bias, Toxicity and PIILeakage,
  one Noul per prompt instruction for PromptAlignment, two Nouls and a
  four-level Score about `input` and the structured `tools_called` for
  ArgumentCorrectness, two Nouls and a four-level Score about `input` and
  `actual_output`, then one Noul per given assessment question, for
  Summarization). The score is the
  weighted mean of the answers, the reason deterministic text built from
  them, and no LLM is called. A Jev error is not caught.
- `hybrid` - the LLM extracts and writes the reason; Jev takes the decisions,
  one Noul per claim (`claim_<i>`), statement, node, sentence or context. A
  Jev call that fails hands that decision to the LLM and is recorded in
  `system_one_fallback_reason` (`"ConnectionError: Jev is down"`).

JsonCorrectness decides in code in every mode, so Jev is never asked: its
`_system_one_eval_spec` is `None`, it builds no System One model, and under
`system_one` it has no LLM either, so a failure's reason is pydantic's
`ValidationError` text (DeepEvalEx lays its own validation error out the same
way, with pydantic's messages but without its `[type=...]` details and links,
so its `system_one` scenarios use matching output). It has no
`hybrid_fallback` scenario, as nothing can fail over. Under `evaluate()` it
still counts as a `system_one` candidate, so a test case's one other
`system_one` metric is batched alone (`m0.` keys).

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
| `<metric>_system_one` | Faithfulness, Hallucination, AnswerRelevancy, ContextualPrecision, ContextualRecall, ContextualRelevancy, Bias, Toxicity, PIILeakage, PromptAlignment, ArgumentCorrectness, Summarization (with two `assessment_questions`, `q_3` and `q_4`): the whole metric in one request; ToolCorrectness: runs as `hybrid`, Jev scores tool selection |
| `faithfulness_system_one_strict` | Strict mode on Jev: one question misses the strict bar, score 0 |
| `turn_relevancy_system_one`, `conversation_completeness_system_one` | The conversational metrics' whole-metric request: the state is `{"turns": [...]}`, each turn's `content` and `role` (`construct_multi_turn_state`); results export under `conversationalTestCases` |
| `turn_relevancy_system_one_strict` | TurnRelevancy in strict mode on Jev, with a `window_size` the whole-metric request does not use |
| `turn_relevancy_hybrid`, `conversation_completeness_hybrid` | `hybrid` with a `SystemOneBinarySpec` per decision: one request per sliding window (TurnRelevancy, the window's `turns`) or per extracted user intention (ConversationCompleteness, the `turns` and the `intention`), its one Noul keyed `verdict`, P(yes) of `0.5` and above `yes` |
| `turn_relevancy_hybrid_fallback`, `conversation_completeness_hybrid_fallback` | The same with Jev down: each window or intention falls back to the LLM, the reasons joined in `system_one_fallback_reason` |
| `knowledge_retention_system_one`, `role_adherence_system_one` | The whole-metric request of KnowledgeRetention (the turns) and RoleAdherence (the turns, and `chatbot_role` under `test_case`) |
| `knowledge_retention_hybrid` | `hybrid`: the LLM extracts each user turn's facts and writes the reason; one request per judged assistant turn about its `llm_message` and the `accumulated_knowledge`, P(yes) of `0.5` and above `yes` (it forgets) |
| `role_adherence_hybrid` | `hybrid`: one request per assistant turn about the `chatbot_role`, the `previous_turns` and its `ai_message`, P(yes) below `0.5` out of character with the reason `P(in character)=0.31`; the LLM writes the reason |
| `knowledge_retention_hybrid_fallback`, `role_adherence_hybrid_fallback` | The same with Jev down: KnowledgeRetention falls back per turn; RoleAdherence asks every turn (deepeval gathers them), then the LLM lists the out of character turns |
| `<metric>_hybrid` | The same thirteen metrics in `hybrid`: the LLM extracts and explains (`prompts.json`), Jev decides each item; ContextualRelevancy asks one request per retrieval context node, about its sentences (`statement_<i>`); Bias and Toxicity ask whether each opinion is biased (toxic), `opinion_<i>`, P(yes) of `0.5` and above failing it; PIILeakage whether each extracted statement holds PII, `statement_<i>`, likewise; PromptAlignment whether each instruction is followed, `instruction_<i>` with `input` and `actual_output` in the state, P(yes) of `0.5` and above passing it (no LLM extraction); ArgumentCorrectness whether each tool call's input parameters address the input, `tool_call_<i>` holding the call's `ToolCall.__repr__` with `input` in the state, likewise passing (no LLM extraction); Summarization whether each claim of the summary agrees with the truths of the original text, `summary_claim_<i>` with `original_text` (the truths) in the state, the LLM still asking and answering the coverage questions |
| `<metric>_hybrid_fallback` | `hybrid` with `ExplodingSystemOneModel`: each Jev call fails, the scripted judge takes the decisions, `system_one_fallback_reason` set |
| `jev_eval` | `JevEval` with a weighted Noul, a Score and a Choice (credits and a not-applicable option) |
| `jev_eval_strict_not_applicable` | `JevEval` in strict mode without the `[JevEval]` suffix, a Noul with `true` / `false` criteria, a Choice judged not applicable |
| `batch_system_one` | Faithfulness, AnswerRelevancy and ContextualRecall batched into one request by `evaluate()`; cost and tokens split by question count |
| `batch_system_one_retrieval` | ContextualRelevancy and ContextualPrecision batched into one request by `evaluate()` |
| `batch_system_one_safety` | Bias and Toxicity batched into one request about `actual_output` by `evaluate()` |
| `batch_system_one_pii_alignment` | PIILeakage and PromptAlignment (with its own `prompt_instructions`) batched into one request by `evaluate()` |
| `json_correctness_system_one` | JsonCorrectness decided in code with neither Jev nor an LLM: no `decide()` call, no evaluation model, the cost seeded at `0` |
| `json_correctness_hybrid` | JsonCorrectness in `hybrid`: no `decide()` call, the LLM explains the failure (`prompts.json`) |
| `batch_system_one_json` | Bias and JsonCorrectness under `system_one` in `evaluate()`: JsonCorrectness makes two candidates but asks nothing, so the one request holds Bias's questions alone, keyed `m0.` |
| `batch_system_one_summarization` | Summarization and AnswerRelevancy batched into one request about `input` and `actual_output` by `evaluate()` |
| `batch_system_one_agent` | ArgumentCorrectness and AnswerRelevancy batched into one request by `evaluate()`, the state merging `input`, `tools_called` and `actual_output` |
| `batch_system_one_conversational` | TurnRelevancy and ConversationCompleteness batched into one request about the turns by `evaluate()` |
| `batch_system_one_retention_role` | KnowledgeRetention and RoleAdherence batched into one request by `evaluate()`, the state holding the turns and the `chatbot_role` |
| `batch_system_one_down` | Two batched metrics with Jev down: no fallback, `measure()` raises and `evaluate()` records the error on each metric |
| `refusal_classifier_system_one` | `RefusalClassifier` on Jev: one Choice over its labels, deterministic reason |

The Elixir test checks that every scenario has its files, that each call's
questions are well formed and answered under their own type and nothing
else, that a batched request prefixes its keys per metric that asks
anything (and an unbatched `evaluate()` repeats `measure()`'s calls), that a
metric that asks nothing (JsonCorrectness) makes no call, that fallbacks,
raised errors and confidence appear exactly when Jev failed or answered, and
that the export agrees with `measure()` on evaluation model and reason.

`test/deep_eval_ex/metrics/system_one_parity_test.exs`
(`DeepEvalEx.Test.SystemOneParity`) measures the scenarios of the metrics
that run on System One with the real DeepEvalEx metric, the fake answered
by `DeepEvalEx.SystemOne.Adapters.Mock.from_fixture/2` and the judge by the
Mock adapter's script, and compares the `decide()` calls of `measure()` and
`evaluate()`, the measured state, the judge's prompts and the test run with
the fixture, byte for byte. It covers Faithfulness, AnswerRelevancy,
ContextualPrecision, ContextualRecall, ContextualRelevancy, Hallucination,
Bias, Toxicity, PIILeakage, PromptAlignment, ArgumentCorrectness, Summarization and ToolCorrectness: each one's `system_one`, `hybrid` and `hybrid_fallback`
scenarios, JsonCorrectness's `system_one` and `hybrid`, and
`faithfulness_system_one_strict`, and
`DeepEvalEx.Metrics.JevEval` (`jev_eval` and
`jev_eval_strict_not_applicable`), and the batched scenarios.
