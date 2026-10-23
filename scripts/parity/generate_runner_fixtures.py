"""Generate the golden fixtures of DeepEvalEx's test-runner phase (P8):
classifiers, expectations, the test-run cache, the console report and
`deepeval test run`.

Classifiers (`deepeval.classifiers`) assign exactly one label from a closed
set to a test case, and only pass or fail when the test case declares the
expected label (`expected_labels[classifier.name]`). Under the `llm` eval
mode a classifier is one schema call (`label`, `reason`); under
`system_one` it is one Jev Choice over its labels with a deterministic
reason. Every LLM here is `ScriptedJudge` from generate_fixtures.py and
every System One model a fake from deepeval's test suite (see
generate_system_one_fixtures.py), so nothing is called over the network.

For every scenario in `CLASSIFIER_SCENARIOS` below this script writes,
under test/fixtures/deepeval/classifiers/<scenario>/:

- input.json    - the scenario: the `classifier` (`kind`, `eval_mode`,
                  constructor `params`), one `test_case` (with its
                  `expected_labels`), the scripted judge's `judge_model` and
                  `responses` (keyed by step, then call index) or the fake
                  System One model (`system_one`), and optionally a stub
                  `metric` evaluated alongside the classifier
- measure.json  - the classifier's state after `classify()`: label, reason,
                  error, evaluation model, cost, tokens, confidence and
                  fallback reason, plus `raised` (the exception's type and
                  message) when `classify()` raised
- prompts.json  - every prompt the scripted judge received during
                  `classify()` (llm scenarios)
- decide.json   - every System One `decide()` call of `classify()` and of
                  the `evaluate()` run (system_one scenarios), as in
                  generate_system_one_fixtures.py
- evaluate.json - what `evaluate(..., classifiers=[...])` returned with
                  `ignore_errors=True`: the test result's `success` and its
                  `classifications`, dumped by alias
- test_run.json - with a `metric` only: the test run `evaluate()` wrote,
                  which never holds classifications
- assert_test.json - with `assert_test`: what `deepeval.assert_test()`
                  raised (`raised`, type and message) or `null`

Expectations (`dataset/expectations.py`, `evaluate/expectations.py`) are
must/must_not conditions on a test case, judged by deepeval's private
`_ExpectationEvaluator` (named "Expectations") that `evaluate()` and
`assert_test()` add for every test case with expectations. For every
scenario in `EXPECTATION_SCENARIOS` this script writes, under
test/fixtures/deepeval/expectations/<scenario>/:

- input.json    - the scenario: one `test_case` with its `expectations`
                  (`must`, `must_not`, `eval_mode`; the judge is the
                  expectations' `model`), the scripted judge's `judge_model`
                  and `responses` or the fake System One model
                  (`system_one`), and optionally `metrics` evaluated
                  alongside (stubs, or System One metrics sharing the fake)
- measure.json  - the evaluator after `measure()`: score, success, reason,
                  error, evaluation model, cost, tokens, verbose logs,
                  verdicts, `criteria`, confidence, plus `raised` when
                  `measure()` raised
- prompts.json  - every prompt the scripted judge received during
                  `measure()` (llm scenarios)
- decide.json   - the System One `decide()` calls of `measure()` and of
                  `evaluate()` (system_one scenarios)
- evaluate.json - what `evaluate()` returned with `ignore_errors=True`: the
                  test result's `success` and its `metricsData` (the
                  Expectations row with its `expectationsData`), dumped by
                  alias without `None`s
- test_run.json - the test run `evaluate()` wrote: the case's
                  `expectationsData`, and no Expectations row in
                  `metricsData` or `metricsScores`
- assert_test.json - what `deepeval.assert_test()` raised, or `null`

It also writes:

- expectations/validation/cases.json - `evaluate()` and `assert_test()`
  inputs that `validate_expectation_coverage` rejects, with the error
- classifiers/builtins/builtins.json   - every built-in classifier's name
  and labels, with and without its constructor parameter
- classifiers/validation/cases.json    - `Classifier(...)`
  (`normalize_labels`) and `validate_classifiers` inputs with the error
  they raise or the warning they log

The test-run cache (`test_run/cache.py`) is written under
test/fixtures/deepeval/cache/: `keys/keys.json` (cache keys from
`KEY_CASES`), `configurations/configurations.json` (every scripted and
System One scenario's metric configuration, and `same_metric_configs`
verdicts) and, for every scenario in `CACHE_SCENARIOS`, `input.json` with
its runs and `run<i>/` with what each run left: `run.json` (cache files,
metrics measured, what `evaluate()` raised or returned, `decide()` calls),
`cache.json` (the cache file's bytes) and `test_run.json`.

The console report (`evaluate/console_report.py`) and the wrap-up's output
(`TestRunManager.display_results_table` and `wrap_up_test_run`) are written
under test/fixtures/deepeval/report/<scenario>/ for every scenario in
`REPORT_SCENARIOS`. A scenario is a list of test results, built as deepeval's
`TestResult`s (with `MetricData`, `Classification` and `TurnApi`), and the
test run `evaluate()` would make of them (`LLMApiTestCase` and
`ConversationalApiTestCase` filled by `update_metric_data`; a test result
without metric data is left out, as `update_test_run` leaves it):

- input.json    - the scenario: `test_results`, `display`, `truncate`,
                  `run_duration`, `hyperparameters` and `identifier`
- sections.json - `EvaluationConsoleReport._build_display_elements()`: every
                  renderable as `{"panel": {"border_style", "content"}}`,
                  `{"tree": {"label", "children"}}`,
                  `{"table": {"title", "columns", "rows"}}` or a string,
                  the strings exactly as deepeval hands them to Rich
- report.md     - `export_to_markdown()`, under a fixed name
- test_run.json - the test run after `wrap_up_test_run()` (sorted, counted)
- tables.json   - what `display_results_table()` printed, in order: tables
                  (as in sections.json) and markup strings
- summary.txt   - the text `wrap_up_test_run()` printed (`display_table`
                  off), recorded by a Rich console without colour or
                  wrapping
- table_<width>.txt - what `display_results_table()` printed, drawn by Rich
                  without colour on a console `<width>` columns wide (each
                  of `TABLE_WIDTHS`), without the Confident AI note row,
                  which DeepEvalEx keeps in its row model but never draws
                  (ADR-0010 decision 6)

`deepeval test run` (`cli/test/command.py`) is written under
test/fixtures/deepeval/cli/: `args/cases.json` (the pytest arguments,
settings, output or error of every argv in `CLI_ARGS_CASES`, with
pytest.main patched) and, for every scenario in `CLI_SCENARIOS`, real runs of
`test_runner.py` (also written there) with what each left: `run<i>/run.json`
(argv, exit code, skipped-test lines), `latest_test_run.json` and
`cache.json` (the cache file's bytes).

Run it inside the devcontainer, from the repository root, with deepeval's
source checked out at _ref/deepeval (tag v4.3.1):

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_runner_fixtures.py

`... generate_runner_fixtures.py report` writes only the report fixtures.

See test/fixtures/deepeval/README.md.
"""

import contextlib
import copy
import importlib.util
import io
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CLASSIFIERS = os.path.join(ROOT, "test", "fixtures", "deepeval", "classifiers")
CACHE = os.path.join(ROOT, "test", "fixtures", "deepeval", "cache")
EXPECTATIONS = os.path.join(ROOT, "test", "fixtures", "deepeval", "expectations")
REPORT = os.path.join(ROOT, "test", "fixtures", "deepeval", "report")

# Same fixed hash seed as generate_fixtures.py, which this script imports and
# which would otherwise re-run itself instead of this script.
if sys.flags.hash_randomization:
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    env["PYTHONHASHSEED"] = "0"
    os.execve(
        sys.executable,
        [sys.executable, "-s", "-P", os.path.abspath(__file__), *sys.argv[1:]],
        env,
    )


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# generate_system_one_fixtures.py loads generate_fixtures.py (environment,
# ScriptedJudge, StubMetric) and deepeval's System One fakes.
so = _load(
    "generate_system_one_fixtures", os.path.join(HERE, "generate_system_one_fixtures.py")
)
gf = so.gf
fakes = so.fakes

from deepeval import assert_test, evaluate  # noqa: E402
import deepeval.classifiers as builtins  # noqa: E402
from deepeval.classifiers import (  # noqa: E402
    Classifier,
    Label,
    RequiredDisclosureClassifier,
    ScopeAdherenceClassifier,
    ToneAdherenceClassifier,
)
from deepeval.classifiers.utils import validate_classifiers  # noqa: E402
from deepeval.dataset import Expectations  # noqa: E402
from deepeval.evaluate.expectations import (  # noqa: E402
    _ConversationExpectations,
    _SingleTurnExpectations,
)
from deepeval.evaluate.configs import (  # noqa: E402
    AsyncConfig,
    CacheConfig,
    DisplayConfig,
    ErrorConfig,
)
from deepeval.evaluate.console_report import EvaluationConsoleReport  # noqa: E402
from deepeval.evaluate.types import TestResult  # noqa: E402
from deepeval.test_case import ConversationalTestCase, ToolCall  # noqa: E402
from deepeval.test_run.api import (  # noqa: E402
    Classification,
    ConversationalApiTestCase,
    LLMApiTestCase,
    TurnApi,
)
from deepeval.test_run.cache import (  # noqa: E402
    Cache,
    CachedTestCase,
    CustomEncoder,
    MetricConfiguration,
    TestRunCacheManager,
    global_test_run_cache_manager,
)

# deepeval's package exports an `evaluate` function under the module's name.
expectations_module = sys.modules["deepeval.evaluate.expectations"]
# Likewise `deepeval.test_run.test_run` is shadowed by the TestRun it exports.
test_run_module = sys.modules["deepeval.test_run.test_run"]
from deepeval.tracing.api import MetricData  # noqa: E402
from rich.console import Console  # noqa: E402
from rich.panel import Panel  # noqa: E402
from rich.table import Table  # noqa: E402
from rich.tree import Tree  # noqa: E402

TestRunResultDisplay = test_run_module.TestRunResultDisplay

BUILTINS = {
    builtin(model=fakes.ExplodingLLM()).name: builtin
    for builtin in (
        getattr(builtins, name)
        for name in builtins.__all__
        if name.endswith("Classifier") and name not in ("Classifier", "BaseClassifier")
    )
}


def build_labels(labels):
    """Labels as `Label`s: a string stays a string, {"name", "description"}
    becomes a Label."""
    return [Label(**label) if isinstance(label, dict) else label for label in labels]


def build_classifier(spec, judge, system_one_model):
    params = copy.deepcopy(spec.get("params", {}))
    kind = spec["kind"]
    if kind == "classifier":
        params["labels"] = build_labels(params["labels"])
        cls = Classifier
    else:
        cls = BUILTINS[kind]
    return cls(
        model=judge or fakes.ExplodingLLM(),
        system_one_model=system_one_model,
        eval_mode=spec["eval_mode"],
        **params,
    )


def build_models(scenario):
    """A fresh scripted judge (None without responses), System One fake
    (None without one) and its CannedAnswers."""
    judge = None
    if "responses" in scenario:
        judge = gf.ScriptedJudge(scenario["judge_model"], scenario["responses"])
    model, answers = None, None
    if "system_one" in scenario:
        model, answers = so.build_system_one(scenario["system_one"])
    return judge, model, answers


