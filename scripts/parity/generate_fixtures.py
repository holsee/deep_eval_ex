"""Generate the golden fixtures DeepEvalEx's parity tests compare against.

It writes two kinds of fixtures.

Export scenarios (`SCENARIOS` below) are deterministic `deepeval.evaluate()`
calls. For every scenario this script writes, under
test/fixtures/deepeval/<scenario>/:

- input.json    - the scenario's inputs: `test_cases` (keyword arguments of
                  deepeval's `LLMTestCase`, snake_case), `metrics` (see
                  `build_metric`), `identifier`, `hyperparameters` and
                  `error_config` (`ErrorConfig`'s keyword arguments;
                  `ignore_errors=True` unless the scenario sets it)
- test_run.json - the `test_run_<timestamp>.json` deepeval wrote for it,
                  copied byte for byte
- raised.json   - in place of test_run.json when evaluate() raised (with
                  `ignore_errors=False`): the exception's `type` name and
                  its `message`, `str(exception)`

test/deep_eval_ex/parity_test.exs runs the same inputs through DeepEvalEx and
compares its export with test_run.json.

No LLM is called: metrics are deepeval's ExactMatchMetric or custom
`BaseMetric` stubs returning fixed values, so the output only depends on
deepeval itself. The `missing_params` scenario also runs FaithfulnessMetric
and GEval, with a `ScriptedJudge` holding no responses: every test case
lacks one of their required params, so they fail validation before calling
it (a call would raise and show up as the metric's error).

Scripted-judge scenarios run deepeval's real metrics against `ScriptedJudge`,
a `DeepEvalBaseLLM` that answers each call with a canned response from a
committed script, test/fixtures/deepeval/scripted/<scenario>/script.json:
the metric (`kind` and constructor `params`), one `test_case` and the judge's
`responses`, keyed by metric kind, then by step (the sorted field names of the
schema deepeval asks for, e.g. "verdicts" or "reason,score"), then by call
index. Next to each script this writes:

- prompts.json  - every prompt deepeval sent the judge, in order, with its step
- measure.json  - the metric's state after `measure()`: score, success,
                  reason, threshold, error, evaluation model, cost, tokens
                  and verbose_logs
- test_run.json - the test run `deepeval.evaluate()` wrote for the same
                  metric and test case

test/deep_eval_ex/scripted_parity_test.exs replays each script through
DeepEvalEx.LLM.Adapters.Mock and compares all three.

Prompt goldens (`PROMPT_CASES` below) render every prompt template deepeval
uses for the seven LLM-judged metrics, the way the metric itself renders it
(its `_get_prompt`, with the arguments its own helpers build), for fixed
inputs. For every case this script writes, under
test/fixtures/deepeval/prompts/<case>/:

- input.json    - `template` (deepeval's template class key and method, e.g.
                  "FaithfulnessMetric.generate_truths") and `inputs`, the
                  metric-level values the prompt is built from
- prompt.txt    - the rendered prompt, byte for byte

test/deep_eval_ex/prompt_golden_test.exs renders the same inputs with the
matching DeepEvalEx.Prompts function and compares the strings exactly.

Run it inside the devcontainer, from the repository root:

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import glob
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "test", "fixtures", "deepeval")
SCRIPTED = os.path.join(FIXTURES, "scripted")
ROUND_TRIP = os.path.join(FIXTURES, "round_trip")
PROMPTS = os.path.join(FIXTURES, "prompts")

# deepeval builds some reasons by iterating sets (ToolCorrectness's missing
# tools), whose order follows string hashing. Fix the hash seed so every run
# writes the same bytes. -I ignores PYTHONHASHSEED, so run again without it,
# keeping its isolation: -s and -P, and no other PYTHON* variables.
if sys.flags.hash_randomization:
    env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
    env["PYTHONHASHSEED"] = "0"
    os.execve(sys.executable, [sys.executable, "-s", "-P", os.path.abspath(__file__)], env)

# Before deepeval is imported: no telemetry, no Confident AI, no prompts.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"
os.environ["DEEPEVAL_NO_INSPECT_PROMPT"] = "1"
os.environ["DEEPEVAL_LOCAL_STORE"] = "json"
for var in ("CONFIDENT_API_KEY", "DEEPEVAL_RESULTS_FOLDER", "DEEPEVAL_VERBOSE_MODE"):
    os.environ.pop(var, None)

# deepeval writes its cache and rolling snapshot under ./.deepeval; keep them
# out of the repository.
WORK_DIR = tempfile.mkdtemp(prefix="deepeval_parity_")
os.chdir(WORK_DIR)

import deepeval  # noqa: E402
from deepeval import evaluate  # noqa: E402
from deepeval.dataset import EvaluationDataset, Golden  # noqa: E402
from deepeval.evaluate.configs import (  # noqa: E402
    AsyncConfig,
    CacheConfig,
    DisplayConfig,
    ErrorConfig,
)
from deepeval.metrics import (  # noqa: E402
    AnswerRelevancyMetric,
    BaseMetric,
    ContextualPrecisionMetric,
    ContextualRecallMetric,
    ExactMatchMetric,
    FaithfulnessMetric,
    GEval,
    HallucinationMetric,
    ToolCorrectnessMetric,
)
from deepeval.metrics.contextual_precision.contextual_precision import (  # noqa: E402
    _contextual_precision_verdict_fields,
)
from deepeval.metrics.contextual_recall.contextual_recall import (  # noqa: E402
    _contextual_recall_verdict_kwargs,
)
from deepeval.metrics.faithfulness.faithfulness import (  # noqa: E402
    _faithfulness_claims_multimodal_instruction,
    _faithfulness_truths_limit_phrase,
    _faithfulness_truths_multimodal_instruction,
)
from deepeval.metrics.g_eval.utils import Rubric  # noqa: E402
from deepeval.metrics.utils.verbose import print_tools_called  # noqa: E402
from deepeval.models import DeepEvalBaseLLM  # noqa: E402
from deepeval.prompt import Prompt, PromptMessage  # noqa: E402
from deepeval.templates import iter_base_template_methods  # noqa: E402
from deepeval.test_case import (  # noqa: E402
    LLMTestCase,
    SingleTurnParams,
    ToolCall,
    ToolCallParams,
)
from deepeval.tracing import observe, update_current_span, update_current_trace  # noqa: E402
from openai.types.chat import ChatCompletion  # noqa: E402

DEEPEVAL_VERSION = "4.3.1"


class StubMetric(BaseMetric):
    """Emulates an LLM-judged metric: fixed score, reason, judge model,
    cost and token counts. Mirrored by DeepEvalEx.Test.ParityMetrics.Stub."""

    # deepeval copies metrics per test case by calling __init__ with the
    # instance attributes named like its parameters, hence the fixed_* names.
    def __init__(self, name, fixed_score, fixed_reason, threshold, fixed_model,
                 fixed_cost, fixed_input_tokens, fixed_output_tokens):
        self.name = name
        self.fixed_score = fixed_score
        self.fixed_reason = fixed_reason
        self.threshold = threshold
        self.fixed_model = fixed_model
        self.fixed_cost = fixed_cost
        self.fixed_input_tokens = fixed_input_tokens
        self.fixed_output_tokens = fixed_output_tokens

    def measure(self, test_case, *args, **kwargs):
        self.score = self.fixed_score
        self.reason = self.fixed_reason
        self.evaluation_model = self.fixed_model
        self.evaluation_cost = self.fixed_cost
        self.input_tokens = self.fixed_input_tokens
        self.output_tokens = self.fixed_output_tokens
        self.success = self.score >= self.threshold
        return self.score

    async def a_measure(self, test_case, *args, **kwargs):
        return self.measure(test_case)

    def is_successful(self):
        if self.error is not None:
            return False
        return bool(self.success)

    @property
    def __name__(self):
        return self.name


class ErrorMetric(BaseMetric):
    """Always raises. With ErrorConfig(ignore_errors=True) deepeval's async
    executor records `str(exception)`, i.e. just the message, as the
    metric's error. Mirrored by DeepEvalEx.Test.ParityMetrics.Failing."""

    EXCEPTIONS = {"ValueError": ValueError, "RuntimeError": RuntimeError}

    def __init__(self, name, threshold, exception, message):
        self.name = name
        self.threshold = threshold
        self.exception = exception
        self.message = message

    def measure(self, test_case, *args, **kwargs):
        raise self.EXCEPTIONS[self.exception](self.message)

    async def a_measure(self, test_case, *args, **kwargs):
        return self.measure(test_case)

    def is_successful(self):
        return False

    @property
    def __name__(self):
        return self.name


