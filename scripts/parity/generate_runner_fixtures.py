"""Generate the golden fixtures of DeepEvalEx's test-runner phase (P8):
classifiers for now; the cache, report, expectations and CLI sets follow.

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

It also writes:

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

from deepeval import assert_test  # noqa: E402
import deepeval.classifiers as builtins  # noqa: E402
from deepeval.classifiers import (  # noqa: E402
    Classifier,
    Label,
    RequiredDisclosureClassifier,
    ScopeAdherenceClassifier,
    ToneAdherenceClassifier,
)
from deepeval.classifiers.utils import validate_classifiers  # noqa: E402

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
    finally:
        shutil.rmtree(gf.WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