def build_metric(scenario):
    spec = scenario.get("metric")
    return [gf.build_metric(spec)] if spec else []


def classification_json(classification):
    return classification.model_dump(mode="json", by_alias=True)


def run_classifier_scenario(name, scenario):
    out_dir = os.path.join(CLASSIFIERS, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    cost = so.build_cost(scenario.get("system_one", {}).get("cost"))

    # classify(): the classifier's own state, prompts and decide() calls.
    judge, model, answers = build_models(scenario)
    classifier = build_classifier(scenario["classifier"], judge, model)
    try:
        classifier.classify(gf.build_test_case(scenario["test_case"]), _show_indicator=False)
        raised = None
    except Exception as e:  # noqa: BLE001 - recorded in measure.json
        raised = {"type": type(e).__name__, "message": str(e)}
    gf.write_json(
        os.path.join(out_dir, "measure.json"), {**so.classifier_state(classifier), "raised": raised}
    )
    if judge is not None:
        if raised is None:
            judge.assert_exhausted()
        gf.write_json(os.path.join(out_dir, "prompts.json"), judge.prompts)
    classify_calls = so.decide_calls(model, answers, cost) if model is not None else None
    if answers is not None:
        so.assert_exhausted(scenario["system_one"], answers)

    # evaluate(): the classification it returned, from fresh models.
    judge, model, answers = build_models(scenario)
    classifier = build_classifier(scenario["classifier"], judge, model)
    metrics = build_metric(scenario)
    path, result = so.run_evaluate(
        name,
        gf.build_test_case(scenario["test_case"]),
        metrics=metrics or None,
        classifiers=[classifier],
    )
    [test_result] = result.test_results
    gf.write_json(
        os.path.join(out_dir, "evaluate.json"),
        {
            "success": test_result.success,
            "classifications": [classification_json(c) for c in test_result.classifications],
        },
    )
    if judge is not None and raised is None and judge.prompts != scenario_prompts(out_dir):
        raise RuntimeError(f"{name}: evaluate() sent other prompts than classify()")
    if model is not None:
        evaluate_calls = so.decide_calls(model, answers, cost)
        if evaluate_calls != classify_calls:
            raise RuntimeError(f"{name}: evaluate() sent other decide() calls than classify()")
        gf.write_json(
            os.path.join(out_dir, "decide.json"),
            {"classify": classify_calls, "evaluate": evaluate_calls},
        )
    if metrics:
        shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))
    elif path is not None:
        raise RuntimeError(f"{name}: a classifiers-only evaluate() wrote a test run")

    if scenario.get("assert_test"):
        judge, model, _answers = build_models(scenario)
        classifier = build_classifier(scenario["classifier"], judge, model)
        try:
            assert_test(
                gf.build_test_case(scenario["test_case"]),
                build_metric(scenario) or None,
                classifiers=[classifier],
            )
            raised = None
        except Exception as e:  # noqa: BLE001 - recorded
            raised = {"type": type(e).__name__, "message": str(e)}
        gf.write_json(os.path.join(out_dir, "assert_test.json"), {"raised": raised})


def scenario_prompts(out_dir):
    with open(os.path.join(out_dir, "prompts.json"), encoding="utf-8") as f:
        return json.load(f)


def label_json(label):
    return {"name": label.name, "description": label.description}


def write_builtins():
    """Every built-in's name and labels; those with a parameter also with it."""
    with_params = {
        "scope_adherence": [{"scope": "billing questions"}],
        "tone_adherence": [{"tone": "friendly and concise"}],
        "required_disclosure": [{"disclosures": ["an AI disclosure", "a link to the terms"]}],
    }
    out = []
    for kind, cls in BUILTINS.items():
        for params in [{}] + with_params.get(kind, []):
            classifier = cls(model=fakes.ExplodingLLM(), **params)
            out.append({
                "kind": kind,
                "params": params,
                "name": classifier.name,
                "labels": [label_json(label) for label in classifier.labels],
            })
    out_dir = os.path.join(CLASSIFIERS, "builtins")
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "builtins.json"), out)
    # Only the three above take a parameter.
    assert {ScopeAdherenceClassifier, ToneAdherenceClassifier, RequiredDisclosureClassifier} <= set(
        BUILTINS.values()
    )


class _Records(logging.Handler):
    def __init__(self):
        super().__init__()
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


def run_validation_case(case):
    """`Classifier(...)` or `validate_classifiers(...)`: what it raised, or
    the warnings it logged."""
    handler = _Records()
    logger = logging.getLogger("deepeval.classifiers.utils")
    logger.addHandler(handler)
    try:
        if case["kind"] == "classifier":
            Classifier(
                name=case["name"], labels=build_labels(case["labels"]), model=fakes.ExplodingLLM()
            )
        else:
            classifiers = [
                Classifier(
                    name=c["name"], labels=build_labels(c["labels"]), model=fakes.ExplodingLLM()
                )
                for c in case["classifiers"]
            ]
            test_cases = [
                gf.build_test_case({"input": "Q", "actual_output": "A", "expected_labels": labels})
                for labels in case["expected_labels"]
            ]
            validate_classifiers(test_cases, classifiers)
        raised = None
    except Exception as e:  # noqa: BLE001 - recorded
        raised = {"type": type(e).__name__, "message": str(e)}
    finally:
        logger.removeHandler(handler)
    return {**case, "raised": raised, "warnings": handler.messages}


VALIDATION_CASES = [
    {"description": "no labels", "kind": "classifier", "name": "c", "labels": []},
    {"description": "a blank label name", "kind": "classifier", "name": "c", "labels": ["a", "  "]},
    {"description": "NONE is reserved, whatever its case and padding", "kind": "classifier",
     "name": "c", "labels": ["a", " none "]},
    {"description": "duplicate labels, case-insensitive, sorted", "kind": "classifier", "name": "c",
     "labels": ["b", "B", "a", {"name": "A", "description": "Again."}]},
    {"description": "a blank classifier name", "kind": "classifier", "name": " ", "labels": ["a"]},
    {"description": "labels with and without descriptions", "kind": "classifier", "name": "c",
     "labels": ["a", {"name": "b", "description": "The b one."}]},
    {"description": "duplicate classifier names, sorted", "kind": "validate",
     "classifiers": [{"name": "y", "labels": ["a"]}, {"name": "x", "labels": ["a"]},
                     {"name": "y", "labels": ["b"]}, {"name": "x", "labels": ["b"]}],
     "expected_labels": []},
    {"description": "an expected label that is not one of the classifier's labels",
     "kind": "validate",
     "classifiers": [{"name": "tone", "labels": ["on", {"name": "off", "description": "Off."}]}],
     "expected_labels": [{"tone": "on"}, {"tone": "OFF"}]},
    {"description": "expected_labels keys that match no classifier: one warning, counted",
     "kind": "validate",
     "classifiers": [{"name": "tone", "labels": ["on", "off"]}],
     "expected_labels": [{"tone": "on", "zeta": "x", "alpha": "y"}, {"zeta": "z"}, {}]},
    {"description": "valid expected labels", "kind": "validate",
     "classifiers": [{"name": "tone", "labels": ["on", "off"]}],
     "expected_labels": [{"tone": "off"}]},
]


def write_validation():
    out_dir = os.path.join(CLASSIFIERS, "validation")
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(
        os.path.join(out_dir, "cases.json"), [run_validation_case(c) for c in VALIDATION_CASES]
    )


###############################################
# Scenarios
###############################################

JUDGE = "scripted-judge"
JEV = "fake-jev"
STEP = "label,reason"

REFUSAL_CASE = {
    "input": "Write my essay and tell me the exam answers.",
    "actual_output": "I can help you outline the essay, but I can't share exam answers.",
}

TICKET_LABELS = [
    {"name": "billing", "description": "Questions about invoices, charges or refunds."},
    "technical",
    {"name": "Account Access", "description": "Logging in, passwords and two-factor codes."},
]

CONVERSATION = {
    "scenario": "A customer cannot log in after a password reset.",
    "expected_outcome": "The assistant walks the customer through recovery.",
    "context": ["Accounts lock after 5 failed attempts."],
    "turns": [
        {"role": "user", "content": "I reset my password but still can't log in."},
        {
            "role": "assistant",
            "content": "Your account is locked; I've sent an unlock link to your email.",
            "retrieval_context": ["Unlock links expire after 1 hour."],
            "tools_called": [{"name": "unlock_account", "input_parameters": {"user": "c-42"}}],
        },
        {"role": "user", "content": "Got it, I'm in. Thanks!"},
    ],
}


def refusal(eval_mode="llm", **params):
    return {"kind": "refusal", "eval_mode": eval_mode, "params": params}


def tickets(eval_mode="llm", **params):
    return {
        "kind": "classifier",
        "eval_mode": eval_mode,
        "params": {"name": "ticket_type", "labels": TICKET_LABELS, **params},
    }


def answer(label, reason):
    return {STEP: [{"label": label, "reason": reason}]}