def build_metric(spec):
    kind = spec["kind"]
    if kind == "exact_match":
        return ExactMatchMetric()
    if kind == "stub":
        return StubMetric(
            spec["name"], spec["score"], spec["reason"], spec["threshold"],
            spec["evaluation_model"], spec["evaluation_cost"],
            spec["input_tokens"], spec["output_tokens"],
        )
    if kind == "error":
        return ErrorMetric(spec["name"], spec["threshold"], spec["exception"], spec["message"])
    if kind == "faithfulness":
        return FaithfulnessMetric(model=ScriptedJudge(spec["judge_model"], {}))
    if kind == "g_eval":
        return GEval(
            name=spec["name"],
            criteria=spec["criteria"],
            evaluation_params=[SingleTurnParams(p) for p in spec["evaluation_params"]],
            model=ScriptedJudge(spec["judge_model"], {}),
        )
    raise ValueError(f"unknown metric kind {kind!r}")


def build_test_case(spec):
    spec = dict(spec)
    for key in ("tools_called", "expected_tools"):
        if key in spec:
            spec[key] = [ToolCall(**tool_call) for tool_call in spec[key]]
    return LLMTestCase(**spec)


STUB_JUDGE = {
    "kind": "stub",
    "name": "Stub Judge",
    "score": 0.75,
    "reason": "Three of the four statements are supported. café ✓",
    "threshold": 0.7,
    "evaluation_model": "gpt-4o-mini",
    "evaluation_cost": 0.000321,
    "input_tokens": 1234,
    "output_tokens": 56,
}

STRICT_JUDGE = {
    "kind": "stub",
    "name": "Strict Judge",
    "score": 0.5,
    "reason": "Half of the claims are supported.",
    "threshold": 0.9,
    "evaluation_model": "gpt-4o",
    "evaluation_cost": 0.0025,
    "input_tokens": 2048,
    "output_tokens": 128,
}

