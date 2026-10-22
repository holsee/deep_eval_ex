# deepeval golden fixtures

Fixtures written by **deepeval 4.3.1**, in three sets:

- export scenarios (the directories below, except `scripted/`), used by
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

## Export scenarios

Each directory is one scenario:

| Scenario          | What it covers                                                                                 |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `exact_match`     | `ExactMatchMetric` passing and failing over 3 test cases, one with name, tags, metadata, comments |
| `llm_metric`      | Two stub metrics emulating LLM judges: reason, evaluation model, cost and token counts         |
| `metric_error`    | A metric that raises, with `ignore_errors=True`: `error` set, no `score`, counted in `errors`  |
| `rag_and_tools`   | `retrieval_context`, `context`, `tools_called` / `expected_tools`, `token_cost`, `completion_time` |
| `hyperparameters` | `identifier` and `hyperparameters` (string, float, int, bool and dropped `None` values)        |

and holds:

- `input.json` - the scenario's inputs: `test_cases` (keyword arguments of
  deepeval's `LLMTestCase`), `metrics` (`exact_match`, `stub` or `error`
  specs), `identifier` and `hyperparameters`
- `test_run.json` - the file deepeval wrote for those inputs, unchanged

No LLM is called. The `stub` and `error` metrics are custom deepeval
`BaseMetric`s returning fixed values or raising; the parity test mirrors them
with `DeepEvalEx.Test.ParityMetrics.Stub` and `.Failing`
(`test/support/parity_metrics.ex`).

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
  listed by call index. A step is the sorted, comma-separated field names of
  the schema the metric asks for (`truths`, `claims`, `verdicts`, `reason`,
  `statements`, `steps`, `reason,score`; `text` for a call without one), so
  it names the same call in deepeval and DeepEvalEx whatever their prompts say

Scripts are written by hand and committed; the generator refuses a script with
a missing or an unused response. Next to each script it writes:

- `prompts.json` - every prompt deepeval sent the judge, in order, with its step
- `measure.json` - the metric after `measure()`: `score`, `success`, `reason`,
  `threshold`, `error`, `evaluation_model`, `evaluation_cost`, `input_tokens`,
  `output_tokens` and `verbose_logs`
- `test_run.json` - the file `deepeval.evaluate()` wrote for the same metric
  and test case, unchanged

The generator checks that `measure()` and `evaluate()` sent the same prompts.

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
| GEval | `g_eval_criteria_pass` (steps generated from criteria), `g_eval_steps_fail` (given steps), `g_eval_strict` |
| Faithfulness | `faithfulness_pass`, `faithfulness_fail`, `faithfulness_borderline`, `faithfulness_no_claims` (empty list), `faithfulness_strict` |
| Hallucination | `hallucination_pass`, `hallucination_fail` (two contradictions out of three contexts), `hallucination_strict` |
| AnswerRelevancy | `answer_relevancy_pass`, `answer_relevancy_fail`, `answer_relevancy_no_statements` (empty list), `answer_relevancy_strict` |
| ContextualPrecision | `contextual_precision_pass`, `contextual_precision_fail`, `contextual_precision_strict` |
| ContextualRecall | `contextual_recall_pass`, `contextual_recall_fail`, `contextual_recall_strict` |
| ToolCorrectness | `tool_correctness_pass`, `tool_correctness_fail`, `tool_correctness_available_tools` (LLM-scored tool selection), `tool_correctness_strict` |

### Not covered

Two cases need fixtures of their own, to be added with the unit that needs
them:

- **GEval logprob weighting (P1.10).** `ScriptedJudge` has no
  `generate_raw_response`, so deepeval's rubric scoring takes its
  `AttributeError` fallback and uses the raw `score`, as for any judge without
  logprobs. Exercising the weighting needs a judge that replays canned
  logprob payloads, and a matching Mock path.