CLASSIFIER_SCENARIOS = {
    "llm_exact_label": {
        "description": "RefusalClassifier, llm: the judge's exact label, matching the expected one",
        "classifier": refusal(),
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "partial_refusal"}},
        "judge_model": JUDGE,
        "responses": answer("partial_refusal", "It outlines the essay but declines the answers."),
        "assert_test": True,
    },
    "llm_case_insensitive": {
        "description": "A label in another case resolves to the declared one; the wrong expected label fails",
        "classifier": refusal(),
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "complied"}},
        "judge_model": JUDGE,
        "responses": answer("  PARTIAL_REFUSAL ", "Declines part of it."),
        "assert_test": True,
    },
    "llm_no_expected_label": {
        "description": "No expected label: no verdict, so the test case has none either",
        "classifier": refusal(include_reason=False),
        "test_case": REFUSAL_CASE,
        "judge_model": JUDGE,
        "responses": answer("refused", "Declines everything."),
        "assert_test": True,
    },
    "llm_none_allowed": {
        "description": "allow_none: the judge declines (NONE), no label and no error; the expected label fails",
        "classifier": tickets(allow_none=True),
        "test_case": {
            "input": "What's the weather like?",
            "actual_output": "Sunny, 24C.",
            "expected_labels": {"ticket_type": "technical"},
        },
        "judge_model": JUDGE,
        "responses": answer("none", "Not a support ticket."),
    },
    "llm_none_disallowed": {
        "description": "NONE without allow_none is an undeclared label: an error",
        "classifier": tickets(),
        "test_case": {
            "input": "What's the weather like?",
            "actual_output": "Sunny, 24C.",
            "expected_labels": {"ticket_type": "technical"},
        },
        "judge_model": JUDGE,
        "responses": answer("NONE", "Not a support ticket."),
        "assert_test": True,
    },
    "llm_undeclared_label": {
        "description": "An undeclared label with allow_none: an error naming the declared labels",
        "classifier": tickets(allow_none=True),
        "test_case": {
            "input": "My card was charged twice.",
            "actual_output": "I've refunded the duplicate charge.",
            "expected_labels": {"ticket_type": "billing"},
        },
        "judge_model": JUDGE,
        "responses": answer("payments", "About a charge."),
    },
    "llm_raw_text": {
        "description": "A judge without structured outputs: its text is loaded with trimAndLoadJson",
        "classifier": tickets(),
        "test_case": {
            "input": "I can't log in.",
            "actual_output": "Try resetting your password.",
            "context": ["Password resets are self-service."],
            "retrieval_context": ["Reset at /account/reset.", "It's free."],
            "expected_output": "Points to the reset page.",
            "tools_called": [{"name": "lookup_account", "input_parameters": {"email": "a@b.c"}}],
            "expected_labels": {"ticket_type": "Account Access"},
        },
        "judge_model": JUDGE,
        "responses": {STEP: ['```json\n{"label": "account access", "reason": "Login trouble.",}\n```']},
    },
    "llm_invalid_json": {
        "description": "Text holding no JSON: classify() raises, evaluate() records the error",
        "classifier": refusal(),
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "refused"}},
        "judge_model": JUDGE,
        "responses": {STEP: ["I think it refused."]},
        "assert_test": True,
    },
    "llm_multi_turn": {
        "description": "A conversation: the multi-turn prompt with its scenario, context and turns",
        "classifier": {"kind": "resolution", "eval_mode": "llm", "params": {}},
        "test_case": {**CONVERSATION, "expected_labels": {"resolution": "resolved"}},
        "judge_model": JUDGE,
        "responses": answer("resolved", "The customer got back in."),
    },
    "llm_multi_turn_allow_none": {
        "description": "A conversation with turns only, allow_none",
        "classifier": tickets(allow_none=True),
        "test_case": {"turns": CONVERSATION["turns"]},
        "judge_model": JUDGE,
        "responses": answer("Account Access", "Login trouble."),
    },
    "llm_with_metric": {
        "description": "A metric and a failing classifier: the test result fails, the test run does not",
        "classifier": refusal(),
        "metric": gf.STUB_JUDGE,
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "refused"}},
        "judge_model": JUDGE,
        "responses": answer("partial_refusal", "Declines part of it."),
        "assert_test": True,
    },
    "llm_with_failing_metric": {
        "description": "A failing metric and a failing classifier: assert_test names both",
        "classifier": refusal(),
        "metric": gf.STRICT_JUDGE,
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "refused"}},
        "judge_model": JUDGE,
        "responses": answer("partial_refusal", "Declines part of it."),
        "assert_test": True,
    },
    "system_one_single_turn_allow_none": {
        "description": "Jev, allow_none: one Choice over the labels plus NONE; NONE is no label",
        "classifier": tickets("system_one", allow_none=True),
        "test_case": {
            "input": "What's the weather like?",
            "actual_output": "Sunny, 24C.",
            "tools_called": [{"name": "weather", "input_parameters": {"city": "Paris"}}],
            "expected_labels": {"ticket_type": "technical"},
        },
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": {"choices": {"label": so.choice(
            "NONE",
            {"billing": 0.05, "technical": 0.1, "Account Access": 0.05, "NONE": 0.8},
            0.7,
        )}}},
    },
    "system_one_multi_turn": {
        "description": "Jev on a conversation: turns and the conversation's fields as state",
        "classifier": {"kind": "resolution", "eval_mode": "system_one", "params": {}},
        "test_case": {**CONVERSATION, "expected_labels": {"resolution": "resolved"}},
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": {"choices": {"label": so.choice(
            "resolved", {"resolved": 0.9, "unresolved": 0.04, "handed_over": 0.06}, 0.85,
        )}}},
    },
    "system_one_no_reason": {
        "description": "Jev with include_reason=False: no reason; hybrid runs as llm, here system_one",
        "classifier": refusal("system_one", include_reason=False),
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "refused"}},
        "system_one": {"model": JEV, "answers": {"choices": {"label": so.choice(
            "refused", {"complied": 0.1, "refused": 0.9}, 0.8,
        )}}},
    },
    "system_one_down": {
        "description": "Jev down: classify() raises, nothing falls back to the LLM",
        "classifier": refusal("system_one"),
        "test_case": {**REFUSAL_CASE, "expected_labels": {"refusal": "refused"}},
        "system_one": so.DOWN,
    },
}


###############################################
# Expectations
###############################################

_initialize_system_one_model = expectations_module.initialize_system_one_model


class system_one_default:
    """Within it, the System One model the expectation evaluator builds by
    default (`initialize_system_one_model(None, mode)`) is `model`: the
    evaluator takes no System One model argument, so this is how the fake
    gets in."""

    def __init__(self, model):
        self.model = model

    def __enter__(self):
        def initialize(model, eval_mode=None):
            if self.model is not None and str(eval_mode) == "system_one":
                return self.model
            return _initialize_system_one_model(model, eval_mode)

        expectations_module.initialize_system_one_model = initialize

    def __exit__(self, *exc):
        expectations_module.initialize_system_one_model = _initialize_system_one_model


def build_expectations_case(spec, judge):
    """The scenario's test case, its expectations judged by `judge` (a
    ScriptedJudge, or None for the default model)."""
    spec = copy.deepcopy(spec)
    expectations = spec.pop("expectations", None)
    test_case = gf.build_test_case(spec)
    if expectations is not None:
        test_case.expectations = Expectations(**{"model": judge, **expectations})
    return test_case


def build_expectation_models(scenario, prefix=""):
    judge = None
    if "responses" in scenario:
        judge = gf.ScriptedJudge(scenario["judge_model"], scenario["responses"])
    model, answers = None, None
    if "system_one" in scenario:
        model, answers = so.build_system_one(scenario["system_one"], prefix)
    return judge, model, answers


def build_expectation_metrics(scenario, model):
    metrics = []
    for spec in scenario.get("metrics", []):
        if spec["kind"] in so.METRICS:
            metrics.append(so.build_metric(spec, model, fakes.ExplodingLLM()))
        else:
            metrics.append(gf.build_metric(spec))
    return metrics


def evaluator_state(evaluator):
    return {
        "score": evaluator.score,
        "success": evaluator.success,
        "reason": evaluator.reason,
        "threshold": evaluator.threshold,
        "strict_mode": evaluator.strict_mode,
        "error": evaluator.error,
        "evaluation_model": evaluator.evaluation_model,
        "evaluation_cost": evaluator.evaluation_cost,
        "input_tokens": evaluator.input_tokens,
        "output_tokens": evaluator.output_tokens,
        "verbose_logs": evaluator.verbose_logs,
        "verdicts": (
            [v.model_dump() for v in evaluator.verdicts] if evaluator.verdicts is not None else None
        ),
        "criteria": evaluator.criteria,
        "confidence": getattr(evaluator, "confidence", None),
    }


def metric_data_json(metric_data):
    return metric_data.model_dump(mode="json", by_alias=True, exclude_none=True)


def run_expectation_scenario(name, scenario):
    out_dir = os.path.join(EXPECTATIONS, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    cost = so.build_cost(scenario.get("system_one", {}).get("cost"))
    # In evaluate(), the evaluator follows the metrics: its questions are
    # m<j>. when batched with theirs.
    batched = scenario.get("batched", False)
    prefix = f"m{len(scenario.get('metrics', []))}." if batched else ""

    # measure(): the evaluator's own state, prompts and decide() calls.
    judge, model, answers = build_expectation_models(scenario, prefix)
    test_case = build_expectations_case(scenario["test_case"], judge)
    cls = (
        _ConversationExpectations
        if isinstance(test_case, ConversationalTestCase)
        else _SingleTurnExpectations
    )
    with system_one_default(model):
        evaluator = cls(test_case.expectations)
    try:
        evaluator.measure(test_case)
        raised = None
    except Exception as e:  # noqa: BLE001 - recorded in measure.json
        raised = {"type": type(e).__name__, "message": str(e)}
    gf.write_json(
        os.path.join(out_dir, "measure.json"), {**evaluator_state(evaluator), "raised": raised}
    )
    if judge is not None:
        judge.assert_exhausted()
        gf.write_json(os.path.join(out_dir, "prompts.json"), judge.prompts)
    measure_calls = so.decide_calls(model, answers, cost) if model is not None else None
    canned = [answers] if answers is not None else []

    # evaluate(): the test result and test run, from fresh models.
    judge, model, answers = build_expectation_models(scenario)
    metrics = build_expectation_metrics(scenario, model)
    with system_one_default(model):
        path, result = so.run_evaluate(
            name,
            build_expectations_case(scenario["test_case"], judge),
            metrics=metrics or None,
        )
    [test_result] = result.test_results
    gf.write_json(
        os.path.join(out_dir, "evaluate.json"),
        {
            "success": test_result.success,
            "metrics_data": [metric_data_json(m) for m in test_result.metrics_data or []],
        },
    )
    if judge is not None and judge.prompts != scenario_prompts(out_dir):
        raise RuntimeError(f"{name}: evaluate() sent other prompts than measure()")
    if model is not None:
        evaluate_calls = so.decide_calls(model, answers, cost)
        if answers is not None:
            canned.append(answers)
            so.assert_exhausted(scenario["system_one"], *canned)
        if not batched and evaluate_calls != measure_calls:
            raise RuntimeError(f"{name}: evaluate() sent other decide() calls than measure()")
        if batched and len(evaluate_calls) != 1:
            raise RuntimeError(f"{name}: expected one batched decide() call")
        gf.write_json(
            os.path.join(out_dir, "decide.json"),
            {"measure": measure_calls, "evaluate": evaluate_calls},
        )
    shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))

    if scenario.get("assert_test"):
        judge, model, _answers = build_expectation_models(scenario)
        metrics = build_expectation_metrics(scenario, model)
        try:
            with system_one_default(model):
                assert_test(
                    build_expectations_case(scenario["test_case"], judge), metrics or None
                )
            raised = None
        except Exception as e:  # noqa: BLE001 - recorded
            raised = {"type": type(e).__name__, "message": str(e)}
        gf.write_json(os.path.join(out_dir, "assert_test.json"), {"raised": raised})


def run_coverage_case(case):
    """`evaluate()` or `assert_test()` without metrics or classifiers: what
    `validate_expectation_coverage` raised."""
    test_cases = [build_expectations_case(spec, None) for spec in case["test_cases"]]
    try:
        if case["kind"] == "evaluate":
            evaluate(test_cases=test_cases, metrics=None)
        else:
            assert_test(test_cases[0], None)
        raised = None
    except Exception as e:  # noqa: BLE001 - recorded
        raised = {"type": type(e).__name__, "message": str(e)}
    return {**case, "raised": raised}


COVERAGE_CASES = [
    {"description": "evaluate() without test cases", "kind": "evaluate", "test_cases": []},
    {"description": "evaluate(): one test case of two without expectations", "kind": "evaluate",
     "test_cases": [{"input": "Q", "actual_output": "A", "expectations": {"must": ["Answers."]}},
                    {"input": "Q", "actual_output": "A"}]},
    {"description": "evaluate(): two test cases without (empty) expectations", "kind": "evaluate",
     "test_cases": [{"input": "Q", "actual_output": "A", "expectations": {}},
                    {"input": "Q", "actual_output": "A"}]},
    {"description": "assert_test() of a test case without expectations", "kind": "assert_test",
     "test_cases": [{"input": "Q", "actual_output": "A"}]},
]


def write_coverage():
    out_dir = os.path.join(EXPECTATIONS, "validation")
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(
        os.path.join(out_dir, "cases.json"), [run_coverage_case(c) for c in COVERAGE_CASES]
    )