SCENARIOS = {
    "exact_match": {
        "test_cases": [
            {"input": "What is 2 + 2?", "actual_output": "4", "expected_output": "4"},
            {
                "input": "Capital of France?",
                "actual_output": "  Paris  ",
                "expected_output": "Paris",
                "name": "capital-france",
                "tags": ["geography", "smoke"],
                "metadata": {"source": "atlas", "difficulty": 2, "weights": [0.5, 1.0],
                             "reviewed": True, "notes": None},
                "comments": "Whitespace is trimmed before comparing.",
            },
            {"input": "Largest planet?", "actual_output": "Saturn", "expected_output": "Jupiter"},
        ],
        "metrics": [{"kind": "exact_match"}],
        "identifier": None,
        "hyperparameters": None,
    },
    "llm_metric": {
        "test_cases": [
            {"input": "Summarise the report.", "actual_output": "Revenue grew 10%."},
            {"input": "Summarise the memo.", "actual_output": "Hiring is paused.",
             "name": "memo"},
        ],
        "metrics": [STUB_JUDGE, STRICT_JUDGE],
        "identifier": None,
        "hyperparameters": None,
    },
    "metric_error": {
        "test_cases": [
            {"input": "Hello", "actual_output": "Hi", "expected_output": "Hi"},
            {"input": "Bye", "actual_output": "Ciao", "expected_output": "Goodbye"},
        ],
        "metrics": [
            {"kind": "exact_match"},
            {"kind": "error", "name": "Flaky Judge", "threshold": 0.5,
             "exception": "ValueError", "message": "judge returned invalid JSON"},
            STUB_JUDGE,
        ],
        "identifier": None,
        "hyperparameters": None,
    },
    "rag_and_tools": {
        "test_cases": [
            {
                "input": "What's the weather in Paris?",
                "actual_output": "It is 18°C and partly cloudy in Paris.",
                "expected_output": "18°C, partly cloudy",
                "retrieval_context": ["Paris: 18°C, partly cloudy.", "Lyon: 21°C, sunny."],
                "context": ["Weather API snapshot for France."],
                "tools_called": [
                    {
                        "name": "get_weather",
                        "description": "Fetch current weather for a city",
                        "reasoning": "The user asked about current weather.",
                        "input_parameters": {"city": "Paris", "units": "metric", "days": 1},
                        "output": {"temp_c": 18.0, "conditions": "partly cloudy", "alerts": []},
                    },
                    {"name": "format_answer", "output": "18°C, partly cloudy"},
                ],
                "expected_tools": [
                    {"name": "get_weather", "input_parameters": {"city": "Paris"}},
                ],
                "token_cost": 0.00042,
                "completion_time": 1.25,
            },
            {
                "input": "Add 2 and 3",
                "actual_output": "5",
                "expected_output": "5",
                "tools_called": [
                    {"name": "add", "input_parameters": {"a": 2, "b": 3}, "output": 5},
                ],
                "token_cost": 0.0001,
                "completion_time": 0.5,
            },
        ],
        "metrics": [{"kind": "exact_match"}, STUB_JUDGE],
        "identifier": None,
        "hyperparameters": None,
    },
    # deepeval's check_llm_test_case_params: `context` does not stand in for
    # `retrieval_context`, an empty `actual_output` is rejected before any
    # missing param, and missing params are joined "'a'", "'a' and 'b'" or
    # "'a', 'b', and 'c'". A context-only test case exports no
    # retrievalContext.
    "missing_params": {
        "test_cases": [
            {
                "input": "Who wrote Hamlet?",
                "actual_output": "William Shakespeare wrote Hamlet.",
                "expected_output": "William Shakespeare",
                "context": ["Hamlet is a tragedy written by William Shakespeare."],
                "name": "context-only",
            },
            {
                "input": "What is the capital of Italy?",
                "actual_output": "",
                "expected_output": "Rome",
                "retrieval_context": ["Rome is the capital of Italy."],
                "name": "empty-output",
            },
            {"input": "What is the boiling point of water?", "name": "input-only"},
        ],
        "metrics": [
            {"kind": "exact_match"},
            {"kind": "faithfulness", "judge_model": "mock-model"},
            {
                "kind": "g_eval",
                "name": "Correctness",
                "criteria": "Is the actual output supported by the retrieval context?",
                "evaluation_params": ["actual_output", "expected_output", "retrieval_context"],
                "judge_model": "mock-model",
            },
        ],
        "identifier": None,
        "hyperparameters": None,
    },
    # ErrorConfig(ignore_errors=False), deepeval's default: the metric's
    # exception propagates out of evaluate() and no test run is written.
    "ignore_errors_false": {
        "test_cases": [{"input": "Hello", "actual_output": "Hi", "expected_output": "Hi"}],
        "metrics": [
            {"kind": "exact_match"},
            {"kind": "error", "name": "Flaky Judge", "threshold": 0.5,
             "exception": "ValueError", "message": "judge returned invalid JSON"},
        ],
        "identifier": None,
        "hyperparameters": None,
        "error_config": {"ignore_errors": False, "skip_on_missing_params": False},
    },
    "missing_params_ignore_errors_false": {
        "test_cases": [{"input": "What is the boiling point of water?",
                        "actual_output": "100 degrees Celsius."}],
        "metrics": [{"kind": "exact_match"}],
        "identifier": None,
        "hyperparameters": None,
        "error_config": {"ignore_errors": False, "skip_on_missing_params": False},
    },
    # ErrorConfig(skip_on_missing_params=True): a metric missing params is
    # left out of metricsData and metricsScores, and a test case left with no
    # metric is left out of the run, keeping the others' order.
    "skip_on_missing_params": {
        "test_cases": [
            {"input": "What is the capital of Italy?", "actual_output": "",
             "expected_output": "Rome", "name": "empty-output"},
            {"input": "Who wrote Hamlet?", "actual_output": "William Shakespeare",
             "expected_output": "William Shakespeare", "name": "no-retrieval-context"},
            {"input": "What is the boiling point of water?", "name": "input-only"},
        ],
        "metrics": [{"kind": "exact_match"},
                    {"kind": "faithfulness", "judge_model": "mock-model"}],
        "identifier": None,
        "hyperparameters": None,
        "error_config": {"ignore_errors": False, "skip_on_missing_params": True},
    },
    "hyperparameters": {
        "test_cases": [
            {"input": "Ping", "actual_output": "Pong", "expected_output": "Pong"},
            {"input": "Marco", "actual_output": "Polo", "expected_output": "Polo"},
        ],
        "metrics": [{"kind": "exact_match"}, STUB_JUDGE],
        "identifier": "nightly-2026-10-22",
        "hyperparameters": {
            "model": "gpt-4o-mini",
            "temperature": 0.7,
            "max_tokens": 512,
            "top_p": 1.0,
            "streaming": False,
            "prompt_version": "v3",
            "seed": None,
        },
    },
}