- **Metric errors.** Every scripted scenario's `measure.json` has
  `error: null`: no script makes a metric fail. An erroring metric's export is
  covered by the `metric_error` export scenario above; a scripted response
  that fails schema validation is not.

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

| Facet | Scenarios | Fails because | Tag |
| --- | --- | --- | --- |
| prompts | every scenario that calls the judge (all but `exact_match_*` and `tool_correctness_pass`, `_fail`, `_strict`) | Prompt templates are paraphrased, not 4.3.1's Jinja templates (P1.6) | P1.6 |
| measure | `hallucination_pass`, `hallucination_fail` | Score direction inverted: 0.0 where deepeval scores 1.0, 0.67 where it scores 0.33 (P1.1) | P1.1 |
| measure | `answer_relevancy_no_statements`, `faithfulness_no_claims` | No verdicts scores the float `1.0`; deepeval's shared QAG scoring returns the integer `1` (P1.2) | P1.2 |
| measure | `answer_relevancy_strict`, `contextual_precision_strict`, `contextual_recall_strict`, `faithfulness_strict` | `strict_mode` ignored: threshold not forced to 1, score not clamped to 0 (P1.3) | P1.3 |
| measure | `hallucination_strict` | `strict_mode` ignored (P1.3) and score direction inverted (P1.1) | P1.3 |
| measure | `exact_match_pass`, `exact_match_fail` | Threshold is the float `1.0`; deepeval's is the integer `1` (P1.3) | P1.3 |
| measure | `tool_correctness_pass`, `_fail`, `_strict` | No evaluation model without `available_tools`, where deepeval reports its judge (P1.3); reasons print tool names as JSON (`["get_weather"]`) rather than Python's repr (`['get_weather']`) (P1.6); in strict mode, float score and threshold where deepeval has integers (P1.3) | P1.6 |
| measure | `tool_correctness_available_tools` | Reason prints tool names as JSON rather than Python's repr (P1.6) | P1.6 |
| measure | `g_eval_strict` | Strict score normalised over the 0-10 range (0.1) and threshold kept at 0.5, where deepeval scores 1 against a threshold of 1 (P1.3, P1.11) | P1.11 |
| verbose_logs | every scenario but `exact_match_*` | No `verbose_logs` on results (P1.7) | P1.7 |
| test_run | every scenario but `exact_match_*` and `g_eval_strict` | No `verboseLogs` in the export (P1.7). Also, as above: strict scores (P1.3), Hallucination direction (P1.1) and its `context` exported as `retrievalContext` too (P1.4), ToolCorrectness `evaluationModel` (P1.3) and reasons (P1.6) | P1.7 |
| test_run | `g_eval_strict` | No `verboseLogs` (P1.7) and strict scoring (P1.3, P1.11) | P1.11 |

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

Which 4.3.1 template each DeepEvalEx prompt function stands for. P1.6
replaces each function's text with its template, verbatim. Templates live in
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

`DeepEvalEx.Prompts.GEval.format_evaluation_steps/1`, `format_params/1` and
`format_test_case_content/2` and `Prompts.ToolCorrectness.format_tools/1`
stand for deepeval's `number_evaluation_steps`,
`construct_g_eval_params_string`, `construct_test_case_string` and
`print_tools_called`.

### Known divergences

Every case is tagged `known_divergence: "P1.6"` in
`@known_divergences` (`test/deep_eval_ex/prompt_golden_test.exs`): the
prompts are paraphrased from older deepeval templates, not 4.3.1's. Besides
the wording, they format the inputs differently: scores rounded with
`Float.round/2` (`0.5`) rather than `.2f` (`0.50`), lists numbered or
JSON-encoded rather than printed as Python lists, `(none)` for an empty
list, GEval's rubric as `- Score n: ...` lines sorted high to low, tools as
JSON in another key order and indentation, with a lower-case `type` and no
`null` fields, and a trailing newline deepeval's prompts lack. P1.6 removes
the tag.
