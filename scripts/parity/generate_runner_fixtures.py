"""Generate the golden fixtures of DeepEvalEx's test-runner phase (P8):
classifiers and expectations for now; the cache, report and CLI sets follow.

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

Run it inside the devcontainer, from the repository root, with deepeval's
source checked out at _ref/deepeval (tag v4.3.1):

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_runner_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import copy
import importlib.util
import json
import logging
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CLASSIFIERS = os.path.join(ROOT, "test", "fixtures", "deepeval", "classifiers")
EXPECTATIONS = os.path.join(ROOT, "test", "fixtures", "deepeval", "expectations")

# Same fixed hash seed as generate_fixtures.py, which this script imports and
# which would otherwise re-run itself instead of this script.
if sys.flags.hash_randomization:
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    env["PYTHONHASHSEED"] = "0"
    os.execve(sys.executable, [sys.executable, "-s", "-P", os.path.abspath(__file__)], env)


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
from deepeval.test_case import ConversationalTestCase  # noqa: E402

# deepeval's package exports an `evaluate` function under the module's name.
expectations_module = sys.modules["deepeval.evaluate.expectations"]

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
        test_case.expectations = Expectations(model=judge, **expectations)
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


def main():
    if gf.deepeval.__version__ != gf.DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {gf.DEEPEVAL_VERSION}, found {gf.deepeval.__version__}")
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
    finally:
        shutil.rmtree(gf.WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