class ScriptedJudge(DeepEvalBaseLLM):
    """A judge that replays canned responses instead of calling an LLM.

    `responses` maps a step to the list of responses for its successive
    calls. A step is the comma-separated, sorted field names of the schema
    deepeval asks for ("text" for a call without a schema), so it names the
    same call in deepeval and in DeepEvalEx whatever the prompt says.
    DeepEvalEx.LLM.Adapters.Mock's scripted mode replays the same script.

    A response is validated against the schema, except a string, which is
    returned as the judge's raw text, as a judge without structured outputs
    answers: deepeval then parses it with trimAndLoadJson.

    The "raw_response" step answers `generate_raw_response`, which GEval
    calls for a logprob-weighted score: each response is an OpenAI chat
    completion, with `logprobs`, returned as openai's `ChatCompletion`. A
    script without that step has the judge raise AttributeError, as a judge
    without the method does, so deepeval falls back to the "reason,score"
    schema call.

    Records every prompt with its step. Raises when a step has no response
    left, so a script missing a response fails the run.
    """

    def __init__(self, model_name, responses):
        self.model_name = model_name
        self.responses = responses
        self.calls = {}
        self.prompts = []
        super().__init__(model_name)

    def load_model(self):
        return self

    def get_model_name(self):
        return self.model_name

    def generate(self, prompt, schema=None):
        response = self._next(step_key(schema), prompt)
        if schema is None or isinstance(response, str):
            return response
        return schema.model_validate(response)

    def _next(self, step, prompt):
        index = self.calls.get(step, 0)
        self.calls[step] = index + 1
        self.prompts.append({"step": step, "prompt": prompt})
        try:
            return self.responses[step][index]
        except (KeyError, IndexError):
            raise RuntimeError(f"script has no response {index} for step {step!r}") from None

    async def a_generate(self, prompt, schema=None):
        return self.generate(prompt, schema)

    def generate_raw_response(self, prompt, top_logprobs=5, **kwargs):
        if RAW_RESPONSE_STEP not in self.responses:
            raise AttributeError("script has no raw responses")
        response = self._next(RAW_RESPONSE_STEP, prompt)
        # A custom model reports no cost, as generate() does.
        return ChatCompletion.model_validate(response), None

    async def a_generate_raw_response(self, prompt, top_logprobs=5, **kwargs):
        return self.generate_raw_response(prompt, top_logprobs, **kwargs)

    def assert_exhausted(self):
        for step, responses in self.responses.items():
            used = self.calls.get(step, 0)
            if used != len(responses):
                raise RuntimeError(
                    f"step {step!r} used {used} of {len(responses)} scripted responses"
                )


# The step of generate_raw_response calls, which ask for no schema.
RAW_RESPONSE_STEP = "raw_response"


def step_key(schema):
    if schema is None:
        return "text"
    return ",".join(sorted(schema.model_fields))


SCRIPTED_METRICS = {
    "exact_match": ExactMatchMetric,
    "g_eval": GEval,
    "faithfulness": FaithfulnessMetric,
    "hallucination": HallucinationMetric,
    "answer_relevancy": AnswerRelevancyMetric,
    "contextual_precision": ContextualPrecisionMetric,
    "contextual_recall": ContextualRecallMetric,
    "tool_correctness": ToolCorrectnessMetric,
}


def build_scripted_metric(script):
    """The script's metric with a fresh ScriptedJudge, or None as the judge
    for metrics that call no LLM."""
    kind = script["metric"]["kind"]
    params = dict(script["metric"]["params"])
    if kind == "g_eval" and "evaluation_params" in params:
        params["evaluation_params"] = [SingleTurnParams(p) for p in params["evaluation_params"]]
    if kind == "tool_correctness":
        if "evaluation_params" in params:
            params["evaluation_params"] = [ToolCallParams(p) for p in params["evaluation_params"]]
        if "available_tools" in params:
            params["available_tools"] = [ToolCall(**tool) for tool in params["available_tools"]]
    if kind == "exact_match":
        return SCRIPTED_METRICS[kind](**params), None
    judge = ScriptedJudge(script["judge_model"], script["responses"].get(kind, {}))
    return SCRIPTED_METRICS[kind](model=judge, **params), judge


def measured_state(metric):
    return {
        "score": metric.score,
        "success": metric.success,
        "reason": metric.reason,
        "threshold": metric.threshold,
        "error": metric.error,
        "evaluation_model": metric.evaluation_model,
        "evaluation_cost": metric.evaluation_cost,
        "input_tokens": metric.input_tokens,
        "output_tokens": metric.output_tokens,
        "verbose_logs": metric.verbose_logs,
    }


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def run_scripted_scenario(name):
    out_dir = os.path.join(SCRIPTED, name)
    with open(os.path.join(out_dir, "script.json"), encoding="utf-8") as f:
        script = json.load(f)

    # measure(): the metric's own state, and the prompts it sent.
    measured, judge = build_scripted_metric(script)
    try:
        measured.measure(build_test_case(script["test_case"]), _show_indicator=False)
    except ValueError:
        # trimAndLoadJson sets metric.error before raising; keep the state
        # the metric was left in.
        if measured.error is None:
            raise
    prompts = judge.prompts if judge else []
    if judge:
        judge.assert_exhausted()

    # evaluate(): the test run export, from a fresh metric and judge.
    results_folder = tempfile.mkdtemp(prefix=f"{name}_", dir=WORK_DIR)
    metric, judge = build_scripted_metric(script)
    evaluate(
        test_cases=[build_test_case(script["test_case"])],
        metrics=[metric],
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
    if judge:
        judge.assert_exhausted()
        if judge.prompts != prompts:
            raise RuntimeError(f"{name}: evaluate() sent other prompts than measure()")

    [path] = glob.glob(os.path.join(results_folder, "test_run_*.json"))
    shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))
    write_json(os.path.join(out_dir, "prompts.json"), prompts)
    write_json(os.path.join(out_dir, "measure.json"), measured_state(measured))