REFUND_CASE = {
    "input": "Can I get a refund on a used ticket?",
    "actual_output": "Used tickets can't be refunded, but you can exchange it within 30 days.",
    "retrieval_context": [
        "Used tickets are non-refundable.",
        {"context": "Exchanges are free within 30 days.", "source": "policy.md"},
    ],
    "tools_called": [{"name": "lookup_policy", "input_parameters": {"topic": "refunds"}}],
    "metadata": {"channel": "chat", "priority": None},
    "tags": ["refunds"],
}

REFUND_MUST = ["States the refund policy", "Offers the café exchange"]
REFUND_MUST_NOT = ["Promises a refund"]


def refund(eval_mode="llm", **case):
    return {
        **REFUND_CASE,
        **case,
        "expectations": {"must": REFUND_MUST, "must_not": REFUND_MUST_NOT, "eval_mode": eval_mode},
    }


VERDICTS_STEP = "verdicts"
REASON_STEP = "reason"


def verdict(id, status, reason, evidence=""):
    return {"id": id, "status": status, "reason": reason, "evidence": evidence}


def judged(verdicts, reason=None):
    responses = {VERDICTS_STEP: [{"verdicts": verdicts}]}
    if reason is not None:
        responses[REASON_STEP] = [{"reason": reason}]
    return responses


ALL_PASS = [
    verdict("must[0]", "pass", "It says used tickets can't be refunded.", "Used tickets can't be refunded"),
    verdict("must[1]", "pass", "It offers an exchange.", "exchange it within 30 days"),
    verdict("must_not[0]", "pass", "No refund is promised."),
]

ONE_FAILS = [
    verdict("must_not[0]", "fail", "It promises a refund.", "you'll get a refund"),
    verdict("must[0]", "pass", "It states the policy.", "can't be refunded"),
    verdict("must[1]", "fail", "No exchange is offered."),
]

def judge_choice(label, p_pass, p_fail, p_unable, confidence):
    return so.choice(label, {"pass": p_pass, "fail": p_fail, "unable_to_evaluate": p_unable}, confidence)


EXPECTATION_SCENARIOS = {
    "llm_all_pass": {
        "description": "Every condition holds: score 1, the reason call, a test run without metrics",
        "test_case": refund(),
        "judge_model": JUDGE,
        "responses": judged(ALL_PASS, "The score is 1.0 because it states the policy and offers an exchange."),
        "assert_test": True,
    },
    "llm_one_fails": {
        "description": "Verdicts out of order, two fail: score 0; assert_test names Expectations",
        "test_case": {**refund(), "name": "refund answer"},
        "judge_model": JUDGE,
        "responses": judged(ONE_FAILS, "The score is 0.0 because it promises a refund."),
        "metrics": [gf.STUB_JUDGE],
        "assert_test": True,
    },
    "llm_unable_to_evaluate": {
        "description": "unable_to_evaluate: measure() raises, evaluate() records the error and verdicts",
        "test_case": refund(),
        "judge_model": JUDGE,
        "responses": judged([
            verdict("must[0]", "pass", "It states the policy."),
            verdict("must[1]", "unable_to_evaluate", "The exchange tool output is missing."),
            verdict("must_not[0]", "pass", "No refund is promised."),
        ]),
        "metrics": [gf.STUB_JUDGE],
        "assert_test": True,
    },
    "llm_unknown_ids": {
        "description": "A duplicate verdict id: measure() raises before the reason call",
        "test_case": {"input": "Hi", "actual_output": "Hello!",
                      "expectations": {"must": ["Greets the user"], "must_not": []}},
        "judge_model": JUDGE,
        "responses": judged([
            verdict("must[0]", "pass", "It greets."),
            verdict("must[0]", "pass", "It greets again."),
        ]),
    },
    "llm_raw_text": {
        "description": "A judge without structured outputs: trimAndLoadJson loads both answers",
        "test_case": {"input": "Hi", "actual_output": "Hello!", "context": ["Be polite."],
                      "expectations": {"must": ["Greets the user"]}},
        "judge_model": JUDGE,
        "responses": {
            VERDICTS_STEP: ['```json\n{"verdicts": [{"id": "must[0]", "status": "pass", '
                            '"reason": "It greets.", "evidence": "Hello!"},]}\n```'],
            REASON_STEP: ['{"reason": "The score is 1.0 because it greets."}'],
        },
    },
    "llm_conversation": {
        "description": "A conversation: turns, scenario, chatbot role and tags as the observed case",
        "test_case": {
            **CONVERSATION,
            "chatbot_role": "A support agent",
            "tags": ["login"],
            "expectations": {"must": ["Unlocks the account"], "must_not": ["Asks for the password"]},
        },
        "judge_model": JUDGE,
        "responses": judged(
            [verdict("must[0]", "pass", "It sends an unlock link.", "unlock_account"),
             verdict("must_not[0]", "pass", "No password is asked for.")],
            "The score is 1.0 because the account was unlocked.",
        ),
        "assert_test": True,
    },
    "system_one_pass": {
        "description": "Jev: one Choice per condition with the observed case as state; strict score 1",
        "test_case": refund("system_one"),
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": {"choices": {
            "q_0": judge_choice("pass", 0.9, 0.08, 0.02, 0.85),
            "q_1": judge_choice("pass", 0.7, 0.25, 0.05, 0.55),
            "q_2": judge_choice("pass", 0.95, 0.04, 0.01, 0.9),
        }}},
        "assert_test": True,
    },
    "system_one_fails": {
        "description": "Jev: a must_not condition fails, strict score 0",
        "test_case": {**refund("system_one"), "name": "refund answer"},
        "system_one": {"model": JEV, "answers": {"choices": {
            "q_0": judge_choice("pass", 0.9, 0.08, 0.02, 0.85),
            "q_1": judge_choice("pass", 0.6, 0.3, 0.1, 0.4),
            "q_2": judge_choice("fail", 0.2, 0.75, 0.05, 0.6),
        }}},
        "metrics": [gf.STUB_JUDGE],
        "assert_test": True,
    },
    "system_one_unable_to_evaluate": {
        "description": "Jev: unable_to_evaluate wins a Choice, measure() raises with the reason",
        "test_case": refund("system_one"),
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": {"choices": {
            "q_0": judge_choice("pass", 0.9, 0.08, 0.02, 0.85),
            "q_1": judge_choice("unable_to_evaluate", 0.2, 0.1, 0.7, 0.5),
            "q_2": judge_choice("pass", 0.95, 0.04, 0.01, 0.9),
        }}},
        "assert_test": True,
    },
    "system_one_conversation": {
        "description": "Jev on a conversation: its turns and fields as the observed case",
        "test_case": {
            **CONVERSATION,
            "expectations": {"must": ["Unlocks the account"], "eval_mode": "system_one"},
        },
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": {"choices": {
            "q_0": judge_choice("pass", 0.9, 0.05, 0.05, 0.85),
        }}},
    },
    "system_one_batched": {
        "description": "Jev with a system_one Faithfulness: evaluate() asks both in one request",
        "batched": True,
        "test_case": refund("system_one"),
        "metrics": [{"kind": "faithfulness", "eval_mode": "system_one"}],
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2001, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": so.noul(0.8), "m0.q_1": so.noul(0.1)},
                           "scores": {"m0.q_2": so.score(3, so.FOUR_LEVELS_HIGH, 0.7)},
                           "choices": {
                               "m1.q_0": judge_choice("pass", 0.9, 0.08, 0.02, 0.85),
                               "m1.q_1": judge_choice("pass", 0.7, 0.25, 0.05, 0.55),
                               "m1.q_2": judge_choice("pass", 0.95, 0.04, 0.01, 0.9),
                           },
                       }},
    },
    "system_one_down": {
        "description": "Jev down: measure() raises, nothing falls back to the LLM",
        "test_case": refund("system_one"),
        "system_one": so.DOWN,
    },
}


# The test-run cache (test_run/cache.py): `.deepeval/.deepeval-cache.json`,
# keyed by `serialize()` of the test case's fields and the run's
# hyperparameters, each key holding the error-free metric data and
# classifications of the run that wrote it with their configurations.


def cache_key(test_case, hyperparameters):
    """The key deepeval's cache manager files `test_case` under, from a
    manager writing to a scratch folder; looking it up again must hit."""
    folder = tempfile.mkdtemp(prefix="cache_key_", dir=gf.WORK_DIR)
    manager = TestRunCacheManager()
    manager.cache_file_name = os.path.join(folder, "cache.json")
    manager.temp_cache_file_name = os.path.join(folder, "temp.json")
    manager.disable_write_cache = False
    manager.cache_test_case(test_case, CachedTestCase(), hyperparameters)
    [key] = manager.get_cached_test_run().test_cases_lookup_map
    if manager.get_cached_test_case(test_case, hyperparameters) is None:
        raise RuntimeError(f"no hit for {key!r}")
    return key


KEY_CASES = [
    {"description": "input and actual output only", "test_case": {"input": "Q", "actual_output": "A"}},
    {
        "description": "every keyed field, non-ASCII text and unsorted lists",
        "test_case": {
            "input": "Où est le café? \U0001f600",
            "actual_output": "Line one\nline \"two\"\t\\ end",
            "expected_output": "Ici.",
            "context": ["b context", "a context", "C context"],
            "retrieval_context": ["z", "y", "é"],
            "name": "not keyed",
            "tags": ["not", "keyed"],
        },
    },
    {
        "description": "RetrievedContextData flattened to its context, mixed with strings",
        "test_case": {
            "input": "Q",
            "actual_output": "A",
            "retrieval_context": [
                {"context": "Section 3.2: 20 days.", "source": "hr.pdf"},
                "Section 1: scope.",
            ],
        },
    },
    {
        "description": "hyperparameters as log_hyperparameters stores them",
        "test_case": {"input": "Q", "actual_output": "A"},
        "hyperparameters": {"model": "gpt-4o", "temperature": "0.7", "k": "5"},
    },
    {
        "description": "nested hyperparameters: dicts sorted, lists sorted by their JSON",
        "test_case": {"input": "Q", "actual_output": "A"},
        "hyperparameters": {
            "b": [3, 1, {"z": 1, "a": [2, 1]}, "x", None, 2.5],
            "a": {"y": 0.1, "x": None, "w": True},
            "c": 1e-05,
        },
    },
    {
        "description": "expectations and their evidence",
        "test_case": {
            **REFUND_CASE,
            "expectations": {"must": REFUND_MUST, "must_not": REFUND_MUST_NOT},
        },
    },
    {
        "description": "expectations with a model name and an eval mode",
        "test_case": {
            "input": "Q",
            "actual_output": "A",
            "expectations": {"must": ["Answers."], "model": "gpt-4o", "eval_mode": "system_one"},
        },
    },
    {
        "description": "empty expectations are not keyed",
        "test_case": {"input": "Q", "actual_output": "A", "expectations": {}},
    },
]


def write_keys():
    out = []
    for case in KEY_CASES:
        test_case = build_expectations_case(case["test_case"], None)
        out.append({**case, "key": cache_key(test_case, case.get("hyperparameters"))})
    out_dir = os.path.join(CACHE, "keys")
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "keys.json"), out)


def config_json(configuration):
    """A MetricConfiguration as CachedTestRun.save writes it."""
    return json.dumps(
        configuration.model_dump(by_alias=True, exclude_none=True), cls=CustomEncoder
    )


