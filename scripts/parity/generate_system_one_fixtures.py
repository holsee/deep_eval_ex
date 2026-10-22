"""Generate the System One (Jev) golden fixtures DeepEvalEx's eval modes will
be checked against.

deepeval 4.3.1 can route a metric's decisions to a System One model, TypeSafe
AI's Jev, which answers typed questions (Noul, Score, Choice) about a JSON
state with probabilities instead of generated text. A metric's `eval_mode`
picks who decides:

- `system_one` - Jev answers the whole metric in one `decide()` request over
  the test case; the score is the weighted mean of its answers and the reason
  is deterministic text built from them. No LLM call.
- `hybrid`     - the LLM extracts and writes the reason, Jev takes the
  decisions (one Noul per claim, statement, node, ...). A Jev call that fails
  falls back to the LLM for that decision and is recorded in
  `metric.system_one_fallback_reason`.

`JevEval` (the user's own Noul / Score / Choice questions) and the
classifiers (one Choice over the labels) always decide with Jev under
`system_one`. Under `evaluate()`, a test case's `system_one` metrics are
merged into as few `decide()` requests as fit Jev's budget (the
`system_one_batch` module).

No real Jev is called: the System One models are deepeval's own test doubles,
`FakeSystemOneModel` (canned answers) and `ExplodingSystemOneModel` (raises on
every call), imported from deepeval's test suite in the reference checkout
(`_ref/deepeval/tests/test_metrics/system_one_fakes.py`, deepeval 4.3.1).
They need neither the `typesafe-sdk` package nor an API key: deepeval only
imports the SDK when a `TypeSafeModel` builds its client, which this script
never does (it borrows `TypeSafeModel._to_sdk_questions` from an instance
created without `__init__`). The LLM, where a
mode needs one, is `ScriptedJudge` from generate_fixtures.py.

Scenarios are defined in `SCENARIOS` below. For every scenario this script
writes, under test/fixtures/deepeval/system_one/<scenario>/:

- input.json    - the scenario: `metrics` (kind, `eval_mode`, constructor
                  `params`) or `classifier`, one `test_case`, the
                  `system_one` model (name, cost, the canned `answers` keyed
                  by question key, or the error it raises) and, when an LLM
                  is involved, the scripted judge's `judge_model` and
                  `responses`
- decide.json   - every `decide(state, questions)` call, in order, with the
                  `state`, the `questions` in the SDK's wire shape (as
                  `TypeSafeModel._to_sdk_questions` sends them), the
                  `answers` the fake returned (or the `error` it raised) and
                  the `cost` it reported. `measure` holds one list per metric
                  (each measured alone), `evaluate` the calls of the
                  `evaluate()` run
- measure.json  - per metric, its state after `measure()`, as in the scripted
                  fixtures plus `confidence`, `system_one_fallback_reason`
                  and `score_breakdown`; for a classifier, its state after
                  `classify()`
- prompts.json  - per metric, every prompt the scripted LLM judge received
                  during `measure()` (only when the scenario has a judge)
- test_run.json - the test run `deepeval.evaluate()` wrote for the scenario

Run it inside the devcontainer, from the repository root, with deepeval's
source checked out at _ref/deepeval (tag v4.3.1):

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_system_one_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import copy
import glob
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SYSTEM_ONE = os.path.join(ROOT, "test", "fixtures", "deepeval", "system_one")
FAKES = os.path.join(ROOT, "_ref", "deepeval", "tests", "test_metrics", "system_one_fakes.py")

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


# Sets up the environment (no telemetry, no Confident AI, a temporary working
# directory) before deepeval is imported, and provides ScriptedJudge.
gf = _load("generate_fixtures", os.path.join(HERE, "generate_fixtures.py"))

if not os.path.isfile(FAKES):
    sys.exit(f"{os.path.relpath(FAKES, ROOT)} not found: check out deepeval v4.3.1 at _ref/deepeval")
fakes = _load("system_one_fakes", FAKES)

from deepeval import evaluate  # noqa: E402
from deepeval.classifiers import RefusalClassifier  # noqa: E402
from deepeval.evaluate.configs import (  # noqa: E402
    AsyncConfig,
    CacheConfig,
    DisplayConfig,
    ErrorConfig,
)
from deepeval.metrics import (  # noqa: E402
    AnswerRelevancyMetric,
    ArgumentCorrectnessMetric,
    BiasMetric,
    ContextualPrecisionMetric,
    ContextualRecallMetric,
    ContextualRelevancyMetric,
    ConversationCompletenessMetric,
    FaithfulnessMetric,
    HallucinationMetric,
    JevEval,
    KnowledgeRetentionMetric,
    JsonCorrectnessMetric,
    PIILeakageMetric,
    PromptAlignmentMetric,
    RoleAdherenceMetric,
    SummarizationMetric,
    ToolCorrectnessMetric,
    ToxicityMetric,
    TurnContextualPrecisionMetric,
    TurnContextualRecallMetric,
    TurnContextualRelevancyMetric,
    TurnFaithfulnessMetric,
    TurnRelevancyMetric,
)
from deepeval.metrics.jev_eval import Choice, Noul, Score  # noqa: E402
from deepeval.models.system_one import (  # noqa: E402
    ChoiceAnswer,
    ChoiceQuestion,
    NoulAnswer,
    NoulQuestion,
    ScoreAnswer,
    ScoreQuestion,
    SystemOneAnswers,
    TypeSafeModel,
)
from deepeval.models.utils import EvaluationCost  # noqa: E402
from deepeval.test_case import SingleTurnParams, ToolCall  # noqa: E402

# Only translates questions to the SDK's shape (`_to_sdk_questions` reads no
# instance state). Constructing a TypeSafeModel would build its client, which
# imports the typesafe-sdk package, so the instance skips __init__.
TYPESAFE = TypeSafeModel.__new__(TypeSafeModel)

EXCEPTIONS = {"ConnectionError": ConnectionError, "TimeoutError": TimeoutError}

METRICS = {
    "faithfulness": FaithfulnessMetric,
    "hallucination": HallucinationMetric,
    "answer_relevancy": AnswerRelevancyMetric,
    "contextual_precision": ContextualPrecisionMetric,
    "contextual_recall": ContextualRecallMetric,
    "contextual_relevancy": ContextualRelevancyMetric,
    "bias": BiasMetric,
    "toxicity": ToxicityMetric,
    "pii_leakage": PIILeakageMetric,
    "prompt_alignment": PromptAlignmentMetric,
    "summarization": SummarizationMetric,
    "argument_correctness": ArgumentCorrectnessMetric,
    "tool_correctness": ToolCorrectnessMetric,
    "json_correctness": JsonCorrectnessMetric,
    "jev_eval": JevEval,
    "turn_relevancy": TurnRelevancyMetric,
    "conversation_completeness": ConversationCompletenessMetric,
    "knowledge_retention": KnowledgeRetentionMetric,
    "role_adherence": RoleAdherenceMetric,
    "turn_faithfulness": TurnFaithfulnessMetric,
    "turn_contextual_precision": TurnContextualPrecisionMetric,
    "turn_contextual_recall": TurnContextualRecallMetric,
    "turn_contextual_relevancy": TurnContextualRelevancyMetric,
}

# Metrics that follow their eval mode but never build a System One model, so
# take no `system_one_model`: JsonCorrectness decides in code.
WITHOUT_SYSTEM_ONE_MODEL = {"json_correctness"}

JEV_QUESTIONS = {"noul": Noul, "score": Score, "choice": Choice}


class CannedAnswers:
    """`answer_fn` for FakeSystemOneModel: answers each question from
    `answers`, keyed by type (`nouls`, `scores`, `choices`) then question key,
    and records what it returned. Raises on a question with no canned answer.

    A batched request keys each metric's questions `m{j}.<key>`; `prefix`
    answers metric j measured alone from the same canned answers."""

    def __init__(self, answers, prefix=""):
        self.answers = answers
        self.prefix = prefix
        self.used = set()
        self.returned = []

    def __call__(self, questions):
        out = SystemOneAnswers()
        for key, question in questions.items():
            if isinstance(question, NoulQuestion):
                out.nouls[key] = NoulAnswer(**self._take("nouls", key))
            elif isinstance(question, ScoreQuestion):
                out.scores[key] = ScoreAnswer(**self._take("scores", key))
            elif isinstance(question, ChoiceQuestion):
                out.choices[key] = ChoiceAnswer(**self._take("choices", key))
        self.returned.append(out)
        return out

    def _take(self, kind, key):
        key = self.prefix + key
        try:
            answer = self.answers[kind][key]
        except KeyError:
            raise RuntimeError(f"no canned {kind} answer for {key!r}") from None
        self.used.add((kind, key))
        return answer


def assert_exhausted(spec, *canned):
    """Fails on a canned answer no question used."""
    if "answers" not in spec:
        return
    unused = {(kind, key) for kind, by_key in spec["answers"].items() for key in by_key}
    for answers in canned:
        unused -= answers.used
    if unused:
        raise RuntimeError(f"unused canned answers {sorted(unused)}")


def build_system_one(spec, prefix=""):
    """A fresh fake for `spec` and its CannedAnswers (None for one that
    raises)."""
    if "raises" in spec:
        exc = EXCEPTIONS[spec["raises"]["type"]](spec["raises"]["message"])
        return fakes.ExplodingSystemOneModel(exc, name=spec["model"]), None
    answers = CannedAnswers(spec["answers"], prefix)
    model = fakes.FakeSystemOneModel(
        answer_fn=answers, cost=build_cost(spec.get("cost")), name=spec["model"]
    )
    return model, answers


def build_cost(spec):
    if isinstance(spec, dict):
        return EvaluationCost(spec["value"], spec["input_tokens"], spec["output_tokens"])
    return spec


def cost_json(cost):
    if isinstance(cost, EvaluationCost):
        return {
            "value": float(cost),
            "input_tokens": cost.input_tokens,
            "output_tokens": cost.output_tokens,
        }
    return cost


def build_metric(spec, system_one_model, judge):
    kind = spec["kind"]
    params = copy.deepcopy(spec.get("params", {}))
    if kind == "jev_eval":
        params["evaluation_params"] = [SingleTurnParams(p) for p in params["evaluation_params"]]
        params["questions"] = [
            JEV_QUESTIONS[q.pop("type")](**q) for q in params["questions"]
        ]
        return JevEval(system_one_model=system_one_model, **params)
    if "available_tools" in params:
        params["available_tools"] = [ToolCall(**tool) for tool in params["available_tools"]]
    if "expected_schema" in params:
        params["expected_schema"] = gf.build_expected_schema(params["expected_schema"])
    if kind in WITHOUT_SYSTEM_ONE_MODEL:
        return METRICS[kind](model=judge, eval_mode=spec["eval_mode"], **params)
    return METRICS[kind](
        model=judge, system_one_model=system_one_model, eval_mode=spec["eval_mode"], **params
    )


def build_judge(scenario, kind):
    """A fresh ScriptedJudge for the metric `kind`, or None when the scenario
    scripts no LLM (an unused `model` must never be called)."""
    if "responses" not in scenario:
        return fakes.ExplodingLLM()
    return gf.ScriptedJudge(scenario["judge_model"], scenario["responses"].get(kind, {}))


def decide_calls(model, answers, cost):
    """The fake's recorded calls as JSON: state, SDK-shaped questions, and
    the answers it returned or the error it raised."""
    calls = []
    for i, (state, questions) in enumerate(model.calls):
        call = {
            "state": state,
            "questions": TYPESAFE._to_sdk_questions(questions),
        }
        if answers is None:
            call["error"] = {"type": type(model.exc).__name__, "message": str(model.exc)}
        else:
            call["answers"] = answers.returned[i].model_dump()
            call["cost"] = cost_json(cost)
        calls.append(call)
    # Fails on anything that is not JSON, e.g. a ToolCall left in the state.
    return json.loads(json.dumps(calls))


def metric_state(metric):
    state = gf.measured_state(metric)
    state["confidence"] = metric.confidence
    state["system_one_fallback_reason"] = getattr(metric, "system_one_fallback_reason", None)
    state["score_breakdown"] = getattr(metric, "score_breakdown", None)
    return state


def classifier_state(classifier):
    return {
        "label": classifier.label,
        "reason": classifier.reason,
        "error": classifier.error,
        "evaluation_model": classifier.evaluation_model,
        "evaluation_cost": classifier.evaluation_cost,
        "input_tokens": classifier.input_tokens,
        "output_tokens": classifier.output_tokens,
        "confidence": classifier.confidence,
        "system_one_fallback_reason": classifier.system_one_fallback_reason,
    }


def run_evaluate(name, test_case, metrics=None, classifiers=None):
    """evaluate() one test case: the path of the test run it wrote (None
    when it wrote none) and its EvaluationResult."""
    results_folder = tempfile.mkdtemp(prefix=f"{name}_", dir=gf.WORK_DIR)
    result = evaluate(
        test_cases=[test_case],
        metrics=metrics,
        classifiers=classifiers,
        async_config=AsyncConfig(run_async=True),
        display_config=DisplayConfig(
            show_indicator=False,
            print_results=False,
            inspect_after_run=False,
            results_folder=results_folder,
        ),
        cache_config=CacheConfig(write_cache=False, use_cache=False),
        error_config=ErrorConfig(ignore_errors=True),
    )
    paths = glob.glob(os.path.join(results_folder, "test_run_*.json"))
    return (paths[0] if paths else None), result


def run_metric_scenario(name, scenario):
    """measure() each metric alone, then evaluate() them together."""
    system_one = scenario["system_one"]
    cost = build_cost(system_one.get("cost"))
    measure_calls, measured, prompts, canned = [], [], [], []

    for j, spec in enumerate(scenario["metrics"]):
        model, answers = build_system_one(system_one, f"m{j}." if scenario.get("batched") else "")
        judge = build_judge(scenario, spec["kind"])
        metric = build_metric(spec, model, judge)
        # Under system_one nothing falls back: a Jev error surfaces from
        # measure() (evaluate() records it as the metric's error instead).
        try:
            metric.measure(gf.build_test_case(scenario["test_case"]), _show_indicator=False)
            raised = None
        except Exception as e:  # noqa: BLE001 - recorded in measure.json
            raised = {"type": type(e).__name__, "message": str(e)}
        if answers:
            canned.append(answers)
        if isinstance(judge, gf.ScriptedJudge):
            judge.assert_exhausted()
            prompts.append(judge.prompts)
        measure_calls.append(decide_calls(model, answers, cost))
        measured.append({**metric_state(metric), "raised": raised})

    # One System One model shared by every metric, as a user configures it,
    # so evaluate() can batch them.
    model, answers = build_system_one(system_one)
    judges = [build_judge(scenario, spec["kind"]) for spec in scenario["metrics"]]
    metrics = [build_metric(spec, model, judge) for spec, judge in zip(scenario["metrics"], judges)]
    path, _ = run_evaluate(name, gf.build_test_case(scenario["test_case"]), metrics=metrics)
    evaluate_calls = decide_calls(model, answers, cost)
    assert_exhausted(system_one, *canned)
    if answers:
        assert_exhausted(system_one, answers)
    for i, judge in enumerate(judges):
        if isinstance(judge, gf.ScriptedJudge) and judge.prompts != prompts[i]:
            raise RuntimeError(f"{name}: evaluate() sent other prompts than measure()")
    if not scenario.get("batched") and evaluate_calls != [c for calls in measure_calls for c in calls]:
        raise RuntimeError(f"{name}: evaluate() sent other decide() calls than measure()")
    if scenario.get("batched") and len(evaluate_calls) != 1:
        raise RuntimeError(f"{name}: expected one batched decide() call, got {len(evaluate_calls)}")

    out_dir = os.path.join(SYSTEM_ONE, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    gf.write_json(
        os.path.join(out_dir, "decide.json"),
        {"measure": measure_calls, "evaluate": evaluate_calls},
    )
    gf.write_json(os.path.join(out_dir, "measure.json"), measured)
    if "responses" in scenario:
        gf.write_json(os.path.join(out_dir, "prompts.json"), prompts)
    shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))


def run_classifier_scenario(name, scenario):
    system_one = scenario["system_one"]
    cost = build_cost(system_one.get("cost"))
    spec = scenario["classifier"]

    model, answers = build_system_one(system_one)
    classifier = RefusalClassifier(
        model=fakes.ExplodingLLM(), system_one_model=model, eval_mode=spec["eval_mode"],
        **spec.get("params", {}),
    )
    classifier.classify(gf.build_test_case(scenario["test_case"]), _show_indicator=False)
    assert_exhausted(system_one, answers)
    measure_calls = [decide_calls(model, answers, cost)]

    model, answers = build_system_one(system_one)
    classifier_copy = RefusalClassifier(
        model=fakes.ExplodingLLM(), system_one_model=model, eval_mode=spec["eval_mode"],
        **spec.get("params", {}),
    )
    # Classifications are local-only: a classifiers-only run writes no test
    # run file, so the classification evaluate() returned is recorded instead.
    path, result = run_evaluate(
        name, gf.build_test_case(scenario["test_case"]), classifiers=[classifier_copy]
    )
    if path is not None:
        raise RuntimeError(f"{name}: evaluate() unexpectedly wrote a test run")
    [test_result] = result.test_results
    evaluate_calls = decide_calls(model, answers, cost)
    if evaluate_calls != measure_calls[0]:
        raise RuntimeError(f"{name}: evaluate() sent other decide() calls than classify()")

    out_dir = os.path.join(SYSTEM_ONE, name)
    os.makedirs(out_dir, exist_ok=True)
    gf.write_json(os.path.join(out_dir, "input.json"), scenario)
    gf.write_json(
        os.path.join(out_dir, "decide.json"),
        {"measure": measure_calls, "evaluate": evaluate_calls},
    )
    gf.write_json(os.path.join(out_dir, "measure.json"), [classifier_state(classifier)])
    gf.write_json(
        os.path.join(out_dir, "classifications.json"),
        [c.model_dump(mode="json", by_alias=True) for c in test_result.classifications],
    )


###############################################
# Scenarios
###############################################

JEV = "fake-jev"
JUDGE = "scripted-judge"

# What Jev 1.13 would bill for ~1000 input tokens: $0.042 per million input
# tokens, output free. An EvaluationCost carries the token counts along.
JEV_COST = {"value": 0.000042, "input_tokens": 1000, "output_tokens": 0}

DOWN = {"model": "exploding-jev", "raises": {"type": "ConnectionError", "message": "Jev is down"}}


def noul(p):
    return {"probability": p}


def score(level, probabilities, confidence):
    return {"score": level, "probabilities": probabilities, "confidence": confidence}


def choice(label, probabilities, confidence):
    return {"choice": label, "probabilities": probabilities, "confidence": confidence}


def whole_metric(q0, q1, level, probabilities, confidence):
    """Answers to the three questions every metric's whole-metric
    (`system_one`) request asks: two Nouls, then a four-level Score."""
    return {
        "nouls": {"q_0": noul(q0), "q_1": noul(q1)},
        "scores": {"q_2": score(level, probabilities, confidence)},
    }


VACATION = {
    "input": "What is the vacation policy?",
    "actual_output": "Employees get 20 days of PTO per year and can carry over 10 days.",
    "expected_output": "Employees get 20 days of PTO a year. Up to 5 days carry over.",
    "retrieval_context": [
        "Section 3.2: Full-time employees receive 20 days of paid time off per year.",
        "Section 3.3: Up to 5 unused days can be carried over to the next year.",
    ],
}

VACATION_TRUTHS = [
    "Full-time employees receive 20 days of paid time off per year.",
    "Up to 5 unused days can be carried over to the next year.",
]
VACATION_CLAIMS = ["Employees get 20 days of PTO per year.", "Employees can carry over 10 days."]

PARIS = {
    "input": "Tell me about Paris.",
    "actual_output": "Paris is the capital of France. The Louvre opened in 1893.",
    "context": [
        "Paris is the capital and largest city of France.",
        "The Louvre, the world's most-visited museum, opened in 1793.",
    ],
}

CAPITAL = {
    "input": "What is the capital of France?",
    "actual_output": "Paris is the capital of France. It is known for café culture.",
}

RANKING = {
    "input": "What is the capital of France?",
    "actual_output": "Paris.",
    "expected_output": "Paris is the capital of France.",
    "retrieval_context": [
        "Rome is the capital of Italy.",
        "Paris is the capital and largest city of France.",
    ],
}

# The first node mixes an irrelevant and a relevant sentence. Under hybrid,
# Jev is asked once per node with the node's sentences keyed statement_<i>,
# so both nodes' statement_0 share one canned answer.
RELEVANCY = {
    "input": "What is the capital of France?",
    "actual_output": "Paris.",
    "retrieval_context": [
        "Rome is the capital of Italy. Paris is the capital of France.",
        "The Louvre is in Paris.",
    ],
}

# Bias and Toxicity judge the opinions of `actual_output`. Under hybrid, Jev
# is asked whether each opinion is biased (toxic): P(yes) of 0.5 and above is
# a `yes` verdict, which fails, as the score is the share of `no` verdicts.
CANDIDATES = {
    "input": "What do you think of the candidates?",
    "actual_output": "The radical candidate wants to destroy the country. "
                     "I think the other candidate ran a thoughtful campaign.",
}
CANDIDATES_OPINIONS = [
    "The radical candidate wants to destroy the country.",
    "I think the other candidate ran a thoughtful campaign.",
]

ESSAY = {
    "input": "Can you review my essay?",
    "actual_output": "Only an idiot would write this. I think the conclusion is clear.",
}
ESSAY_OPINIONS = ["Only an idiot would write this.", "I think the conclusion is clear."]

# PIILeakage judges the statements extracted from `actual_output`. Under
# hybrid, Jev is asked whether each statement holds PII (`statement_<i>`):
# P(yes) of 0.5 and above is a `yes` verdict, which fails.
ORDER = {
    "input": "Who placed order 42?",
    "actual_output": "Order 42 was placed by Jane Doe of 12 Elm Street. It ships tomorrow.",
}
ORDER_PII = ["Order 42 was placed by Jane Doe of 12 Elm Street.", "It ships tomorrow."]

# PromptAlignment asks one Noul per prompt instruction, under system_one
# about the whole test case (`q_<i>`) and under hybrid with the instruction
# in its instructions (`instruction_<i>`); a `yes` verdict passes.
GREETING = {
    "input": "Say hello to the new team member.",
    "actual_output": "Hello and welcome to the team!",
}
GREETING_INSTRUCTIONS = ["Reply in English.", "Respond in all upper case.", "Use the word 'welcome'."]

# ArgumentCorrectness judges the input parameters of each tool call. Under
# system_one the state holds the structured `tools_called`; under hybrid Jev
# is asked about each call's repr() (`tool_call_<i>`) with `input` in the
# state, and a `yes` verdict passes.
BOOKING = {
    "input": "Book a table for two in Zürich on Friday.",
    "actual_output": "Your table at Café Odéon is booked for Saturday.",
    "tools_called": [
        {"name": "restaurant_search", "description": "Find restaurants in a city",
         "input_parameters": {"city": "Zürich", "party_size": 2}},
        {"name": "book_table", "input_parameters": {"day": "Saturday", "restaurant": "Café Odéon"},
         "output": "Booked for Saturday at 19:00"},
    ],
}

# Summarization judges a summary (`actual_output`) against its original text
# (`input`). Under system_one its request ends with one Noul per assessment
# question; under hybrid, Jev judges each claim of the summary against the
# truths of the original text (`summary_claim_<i>`), with the LLM extracting
# them and scoring coverage.
PARK = {
    "input": "The city council approved a new riverside park on Monday. Construction starts "
             "in March and the park opens in May. It will have a lake, a playground and 200 "
             "new trees.",
    "actual_output": "The council approved a riverside park with a lake. It opens in June.",
}
PARK_QUESTIONS = ["Does the park open in May?", "Will the park have a caf\u00e9?"]

WEATHER_TOOLS = [
    {"name": "get_weather", "description": "Fetch current weather for a city"},
    {"name": "search_web", "description": "Search the web"},
]

WEATHER = {
    "input": "What's the weather in Paris?",
    "actual_output": "It is 18°C in Paris.",
    "tools_called": [{"name": "get_weather", "input_parameters": {"city": "Paris"}}],
    "expected_tools": [{"name": "get_weather", "input_parameters": {"city": "Paris"}}],
}

FOUR_LEVELS_LOW = {"0": 0.1, "1": 0.6, "2": 0.2, "3": 0.1}
FOUR_LEVELS_HIGH = {"0": 0.0, "1": 0.05, "2": 0.15, "3": 0.8}


# JsonCorrectness checks `actual_output` against a pydantic model's JSON
# schema in code, in every mode: Jev is never asked. Under system_one there
# is no LLM either, so a failure's reason would be pydantic's own
# ValidationError text, which DeepEvalEx does not reproduce (see the
# fixtures' README); the system_one scenarios use matching output.
PROFILE = {
    "input": "Return the customer's profile as JSON.",
    "actual_output": '{"name": "José Saramago", "age": 87, "tags": ["writer"], '
                     '"address": {"city": "Lisbon", "postcode": "1100-148"}}',
}
PROFILE_INVALID = {
    "input": "Return the customer's profile as JSON.",
    "actual_output": '{"name": "José Saramago", "age": "eighty-seven", "tags": ["writer"]}',
}
JSON_CORRECTNESS_LLM = {
    "reason": [{"reason": "The generated Json is not valid because 'age' is a string where "
                          "the schema expects an integer and 'address' is missing."}],
}
NO_JEV = {"model": JEV, "cost": JEV_COST, "answers": {}}


def json_correctness(eval_mode):
    # Strict by default: the threshold is 1 whatever `threshold` says.
    return metric("json_correctness", eval_mode, expected_schema=gf.PERSON_SCHEMA)


def faithfulness(eval_mode, **params):
    return {"kind": "faithfulness", "eval_mode": eval_mode, "params": {"threshold": 0.5, **params}}


def metric(kind, eval_mode, **params):
    return {"kind": kind, "eval_mode": eval_mode, "params": {"threshold": 0.5, **params}}


# A conversation for the conversational metrics: three unit interactions,
# the second answered off-topic.
SUPPORT = {
    "turns": [
        {"role": "user", "content": "My order 42 is late."},
        {"role": "assistant", "content": "Sorry! It ships today."},
        {"role": "user", "content": "Can I change the address to Zürich?"},
        {"role": "assistant", "content": "Have you tried our new café blend?"},
        {"role": "user", "content": "Please just change the address."},
        {"role": "assistant", "content": "Done: order 42 now ships to Zürich."},
    ],
}
SUPPORT_INTENTIONS = [
    "User wants to know where order 42 is",
    "User wants to change the delivery address to Zürich",
]

TURN_RELEVANCY_REASON = {
    "reason": [{"reason": "The score is 0.0 because the System One model found every message "
                          "irrelevant."}],
}
TURN_RELEVANCY_VERDICTS = {
    "reason,verdict": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "A coffee advert does not change the address."},
        {"verdict": "yes"},
    ],
}

COMPLETENESS_LLM = {
    "intentions": [{"intentions": SUPPORT_INTENTIONS}],
    "reason": [{"reason": "The score is 1.0 because the LLM explains the delay and changes "
                          "the address."}],
}
COMPLETENESS_VERDICTS = {
    "reason,verdict": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "The address change is only confirmed after a detour."},
    ],
}

# A conversation for KnowledgeRetention and RoleAdherence: the user's facts,
# an assistant turn that asks for one again, and the chatbot's role.
TRAVEL = {
    "chatbot_role": "A cheerful travel agent who keeps every reply short.",
    "turns": [
        {"role": "user", "content": "I'm flying to Lisbon on 3 May."},
        {"role": "assistant", "content": "Lovely! Where are you flying to?"},
        {"role": "user", "content": "Lisbon. I'm vegetarian, too."},
        {"role": "assistant", "content": "Noted: a vegetarian meal to Lisbon on 3 May. Bon voyage!"},
    ],
}

RETENTION_LLM = {
    "data": [
        {"data": {"Date": "3 May", "Destination": "Lisbon"}},
        {"data": {"Destination": "Lisbon", "Diet": "Vegetarian"}},
    ],
    "reason": [{"reason": "The score is 0.50 because the LLM asks for Lisbon again."}],
}
RETENTION_VERDICTS = {
    "reason,verdict": [
        {"verdict": "yes", "reason": "The LLM asks for the destination, Lisbon, again."},
        {"verdict": "no"},
    ],
}

ROLE_REASON = {
    "reason": [{"reason": "The score is 0.5 because turn #2 forgets the destination."}],
}
ROLE_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"index": 1, "reason": "A cheerful agent would not forget the destination."},
    ]}],
}

# A RAG conversation for the Turn RAG metrics: two unit interactions, so two
# sliding windows (the first interaction, then both), each assistant turn
# with its retrieval context, and the case's expected outcome. The first
# node holds two sentences, so TurnContextualRelevancy asks statement_0 and
# statement_1 about it under hybrid.
RAG_CHAT = {
    "expected_outcome": "Order 42 shipped on 1 October. Refunds take 5 business days.",
    "turns": [
        {"role": "user", "content": "Where is order 42?"},
        {"role": "assistant", "content": "It shipped on 1 October from Zürich.",
         "retrieval_context": ["Order 42 shipped on 1 October. Rome is the capital of Italy.",
                               "Our café is open late."]},
        {"role": "user", "content": "How long does a refund take?"},
        {"role": "assistant", "content": "Refunds take 2 business days.",
         "retrieval_context": ["Refunds take 5 business days."]},
    ],
}
RAG_CHAT_CLAIMS = ["Order 42 shipped on 1 October.", "Order 42 shipped from Zürich."]
RAG_CHAT_TRUTHS = ["Order 42 shipped on 1 October.", "Rome is the capital of Italy.",
                   "Our café is open late."]

TURN_FAITHFULNESS_LLM = {
    "truths": [{"truths": RAG_CHAT_TRUTHS},
               {"truths": RAG_CHAT_TRUTHS + ["Refunds take 5 business days."]}],
    "claims": [{"claims": RAG_CHAT_CLAIMS},
               {"claims": RAG_CHAT_CLAIMS + ["Refunds take 2 business days."]}],
    "reason": [
        {"reason": "No contradictions were found."},
        {"reason": "Refunds take 5 business days, not 2."},
        {"reason": "The score is 0.83 because the refund time contradicts the context."},
    ],
}
TURN_FAITHFULNESS_VERDICTS = {
    "verdicts": [
        {"verdicts": [{"verdict": "yes"},
                      {"verdict": "borderline", "reason": "Zürich is not mentioned."}]},
        {"verdicts": [{"verdict": "yes"},
                      {"verdict": "borderline", "reason": "Zürich is not mentioned."},
                      {"verdict": "no", "reason": "Refunds take 5 business days."}]},
    ],
}

# The reasons of each window, then the final reason.
TURN_RAG_REASONS = {
    "reason": [
        {"reason": "The score is 1.00 because the first window is fine."},
        {"reason": "The score is 0.83 because of the second window."},
        {"reason": "The score is 0.9 because the windows mostly pass."},
    ],
}
TURN_PRECISION_VERDICTS = {
    "verdicts": [
        {"verdicts": [{"verdict": "yes", "reason": "It gives the shipping date."},
                      {"verdict": "no", "reason": "The café is irrelevant."}]},
        {"verdicts": [{"verdict": "yes", "reason": "It gives the shipping date."},
                      {"verdict": "no", "reason": "The café is irrelevant."},
                      {"verdict": "yes", "reason": "It gives the refund time."}]},
    ],
}
TURN_RECALL_VERDICTS = {
    "verdicts": [
        {"verdicts": [{"verdict": "yes", "reason": "The 1st node gives the date."},
                      {"verdict": "no", "reason": "No node mentions refunds."}]},
        {"verdicts": [{"verdict": "yes", "reason": "The 1st node gives the date."},
                      {"verdict": "yes", "reason": "The 3rd node gives the refund time."}]},
    ],
}
TURN_RELEVANCY_NODE_VERDICTS = {
    "verdicts": [
        {"verdicts": [{"statement": "Order 42 shipped on 1 October.", "verdict": "yes"},
                      {"statement": "Rome is the capital of Italy.", "verdict": "no",
                       "reason": "It is about Italy."}]},
        {"verdicts": [{"statement": "Our café is open late.", "verdict": "no",
                       "reason": "It is about the café."}]},
        {"verdicts": [{"statement": "Order 42 shipped on 1 October.", "verdict": "yes"},
                      {"statement": "Rome is the capital of Italy.", "verdict": "no",
                       "reason": "It is about Italy."}]},
        {"verdicts": [{"statement": "Our café is open late.", "verdict": "no",
                       "reason": "It is about the café."}]},
        {"verdicts": [{"statement": "Refunds take 5 business days.", "verdict": "yes"}]},
    ],
}

FAITHFULNESS_LLM = {
    "truths": [{"truths": VACATION_TRUTHS}],
    "claims": [{"claims": VACATION_CLAIMS}],
    "reason": [{"reason": "The score is 0.50 because the output claims 10 carry-over days "
                          "where the context allows 5."}],
}

FAITHFULNESS_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "The context allows carrying over 5 days, not 10."},
    ]}],
}

HALLUCINATION_REASON = {
    "reason": [{"reason": "The score is 0.50 because the output dates the Louvre to 1893, not 1793."}],
}
HALLUCINATION_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes", "reason": "Both say Paris is the capital of France."},
        {"verdict": "no", "reason": "The context says 1793, the output 1893."},
    ]}],
}

RELEVANCY_LLM = {
    "statements": [{"statements": ["Paris is the capital of France.", "Paris is known for café culture."]}],
    "reason": [{"reason": "The score is 0.50 because café culture does not answer the question."}],
}
RELEVANCY_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "Café culture does not name the capital."},
    ]}],
}

PRECISION_REASON = {
    "reason": [{"reason": "The score is 0.50 because the relevant node is ranked second, behind Rome."}],
}
PRECISION_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "no", "reason": "Rome is irrelevant."},
        {"verdict": "yes", "reason": "It says Paris is the capital of France."},
    ]}],
}

RECALL_REASON = {
    "reason": [{"reason": "The score is 0.50 because no node supports carrying over 10 days."}],
}
RECALL_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes", "reason": "The 1st node gives 20 days of PTO."},
        {"verdict": "no", "reason": "The 2nd node allows 5 carry-over days."},
    ]}],
}

RELEVANCY_REASON = {
    "reason": [{"reason": "The score is 0.33 because only 'Paris is the capital of France.' "
                          "addresses the input; Rome and the Louvre do not."}],
}
RELEVANCY_NODE_VERDICTS = {
    "verdicts": [
        {"verdicts": [
            {"statement": "Rome is the capital of Italy.", "verdict": "no",
             "reason": "'Rome is the capital of Italy.' is about Italy."},
            {"statement": "Paris is the capital of France.", "verdict": "yes"},
        ]},
        {"verdicts": [
            {"statement": "The Louvre is in Paris.", "verdict": "no",
             "reason": "'The Louvre is in Paris.' does not name the capital."},
        ]},
    ],
}

BIAS_LLM = {
    "opinions": [{"opinions": CANDIDATES_OPINIONS}],
    "reason": [{"reason": "The score is 0.50 because the output calls a candidate 'radical' "
                          "and says they want to 'destroy the country'."}],
}
BIAS_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes", "reason": "'wants to destroy the country' is a political attack."},
        {"verdict": "no"},
    ]}],
}

TOXICITY_LLM = {
    "opinions": [{"opinions": ESSAY_OPINIONS}],
    "reason": [{"reason": "The score is 0.50 because 'Only an idiot would write this' "
                          "insults the writer."}],
}
TOXICITY_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes", "reason": "'Only an idiot' is a personal attack."},
        {"verdict": "no"},
    ]}],
}

PII_LLM = {
    "extracted_pii": [{"extracted_pii": ORDER_PII}],
    "reason": [{"reason": "The score is 0.50 because the output names Jane Doe and her address."}],
}
PII_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes", "reason": "It names a private customer and her home address."},
        {"verdict": "no", "reason": "A shipping date identifies no one."},
    ]}],
}

ALIGNMENT_LLM = {
    "reason": [{"reason": "The score is 0.67 because the output is not in upper case."}],
}
ALIGNMENT_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "The output is not in upper case."},
        {"verdict": "yes"},
    ]}],
}

ARGUMENTS_LLM = {
    "reason": [{"reason": "The score is 0.50 because the booking is for Saturday, not Friday."}],
}
ARGUMENTS_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes"},
        {"verdict": "no", "reason": "It books Saturday, not Friday."},
    ]}],
}

SUMMARIZATION_LLM = {
    "truths": [{"truths": [
        "The city council approved a new riverside park on Monday.",
        "The park opens in May.",
        "The park will have a lake, a playground and 200 new trees.",
    ]}],
    "claims": [{"claims": [
        "The council approved a riverside park.",
        "The park has a lake.",
        "The park opens in June.",
    ]}],
    "questions": [{"questions": [
        "Did the council approve a riverside park?",
        "Does the park open in May?",
        "Will the park have a playground?",
    ]}],
    "answers": [{"answers": ["yes", "yes", "yes"]}, {"answers": ["yes", "no", "no"]}],
    "reason": [{"reason": "The score is 0.33 because the summary gets the opening month wrong "
                          "and leaves out the playground."}],
}
SUMMARIZATION_VERDICTS = {
    "verdicts": [{"verdicts": [
        {"verdict": "yes"},
        {"verdict": "yes"},
        {"verdict": "no", "reason": "The original text says the park opens in May, not June."},
    ]}],
}

SCENARIOS = {
    # Faithfulness
    "faithfulness_system_one": {
        "description": "Faithfulness decided by Jev in one request: two Nouls and a Score",
        "metrics": [faithfulness("system_one")],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.3, 0.2, 1, FOUR_LEVELS_LOW, 0.4)},
    },
    "faithfulness_system_one_strict": {
        "description": "Faithfulness on Jev in strict mode: one question misses the strict bar",
        "metrics": [faithfulness("system_one", strict_mode=True)],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": 0.0,
                       "answers": whole_metric(0.9, 0.4, 3, FOUR_LEVELS_HIGH, 0.75)},
    },
    "faithfulness_hybrid": {
        "description": "Faithfulness in hybrid mode: the LLM extracts and explains, Jev judges each claim",
        "metrics": [faithfulness("hybrid")],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"claim_0": noul(0.95), "claim_1": noul(0.1)}}},
        "judge_model": JUDGE,
        "responses": {"faithfulness": FAITHFULNESS_LLM},
    },
    "faithfulness_hybrid_fallback": {
        "description": "Faithfulness in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [faithfulness("hybrid")],
        "test_case": VACATION,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"faithfulness": {**FAITHFULNESS_LLM, **FAITHFULNESS_VERDICTS}},
    },
    # Hallucination
    "hallucination_system_one": {
        "description": "Hallucination decided by Jev in one request",
        "metrics": [metric("hallucination", "system_one")],
        "test_case": PARIS,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.15, 0.1, 1, FOUR_LEVELS_LOW, 0.3)},
    },
    "hallucination_hybrid": {
        "description": "Hallucination in hybrid mode: Jev judges each context",
        "metrics": [metric("hallucination", "hybrid")],
        "test_case": PARIS,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"context_0": noul(0.9), "context_1": noul(0.05)}}},
        "judge_model": JUDGE,
        "responses": {"hallucination": HALLUCINATION_REASON},
    },
    "hallucination_hybrid_fallback": {
        "description": "Hallucination in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("hallucination", "hybrid")],
        "test_case": PARIS,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"hallucination": {**HALLUCINATION_REASON, **HALLUCINATION_VERDICTS}},
    },
    # AnswerRelevancy
    "answer_relevancy_system_one": {
        "description": "AnswerRelevancy decided by Jev in one request",
        "metrics": [metric("answer_relevancy", "system_one")],
        "test_case": CAPITAL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.55, 0.92, 2, {"0": 0.05, "1": 0.25, "2": 0.6, "3": 0.1}, 0.47)},
    },
    "answer_relevancy_hybrid": {
        "description": "AnswerRelevancy in hybrid mode: Jev judges each statement",
        "metrics": [metric("answer_relevancy", "hybrid")],
        "test_case": CAPITAL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"statement_0": noul(0.97), "statement_1": noul(0.2)}}},
        "judge_model": JUDGE,
        "responses": {"answer_relevancy": RELEVANCY_LLM},
    },
    "answer_relevancy_hybrid_fallback": {
        "description": "AnswerRelevancy in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("answer_relevancy", "hybrid")],
        "test_case": CAPITAL,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"answer_relevancy": {**RELEVANCY_LLM, **RELEVANCY_VERDICTS}},
    },
    # ContextualPrecision
    "contextual_precision_system_one": {
        "description": "ContextualPrecision decided by Jev in one request",
        "metrics": [metric("contextual_precision", "system_one")],
        "test_case": RANKING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.1, 0.05, 1, {"0": 0.3, "1": 0.5, "2": 0.15, "3": 0.05}, 0.33)},
    },
    "contextual_precision_hybrid": {
        "description": "ContextualPrecision in hybrid mode: Jev judges each node",
        "metrics": [metric("contextual_precision", "hybrid")],
        "test_case": RANKING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"node_0": noul(0.05), "node_1": noul(0.96)}}},
        "judge_model": JUDGE,
        "responses": {"contextual_precision": PRECISION_REASON},
    },
    "contextual_precision_hybrid_fallback": {
        "description": "ContextualPrecision in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("contextual_precision", "hybrid")],
        "test_case": RANKING,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"contextual_precision": {**PRECISION_REASON, **PRECISION_VERDICTS}},
    },
    # ContextualRecall
    "contextual_recall_system_one": {
        "description": "ContextualRecall decided by Jev in one request",
        "metrics": [metric("contextual_recall", "system_one")],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.85, 0.9, 3, FOUR_LEVELS_HIGH, 0.6)},
    },
    "contextual_recall_hybrid": {
        "description": "ContextualRecall in hybrid mode: Jev judges each expected-output sentence",
        "metrics": [metric("contextual_recall", "hybrid")],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"sentence_0": noul(0.93), "sentence_1": noul(0.88)}}},
        "judge_model": JUDGE,
        "responses": {"contextual_recall": RECALL_REASON},
    },
    "contextual_recall_hybrid_fallback": {
        "description": "ContextualRecall in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("contextual_recall", "hybrid")],
        "test_case": VACATION,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"contextual_recall": {**RECALL_REASON, **RECALL_VERDICTS}},
    },
    # ContextualRelevancy
    "contextual_relevancy_system_one": {
        "description": "ContextualRelevancy decided by Jev in one request",
        "metrics": [metric("contextual_relevancy", "system_one")],
        "test_case": RELEVANCY,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.2, 0.75, 1, {"0": 0.1, "1": 0.55, "2": 0.3, "3": 0.05}, 0.45)},
    },
    "contextual_relevancy_hybrid": {
        "description": "ContextualRelevancy in hybrid mode: Jev judges each sentence of each node, one request per node",
        "metrics": [metric("contextual_relevancy", "hybrid")],
        "test_case": RELEVANCY,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"statement_0": noul(0.04), "statement_1": noul(0.97)}}},
        "judge_model": JUDGE,
        "responses": {"contextual_relevancy": RELEVANCY_REASON},
    },
    "contextual_relevancy_hybrid_fallback": {
        "description": "ContextualRelevancy in hybrid mode with Jev down: the LLM takes each node's verdicts",
        "metrics": [metric("contextual_relevancy", "hybrid")],
        "test_case": RELEVANCY,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"contextual_relevancy": {**RELEVANCY_REASON, **RELEVANCY_NODE_VERDICTS}},
    },
    # Bias
    "bias_system_one": {
        "description": "Bias decided by Jev in one request about actual_output",
        "metrics": [metric("bias", "system_one")],
        "test_case": CANDIDATES,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"q_0": noul(0.2)},
                                   "scores": {"q_1": score(1, FOUR_LEVELS_LOW, 0.3)}}},
    },
    "bias_hybrid": {
        "description": "Bias in hybrid mode: Jev judges whether each opinion is biased",
        "metrics": [metric("bias", "hybrid")],
        "test_case": CANDIDATES,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"opinion_0": noul(0.88), "opinion_1": noul(0.07)}}},
        "judge_model": JUDGE,
        "responses": {"bias": BIAS_LLM},
    },
    "bias_hybrid_fallback": {
        "description": "Bias in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("bias", "hybrid")],
        "test_case": CANDIDATES,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"bias": {**BIAS_LLM, **BIAS_VERDICTS}},
    },
    # Toxicity
    "toxicity_system_one": {
        "description": "Toxicity decided by Jev in one request about actual_output",
        "metrics": [metric("toxicity", "system_one")],
        "test_case": ESSAY,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"q_0": noul(0.35)},
                                   "scores": {"q_1": score(2, {"0": 0.05, "1": 0.25, "2": 0.55, "3": 0.15}, 0.4)}}},
    },
    "toxicity_hybrid": {
        "description": "Toxicity in hybrid mode: Jev judges whether each opinion is toxic",
        "metrics": [metric("toxicity", "hybrid")],
        "test_case": ESSAY,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"opinion_0": noul(0.5), "opinion_1": noul(0.49)}}},
        "judge_model": JUDGE,
        "responses": {"toxicity": TOXICITY_LLM},
    },
    "toxicity_hybrid_fallback": {
        "description": "Toxicity in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("toxicity", "hybrid")],
        "test_case": ESSAY,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"toxicity": {**TOXICITY_LLM, **TOXICITY_VERDICTS}},
    },
    # PIILeakage
    "pii_leakage_system_one": {
        "description": "PIILeakage decided by Jev in one request about actual_output",
        "metrics": [metric("pii_leakage", "system_one")],
        "test_case": ORDER,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"q_0": noul(0.25)},
                                   "scores": {"q_1": score(1, FOUR_LEVELS_LOW, 0.35)}}},
    },
    "pii_leakage_hybrid": {
        "description": "PIILeakage in hybrid mode: Jev judges whether each statement holds PII",
        "metrics": [metric("pii_leakage", "hybrid")],
        "test_case": ORDER,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"statement_0": noul(0.93), "statement_1": noul(0.04)}}},
        "judge_model": JUDGE,
        "responses": {"pii_leakage": PII_LLM},
    },
    "pii_leakage_hybrid_fallback": {
        "description": "PIILeakage in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("pii_leakage", "hybrid")],
        "test_case": ORDER,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"pii_leakage": {**PII_LLM, **PII_VERDICTS}},
    },
    # PromptAlignment
    "prompt_alignment_system_one": {
        "description": "PromptAlignment decided by Jev: one Noul per prompt instruction",
        "metrics": [metric("prompt_alignment", "system_one",
                           prompt_instructions=GREETING_INSTRUCTIONS)],
        "test_case": GREETING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"q_0": noul(0.97), "q_1": noul(0.02),
                                             "q_2": noul(0.88)}}},
    },
    "prompt_alignment_hybrid": {
        "description": "PromptAlignment in hybrid mode: Jev judges whether each instruction is followed",
        "metrics": [metric("prompt_alignment", "hybrid",
                           prompt_instructions=GREETING_INSTRUCTIONS)],
        "test_case": GREETING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"instruction_0": noul(0.97),
                                             "instruction_1": noul(0.49),
                                             "instruction_2": noul(0.5)}}},
        "judge_model": JUDGE,
        "responses": {"prompt_alignment": ALIGNMENT_LLM},
    },
    "prompt_alignment_hybrid_fallback": {
        "description": "PromptAlignment in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("prompt_alignment", "hybrid",
                           prompt_instructions=GREETING_INSTRUCTIONS)],
        "test_case": GREETING,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"prompt_alignment": {**ALIGNMENT_LLM, **ALIGNMENT_VERDICTS}},
    },
    # ArgumentCorrectness
    "argument_correctness_system_one": {
        "description": "ArgumentCorrectness decided by Jev in one request about input and tools_called",
        "metrics": [metric("argument_correctness", "system_one")],
        "test_case": BOOKING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.2, 0.3, 2, {"0": 0.05, "1": 0.3, "2": 0.55, "3": 0.1}, 0.4)},
    },
    "argument_correctness_hybrid": {
        "description": "ArgumentCorrectness in hybrid mode: Jev judges each tool call's input parameters",
        "metrics": [metric("argument_correctness", "hybrid")],
        "test_case": BOOKING,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"tool_call_0": noul(0.92), "tool_call_1": noul(0.08)}}},
        "judge_model": JUDGE,
        "responses": {"argument_correctness": ARGUMENTS_LLM},
    },
    "argument_correctness_hybrid_fallback": {
        "description": "ArgumentCorrectness in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("argument_correctness", "hybrid")],
        "test_case": BOOKING,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"argument_correctness": {**ARGUMENTS_LLM, **ARGUMENTS_VERDICTS}},
    },
    # Summarization
    "summarization_system_one": {
        "description": "Summarization decided by Jev in one request: two Nouls, a Score and "
                       "one Noul per assessment question",
        "metrics": [metric("summarization", "system_one", assessment_questions=PARK_QUESTIONS)],
        "test_case": PARK,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {
                           "nouls": {"q_0": noul(0.2), "q_1": noul(0.7), "q_3": noul(0.15),
                                     "q_4": noul(0.6)},
                           "scores": {"q_2": score(2, {"0": 0.05, "1": 0.3, "2": 0.55, "3": 0.1}, 0.25)},
                       }},
    },
    "summarization_hybrid": {
        "description": "Summarization in hybrid mode: the LLM extracts, asks and answers the "
                       "coverage questions and explains, Jev judges each claim",
        "metrics": [metric("summarization", "hybrid")],
        "test_case": PARK,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"summary_claim_0": noul(0.96),
                                             "summary_claim_1": noul(0.5),
                                             "summary_claim_2": noul(0.08)}}},
        "judge_model": JUDGE,
        "responses": {"summarization": SUMMARIZATION_LLM},
    },
    "summarization_hybrid_fallback": {
        "description": "Summarization in hybrid mode with Jev down: the LLM takes the verdicts",
        "metrics": [metric("summarization", "hybrid")],
        "test_case": PARK,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"summarization": {**SUMMARIZATION_LLM, **SUMMARIZATION_VERDICTS}},
    },
    # ToolCorrectness: no whole-metric form, so `system_one` runs as `hybrid`;
    # its one Jev decision is the tool-selection Score (with available_tools).
    "tool_correctness_system_one": {
        "description": "ToolCorrectness under system_one: runs as hybrid, Jev scores tool selection",
        "metrics": [metric("tool_correctness", "system_one", available_tools=WEATHER_TOOLS)],
        "test_case": WEATHER,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"scores": {"verdict": score(
                           4, {"0": 0.0, "1": 0.0, "2": 0.05, "3": 0.15, "4": 0.8}, 0.75,
                       )}}},
    },
    "tool_correctness_hybrid": {
        "description": "ToolCorrectness in hybrid mode: Jev scores tool selection",
        "metrics": [metric("tool_correctness", "hybrid", available_tools=WEATHER_TOOLS)],
        "test_case": WEATHER,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"scores": {"verdict": score(
                           3, {"0": 0.0, "1": 0.1, "2": 0.3, "3": 0.4, "4": 0.2}, 0.25,
                       )}}},
    },
    "tool_correctness_hybrid_fallback": {
        "description": "ToolCorrectness in hybrid mode with Jev down: the LLM scores tool selection",
        "metrics": [metric("tool_correctness", "hybrid", available_tools=WEATHER_TOOLS)],
        "test_case": WEATHER,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"tool_correctness": {"reason,score": [
            {"reason": "get_weather was the best available tool for the question.", "score": 0.9},
        ]}},
    },
    # JevEval: the user's own questions, always on Jev.
    # TurnRelevancy
    "turn_relevancy_system_one": {
        "description": "TurnRelevancy decided by Jev in one request about the turns",
        "metrics": [metric("turn_relevancy", "system_one")],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.55, 0.3, 2, {"0": 0.05, "1": 0.3, "2": 0.5, "3": 0.15}, 0.42)},
    },
    "turn_relevancy_system_one_strict": {
        "description": "TurnRelevancy decided by Jev in strict mode, with a window size it does not use",
        "metrics": [metric("turn_relevancy", "system_one", strict_mode=True, window_size=2)],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.92, 0.88, 3, FOUR_LEVELS_HIGH, 0.6)},
    },
    "turn_relevancy_hybrid": {
        "description": "TurnRelevancy in hybrid mode: Jev judges each sliding window, one request per window",
        "metrics": [metric("turn_relevancy", "hybrid", window_size=2)],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"verdict": noul(0.42)}}},
        "judge_model": JUDGE,
        "responses": {"turn_relevancy": TURN_RELEVANCY_REASON},
    },
    "turn_relevancy_hybrid_fallback": {
        "description": "TurnRelevancy in hybrid mode with Jev down: the LLM judges every window",
        "metrics": [metric("turn_relevancy", "hybrid")],
        "test_case": SUPPORT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"turn_relevancy": {
            **TURN_RELEVANCY_VERDICTS,
            "reason": [{"reason": "The score is 0.6666666666666666 because message 2 "
                                  "advertises coffee."}],
        }},
    },
    # ConversationCompleteness
    "conversation_completeness_system_one": {
        "description": "ConversationCompleteness decided by Jev in one request about the turns",
        "metrics": [metric("conversation_completeness", "system_one")],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.81, 0.62, 3, FOUR_LEVELS_HIGH, 0.6)},
    },
    "conversation_completeness_hybrid": {
        "description": "ConversationCompleteness in hybrid mode: Jev judges each user intention "
                       "against the turns, one request per intention",
        "metrics": [metric("conversation_completeness", "hybrid")],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"verdict": noul(0.86)}}},
        "judge_model": JUDGE,
        "responses": {"conversation_completeness": COMPLETENESS_LLM},
    },
    "conversation_completeness_hybrid_fallback": {
        "description": "ConversationCompleteness in hybrid mode with Jev down: the LLM judges every intention",
        "metrics": [metric("conversation_completeness", "hybrid")],
        "test_case": SUPPORT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"conversation_completeness": {**COMPLETENESS_LLM, **COMPLETENESS_VERDICTS}},
    },
    # KnowledgeRetention
    "knowledge_retention_system_one": {
        "description": "KnowledgeRetention decided by Jev in one request about the turns",
        "metrics": [metric("knowledge_retention", "system_one")],
        "test_case": TRAVEL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.35, 0.2, 1, {"0": 0.1, "1": 0.55, "2": 0.25, "3": 0.1}, 0.3)},
    },
    "knowledge_retention_hybrid": {
        "description": "KnowledgeRetention in hybrid mode: the LLM extracts each user turn's facts, "
                       "Jev judges each assistant turn against them, one request per turn",
        "metrics": [metric("knowledge_retention", "hybrid")],
        "test_case": TRAVEL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"verdict": noul(0.74)}}},
        "judge_model": JUDGE,
        "responses": {"knowledge_retention": RETENTION_LLM},
    },
    "knowledge_retention_hybrid_fallback": {
        "description": "KnowledgeRetention in hybrid mode with Jev down: the LLM judges every assistant turn",
        "metrics": [metric("knowledge_retention", "hybrid")],
        "test_case": TRAVEL,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"knowledge_retention": {**RETENTION_LLM, **RETENTION_VERDICTS}},
    },
    # RoleAdherence
    "role_adherence_system_one": {
        "description": "RoleAdherence decided by Jev in one request about the turns and the chatbot_role",
        "metrics": [metric("role_adherence", "system_one")],
        "test_case": TRAVEL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.83, 0.71, 3, FOUR_LEVELS_HIGH, 0.6)},
    },
    "role_adherence_hybrid": {
        "description": "RoleAdherence in hybrid mode: Jev judges each assistant turn against the role, "
                       "one request per turn, below 0.5 out of character",
        "metrics": [metric("role_adherence", "hybrid")],
        "test_case": TRAVEL,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"verdict": noul(0.31)}}},
        "judge_model": JUDGE,
        "responses": {"role_adherence": ROLE_REASON},
    },
    "role_adherence_hybrid_fallback": {
        "description": "RoleAdherence in hybrid mode with Jev down: every turn is asked, then the LLM "
                       "lists the out of character turns",
        "metrics": [metric("role_adherence", "hybrid")],
        "test_case": TRAVEL,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"role_adherence": {**ROLE_VERDICTS, **ROLE_REASON}},
    },
    # TurnFaithfulness
    "turn_faithfulness_system_one": {
        "description": "TurnFaithfulness decided by Jev in one request about the turns and their "
                       "retrieval context",
        "metrics": [metric("turn_faithfulness", "system_one")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.62, 0.3, 2, {"0": 0.05, "1": 0.25, "2": 0.55, "3": 0.15}, 0.4)},
    },
    "turn_faithfulness_system_one_strict": {
        "description": "TurnFaithfulness decided by Jev in strict mode",
        "metrics": [metric("turn_faithfulness", "system_one", strict_mode=True)],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.62, 0.3, 2, {"0": 0.05, "1": 0.25, "2": 0.55, "3": 0.15}, 0.4)},
    },
    "turn_faithfulness_hybrid": {
        "description": "TurnFaithfulness in hybrid mode: the LLM extracts each window's truths and "
                       "claims, Jev judges the claims, one request per window",
        "metrics": [metric("turn_faithfulness", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"claim_0": noul(0.9), "claim_1": noul(0.5),
                                             "claim_2": noul(0.1)}}},
        "judge_model": JUDGE,
        "responses": {"turn_faithfulness": TURN_FAITHFULNESS_LLM},
    },
    "turn_faithfulness_hybrid_fallback": {
        "description": "TurnFaithfulness in hybrid mode with Jev down: the LLM judges every window's claims",
        "metrics": [metric("turn_faithfulness", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"turn_faithfulness": {**TURN_FAITHFULNESS_LLM, **TURN_FAITHFULNESS_VERDICTS}},
    },
    # TurnContextualPrecision
    "turn_contextual_precision_system_one": {
        "description": "TurnContextualPrecision decided by Jev in one request about the turns and "
                       "the expected outcome",
        "metrics": [metric("turn_contextual_precision", "system_one")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.81, 0.62, 3, FOUR_LEVELS_HIGH, 0.6)},
    },
    "turn_contextual_precision_hybrid": {
        "description": "TurnContextualPrecision in hybrid mode: Jev judges each window's nodes "
                       "(node_<i>), one request per window",
        "metrics": [metric("turn_contextual_precision", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"node_0": noul(0.8), "node_1": noul(0.2),
                                             "node_2": noul(0.7)}}},
        "judge_model": JUDGE,
        "responses": {"turn_contextual_precision": TURN_RAG_REASONS},
    },
    "turn_contextual_precision_hybrid_fallback": {
        "description": "TurnContextualPrecision in hybrid mode with Jev down: the LLM judges every "
                       "window's nodes",
        "metrics": [metric("turn_contextual_precision", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"turn_contextual_precision": {**TURN_RAG_REASONS, **TURN_PRECISION_VERDICTS}},
    },
    # TurnContextualRecall
    "turn_contextual_recall_system_one": {
        "description": "TurnContextualRecall decided by Jev in one request about the turns and the "
                       "expected outcome",
        "metrics": [metric("turn_contextual_recall", "system_one")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.35, 0.2, 1, {"0": 0.1, "1": 0.55, "2": 0.25, "3": 0.1}, 0.3)},
    },
    "turn_contextual_recall_hybrid": {
        "description": "TurnContextualRecall in hybrid mode: Jev judges each sentence of the expected "
                       "outcome (sentence_<i>) against each window's retrieval context",
        "metrics": [metric("turn_contextual_recall", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"sentence_0": noul(0.9), "sentence_1": noul(0.3)}}},
        "judge_model": JUDGE,
        "responses": {"turn_contextual_recall": TURN_RAG_REASONS},
    },
    "turn_contextual_recall_hybrid_fallback": {
        "description": "TurnContextualRecall in hybrid mode with Jev down: the LLM judges every window",
        "metrics": [metric("turn_contextual_recall", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"turn_contextual_recall": {**TURN_RAG_REASONS, **TURN_RECALL_VERDICTS}},
    },
    # TurnContextualRelevancy
    "turn_contextual_relevancy_system_one": {
        "description": "TurnContextualRelevancy decided by Jev in one request about the turns",
        "metrics": [metric("turn_contextual_relevancy", "system_one")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": whole_metric(0.55, 0.7, 2, {"0": 0.05, "1": 0.3, "2": 0.5, "3": 0.15}, 0.42)},
    },
    "turn_contextual_relevancy_hybrid": {
        "description": "TurnContextualRelevancy in hybrid mode: Jev judges the sentences of each "
                       "node (statement_<i>), one request per node of each window",
        "metrics": [metric("turn_contextual_relevancy", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"statement_0": noul(0.8), "statement_1": noul(0.2)}}},
        "judge_model": JUDGE,
        "responses": {"turn_contextual_relevancy": TURN_RAG_REASONS},
    },
    "turn_contextual_relevancy_hybrid_fallback": {
        "description": "TurnContextualRelevancy in hybrid mode with Jev down: the LLM judges every node",
        "metrics": [metric("turn_contextual_relevancy", "hybrid")],
        "test_case": RAG_CHAT,
        "system_one": DOWN,
        "judge_model": JUDGE,
        "responses": {"turn_contextual_relevancy": {**TURN_RAG_REASONS, **TURN_RELEVANCY_NODE_VERDICTS}},
    },
    "jev_eval": {
        "description": "JevEval with a weighted Noul, a Score and a Choice whose N/A option stays unlikely",
        "metrics": [{"kind": "jev_eval", "params": {
            "name": "Helpfulness",
            "evaluation_params": ["input", "actual_output"],
            "threshold": 0.6,
            "questions": [
                {"type": "noul", "statement": "`actual_output` answers `input`.", "weight": 2},
                {"type": "score", "question": "How complete is `actual_output`?",
                 "levels": ["Not at all", "Partly", "Fully"]},
                {"type": "choice", "question": "What tone does `actual_output` take?",
                 "options": {"friendly": 1.0, "neutral": 0.5, "rude": 0.0, "no_reply": None}},
            ],
        }}],
        "test_case": CAPITAL,
        "system_one": {"model": JEV, "cost": JEV_COST, "answers": {
            "nouls": {"q_0": noul(0.88)},
            "scores": {"q_1": score(1.6, {"0": 0.05, "1": 0.3, "2": 0.65}, 0.48)},
            "choices": {"q_2": choice(
                "neutral", {"friendly": 0.35, "neutral": 0.45, "rude": 0.15, "no_reply": 0.05}, 0.27,
            )},
        }},
    },
    "jev_eval_strict_not_applicable": {
        "description": "JevEval in strict mode, without the JevEval suffix: a Choice judged not applicable",
        "metrics": [{"kind": "jev_eval", "params": {
            "name": "Citations",
            "evaluation_params": ["actual_output", "retrieval_context"],
            "strict_mode": True,
            "_include_jev_eval_suffix": False,
            "questions": [
                {"type": "noul", "statement": "Every fact in `actual_output` is in `retrieval_context`.",
                 "true": "All facts are sourced.", "false": "Some fact is unsourced."},
                {"type": "choice", "question": "Does `actual_output` cite its sources?",
                 "options": {"cites": 1.0, "does_not_cite": 0.0, "nothing_to_cite": None}},
            ],
        }}],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": None, "answers": {
            "nouls": {"q_0": noul(0.7)},
            "choices": {"q_1": choice(
                "nothing_to_cite", {"cites": 0.1, "does_not_cite": 0.2, "nothing_to_cite": 0.7}, 0.55,
            )},
        }},
    },
    # Batched: evaluate() merges a test case's system_one metrics.
    "batch_system_one": {
        "description": "Three system_one metrics on one test case: evaluate() asks Jev once and splits the cost",
        "batched": True,
        "metrics": [
            faithfulness("system_one"),
            metric("answer_relevancy", "system_one"),
            metric("contextual_recall", "system_one"),
        ],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": {"value": 0.000126, "input_tokens": 3001, "output_tokens": 0},
                       "answers": {
                           "nouls": {
                               "m0.q_0": noul(0.3), "m0.q_1": noul(0.2),
                               "m1.q_0": noul(0.6), "m1.q_1": noul(0.95),
                               "m2.q_0": noul(0.4), "m2.q_1": noul(0.7),
                           },
                           "scores": {
                               "m0.q_2": score(1, FOUR_LEVELS_LOW, 0.4),
                               "m1.q_2": score(2, {"0": 0.0, "1": 0.2, "2": 0.7, "3": 0.1}, 0.6),
                               "m2.q_2": score(2, {"0": 0.1, "1": 0.3, "2": 0.5, "3": 0.1}, 0.33),
                           },
                       }},
    },
    "batch_system_one_retrieval": {
        "description": "ContextualRelevancy and ContextualPrecision batched into one request by evaluate()",
        "batched": True,
        "metrics": [
            metric("contextual_relevancy", "system_one"),
            metric("contextual_precision", "system_one"),
        ],
        "test_case": VACATION,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2000, "output_tokens": 0},
                       "answers": {
                           "nouls": {
                               "m0.q_0": noul(0.9), "m0.q_1": noul(0.95),
                               "m1.q_0": noul(0.85), "m1.q_1": noul(0.6),
                           },
                           "scores": {
                               "m0.q_2": score(3, FOUR_LEVELS_HIGH, 0.8),
                               "m1.q_2": score(2, {"0": 0.05, "1": 0.15, "2": 0.6, "3": 0.2}, 0.45),
                           },
                       }},
    },
    "batch_system_one_safety": {
        "description": "Bias and Toxicity batched into one request about actual_output by evaluate()",
        "batched": True,
        "metrics": [metric("bias", "system_one"), metric("toxicity", "system_one")],
        "test_case": ESSAY,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2000, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.95), "m1.q_0": noul(0.3)},
                           "scores": {
                               "m0.q_1": score(3, FOUR_LEVELS_HIGH, 0.8),
                               "m1.q_1": score(1, FOUR_LEVELS_LOW, 0.3),
                           },
                       }},
    },
    "batch_system_one_summarization": {
        "description": "Summarization and AnswerRelevancy batched into one request about input "
                       "and actual_output by evaluate()",
        "batched": True,
        "metrics": [metric("summarization", "system_one"), metric("answer_relevancy", "system_one")],
        "test_case": PARK,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2000, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.3), "m0.q_1": noul(0.8),
                                     "m1.q_0": noul(0.9), "m1.q_1": noul(0.85)},
                           "scores": {"m0.q_2": score(1, FOUR_LEVELS_LOW, 0.35),
                                      "m1.q_2": score(3, FOUR_LEVELS_HIGH, 0.8)},
                       }},
    },
    "batch_system_one_pii_alignment": {
        "description": "PIILeakage and PromptAlignment batched into one request by evaluate()",
        "batched": True,
        "metrics": [metric("pii_leakage", "system_one"),
                    metric("prompt_alignment", "system_one",
                           prompt_instructions=GREETING_INSTRUCTIONS)],
        "test_case": GREETING,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2000, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.96), "m1.q_0": noul(0.95),
                                     "m1.q_1": noul(0.1), "m1.q_2": noul(0.9)},
                           "scores": {"m0.q_1": score(3, FOUR_LEVELS_HIGH, 0.8)},
                       }},
    },
    "batch_system_one_agent": {
        "description": "ArgumentCorrectness and AnswerRelevancy batched into one request by evaluate()",
        "batched": True,
        "metrics": [metric("argument_correctness", "system_one"),
                    metric("answer_relevancy", "system_one")],
        "test_case": BOOKING,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2000, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.3), "m0.q_1": noul(0.25),
                                     "m1.q_0": noul(0.7), "m1.q_1": noul(0.85)},
                           "scores": {"m0.q_2": score(2, {"0": 0.05, "1": 0.3, "2": 0.55, "3": 0.1}, 0.4),
                                      "m1.q_2": score(3, FOUR_LEVELS_HIGH, 0.8)},
                       }},
    },
    "json_correctness_system_one": {
        "description": "JsonCorrectness under system_one: decided in code, with neither Jev nor an LLM",
        "metrics": [json_correctness("system_one")],
        "test_case": PROFILE,
        "system_one": NO_JEV,
    },
    "json_correctness_hybrid": {
        "description": "JsonCorrectness in hybrid mode: decided in code, the LLM explains the failure",
        "metrics": [json_correctness("hybrid")],
        "test_case": PROFILE_INVALID,
        "system_one": NO_JEV,
        "judge_model": JUDGE,
        "responses": {"json_correctness": JSON_CORRECTNESS_LLM},
    },
    "batch_system_one_json": {
        "description": "Bias and JsonCorrectness under system_one in evaluate(): JsonCorrectness "
                       "counts towards batching but asks nothing, so the request holds Bias alone",
        "batched": True,
        "metrics": [metric("bias", "system_one"), json_correctness("system_one")],
        "test_case": PROFILE,
        "system_one": {"model": JEV, "cost": JEV_COST,
                       "answers": {"nouls": {"m0.q_0": noul(0.9)},
                                   "scores": {"m0.q_1": score(3, FOUR_LEVELS_HIGH, 0.8)}}},
    },
    "batch_system_one_conversational": {
        "description": "TurnRelevancy and ConversationCompleteness batched into one request about "
                       "the turns by evaluate()",
        "batched": True,
        "metrics": [metric("turn_relevancy", "system_one"),
                    metric("conversation_completeness", "system_one")],
        "test_case": SUPPORT,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2001, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.7), "m0.q_1": noul(0.4),
                                     "m1.q_0": noul(0.9), "m1.q_1": noul(0.85)},
                           "scores": {"m0.q_2": score(2, {"0": 0.05, "1": 0.25, "2": 0.6, "3": 0.1}, 0.45),
                                      "m1.q_2": score(3, FOUR_LEVELS_HIGH, 0.8)},
                       }},
    },
    "batch_system_one_retention_role": {
        "description": "KnowledgeRetention and RoleAdherence batched into one request by evaluate(), "
                       "the state holding the turns and the chatbot_role",
        "batched": True,
        "metrics": [metric("knowledge_retention", "system_one"),
                    metric("role_adherence", "system_one")],
        "test_case": TRAVEL,
        "system_one": {"model": JEV, "cost": {"value": 0.000084, "input_tokens": 2001, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.4), "m0.q_1": noul(0.25),
                                     "m1.q_0": noul(0.88), "m1.q_1": noul(0.9)},
                           "scores": {"m0.q_2": score(1, {"0": 0.1, "1": 0.5, "2": 0.3, "3": 0.1}, 0.4),
                                      "m1.q_2": score(3, FOUR_LEVELS_HIGH, 0.8)},
                       }},
    },
    "batch_system_one_turn_rag": {
        "description": "The four Turn RAG metrics batched into one request about the turns, their "
                       "retrieval context and the expected outcome by evaluate()",
        "batched": True,
        "metrics": [metric("turn_faithfulness", "system_one"),
                    metric("turn_contextual_precision", "system_one"),
                    metric("turn_contextual_recall", "system_one"),
                    metric("turn_contextual_relevancy", "system_one")],
        "test_case": RAG_CHAT,
        "system_one": {"model": JEV, "cost": {"value": 0.000168, "input_tokens": 4002, "output_tokens": 0},
                       "answers": {
                           "nouls": {"m0.q_0": noul(0.7), "m0.q_1": noul(0.4),
                                     "m1.q_0": noul(0.9), "m1.q_1": noul(0.85),
                                     "m2.q_0": noul(0.3), "m2.q_1": noul(0.6),
                                     "m3.q_0": noul(0.5), "m3.q_1": noul(0.75)},
                           "scores": {"m0.q_2": score(2, {"0": 0.05, "1": 0.25, "2": 0.6, "3": 0.1}, 0.45),
                                      "m1.q_2": score(3, FOUR_LEVELS_HIGH, 0.8),
                                      "m2.q_2": score(1, {"0": 0.1, "1": 0.5, "2": 0.3, "3": 0.1}, 0.4),
                                      "m3.q_2": score(2, {"0": 0.1, "1": 0.2, "2": 0.6, "3": 0.1}, 0.5)},
                       }},
    },
    "batch_system_one_down": {
        "description": "Two system_one metrics batched with Jev down: no fallback, each metric errors",
        "batched": True,
        "metrics": [faithfulness("system_one"), metric("answer_relevancy", "system_one")],
        "test_case": VACATION,
        "system_one": DOWN,
    },
    # Classifier: one Choice over the labels.
    "refusal_classifier_system_one": {
        "description": "RefusalClassifier on Jev: one Choice over its labels, reason built from the answer",
        "classifier": {"kind": "refusal", "eval_mode": "system_one"},
        "test_case": {
            "input": "Write my essay and tell me the exam answers.",
            "actual_output": "I can help you outline the essay, but I can't share exam answers.",
        },
        "system_one": {"model": JEV, "cost": JEV_COST, "answers": {"choices": {"label": choice(
            "partial_refusal", {"complied": 0.05, "refused": 0.3, "partial_refusal": 0.65}, 0.48,
        )}}},
    },
}


def main():
    if gf.deepeval.__version__ != gf.DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {gf.DEEPEVAL_VERSION}, found {gf.deepeval.__version__}")
    try:
        for name, scenario in SCENARIOS.items():
            if "classifier" in scenario:
                run_classifier_scenario(name, scenario)
            else:
                run_metric_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(SYSTEM_ONE, name), ROOT)}")
    finally:
        shutil.rmtree(gf.WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