# Prompt goldens. Each renderer builds a prompt the way deepeval's metric does
# for a single-turn, text-only test case: the metric's own `_get_prompt` (so
# a strict Jinja environment and `multimodal=False`), with the arguments its
# helpers derive from the metric-level `inputs`. GEval's renderers call the
# metric's `_steps_prompt` / `_results_prompt` directly.


def _prompt_judge():
    return ScriptedJudge("prompt-golden-judge", {})


def _score(inputs):
    # Every metric formats its score for the reason prompt this way.
    return format(inputs["score"], ".2f")


def _render_g_eval_results(inputs, strict_mode):
    rubric = inputs.get("rubric")
    metric = GEval(
        name="Golden",
        evaluation_params=[SingleTurnParams(p) for p in inputs["evaluation_params"]],
        evaluation_steps=inputs["evaluation_steps"],
        rubric=[Rubric(**r) for r in rubric] if rubric else None,
        strict_mode=strict_mode,
        model=_prompt_judge(),
    )
    return metric._results_prompt(build_test_case(inputs["test_case"]), False, None)


def _render_g_eval_steps(inputs):
    metric = GEval(
        name="Golden",
        evaluation_params=[SingleTurnParams(p) for p in inputs["evaluation_params"]],
        criteria=inputs["criteria"],
        model=_prompt_judge(),
    )
    return metric._steps_prompt(False)


def _prompt(metric_cls, method, **kwargs):
    return metric_cls(model=_prompt_judge())._get_prompt(method, multimodal=False, **kwargs)


PROMPT_RENDERERS = {
    "GEval.generate_evaluation_steps": _render_g_eval_steps,
    "GEval.generate_evaluation_results": lambda i: _render_g_eval_results(i, False),
    "GEval.generate_strict_evaluation_results": lambda i: _render_g_eval_results(i, True),
    "FaithfulnessMetric.generate_claims": lambda i: _prompt(
        FaithfulnessMetric, "generate_claims",
        actual_output=i["actual_output"],
        multimodal_instruction=_faithfulness_claims_multimodal_instruction(False),
    ),
    "FaithfulnessMetric.generate_truths": lambda i: _prompt(
        FaithfulnessMetric, "generate_truths",
        retrieval_context="\n\n".join(i["retrieval_context"]),
        limit=_faithfulness_truths_limit_phrase(i["truths_extraction_limit"]),
        multimodal_instruction=_faithfulness_truths_multimodal_instruction(False),
    ),
    "FaithfulnessMetric.generate_verdicts": lambda i: _prompt(
        FaithfulnessMetric, "generate_verdicts",
        claims=i["claims"],
        retrieval_context="\n\n".join(i["truths"]),
    ),
    "FaithfulnessMetric.generate_reason": lambda i: _prompt(
        FaithfulnessMetric, "generate_reason",
        contradictions=i["contradictions"],
        score=_score(i),
    ),
    "HallucinationMetric.generate_verdicts": lambda i: _prompt(
        HallucinationMetric, "generate_verdicts",
        actual_output=i["actual_output"],
        contexts=i["contexts"],
        contexts_count=len(i["contexts"]),
    ),
    "HallucinationMetric.generate_reason": lambda i: _prompt(
        HallucinationMetric, "generate_reason",
        factual_alignments=i["factual_alignments"],
        contradictions=i["contradictions"],
        score=_score(i),
    ),
    "AnswerRelevancyMetric.generate_statements": lambda i: _prompt(
        AnswerRelevancyMetric, "generate_statements",
        actual_output=i["actual_output"],
    ),
    "AnswerRelevancyMetric.generate_verdicts": lambda i: _prompt(
        AnswerRelevancyMetric, "generate_verdicts",
        input=i["input"],
        statements=i["statements"],
    ),
    "AnswerRelevancyMetric.generate_reason": lambda i: _prompt(
        AnswerRelevancyMetric, "generate_reason",
        irrelevant_statements=i["irrelevant_statements"],
        input=i["input"],
        score=_score(i),
    ),
    "ContextualPrecisionMetric.generate_verdicts": lambda i: _prompt(
        ContextualPrecisionMetric, "generate_verdicts",
        input=i["input"],
        expected_output=i["expected_output"],
        **dict(zip(
            ("document_count_str", "context_to_display", "multimodal_note"),
            _contextual_precision_verdict_fields(i["retrieval_context"], False),
        )),
    ),
    "ContextualPrecisionMetric.generate_reason": lambda i: _prompt(
        ContextualPrecisionMetric, "generate_reason",
        input=i["input"],
        verdicts=[{"verdict": v["verdict"], "reason": v["reason"]} for v in i["verdicts"]],
        score=_score(i),
    ),
    "ContextualRecallMetric.generate_verdicts": lambda i: _prompt(
        ContextualRecallMetric, "generate_verdicts",
        expected_output=i["expected_output"],
        **_contextual_recall_verdict_kwargs(i["retrieval_context"], False),
    ),
    "ContextualRecallMetric.generate_reason": lambda i: _prompt(
        ContextualRecallMetric, "generate_reason",
        expected_output=i["expected_output"],
        supportive_reasons=i["supportive_reasons"],
        unsupportive_reasons=i["unsupportive_reasons"],
        score=_score(i),
        content_type="sentence",
    ),
    # System One (`eval_mode`) templates: the questions of the whole metric
    # under `system_one`, and the question asked about each item under
    # `hybrid`. They take no arguments.
    "FaithfulnessMetric._experimental_system_one_questions": lambda i: _prompt(
        FaithfulnessMetric, "_experimental_system_one_questions",
    ),
    "FaithfulnessMetric._experimental_system_one_verdict": lambda i: _prompt(
        FaithfulnessMetric, "_experimental_system_one_verdict",
    ),
    "AnswerRelevancyMetric._experimental_system_one_questions": lambda i: _prompt(
        AnswerRelevancyMetric, "_experimental_system_one_questions",
    ),
    "AnswerRelevancyMetric._experimental_system_one_verdict": lambda i: _prompt(
        AnswerRelevancyMetric, "_experimental_system_one_verdict",
    ),
    "ContextualPrecisionMetric._experimental_system_one_questions": lambda i: _prompt(
        ContextualPrecisionMetric, "_experimental_system_one_questions",
    ),
    "ContextualPrecisionMetric._experimental_system_one_verdict": lambda i: _prompt(
        ContextualPrecisionMetric, "_experimental_system_one_verdict",
    ),
    "ContextualRecallMetric._experimental_system_one_questions": lambda i: _prompt(
        ContextualRecallMetric, "_experimental_system_one_questions",
    ),
    "ContextualRecallMetric._experimental_system_one_verdict": lambda i: _prompt(
        ContextualRecallMetric, "_experimental_system_one_verdict",
    ),
    "HallucinationMetric._experimental_system_one_questions": lambda i: _prompt(
        HallucinationMetric, "_experimental_system_one_questions",
    ),
    "HallucinationMetric._experimental_system_one_verdict": lambda i: _prompt(
        HallucinationMetric, "_experimental_system_one_verdict",
    ),
    "ToolCorrectnessMetric._experimental_system_one_tool_selection_score": lambda i: _prompt(
        ToolCorrectnessMetric, "_experimental_system_one_tool_selection_score",
    ),
    "ToolCorrectnessMetric.get_tool_selection_score": lambda i: _prompt(
        ToolCorrectnessMetric, "get_tool_selection_score",
        user_input=i["input"],
        tools_called=print_tools_called([ToolCall(**t) for t in i["tools_called"]]),
        available_tools=print_tools_called([ToolCall(**t) for t in i["available_tools"]]),
    ),
}

