"""Generate the golden test run fixtures DeepEvalEx's parity test compares against.

Each scenario below is a deterministic `deepeval.evaluate()` call. For every
scenario this script writes, under test/fixtures/deepeval/<scenario>/:

- input.json    - the scenario's inputs: `test_cases` (keyword arguments of
                  deepeval's `LLMTestCase`, snake_case), `metrics` (see
                  `build_metric`), `identifier` and `hyperparameters`
- test_run.json - the `test_run_<timestamp>.json` deepeval wrote for it,
                  copied byte for byte

test/deep_eval_ex/parity_test.exs runs the same inputs through DeepEvalEx and
compares its export with test_run.json.

No LLM is called: metrics are deepeval's ExactMatchMetric or custom
`BaseMetric` stubs returning fixed values, so the output only depends on
deepeval itself. Run it inside the devcontainer, from the repository root:

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
from deepeval.evaluate.configs import (  # noqa: E402
    AsyncConfig,
    CacheConfig,
    DisplayConfig,
    ErrorConfig,
)
from deepeval.metrics import BaseMetric, ExactMatchMetric  # noqa: E402
from deepeval.test_case import LLMTestCase, ToolCall  # noqa: E402

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


def run_scenario(name, scenario):
    out_dir = os.path.join(FIXTURES, name)
    os.makedirs(out_dir, exist_ok=True)
    results_folder = tempfile.mkdtemp(prefix=f"{name}_", dir=WORK_DIR)

    kwargs = {}
    if scenario["identifier"] is not None:
        kwargs["identifier"] = scenario["identifier"]
    if scenario["hyperparameters"] is not None:
        kwargs["hyperparameters"] = scenario["hyperparameters"]

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
        error_config=ErrorConfig(ignore_errors=True),
        **kwargs,
    )

    [path] = glob.glob(os.path.join(results_folder, "test_run_*.json"))
    shutil.copyfile(path, os.path.join(out_dir, "test_run.json"))

    with open(os.path.join(out_dir, "input.json"), "w", encoding="utf-8") as f:
        json.dump(scenario, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    if deepeval.__version__ != DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {DEEPEVAL_VERSION}, found {deepeval.__version__}")
    try:
        for name, scenario in SCENARIOS.items():
            run_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(FIXTURES, name), ROOT)}")
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