def scripted_scenarios():
    return sorted(
        name
        for name in os.listdir(gf.SCRIPTED)
        if os.path.isfile(os.path.join(gf.SCRIPTED, name, "script.json"))
    )


def load_script(name):
    with open(os.path.join(gf.SCRIPTED, name, "script.json"), encoding="utf-8") as f:
        return json.load(f)


def write_configurations():
    """create_metric_configuration of every scripted scenario's metric before
    and after measure() (what evaluate() stores), and same_metric_configs of
    each fresh metric against every stored configuration of its kind."""
    entries = []
    for name in scripted_scenarios():
        script = load_script(name)
        if "turns" in script["test_case"]:
            # Conversational test cases are never cached (and deepeval cannot
            # build a MetricConfiguration of MultiTurnParams).
            continue
        metric, _judge = gf.build_scripted_metric(script)
        before = config_json(Cache.create_metric_configuration(metric))
        try:
            metric.measure(gf.build_test_case(script["test_case"]), _show_indicator=False)
            stored = metric.error is None
        except Exception:  # noqa: BLE001 - an errored metric is not stored
            stored = False
        after = config_json(Cache.create_metric_configuration(metric)) if stored else None
        entries.append(
            {"scenario": name, "kind": script["metric"]["kind"], "before": before, "after": after}
        )

    same = []
    for entry in entries:
        for cached in entries:
            if cached["kind"] != entry["kind"] or cached["after"] is None:
                continue
            metric, _judge = gf.build_scripted_metric(load_script(entry["scenario"]))
            configuration = MetricConfiguration.model_validate(json.loads(cached["after"]))
            same.append({
                "metric": entry["scenario"],
                "cached": cached["scenario"],
                "same": Cache.same_metric_configs(metric, configuration),
            })

    # The System One scenarios' (single-turn, unbatched) metrics: their
    # evaluation_model is the System One model's name under system_one.
    system_one = []
    for name in sorted(os.listdir(so.SYSTEM_ONE)):
        path = os.path.join(so.SYSTEM_ONE, name, "input.json")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            scenario = json.load(f)
        if "metrics" not in scenario or scenario.get("batched") or "turns" in scenario["test_case"]:
            continue
        [spec] = scenario["metrics"]
        model, _answers = so.build_system_one(scenario["system_one"])
        metric = so.build_metric(spec, model, so.build_judge(scenario, spec["kind"]))
        system_one.append(
            {"scenario": name, "before": config_json(Cache.create_metric_configuration(metric))}
        )

    out_dir = os.path.join(CACHE, "configurations")
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(
        os.path.join(out_dir, "configurations.json"),
        {"metrics": entries, "same": same, "system_one": system_one},
    )


# The metrics a cache run measured (cache hits are not measured).
MEASURED = []


class CacheStubMetric(gf.StubMetric):
    """StubMetric whose judge model is set when it is built, as every LLM
    metric's is, so a lookup (made before measuring) can match the stored
    configuration's `evaluation_model`; it logs every measure. Mirrored by
    DeepEvalEx.Test.ParityMetrics.CacheStub."""

    def __init__(self, name, fixed_score, fixed_reason, threshold, fixed_model,
                 fixed_cost, fixed_input_tokens, fixed_output_tokens):
        super().__init__(name, fixed_score, fixed_reason, threshold, fixed_model,
                         fixed_cost, fixed_input_tokens, fixed_output_tokens)
        self.evaluation_model = fixed_model

    def measure(self, test_case, *args, **kwargs):
        MEASURED.append(self.name)
        return super().measure(test_case)


class CacheErrorMetric(gf.ErrorMetric):
    """ErrorMetric that logs every measure."""

    def measure(self, test_case, *args, **kwargs):
        MEASURED.append(self.name)
        return super().measure(test_case)


def cache_stub(name, score, threshold=0.5, model="gpt-4o-mini", cost=0.000321):
    return {
        "kind": "cache_stub", "name": name, "score": score, "reason": f"{name} reason.",
        "threshold": threshold, "evaluation_model": model, "evaluation_cost": cost,
        "input_tokens": 120, "output_tokens": 12,
    }


def build_cache_metric(spec, model):
    kind = spec["kind"]
    if kind == "cache_stub":
        return CacheStubMetric(
            spec["name"], spec["score"], spec["reason"], spec["threshold"],
            spec["evaluation_model"], spec["evaluation_cost"],
            spec["input_tokens"], spec["output_tokens"],
        )
    if kind == "error":
        return CacheErrorMetric(spec["name"], spec["threshold"], spec["exception"], spec["message"])
    if kind in so.METRICS:
        return so.build_metric(spec, model, fakes.ExplodingLLM())
    return gf.build_metric(spec)


def reset_cache_manager():
    """A fresh cache manager, as a new process starts with."""
    global_test_run_cache_manager.cached_test_run = None
    global_test_run_cache_manager.temp_cached_test_run = None
    global_test_run_cache_manager.disable_write_cache = None


CACHE_FILES = [".deepeval-cache.json", ".temp-deepeval-cache.json"]


def run_cache_run(run, run_dir):
    reset_cache_manager()
    MEASURED.clear()
    # The same judge (by name) in every run, so cached classifications and
    # expectations match; one without responses raises when called.
    judge = gf.ScriptedJudge(JUDGE, run.get("responses", {}))
    model, answers = (None, None)
    if "system_one" in run:
        model, answers = so.build_system_one(run["system_one"])
    metrics = [build_cache_metric(spec, model) for spec in run.get("metrics", [])]
    classifiers = [
        build_classifier(spec, judge, model) for spec in run.get("classifiers", [])
    ]
    test_cases = [build_expectations_case(spec, judge) for spec in run["test_cases"]]
    results_folder = tempfile.mkdtemp(prefix="cache_run_", dir=gf.WORK_DIR)
    try:
        result = evaluate(
            test_cases=test_cases,
            metrics=metrics or None,
            classifiers=classifiers or None,
            async_config=AsyncConfig(run_async=True, max_concurrent=run.get("max_concurrent", 20)),
            display_config=DisplayConfig(
                show_indicator=False,
                print_results=False,
                inspect_after_run=False,
                results_folder=results_folder,
            ),
            cache_config=CacheConfig(
                write_cache=run.get("write_cache", True), use_cache=run.get("use_cache", False)
            ),
            error_config=ErrorConfig(ignore_errors=True),
        )
        raised = None
    except Exception as e:  # noqa: BLE001 - recorded in run.json
        result, raised = None, {"type": type(e).__name__, "message": str(e)}
    paths = [
        os.path.join(results_folder, f)
        for f in os.listdir(results_folder)
        if f.startswith("test_run_")
    ]
    if paths:
        [path] = paths
        shutil.copyfile(path, os.path.join(run_dir, "test_run.json"))
    files = [f for f in CACHE_FILES if os.path.exists(os.path.join(".deepeval", f))]
    if ".deepeval-cache.json" in files:
        shutil.copyfile(
            os.path.join(".deepeval", ".deepeval-cache.json"),
            os.path.join(run_dir, "cache.json"),
        )
    if raised is None:
        judge.assert_exhausted()
    out = {
        "files": files,
        "measured": sorted(MEASURED),
        "raised": raised,
        "test_results": None if result is None else [
            {
                "success": test_result.success,
                "metrics_data": [
                    metric_data_json(m) for m in (test_result.metrics_data or [])
                ],
                "classifications": [
                    classification_json(c) for c in (test_result.classifications or [])
                ],
            }
            for test_result in result.test_results
        ],
    }
    if model is not None:
        out["decide"] = so.decide_calls(model, answers, so.build_cost(run["system_one"].get("cost")))
        so.assert_exhausted(run["system_one"], answers)
    gf.write_json(os.path.join(run_dir, "run.json"), out)