# Bundled templates of these metrics that no prompt case renders: GEval's
# trace variants (`requires_trace`, i.e. GEval without evaluation_params on a
# traced component), which DeepEvalEx has no counterpart for yet. The System
# One (`DEEPEVAL_EVAL_MODE`) `_experimental_*` templates are private methods,
# which `iter_base_template_methods` leaves out; the cases below render those
# of the metrics DeepEvalEx runs on System One.
UNRENDERED_TEMPLATES = {
    "GEval.generate_trace_evaluation_steps",
    "GEval.generate_trace_evaluation_results",
    "GEval.generate_strict_trace_evaluation_results",
}

PARIS_CONTEXT = [
    "Paris is the capital and largest city of France.",
    "The Louvre, the world's most-visited museum, opened in 1793.",
    "France's café culture dates back to the 17th century.",
]

GOLDEN_TOOLS = [
    {"name": "get_weather", "description": "Fetch current weather for a city"},
    {"name": "search_web", "description": "Search the web"},
]

PROMPT_CASES = {
    "g_eval_generate_evaluation_steps": {
        "template": "GEval.generate_evaluation_steps",
        "inputs": {
            "criteria": "Determine whether the actual output answers the input's question correctly.",
            "evaluation_params": ["input", "actual_output"],
        },
    },
    "g_eval_generate_evaluation_steps_three_params": {
        "template": "GEval.generate_evaluation_steps",
        "inputs": {
            "criteria": "Check the actual output against the expected output for the input.",
            "evaluation_params": ["input", "actual_output", "expected_output"],
        },
    },
    "g_eval_generate_evaluation_results": {
        "template": "GEval.generate_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Read the input's question.",
                "Check that the actual output answers it with the right fact.",
            ],
            "evaluation_params": ["input", "actual_output"],
            "test_case": {
                "input": "What is the capital of France?",
                "actual_output": "Paris is the capital of France.",
            },
        },
    },
    "g_eval_generate_evaluation_results_rubric": {
        "template": "GEval.generate_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Compare the actual output with the expected output.",
                "Penalise missing or wrong facts.",
            ],
            "evaluation_params": ["actual_output", "expected_output"],
            "rubric": [
                {"score_range": [1, 1], "expected_outcome": "Wrong or missing answer."},
                {"score_range": [3, 3], "expected_outcome": "Partly correct answer."},
                {"score_range": [5, 5], "expected_outcome": "Fully correct answer."},
            ],
            "test_case": {
                "input": "What is the capital of France?",
                "actual_output": "It's Paris.",
                "expected_output": "Paris",
            },
        },
    },
    "g_eval_generate_strict_evaluation_results": {
        "template": "GEval.generate_strict_evaluation_results",
        "inputs": {
            "evaluation_steps": ["Check that the actual output names the capital of France."],
            "evaluation_params": ["input", "actual_output"],
            "test_case": {
                "input": "What is the capital of France?",
                "actual_output": "Paris is the capital of France.",
            },
        },
    },
    "faithfulness_generate_claims": {
        "template": "FaithfulnessMetric.generate_claims",
        "inputs": {
            "actual_output": "Paris is the capital of France. The Louvre opened in 1893.",
        },
    },
    "faithfulness_generate_truths": {
        "template": "FaithfulnessMetric.generate_truths",
        "inputs": {"retrieval_context": PARIS_CONTEXT, "truths_extraction_limit": None},
    },
    "faithfulness_generate_truths_limit_1": {
        "template": "FaithfulnessMetric.generate_truths",
        "inputs": {"retrieval_context": PARIS_CONTEXT, "truths_extraction_limit": 1},
    },
    "faithfulness_generate_truths_limit_3": {
        "template": "FaithfulnessMetric.generate_truths",
        "inputs": {"retrieval_context": PARIS_CONTEXT, "truths_extraction_limit": 3},
    },
    "faithfulness_generate_verdicts": {
        "template": "FaithfulnessMetric.generate_verdicts",
        "inputs": {
            "claims": ["Paris is the capital of France.", "The Louvre opened in 1893."],
            "truths": ["Paris is the capital of France.", "The Louvre opened in 1793."],
        },
    },
    "faithfulness_generate_reason": {
        "template": "FaithfulnessMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "contradictions": [
                "The actual output says the Louvre opened in 1893, but it opened in 1793.",
            ],
        },
    },
    "faithfulness_generate_reason_no_contradictions": {
        "template": "FaithfulnessMetric.generate_reason",
        "inputs": {"score": 1.0, "contradictions": []},
    },
    "hallucination_generate_verdicts": {
        "template": "HallucinationMetric.generate_verdicts",
        "inputs": {
            "actual_output": "Paris is the capital of France. The Louvre opened in 1893.",
            "contexts": PARIS_CONTEXT[:2],
        },
    },
    "hallucination_generate_reason": {
        "template": "HallucinationMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "factual_alignments": ["The actual output agrees that Paris is France's capital."],
            "contradictions": ["The actual output says 1893; the context says 1793."],
        },
    },
    "answer_relevancy_generate_statements": {
        "template": "AnswerRelevancyMetric.generate_statements",
        "inputs": {
            "actual_output": "Paris is the capital of France. It's known for café culture.",
        },
    },
    "answer_relevancy_generate_verdicts": {
        "template": "AnswerRelevancyMetric.generate_verdicts",
        "inputs": {
            "input": "What is the capital of France?",
            "statements": ["Paris is the capital of France.", "It's known for café culture."],
        },
    },
    "answer_relevancy_generate_reason": {
        "template": "AnswerRelevancyMetric.generate_reason",
        "inputs": {
            "score": 0.6667,
            "input": "What is the capital of France?",
            "irrelevant_statements": ["Café culture does not answer the question."],
        },
    },
    "contextual_precision_generate_verdicts": {
        "template": "ContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            "input": "What is the capital of France?",
            "expected_output": "Paris",
            "retrieval_context": PARIS_CONTEXT,
        },
    },
    "contextual_precision_generate_verdicts_one_document": {
        "template": "ContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            "input": "What is the capital of France?",
            "expected_output": "Paris",
            "retrieval_context": PARIS_CONTEXT[:1],
        },
    },
    "contextual_precision_generate_reason": {
        "template": "ContextualPrecisionMetric.generate_reason",
        "inputs": {
            "score": 0.8333,
            "input": "What is the capital of France?",
            "verdicts": [
                {"verdict": "yes", "reason": "It says 'Paris is the capital'."},
                {"verdict": "no", "reason": "The Louvre is unrelated to the question."},
                {"verdict": "yes", "reason": "It mentions France."},
            ],
        },
    },
    "contextual_recall_generate_verdicts": {
        "template": "ContextualRecallMetric.generate_verdicts",
        "inputs": {
            "expected_output": "Paris is the capital of France. The Louvre opened in 1793.",
            "retrieval_context": PARIS_CONTEXT,
        },
    },
    "contextual_recall_generate_reason": {
        "template": "ContextualRecallMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "expected_output": "Paris is the capital of France. Its metro opened in 1900.",
            "supportive_reasons": ["The 1st node says Paris is the capital."],
            "unsupportive_reasons": ["No node mentions the metro."],
        },
    },
    "faithfulness_experimental_system_one_questions": {
        "template": "FaithfulnessMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "faithfulness_experimental_system_one_verdict": {
        "template": "FaithfulnessMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "answer_relevancy_experimental_system_one_questions": {
        "template": "AnswerRelevancyMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "answer_relevancy_experimental_system_one_verdict": {
        "template": "AnswerRelevancyMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "contextual_precision_experimental_system_one_questions": {
        "template": "ContextualPrecisionMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "contextual_precision_experimental_system_one_verdict": {
        "template": "ContextualPrecisionMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "contextual_recall_experimental_system_one_questions": {
        "template": "ContextualRecallMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "contextual_recall_experimental_system_one_verdict": {
        "template": "ContextualRecallMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "hallucination_experimental_system_one_questions": {
        "template": "HallucinationMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "hallucination_experimental_system_one_verdict": {
        "template": "HallucinationMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "tool_correctness_experimental_system_one_tool_selection_score": {
        "template": "ToolCorrectnessMetric._experimental_system_one_tool_selection_score",
        "inputs": {},
    },
    "tool_correctness_get_tool_selection_score": {
        "template": "ToolCorrectnessMetric.get_tool_selection_score",
        "inputs": {
            "input": "What's the weather in Paris?",
            "tools_called": [
                {"name": "get_weather", "input_parameters": {"city": "Paris"},
                 "output": {"temp_c": 18}},
            ],
            "available_tools": GOLDEN_TOOLS,
        },
    },
}


def check_prompt_coverage():
    """Fails unless every bundled template of the seven metrics is rendered
    by some case or listed in UNRENDERED_TEMPLATES."""
    rendered = {case["template"] for case in PROMPT_CASES.values()}
    unknown = rendered - PROMPT_RENDERERS.keys()
    if unknown:
        raise RuntimeError(f"no renderer for {sorted(unknown)}")
    classes = {key.split(".")[0] for key in PROMPT_RENDERERS}
    bundled = {
        f"{cls}.{method}"
        for cls in classes
        for method, _ in iter_base_template_methods("metrics", cls)
    }
    missing = bundled - rendered - UNRENDERED_TEMPLATES
    if missing:
        raise RuntimeError(f"no prompt case renders {sorted(missing)}")


def run_prompt_case(name, case):
    out_dir = os.path.join(PROMPTS, name)
    os.makedirs(out_dir, exist_ok=True)
    prompt = PROMPT_RENDERERS[case["template"]](case["inputs"])
    write_json(os.path.join(out_dir, "input.json"), case)
    with open(os.path.join(out_dir, "prompt.txt"), "w", encoding="utf-8", newline="") as f:
        f.write(prompt)


# The ErrorConfig of a scenario that sets none.
DEFAULT_ERROR_CONFIG = {"ignore_errors": True, "skip_on_missing_params": False}