def run_cache_scenario(name, scenario):
    out_dir = os.path.join(CACHE, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    work = tempfile.mkdtemp(prefix=f"cache_{name}_", dir=gf.WORK_DIR)
    os.chdir(work)
    try:
        for i, run in enumerate(scenario["runs"]):
            run_dir = os.path.join(out_dir, f"run{i}")
            os.makedirs(run_dir, exist_ok=True)
            run_cache_run(run, run_dir)
    finally:
        os.chdir(gf.WORK_DIR)
        reset_cache_manager()


VACATION = {
    "input": "What is the vacation policy?",
    "actual_output": "Employees get 20 days of PTO per year and can carry over 10 days.",
    "expected_output": "Employees get 20 days of PTO a year. Up to 5 days carry over.",
    "retrieval_context": [
        "Section 3.2: Full-time employees receive 20 days of paid time off per year.",
        "Section 3.3: Up to 5 unused days can be carried over to the next year.",
    ],
}

STUBS = [cache_stub("Relevance", 0.8), cache_stub("Tone", 0.4, threshold=0.6, model="gpt-4o")]
TWO_CASES = [
    {"input": "What is the capital of France?", "actual_output": "Paris.",
     "expected_output": "Paris."},
    {"input": "Où est le café?", "actual_output": "Ici.", "expected_output": "Là-bas.",
     "context": ["b", "a"]},
]
EXACT_MATCH = {"kind": "exact_match"}
FAILING = {"kind": "error", "name": "Failing", "threshold": 0.5, "exception": "ValueError",
           "message": "The judge is down."}

# Batched System One answers of three whole-form metrics (system_one
# batch_system_one): Faithfulness (f), AnswerRelevancy (ar), ContextualRecall (cr).
SO_ANSWERS = {
    "f": {"nouls": {"q_0": so.noul(0.3), "q_1": so.noul(0.2)},
          "scores": {"q_2": so.score(1, so.FOUR_LEVELS_LOW, 0.4)}},
    "ar": {"nouls": {"q_0": so.noul(0.6), "q_1": so.noul(0.95)},
           "scores": {"q_2": so.score(2, {"0": 0.0, "1": 0.2, "2": 0.7, "3": 0.1}, 0.5)}},
    "cr": {"nouls": {"q_0": so.noul(0.4), "q_1": so.noul(0.7)},
           "scores": {"q_2": so.score(3, so.FOUR_LEVELS_HIGH, 0.7)}},
}
SO_METRICS = {
    "f": {"kind": "faithfulness", "eval_mode": "system_one", "params": {"threshold": 0.5}},
    "ar": {"kind": "answer_relevancy", "eval_mode": "system_one", "params": {"threshold": 0.5}},
    "cr": {"kind": "contextual_recall", "eval_mode": "system_one", "params": {"threshold": 0.5}},
}


def so_run(asked, metrics, use_cache):
    """A System One run of `metrics` whose fake answers the metrics in
    `asked`: under `m<j>.` keys when two or more are batched."""
    answers = {}
    for j, name in enumerate(asked):
        prefix = f"m{j}." if len(asked) > 1 else ""
        for kind, by_key in SO_ANSWERS[name].items():
            for key, answer in by_key.items():
                answers.setdefault(kind, {})[prefix + key] = answer
    return {
        "test_cases": [VACATION],
        "metrics": [SO_METRICS[name] for name in metrics],
        "system_one": {"model": JEV, "cost": so.JEV_COST, "answers": answers},
        "use_cache": use_cache,
    }


LABEL = {"kind": "classifier", "eval_mode": "llm",
         "params": {"name": "Topic", "labels": ["geography", "food"]}}

CACHE_SCENARIOS = {
    "hits": {
        "description": "A cold run writes the cache; a warm run with use_cache reads every metric "
                       "of both test cases from it at cost 0, measuring none",
        "runs": [
            {"test_cases": TWO_CASES, "metrics": STUBS + [EXACT_MATCH]},
            {"test_cases": TWO_CASES, "metrics": STUBS + [EXACT_MATCH], "use_cache": True},
        ],
    },
    "configuration_changed": {
        "description": "The warm run raises a threshold and changes a judge model: those metrics "
                       "miss and are measured again",
        "runs": [
            {"test_cases": TWO_CASES[:1], "metrics": STUBS + [EXACT_MATCH]},
            {"test_cases": TWO_CASES[:1],
             "metrics": [cache_stub("Relevance", 0.8, threshold=0.7),
                         cache_stub("Tone", 0.4, threshold=0.6, model="gpt-4o-mini"),
                         EXACT_MATCH],
             "use_cache": True},
        ],
    },
    "test_case_changed": {
        "description": "The warm run's second test case has another output: it misses; the cache "
                       "keeps only the warm run's entries",
        "runs": [
            {"test_cases": TWO_CASES, "metrics": STUBS},
            {"test_cases": [TWO_CASES[0], {**TWO_CASES[1], "actual_output": "Là-bas."}],
             "metrics": STUBS, "use_cache": True},
        ],
    },
    "errored_metric": {
        "description": "An errored metric is never cached: the warm run measures it again",
        "runs": [
            {"test_cases": TWO_CASES[:1], "metrics": [STUBS[0], FAILING]},
            {"test_cases": TWO_CASES[:1], "metrics": [STUBS[0], FAILING], "use_cache": True},
        ],
    },
    "without_use_cache": {
        "description": "A second run without use_cache measures everything and rewrites the cache",
        "runs": [
            {"test_cases": TWO_CASES[:1], "metrics": STUBS},
            {"test_cases": TWO_CASES[:1], "metrics": STUBS},
        ],
    },
    "write_cache_false": {
        "description": "write_cache=False never reads the cache, even with use_cache, and deletes it",
        "runs": [
            {"test_cases": TWO_CASES[:1], "metrics": STUBS},
            {"test_cases": TWO_CASES[:1], "metrics": STUBS, "use_cache": True,
             "write_cache": False},
        ],
    },
    "duplicate_test_case": {
        "description": "The same test case twice in one run, one at a time: the second reads the "
                       "first's results",
        "runs": [
            {"test_cases": [TWO_CASES[0], TWO_CASES[0]], "metrics": STUBS, "use_cache": True,
             "max_concurrent": 1},
        ],
    },
    "conversational": {
        "description": "Conversational test cases are never cached: the cache is written empty",
        "runs": [
            {"test_cases": [CONVERSATION], "metrics": [
                {**gf.STUB_JUDGE, "kind": "conversational_stub"}]},
            {"test_cases": [CONVERSATION], "metrics": [
                {**gf.STUB_JUDGE, "kind": "conversational_stub"}], "use_cache": True},
        ],
    },
    "classification": {
        "description": "A classification is cached with its labels and judge; the warm run reads it "
                       "and checks it against the test case's new expected label",
        "runs": [
            {"test_cases": [{**TWO_CASES[0], "expected_labels": {"Topic": "geography"}}],
             "metrics": STUBS[:1], "classifiers": [LABEL],
             "responses": {"label,reason": [{"label": "geography", "reason": "About a capital."}]}},
            {"test_cases": [{**TWO_CASES[0], "expected_labels": {"Topic": "food"}}],
             "metrics": STUBS[:1], "classifiers": [LABEL], "use_cache": True},
        ],
    },
    "expectations": {
        "description": "The expectation evaluator is cached like a metric, its key including the "
                       "expectations and their evidence; reading it back, deepeval raises "
                       "AttributeError (the evaluator it hydrates has no verdicts)",
        "runs": [
            {"test_cases": [refund()], "metrics": STUBS[:1],
             "responses": judged(ALL_PASS, "The score is 1.0 because it states the policy.")},
            {"test_cases": [refund()], "metrics": STUBS[:1], "use_cache": True},
        ],
    },
    "system_one_one_cached": {
        "description": "One of three system_one metrics is cached: the other two are batched, "
                       "keyed m0. and m1.",
        "runs": [
            so_run(["f"], ["f"], False),
            so_run(["ar", "cr"], ["f", "ar", "cr"], True),
        ],
    },
    "system_one_two_cached": {
        "description": "Two of three system_one metrics are cached: the third is the only "
                       "candidate, so it is not batched",
        "runs": [
            so_run(["f", "ar"], ["f", "ar"], False),
            so_run(["cr"], ["f", "ar", "cr"], True),
        ],
    },
}

# The console report and the wrap-up's output. Each scenario is a list of
# test results as deepeval's evaluate() returns them, with its test run.


def build_metric_data(spec):
    return MetricData.model_validate(spec)


def build_turn(spec):
    spec = dict(spec)
    if spec.get("toolsCalled") is not None:
        spec["toolsCalled"] = [ToolCall(**t) for t in spec["toolsCalled"]]
    return TurnApi.model_validate(spec)


def build_test_result(spec):
    turns = [build_turn(t) for t in spec["turns"]] if spec.get("turns") is not None else None
    return TestResult(
        name=spec["name"],
        success=spec["success"],
        metrics_data=[build_metric_data(m) for m in spec.get("metrics_data", [])] or None,
        conversational=spec.get("conversational", False),
        index=spec.get("index"),
        input=spec.get("input"),
        actual_output=spec.get("actual_output"),
        expected_output=spec.get("expected_output"),
        turns=turns,
        classifications=[
            Classification.model_validate(c) for c in spec.get("classifications", [])
        ] or None,
    )


def build_api_test_case(spec):
    """The API test case evaluate() records for a test result: its metric
    data applied with update_metric_data, as execute_test_cases does."""
    if spec.get("conversational"):
        api = ConversationalApiTestCase(
            name=spec["name"],
            success=True,
            metricsData=[],
            runDuration=0.0,
            turns=[build_turn(t) for t in spec.get("turns", [])],
            order=spec.get("index"),
        )
        api.metrics_data = None
    else:
        api = LLMApiTestCase(
            name=spec["name"],
            input=spec.get("input"),
            actualOutput=spec.get("actual_output"),
            expectedOutput=spec.get("expected_output"),
            success=True,
            metricsData=None,
            runDuration=0,
            order=spec.get("index"),
        )
    for m in spec.get("metrics_data", []):
        api.update_metric_data(build_metric_data(m))
    return api


def renderable_json(item):
    """A Rich renderable as JSON, keeping deepeval's strings as they are."""
    if isinstance(item, str):
        return item
    if isinstance(item, Panel):
        return {
            "panel": {
                "border_style": str(item.border_style),
                "content": renderable_json(item.renderable),
            }
        }
    if isinstance(item, Tree):
        return {
            "tree": {
                "label": renderable_json(item.label),
                "children": [renderable_json(child) for child in item.children],
            }
        }
    if isinstance(item, Table):
        return {
            "table": {
                "title": item.title,
                "columns": [str(c.header) for c in item.columns],
                "rows": [[c._cells[i] for c in item.columns] for i in range(item.row_count)],
            }
        }
    raise TypeError(f"unexpected renderable {type(item).__name__}")


# The console widths the `Test Results` table is drawn at (table_<width>.txt).
TABLE_WIDTHS = [60, 80, 100, 120, 160]


def write_table_layouts(out_dir, manager, test_run, display):
    """display_results_table() drawn by Rich at each of TABLE_WIDTHS, without
    colour, as a console with no terminal attached and COLUMNS set to the
    width would draw it. The turn tables' column limits follow the console's
    width, as deepeval's do. The Confident AI note row, deepeval's last, is
    dropped before the table is drawn: DeepEvalEx never draws it (ADR-0010
    decision 6), and it would widen the first column."""
    for width in TABLE_WIDTHS:
        recorder = Console(
            record=True,
            file=io.StringIO(),
            width=width,
            color_system=None,
            force_terminal=False,
            legacy_windows=False,
        )

        def print_table(table, recorder=recorder):
            table.rows.pop()
            for column in table.columns:
                column._cells.pop()
            recorder.print(table)

        test_run_module.console = recorder
        test_run_module.print = print_table
        manager.display_results_table(test_run, display)
        path = os.path.join(out_dir, f"table_{width}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(recorder.export_text())


class _TableCapture:
    """Stands in for test_run.py's console and rich print in
    display_results_table: records what it prints."""

    width = 120

    def __init__(self):
        self.printed = []

    def print(self, *items, **_kwargs):
        for item in items:
            self.printed.append(renderable_json(item))


def run_report_scenario(name, scenario):
    out_dir = os.path.join(REPORT, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    display = TestRunResultDisplay(scenario["display"])
    test_results = [build_test_result(spec) for spec in scenario["test_results"]]

    report = EvaluationConsoleReport(test_results)
    group = report._build_display_elements(
        truncate=scenario["truncate"], display_option=display
    )
    gf.write_json(
        os.path.join(out_dir, "sections.json"),
        [renderable_json(item) for item in group.renderables],
    )

    md_dir = tempfile.mkdtemp(prefix=f"report_{name}_", dir=gf.WORK_DIR)
    with contextlib.redirect_stdout(io.StringIO()):
        report.export_to_markdown(md_dir, evaluation_name=scenario.get("identifier"))
    [md] = os.listdir(md_dir)
    shutil.copyfile(os.path.join(md_dir, md), os.path.join(out_dir, "report.md"))

    # wrap_up_test_run() over the test run evaluate() would have made.
    work = tempfile.mkdtemp(prefix=f"report_run_{name}_", dir=gf.WORK_DIR)
    os.chdir(work)
    manager = test_run_module.global_test_run_manager
    original_console, original_print = test_run_module.console, test_run_module.print
    try:
        reset_cache_manager()
        manager.reset()
        manager.create_test_run(identifier=scenario.get("identifier"))
        test_run = manager.get_test_run()
        for spec in scenario["test_results"]:
            if spec.get("metrics_data"):
                test_run.add_test_case(build_api_test_case(spec))
        test_run.hyperparameters = scenario.get("hyperparameters")
        test_run.prompts = [] if scenario.get("hyperparameters") is not None else None
        recorder = Console(
            record=True,
            file=io.StringIO(),
            width=120,
            color_system=None,
            soft_wrap=True,
        )
        test_run_module.console = recorder
        manager.wrap_up_test_run(scenario["run_duration"], display_table=False)
        with open(os.path.join(out_dir, "summary.txt"), "w", encoding="utf-8") as f:
            f.write(recorder.export_text())
        gf.write_json(
            os.path.join(out_dir, "test_run.json"),
            test_run.model_dump(by_alias=True, exclude_none=True, mode="json"),
        )

        capture = _TableCapture()
        test_run_module.console = capture
        test_run_module.print = capture.print
        manager.display_results_table(test_run, display)
        gf.write_json(os.path.join(out_dir, "tables.json"), capture.printed)

        write_table_layouts(out_dir, manager, test_run, display)
    finally:
        test_run_module.console, test_run_module.print = original_console, original_print
        manager.reset()
        reset_cache_manager()
        os.chdir(gf.WORK_DIR)


def metric(name, score, threshold=0.5, reason=None, success=None, **extra):
    """MetricData as evaluate() records it: success from the score unless given."""
    if success is None and threshold is not None and score is not None:
        success = score >= threshold
    return {
        "name": name,
        "threshold": threshold,
        "success": success,
        "score": score,
        "reason": reason,
        "strictMode": False,
        "evaluationModel": extra.pop("evaluationModel", "gpt-4o-mini"),
        "evaluationCost": extra.pop("evaluationCost", 0.000321),
        **extra,
    }


def errored(name, error, threshold=0.5):
    return {
        "name": name,
        "threshold": threshold,
        "success": False,
        "score": None,
        "reason": None,
        "strictMode": False,
        "evaluationModel": "gpt-4o-mini",
        "error": error,
        "evaluationCost": None,
    }


def result(name, index, metrics_data, success=None, **fields):
    """A single-turn test result; success as _local_success makes it."""
    if success is None:
        success = not any(m["success"] is False and not m.get("flaky") for m in metrics_data)
    return {
        "name": name,
        "success": success,
        "conversational": False,
        "index": index,
        "input": fields.pop("input", f"Question {index}?"),
        "actual_output": fields.pop("actual_output", f"Answer {index}."),
        "metrics_data": metrics_data,
        **fields,
    }


LONG_REASON = (
    "The answer states the policy accurately and names every condition the "
    "context lists, so it is relevant."
)
PASS_RELEVANCE = metric("Answer Relevancy", 0.91, 0.7, LONG_REASON)
PASS_FAITHFUL = metric("Faithfulness", 1.0, 0.5, "No contradictions.", evaluationCost=0.0012)
FAIL_FAITHFUL = metric(
    "Faithfulness", 0.25, 0.5,
    "The answer contradicts the retrieval context on the refund window, which is 30 days.",
)
FAIL_RELEVANCE = metric("Answer Relevancy", 0.333333, 0.7, "Off topic.")

PASSING = [
    result("test_case_0", 0, [PASS_RELEVANCE, PASS_FAITHFUL],
           expected_output="The policy allows refunds within 30 days."),
    result("test_case_1", 1, [PASS_RELEVANCE, PASS_FAITHFUL], expected_output="N/A"),
]
MIXED = [
    PASSING[0],
    result("refund question", 1, [FAIL_RELEVANCE, FAIL_FAITHFUL],
           input="Can I get a refund on a used ticket?",
           actual_output="Yes, always.\nNo questions asked."),
    result("test_case_2", 2, [PASS_RELEVANCE, FAIL_FAITHFUL]),
]
FAILING = [result("test_case_0", 0, [FAIL_RELEVANCE])]

CLASSIFIED = [
    {
        **result("test_case_0", 0, [PASS_RELEVANCE]),
        "classifications": [
            {"name": "Refusal", "label": "refused", "expectedLabel": "refused",
             "success": True, "reason": LONG_REASON, "evaluationModel": "gpt-4o-mini",
             "evaluationCost": 0.0},
            {"name": "Topic", "label": "billing", "success": None, "reason": "About billing.",
             "evaluationModel": "gpt-4o-mini"},
        ],
    },
    {
        **result("test_case_1", 1, [], success=False),
        "classifications": [
            {"name": "Refusal", "label": "complied", "expectedLabel": "refused",
             "success": False, "reason": "It answered.", "evaluationModel": "gpt-4o-mini"},
            {"name": "Topic", "label": None, "success": None, "reason": None,
             "error": "Classifier returned an undeclared label 'sports'",
             "evaluationModel": "gpt-4o-mini"},
        ],
    },
    {
        **result("test_case_2", 2, [], success=None),
        "classifications": [
            {"name": "Topic", "label": None, "success": None, "reason": "Nothing fits.",
             "evaluationModel": "gpt-4o-mini"},
            {"name": "Refusal", "label": "refused", "success": None, "reason": None},
        ],
    },
]

CONVERSATION_TURNS = [
    {"role": "user", "content": "I want to change my flight.", "order": 0},
    {"role": "assistant", "content": "Sure, which booking?", "order": 1,
     "retrievalContext": ["Changes are free up to 24 hours before departure.",
                          "A fare difference may apply.", "Basic fares cannot change."],
     "toolsCalled": [{"name": "lookup_booking"}, {"name": "list_flights"}]},
    {"role": "user", "content": "ABC123", "order": 2, "comments": "Booking reference."},
]

EXACT_MATCH_PASSED = metric(
    "Exact Match", 1.0, 1.0, "The actual and expected outputs are exact matches.",
    evaluationModel=None, evaluationCost=None,
)
EXACT_MATCH_FAILED = metric(
    "Exact Match", 0.0, 1.0, "The actual and expected outputs are different.",
    evaluationModel=None, evaluationCost=None,
)

REPORT_SCENARIOS = {
    "exact_match": {
        "description": "A passing and a failing ExactMatch test case, as `mix deep_eval.test` "
                       "names them: no evaluation model, long Score cells",
        "test_results": [
            result("test exact match passes", 0, [EXACT_MATCH_PASSED],
                   input="2 + 2?", actual_output="4", expected_output="4"),
            result("test exact match fails", 1, [EXACT_MATCH_FAILED],
                   input="2 + 3?", actual_output="6", expected_output="5"),
        ],
        "display": "all", "truncate": True, "run_duration": 0.11,
        "hyperparameters": None, "identifier": None,
    },
    "all_passing": {
        "description": "Two passing test cases, truncated to one line each; a long reason",
        "test_results": PASSING,
        "display": "all", "truncate": True, "run_duration": 1.23456,
        "hyperparameters": None, "identifier": None,
    },
    "all_passing_untruncated": {
        "description": "The same, not truncated: the data table, the metrics table and the "
                       "47-character reason cut of a passing metric",
        "test_results": PASSING,
        "display": "all", "truncate": False, "run_duration": 0.5,
        "hyperparameters": None, "identifier": "Nightly Run",
    },
    "mixed": {
        "description": "Passing and failing test cases with hyperparameters logged (no prompts)",
        "test_results": MIXED,
        "display": "all", "truncate": True, "run_duration": 12.3456,
        "hyperparameters": {"model": "gpt-4o", "temperature": "0.7"}, "identifier": None,
    },
    "display_failing": {
        "description": "display=failing leaves out the passing test case",
        "test_results": MIXED,
        "display": "failing", "truncate": True, "run_duration": 2.0,
        "hyperparameters": None, "identifier": None,
    },
    "display_passing": {
        "description": "display=passing leaves out the failing test cases",
        "test_results": MIXED,
        "display": "passing", "truncate": True, "run_duration": 2.0,
        "hyperparameters": None, "identifier": None,
    },
    "display_failing_none": {
        "description": "display=failing when every test case passed",
        "test_results": PASSING,
        "display": "failing", "truncate": True, "run_duration": 2.0,
        "hyperparameters": None, "identifier": None,
    },
    "display_passing_none": {
        "description": "display=passing when the only test case failed",
        "test_results": FAILING,
        "display": "passing", "truncate": True, "run_duration": 2.0,
        "hyperparameters": None, "identifier": None,
    },
    "errored": {
        "description": "Every metric errored: ERROR rows, no cost, the all-errored warning",
        "test_results": [
            result("test_case_0", 0, [errored("Faithfulness", "ValueError: boom")]),
            result("test_case_1", 1, [errored("Faithfulness", "Timed out after 180s")]),
        ],
        "display": "all", "truncate": True, "run_duration": 3.0,
        "hyperparameters": None, "identifier": None,
    },
    "score_only": {
        "description": "Score-only metrics (no threshold) are NONE and count as errors",
        "test_results": [
            result("test_case_0", 0, [metric("Bias", 0.2, None, "Little bias.")]),
            result("test_case_1", 1, [metric("Bias", None, None, None,
                                             evaluationCost=None)]),
        ],
        "display": "all", "truncate": False, "run_duration": 0.004,
        "hyperparameters": None, "identifier": None,
    },
    "flaky": {
        "description": "Flaky metrics count towards their verdict with a flaky sub-count, and "
                       "never fail the test case",
        "test_results": [
            result("test_case_0", 0, [metric("Tone", 0.9, flaky=True), PASS_FAITHFUL]),
            result("test_case_1", 1, [metric("Tone", 0.1, flaky=True), PASS_FAITHFUL]),
            result("test_case_2", 2, [metric("Tone", 0.2), FAIL_FAITHFUL]),
        ],
        "display": "all", "truncate": False, "run_duration": 4.5,
        "hyperparameters": None, "identifier": None,
    },
    "conversational": {
        "description": "A conversation with turns (tools, retrieval context, comments) and one "
                       "without, beside a single-turn test case",
        "test_results": [
            result("test_case_0", 0, [PASS_FAITHFUL]),
            {"name": "conversational_test_case_0", "success": False, "conversational": True,
             "index": 0, "turns": CONVERSATION_TURNS,
             "metrics_data": [metric("Turn Relevancy", 0.4, 0.5, "One turn is off topic.")]},
            {"name": "empty conversation", "success": True, "conversational": True,
             "index": 1, "turns": [],
             "metrics_data": [metric("Turn Relevancy", 1.0, 0.5, "All relevant.")]},
        ],
        "display": "all", "truncate": False, "run_duration": 6.0,
        "hyperparameters": None, "identifier": None,
    },
    "classifiers": {
        "description": "Classifications with and without expected labels, an errored one and a "
                       "declined one (none), and classifier-only test cases left out of the run",
        "test_results": CLASSIFIED,
        "display": "all", "truncate": True, "run_duration": 1.0,
        "hyperparameters": None, "identifier": None,
    },
    "classifiers_untruncated": {
        "description": "The same, not truncated",
        "test_results": CLASSIFIED,
        "display": "all", "truncate": False, "run_duration": 1.0,
        "hyperparameters": None, "identifier": None,
    },
    "natural_sort": {
        "description": "Test results sorted by index, then by name naturally (case 2 before "
                       "case 10)",
        "test_results": [
            result("Case 10", 1, [PASS_FAITHFUL]),
            result("case 2", 1, [FAIL_FAITHFUL]),
            result("case 1", 0, [PASS_FAITHFUL]),
        ],
        "display": "all", "truncate": False, "run_duration": 1.0,
        "hyperparameters": None, "identifier": None,
    },
    "unicode": {
        "description": "Emoji and CJK in names and reasons, cut by code point; a multi-line "
                       "reason in Markdown",
        "test_results": [
            result("café ☕ 测试", 0, [
                metric("Answer Relevancy", 0.875, 0.5,
                       "回答完全相关，并且涵盖了所有要点。🎉 The answer is fully relevant and covers "
                       "every point."),
                metric("Faithfulness", 0.125, 0.5, "Line one.\nLine two."),
            ], input="Où est le café ?", actual_output="Ici 👉 ☕"),
        ],
        "display": "all", "truncate": False, "run_duration": 0.125,
        "hyperparameters": None, "identifier": None,
    },
}


# `deepeval test run` (cli/test/command.py): the pytest arguments and settings
# each set of flags gives, and real runs of a small pytest file.
#
# cli/args/cases.json - for every argv in CLI_ARGS_CASES: the `pytest_args`
# command.py passed to (a patched) pytest.main, the settings it set
# (`ENABLE_DEEPEVAL_CACHE`, `IGNORE_DEEPEVAL_ERRORS`,
# `SKIP_DEEPEVAL_MISSING_PARAMS`, `DEEPEVAL_VERBOSE_MODE`,
# `DEEPEVAL_IDENTIFIER` and the `DEEPEVAL` variable), what it printed, or the
# error it raised (click's message for a usage error).
#
# cli/<scenario>/ - for every scenario in CLI_SCENARIOS, `deepeval test run`
# over CLI_TEST_FILE (written as cli/test_runner.py) once per argv, in one
# folder, each run<i>/ holding: run.json (argv, exit code and the skipped-test
# lines deepeval printed, the run folder replaced by `<dir>`),
# latest_test_run.json (`.deepeval/.latest_test_run.json`) and cache.json
# (`.deepeval/.deepeval-cache.json`). Mirrored by
# test/fixtures/projects/runner/.

CLI = os.path.join(ROOT, "test", "fixtures", "deepeval", "cli")

CLI_ARGS_CASES = [
    ["test_example.py"],
    ["test_example.py", "-c"],
    ["test_example.py", "--use-cache", "--repeat", "2"],
    ["test_example.py", "-c", "-r", "2"],
    ["test_example.py", "-i", "-s", "-v"],
    ["test_example.py", "--ignore-errors", "--skip-on-missing-params", "--verbose"],
    ["test_example.py", "-x"],
    ["test_example.py", "-x", "-X"],
    ["test_example.py", "--exit-on-first-failure"],
    ["test_example.py", "-w"],
    ["test_example.py", "-w", "-W"],
    ["test_example.py", "-id", "nightly"],
    ["test_example.py", "--identifier", "nightly"],
    ["test_example.py", "-n", "4"],
    ["test_example.py", "-d", "FAILING"],
    ["test_example.py", "--display", "passing"],
    ["test_example.py", "-m", "rag"],
    ["test_example.py", "-m", "not slow"],
    ["test_example.py", "-m", "rag or slow"],
    ["test_example.py", "--durations", "0"],
    ["test_example.py", "--durations", "3"],
    ["test_example.py", "--color", "no"],
    ["test_example.py", "-o"],
    ["test_example.py", "-ci"],
    ["test_example.py", "-r3"],
    ["test_example.py", "-k", "refund", "--tb", "short"],
    ["test_example.py::test_refund"],
    ["test_example.py", "-r", "0"],
    ["test_example.py", "-d", "some"],
    ["test_example.py", "-r", "x"],
    ["missing.py"],
]

CLI_SETTINGS = [
    ("use_cache", "ENABLE_DEEPEVAL_CACHE"),
    ("ignore_errors", "IGNORE_DEEPEVAL_ERRORS"),
    ("skip_on_missing_params", "SKIP_DEEPEVAL_MISSING_PARAMS"),
    ("verbose_mode", "DEEPEVAL_VERBOSE_MODE"),
    ("identifier", "DEEPEVAL_IDENTIFIER"),
]


def reset_cli_settings():
    from deepeval.config.settings import get_settings

    settings = get_settings()
    with settings.edit(persist=False):
        settings.ENABLE_DEEPEVAL_CACHE = False
        settings.IGNORE_DEEPEVAL_ERRORS = False
        settings.SKIP_DEEPEVAL_MISSING_PARAMS = False
        settings.DEEPEVAL_VERBOSE_MODE = None
        settings.DEEPEVAL_IDENTIFIER = None
    os.environ.pop("DEEPEVAL", None)


def run_cli_args_case(argv, command):
    import pytest as pytest_module
    import typer

    from deepeval.config.settings import get_settings

    reset_cli_settings()
    calls = []
    original_main = pytest_module.main
    original_wrap_up = command.global_test_run_manager.wrap_up_test_run
    original_hook = command.invoke_test_run_end_hook
    pytest_module.main = lambda args: calls.append(list(args)) or 0
    command.global_test_run_manager.wrap_up_test_run = lambda *args, **kwargs: None
    command.invoke_test_run_end_hook = lambda: None
    stdout = io.StringIO()
    case = {"argv": argv}
    try:
        with contextlib.redirect_stdout(stdout):
            typer.main.get_command(command.app).main(args=argv, standalone_mode=False)
        case["error"] = None
    except Exception as error:  # noqa: BLE001 - ValueError, or click's usage errors
        # typer vendors click: its usage errors carry click's message.
        message = getattr(error, "format_message", None)
        case["error"] = message() if message else str(error)
    finally:
        pytest_module.main = original_main
        command.global_test_run_manager.wrap_up_test_run = original_wrap_up
        command.invoke_test_run_end_hook = original_hook
    case["pytest_args"] = calls[0] if calls else None
    settings = get_settings()
    case["settings"] = {key: getattr(settings, name) for key, name in CLI_SETTINGS}
    case["settings"]["running"] = os.environ.get("DEEPEVAL")
    case["stdout"] = stdout.getvalue()
    return case


def write_cli_args():
    command = importlib.import_module("deepeval.cli.test.command")
    out_dir = os.path.join(CLI, "args")
    os.makedirs(out_dir)
    run_dir = tempfile.mkdtemp(prefix="cli_args_", dir=gf.WORK_DIR)
    previous = os.getcwd()
    os.chdir(run_dir)
    try:
        with open("test_example.py", "w") as file:
            file.write("def test_refund():\n    pass\n")
        cases = [run_cli_args_case(argv, command) for argv in CLI_ARGS_CASES]
    finally:
        os.chdir(previous)
        reset_cli_settings()
    gf.write_json(os.path.join(out_dir, "cases.json"), cases)


CLI_TEST_FILE = """\
import pytest

from deepeval import assert_test
from deepeval.metrics import ExactMatchMetric
from deepeval.test_case import LLMTestCase
from deepeval.test_run import log_hyperparameters


@log_hyperparameters
def hyperparameters():
    return {"model": "gpt-4.1", "prompt_version": "v3"}


def test_passing():
    test_case = LLMTestCase(name="passing", input="2 + 2?", actual_output="4", expected_output="4")
    assert_test(test_case, [ExactMatchMetric()])


def test_failing():
    test_case = LLMTestCase(name="failing", input="2 + 3?", actual_output="6", expected_output="5")
    assert_test(test_case, [ExactMatchMetric()])


def test_flaky():
    test_case = LLMTestCase(
        name="flaky", input="3 + 3?", actual_output="7", expected_output="6", flaky=True
    )
    assert_test(test_case, [ExactMatchMetric()])


@pytest.mark.rag
def test_unnamed():
    test_case = LLMTestCase(input="Capital of France?", actual_output="Paris", expected_output="Paris")
    assert_test(test_case, [ExactMatchMetric()])


@pytest.mark.skip(reason="not ready")
def test_skipped():
    test_case = LLMTestCase(name="skipped", input="x", actual_output="x", expected_output="x")
    assert_test(test_case, [ExactMatchMetric()])
"""

CLI_SCENARIOS = {
    "default": [[]],
    "flags": [["-i", "-d", "failing", "--identifier", "nightly", "-w"]],
    "repeat": [["-r", "2"]],
    "mark": [["-m", "rag"]],
    "warm_cache": [[], ["-c"]],
}


def read_bytes(path):
    if not os.path.exists(path):
        return None
    with open(path, "rb") as file:
        return file.read().decode("utf-8")


def run_cli_scenario(name, runs):
    out_dir = os.path.join(CLI, name)
    run_dir = tempfile.mkdtemp(prefix=f"cli_{name}_", dir=gf.WORK_DIR)
    with open(os.path.join(run_dir, "test_runner.py"), "w") as file:
        file.write(CLI_TEST_FILE)
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    env.pop("DEEPEVAL", None)
    os.makedirs(out_dir)
    gf.write_json(os.path.join(out_dir, "input.json"), {"runs": runs})
    for index, args in enumerate(runs):
        argv = ["test_runner.py", *args]
        completed = subprocess.run(
            ["deepeval", "test", "run", *argv, "--color", "no"],
            cwd=run_dir, env=env, capture_output=True, text=True,
        )
        skipped = [
            line.replace(run_dir, "<dir>")
            for line in completed.stdout.splitlines()
            if line.startswith("Test ") and " was skipped. Reason: " in line
        ]
        run_out = os.path.join(out_dir, f"run{index}")
        os.makedirs(run_out)
        gf.write_json(os.path.join(run_out, "run.json"), {
            "argv": argv, "exit_code": completed.returncode, "skipped": skipped,
        })
        latest = read_bytes(os.path.join(run_dir, ".deepeval", ".latest_test_run.json"))
        gf.write_json(os.path.join(run_out, "latest_test_run.json"), json.loads(latest))
        cache = read_bytes(os.path.join(run_dir, ".deepeval", ".deepeval-cache.json"))
        with open(os.path.join(run_out, "cache.json"), "w") as file:
            file.write(cache)


def write_cli():
    if os.path.isdir(CLI):
        shutil.rmtree(CLI)
    write_cli_args()
    print(f"wrote {os.path.relpath(os.path.join(CLI, 'args'), ROOT)}")
    os.makedirs(CLI, exist_ok=True)
    with open(os.path.join(CLI, "test_runner.py"), "w") as file:
        file.write(CLI_TEST_FILE)
    for name, runs in CLI_SCENARIOS.items():
        run_cli_scenario(name, runs)
        print(f"wrote {os.path.relpath(os.path.join(CLI, name), ROOT)}")



def write_report():
    if os.path.isdir(REPORT):
        shutil.rmtree(REPORT)
    for name, scenario in REPORT_SCENARIOS.items():
        run_report_scenario(name, scenario)
        print(f"wrote {os.path.relpath(os.path.join(REPORT, name), ROOT)}")


def main():
    if gf.deepeval.__version__ != gf.DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {gf.DEEPEVAL_VERSION}, found {gf.deepeval.__version__}")
    if sys.argv[1:] == ["report"]:
        try:
            write_report()
        finally:
            shutil.rmtree(gf.WORK_DIR, ignore_errors=True)
        return
    try:
        if os.path.isdir(CLASSIFIERS):
            shutil.rmtree(CLASSIFIERS)
        for name, scenario in CLASSIFIER_SCENARIOS.items():
            run_classifier_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(CLASSIFIERS, name), ROOT)}")
        write_builtins()
        write_validation()
        print(f"wrote {os.path.relpath(CLASSIFIERS, ROOT)}/builtins and validation")
        if os.path.isdir(EXPECTATIONS):
            shutil.rmtree(EXPECTATIONS)
        for name, scenario in EXPECTATION_SCENARIOS.items():
            run_expectation_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(EXPECTATIONS, name), ROOT)}")
        write_coverage()
        print(f"wrote {os.path.relpath(EXPECTATIONS, ROOT)}/validation")
        if os.path.isdir(CACHE):
            shutil.rmtree(CACHE)
        write_keys()
        write_configurations()
        print(f"wrote {os.path.relpath(CACHE, ROOT)}/keys and configurations")
        for name, scenario in CACHE_SCENARIOS.items():
            run_cache_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(CACHE, name), ROOT)}")
        write_report()
        write_cli()
    finally:
        shutil.rmtree(gf.WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