def run_scenario(name, scenario):
    out_dir = os.path.join(FIXTURES, name)
    os.makedirs(out_dir, exist_ok=True)
    results_folder = tempfile.mkdtemp(prefix=f"{name}_", dir=WORK_DIR)
    scenario = {**scenario, "error_config": scenario.get("error_config", DEFAULT_ERROR_CONFIG)}

    kwargs = {}
    if scenario["identifier"] is not None:
        kwargs["identifier"] = scenario["identifier"]
    if scenario["hyperparameters"] is not None:
        kwargs["hyperparameters"] = scenario["hyperparameters"]

    try:
        evaluate(
            test_cases=[build_test_case(spec) for spec in scenario["test_cases"]],
            metrics=[build_metric(spec) for spec in scenario["metrics"]],
            async_config=AsyncConfig(run_async=True),
            display_config=DisplayConfig(
                show_indicator=False,
                print_results=False,
                inspect_after_run=False,
                results_folder=results_folder,
            ),
            cache_config=CacheConfig(write_cache=False, use_cache=False),
            error_config=ErrorConfig(**scenario["error_config"]),
            **kwargs,
        )
    except Exception as e:
        if scenario["error_config"]["ignore_errors"]:
            raise
        # The exception evaluate() raised, in place of a test run.
        if glob.glob(os.path.join(results_folder, "*")):
            raise RuntimeError(f"{name}: deepeval raised and wrote a test run")
        write_json(os.path.join(out_dir, "raised.json"),
                   {"type": type(e).__name__, "message": str(e)})
    else:
        [path] = glob.glob(os.path.join(results_folder, "test_run_*.json"))
        shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))

    write_json(os.path.join(out_dir, "input.json"), scenario)


SPAN_JUDGE = {**STUB_JUDGE, "name": "Span Judge"}


def run_round_trip_traced_dataset():
    """A richer test run than evaluate() writes: deepeval's evals_iterator
    over a dataset, with an @observe'd app, so the file has the keys the
    export scenarios never produce and DeepEvalEx does not model: each test
    case's `trace`, the run's `traceMetricsScores`, `prompts` (from Prompt
    hyperparameters) and the dataset's `datasetAlias`, `datasetId` and
    `datasetVersion`. DeepEvalEx only loads and re-encodes it, so its uuids
    and timestamps change between runs."""
    out_dir = os.path.join(ROUND_TRIP, "traced_dataset")
    os.makedirs(out_dir, exist_ok=True)
    results_folder = tempfile.mkdtemp(prefix="traced_dataset_", dir=WORK_DIR)

    # A pulled dataset carries its alias, id and version, and hands them to
    # its goldens when they are set; set them as pull() does, without
    # Confident AI.
    dataset = EvaluationDataset()
    dataset._alias = "support-goldens"
    dataset._id = "ds_parity_0001"
    dataset._version = "3"
    dataset.goldens = [
        Golden(input="How do I reset my password?",
               expected_output="Use the 'Forgot password' link.",
               name="password-reset", additional_metadata={"locale": "en-GB"}),
        Golden(input="Wo ist meine Rechnung?", expected_output="Unter Konto › Rechnungen."),
    ]

    @observe(type="retriever", embedder="text-embedding-3-small",
             metrics=[build_metric(SPAN_JUDGE)])
    def retrieve(query):
        documents = [f"FAQ: {query}", "Policy: answers cite the help centre."]
        update_current_span(
            test_case=LLMTestCase(input=query, actual_output=documents[0],
                                  retrieval_context=documents))
        return documents

    @observe(type="llm", model="gpt-4o-mini")
    def generate(query, documents):
        return f"Answer to {query!r} from {len(documents)} documents."

    @observe(type="agent", available_tools=["retrieve"])
    def app(query):
        answer = generate(query, retrieve(query))
        update_current_trace(input=query, output=answer, tags=["round-trip"])
        return answer

    hyperparameters = {
        "model": "gpt-4o-mini",
        "temperature": 0.2,
        "system_prompt": Prompt(alias="support-system",
                                text_template="You are a support agent for {product}."),
        "chat_prompt": Prompt(alias="support-chat", messages_template=[
            PromptMessage(role="system", content="Answer in {language}."),
        ]),
    }
    for golden in dataset.evals_iterator(
        metrics=[build_metric(STUB_JUDGE), build_metric(STRICT_JUDGE)],
        hyperparameters=hyperparameters,
        identifier="traced-dataset",
        async_config=AsyncConfig(run_async=False),
        display_config=DisplayConfig(show_indicator=False, print_results=False,
                                     inspect_after_run=False,
                                     results_folder=results_folder),
        cache_config=CacheConfig(write_cache=False, use_cache=False),
        error_config=ErrorConfig(ignore_errors=True),
    ):
        app(golden.input)

    [path] = glob.glob(os.path.join(results_folder, "test_run_*.json"))
    shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))


def main():
    if deepeval.__version__ != DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {DEEPEVAL_VERSION}, found {deepeval.__version__}")
    try:
        for name, scenario in SCENARIOS.items():
            run_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(FIXTURES, name), ROOT)}")
        run_round_trip_traced_dataset()
        print(f"wrote {os.path.relpath(os.path.join(ROUND_TRIP, 'traced_dataset'), ROOT)}")
        for name in sorted(os.listdir(SCRIPTED)):
            if os.path.isfile(os.path.join(SCRIPTED, name, "script.json")):
                run_scripted_scenario(name)
                print(f"wrote {os.path.relpath(os.path.join(SCRIPTED, name), ROOT)}")
        check_prompt_coverage()
        for name, case in PROMPT_CASES.items():
            run_prompt_case(name, case)
            print(f"wrote {os.path.relpath(os.path.join(PROMPTS, name), ROOT)}")
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
