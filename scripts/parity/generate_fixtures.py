"""Generate the golden fixtures DeepEvalEx's parity tests compare against.

It writes two kinds of fixtures.

Export scenarios (`SCENARIOS` below) are deterministic `deepeval.evaluate()`
calls. For every scenario this script writes, under
test/fixtures/deepeval/<scenario>/:

- input.json    - the scenario's inputs: `test_cases` (keyword arguments of
                  deepeval's `LLMTestCase`, snake_case, or of its
                  `ConversationalTestCase` when they have `turns`), `metrics` (see
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

- dag.json      - for a DAGMetric (`kind` "dag", whose `params.dag` is the
                  graph as `DeepAcyclicGraph.to_dict` writes it): the graph
                  deepeval rebuilt from it, written back by `to_dict` with
                  node ids numbered in its order instead of random uuids

test/deep_eval_ex/scripted_parity_test.exs replays each script through
DeepEvalEx.LLM.Adapters.Mock and compares all three.

Prompt goldens (`PROMPT_CASES` below) render every prompt template deepeval
uses for the thirty LLM-judged metrics, the way the metric itself renders it
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

With the argument `scripted` it rewrites only the scripted-judge scenarios'
outputs; scenario names after it rewrite only those scenarios.

With the argument `prompts` it rewrites only the prompt goldens; case names
after it rewrite only those cases.

With the argument `loop_detection` it writes only
test/fixtures/deepeval/loop_detection/: vector tables of
`difflib.SequenceMatcher` (`sequence_matcher.json`) and of
AgentLoopDetectionMetric's `_input_hash` (`input_hash.json`), see
`write_loop_detection_tables`.

With the argument `multimodal` it writes only
test/fixtures/deepeval/multimodal/content_parts.json: the message content
deepeval's OpenAI, Anthropic and Ollama models build from a prompt holding
image placeholders, see `write_content_parts`.

With the argument `traced` it writes only the traced fixtures,
test/fixtures/deepeval/traced/: agent scripts (`TRACED_SCENARIOS`) run
through deepeval's @observe tracing outside evaluation and under the sync
and async evals_iterator, and `iso_table.json`, deepeval's ISO timestamps
for fixed epoch times. Scenario names after `traced` regenerate only those
scenarios. See the comment above `TRACED_SCENARIOS`.

See test/fixtures/deepeval/README.md.
"""

import asyncio
import glob
import inspect
import json
import os
import random
import shutil
import sys
import tempfile
from datetime import datetime, timedelta, timezone

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
    os.execve(
        sys.executable,
        [sys.executable, "-s", "-P", os.path.abspath(__file__), *sys.argv[1:]],
        env,
    )

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
    AgentLoopDetectionMetric,
    AnswerRelevancyMetric,
    ArgumentCorrectnessMetric,
    BaseConversationalMetric,
    BaseMetric,
    BiasMetric,
    ContextualPrecisionMetric,
    ContextualRecallMetric,
    ContextualRelevancyMetric,
    ConversationalGEval,
    ConversationCompletenessMetric,
    DAGMetric,
    ExactMatchMetric,
    FaithfulnessMetric,
    GEval,
    GoalAccuracyMetric,
    HallucinationMetric,
    KnowledgeRetentionMetric,
    JsonCorrectnessMetric,
    PatternMatchMetric,
    PIILeakageMetric,
    PlanAdherenceMetric,
    PlanQualityMetric,
    PromptAlignmentMetric,
    RoleAdherenceMetric,
    StepEfficiencyMetric,
    SummarizationMetric,
    TaskCompletionMetric,
    ToolCorrectnessMetric,
    ToolPermissionMetric,
    ToolUseMetric,
    ToxicityMetric,
    TurnContextualPrecisionMetric,
    TurnContextualRecallMetric,
    TurnContextualRelevancyMetric,
    TurnFaithfulnessMetric,
    TurnRelevancyMetric,
)
from deepeval.metrics.base_metric import Verdict  # noqa: E402
from deepeval.metrics.dag import DeepAcyclicGraph, NonBinaryJudgementNode  # noqa: E402
from deepeval.metrics.dag.serialization import serialization as dag_serialization  # noqa: E402
from deepeval.metrics.contextual_precision.contextual_precision import (  # noqa: E402
    _contextual_precision_verdict_fields,
)
from deepeval.metrics.contextual_recall.contextual_recall import (  # noqa: E402
    _contextual_recall_verdict_kwargs,
)
from deepeval.metrics.contextual_relevancy.contextual_relevancy import (  # noqa: E402
    _contextual_relevancy_verdict_kwargs,
)
from deepeval.metrics.faithfulness.faithfulness import (  # noqa: E402
    _faithfulness_claims_multimodal_instruction,
    _faithfulness_truths_limit_phrase,
    _faithfulness_truths_multimodal_instruction,
)
from deepeval.metrics.turn_contextual_precision.turn_contextual_precision import (  # noqa: E402
    _contextual_precision_verdict_fields as _turn_contextual_precision_verdict_fields,
)
from deepeval.metrics.turn_contextual_recall.turn_contextual_recall import (  # noqa: E402
    _contextual_recall_verdict_kwargs as _turn_contextual_recall_verdict_kwargs,
)
from deepeval.metrics.turn_contextual_relevancy.turn_contextual_relevancy import (  # noqa: E402
    _contextual_relevancy_verdict_kwargs as _turn_contextual_relevancy_verdict_kwargs,
)
from deepeval.metrics.turn_faithfulness.turn_faithfulness import (  # noqa: E402
    _turn_faithfulness_limit_description,
)
from deepeval.metrics.g_eval.utils import (  # noqa: E402
    Rubric,
    construct_conversational_g_eval_turn_params_string,
)
from deepeval.metrics.utils import convert_turn_to_dict  # noqa: E402
from deepeval.metrics.utils.verbose import print_tools_called  # noqa: E402
from deepeval.models import DeepEvalBaseLLM  # noqa: E402
from deepeval.prompt import Prompt, PromptMessage  # noqa: E402
from deepeval.templates import iter_base_template_methods  # noqa: E402
from deepeval.test_case import (  # noqa: E402
    ConversationalTestCase,
    LLMTestCase,
    MLLMImage,
    MultiTurnParams,
    RetrievedContextData,
    SingleTurnParams,
    ToolCall,
    ToolCallParams,
    Turn,
)
from deepeval.tracing import (  # noqa: E402
    current_span_context,
    current_trace_context,
    next_agent_span,
    next_llm_span,
    next_retriever_span,
    next_span,
    next_tool_span,
    observe,
    trace_manager,
    update_agent_span,
    update_current_span,
    update_current_trace,
    update_llm_span,
    update_retriever_span,
    update_tool_span,
)
from deepeval.tracing.trace_test_manager import trace_testing_manager  # noqa: E402
from deepeval.tracing.utils import to_zod_compatible_iso  # noqa: E402
from deepeval.metrics.utils import compact_trace  # noqa: E402
from difflib import SequenceMatcher  # noqa: E402
from deepeval.utils import serialize_to_json  # noqa: E402
from openai.types.chat import ChatCompletion  # noqa: E402
from pydantic import Field, create_model  # noqa: E402
from typing import List, Union  # noqa: E402

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


class ConversationalStubMetric(BaseConversationalMetric):
    """StubMetric for conversational test cases: the same fixed values, from
    a BaseConversationalMetric, which deepeval runs on ConversationalTestCases.
    Mirrored by DeepEvalEx.Test.ParityMetrics.ConversationalStub."""

    __init__ = StubMetric.__init__
    measure = StubMetric.measure
    a_measure = StubMetric.a_measure
    is_successful = StubMetric.is_successful
    __name__ = StubMetric.__dict__["__name__"]


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
    if kind == "conversational_stub":
        return ConversationalStubMetric(
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


# The Python types of the JSON schema types a pydantic field can have here.
JSON_SCHEMA_TYPES = {
    "string": str,
    "integer": int,
    "number": float,
    "boolean": bool,
    "null": type(None),
}


def build_expected_schema(schema):
    """The pydantic model JsonCorrectnessMetric takes as `expected_schema`,
    from the JSON schema a script holds: the model's `model_json_schema()`,
    which DeepEvalEx's JsonCorrectness takes as it is. Fields, `$defs`
    models, arrays, `anyOf` unions, descriptions and defaults are rebuilt;
    the model's own schema must then be `schema`, key order included, so
    both sides validate against and prompt with the same schema."""
    defs = schema.get("$defs", {})
    models = {}

    def field_type(prop):
        if "$ref" in prop:
            name = prop["$ref"].rsplit("/", 1)[1]
            if name not in models:
                models[name] = build_model(defs[name])
            return models[name]
        if "anyOf" in prop:
            return Union[tuple(field_type(branch) for branch in prop["anyOf"])]
        if prop["type"] == "array":
            return List[field_type(prop["items"])]
        return JSON_SCHEMA_TYPES[prop["type"]]

    def build_model(spec):
        fields = {}
        for name, prop in spec["properties"].items():
            default = ... if name in spec.get("required", []) else prop.get("default")
            kwargs = {"description": prop["description"]} if "description" in prop else {}
            fields[name] = (field_type(prop), Field(default, **kwargs))
        return create_model(spec["title"], **fields)

    model = build_model(schema)
    built = json.dumps(model.model_json_schema())
    if built != json.dumps(schema):
        raise RuntimeError(f"expected_schema is not a pydantic model's schema; built {built}")
    return model


def build_test_case(spec):
    """An LLMTestCase from its keyword arguments, or a ConversationalTestCase
    when they have `turns`, each turn built as one. Its `images` (MLLMImage
    keyword arguments, as an imagesMapping entry holds them) are created
    first, so deepeval's image registry resolves their placeholders."""
    spec = dict(spec)
    register_images(spec.pop("images", []))
    if "turns" in spec:
        spec["turns"] = [build_turn(turn) for turn in spec["turns"]]
        return ConversationalTestCase(**spec)
    return LLMTestCase(**build_tools_and_contexts(spec))


def register_images(images):
    """Creates each MLLMImage, which adds it to deepeval's image registry."""
    return [MLLMImage(**image) for image in images]


def build_turn(spec):
    return Turn(**build_tools_and_contexts(dict(spec)))


def build_tools_and_contexts(spec):
    for key in ("tools_called", "expected_tools"):
        if key in spec:
            spec[key] = [ToolCall(**tool_call) for tool_call in spec[key]]
    # A retrieval_context item written as {"context", "source"} is a
    # RetrievedContextData; strings stay strings.
    if "retrieval_context" in spec:
        spec["retrieval_context"] = [
            RetrievedContextData(**item) if isinstance(item, dict) else item
            for item in spec["retrieval_context"]
        ]
    return spec


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
    # ConversationalTestCases, exported as conversationalTestCases
    # (ConversationalApiTestCase and TurnApi): an unnamed one is named
    # conversational_test_case_<order>, a turn's RetrievedContextData is
    # flattened to its context, an empty retrieval_context is left out and
    # empty tools_called kept. A turn's user_id is never exported:
    # create_api_turn passes it by field name, which TurnApi ignores. A test
    # case's runDuration is the summed time its metrics took, a float even
    # when they are instantaneous.
    "conversational": {
        "test_cases": [
            {
                "scenario": "A customer asks for a refund on a late order. café ✓",
                "expected_outcome": "The assistant starts a refund for order 42.",
                "user_description": "A returning customer, polite but in a hurry.",
                "context": ["Orders over 30 days old are not refundable."],
                "tags": ["refunds", "support"],
                "metadata": {"channel": "chat", "priority": 2, "escalated": False},
                "comments": "Seeded from ticket 1234.",
                "turns": [
                    {"role": "user", "content": "My order is late, I want a refund.",
                     "user_id": "customer-7"},
                    {
                        "role": "assistant",
                        "content": "Sorry about that! I found order 42 and started a refund.",
                        "retrieval_context": [
                            "Refunds take 5 business days.",
                            {"context": "Order 42 shipped on 1 October.", "source": "orders.db"},
                        ],
                        "tools_called": [
                            {
                                "name": "lookup_order",
                                "description": "Find an order by customer",
                                "input_parameters": {"customer": "customer-7", "limit": 1},
                                "output": {"id": 42, "status": "late"},
                            },
                            {"name": "start_refund", "input_parameters": {"order": 42},
                             "output": True},
                        ],
                    },
                    {"role": "user", "content": "Thanks!", "user_id": "customer-7"},
                ],
            },
            {
                "name": "greeting",
                "turns": [
                    {"role": "user", "content": "Hello"},
                    {"role": "assistant", "content": "Hi! How can I help?",
                     "retrieval_context": [], "tools_called": []},
                ],
            },
        ],
        "metrics": [
            {**STUB_JUDGE, "kind": "conversational_stub"},
            {**STRICT_JUDGE, "kind": "conversational_stub"},
        ],
        "identifier": "conversational-export",
        "hyperparameters": None,
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

    def supports_multimodal(self):
        # The prompts of a multimodal test case hold image placeholders,
        # which are recorded as they are; deepeval checks the judge takes
        # images before it asks.
        return True

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
    "contextual_relevancy": ContextualRelevancyMetric,
    "bias": BiasMetric,
    "toxicity": ToxicityMetric,
    "pii_leakage": PIILeakageMetric,
    "prompt_alignment": PromptAlignmentMetric,
    "summarization": SummarizationMetric,
    "argument_correctness": ArgumentCorrectnessMetric,
    "json_correctness": JsonCorrectnessMetric,
    "tool_correctness": ToolCorrectnessMetric,
    "pattern_match": PatternMatchMetric,
    "tool_permission": ToolPermissionMetric,
    "conversational_g_eval": ConversationalGEval,
    "turn_relevancy": TurnRelevancyMetric,
    "conversation_completeness": ConversationCompletenessMetric,
    "knowledge_retention": KnowledgeRetentionMetric,
    "role_adherence": RoleAdherenceMetric,
    "turn_faithfulness": TurnFaithfulnessMetric,
    "turn_contextual_precision": TurnContextualPrecisionMetric,
    "turn_contextual_recall": TurnContextualRecallMetric,
    "turn_contextual_relevancy": TurnContextualRelevancyMetric,
    "goal_accuracy": GoalAccuracyMetric,
    "tool_use": ToolUseMetric,
    "task_completion": TaskCompletionMetric,
    "step_efficiency": StepEfficiencyMetric,
    "plan_quality": PlanQualityMetric,
    "plan_adherence": PlanAdherenceMetric,
    "agent_loop_detection": AgentLoopDetectionMetric,
    "dag": DAGMetric,
}

# Metrics that call no LLM and take no `model`.
JUDGELESS_METRICS = {"exact_match", "pattern_match", "tool_permission", "agent_loop_detection"}


def build_scripted_metric(script):
    """The script's metric with a fresh ScriptedJudge, or None as the judge
    for metrics that call no LLM."""
    kind = script["metric"]["kind"]
    params = dict(script["metric"]["params"])
    if kind == "g_eval" and "evaluation_params" in params:
        params["evaluation_params"] = [SingleTurnParams(p) for p in params["evaluation_params"]]
    if kind == "conversational_g_eval" and "evaluation_params" in params:
        params["evaluation_params"] = [MultiTurnParams(p) for p in params["evaluation_params"]]
    if kind in ("g_eval", "conversational_g_eval") and "rubric" in params:
        params["rubric"] = [Rubric(**rubric) for rubric in params["rubric"]]
    if kind == "tool_correctness" and "evaluation_params" in params:
        params["evaluation_params"] = [ToolCallParams(p) for p in params["evaluation_params"]]
    if kind in ("tool_correctness", "tool_use") and "available_tools" in params:
        params["available_tools"] = [ToolCall(**tool) for tool in params["available_tools"]]
    if kind == "json_correctness":
        params["expected_schema"] = build_expected_schema(params["expected_schema"])
    if kind == "dag":
        params["dag"] = build_dag(params["dag"])
    if kind in JUDGELESS_METRICS:
        return SCRIPTED_METRICS[kind](**params), None
    judge = ScriptedJudge(script["judge_model"], script["responses"].get(kind, {}))
    return SCRIPTED_METRICS[kind](model=judge, **params), judge


def build_dag(spec):
    """A DAGMetric's graph from its `to_dict` form, as `from_dict` builds it.

    A NonBinaryJudgementNode offers its verdicts in the order a Python set of
    them iterates (by string hash), DeepEvalEx in the order of its children.
    The hash seed is fixed, so a script lists each node's verdicts in the
    set's order, which this checks."""
    dag = DeepAcyclicGraph.from_dict(spec)
    for node in dag_serialization._walk_nodes(dag.root_nodes):
        if isinstance(node, NonBinaryJudgementNode):
            children = [child.verdict for child in node.children]
            if node._verdict_options != children:
                raise RuntimeError(
                    f"list the verdicts of {node.criteria!r} as {node._verdict_options}, "
                    "the order deepeval offers them in"
                )
    return dag


def dag_dict(dag):
    """`dag.to_dict()` with the nodes numbered "node_<i>" in its (breadth
    first) order rather than given random uuids, so it can be committed."""
    assign_ids = dag_serialization._assign_ids
    dag_serialization._assign_ids = lambda nodes: {
        id(node): f"node_{i}" for i, node in enumerate(nodes)
    }
    try:
        return dag.to_dict()
    finally:
        dag_serialization._assign_ids = assign_ids


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


def build_scripted_test_case(script):
    """The script's test case; with a `trace` (a nested trace dict, made
    JSON as serialize_to_json does), carrying it as the `_trace_dict` the
    trace metrics read, as evals_iterator gives a traced test case."""
    test_case = build_test_case(script["test_case"])
    if "trace" in script:
        test_case._trace_dict = json.loads(json.dumps(script["trace"]))
    return test_case


def run_scripted_scenario(name):
    out_dir = os.path.join(SCRIPTED, name)
    with open(os.path.join(out_dir, "script.json"), encoding="utf-8") as f:
        script = json.load(f)

    # measure(): the metric's own state, and the prompts it sent.
    measured, judge = build_scripted_metric(script)
    try:
        measured.measure(build_scripted_test_case(script), _show_indicator=False)
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
        test_cases=[build_scripted_test_case(script)],
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
    if script["metric"]["kind"] == "dag":
        write_json(os.path.join(out_dir, "dag.json"), dag_dict(measured.dag))


# Prompt goldens. Each renderer builds a prompt the way deepeval's metric does
# for a single-turn test case: the metric's own `_get_prompt` (so a strict
# Jinja environment, and the case's `multimodal` input, False unless given),
# with the arguments its helpers derive from the metric-level `inputs`. GEval's renderers call the
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
    return metric._results_prompt(build_test_case(inputs["test_case"]), _mm(inputs), None)


def _render_g_eval_steps(inputs):
    metric = GEval(
        name="Golden",
        evaluation_params=[SingleTurnParams(p) for p in inputs["evaluation_params"]],
        criteria=inputs["criteria"],
        model=_prompt_judge(),
    )
    return metric._steps_prompt(_mm(inputs))


def _render_g_eval_trace_steps(inputs):
    # GEval without evaluation_params (requires_trace): the trace variant of
    # the steps prompt.
    metric = GEval(name="Golden", criteria=inputs["criteria"], model=_prompt_judge())
    return metric._steps_prompt(_mm(inputs))


def _render_g_eval_trace_results(inputs, strict_mode):
    # GEval without evaluation_params on a test case carrying the nested
    # trace dict as its _trace_dict, as evals_iterator gives it.
    rubric = inputs.get("rubric")
    metric = GEval(
        name="Golden",
        evaluation_steps=inputs["evaluation_steps"],
        rubric=[Rubric(**r) for r in rubric] if rubric else None,
        strict_mode=strict_mode,
        model=_prompt_judge(),
    )
    test_case = LLMTestCase(input="None")
    test_case._trace_dict = json.loads(json.dumps(inputs["trace"]))
    return metric._results_prompt(test_case, _mm(inputs), None)


def _conversational_g_eval(inputs, **kwargs):
    rubric = inputs.get("rubric")
    return ConversationalGEval(
        name="Golden",
        evaluation_params=[MultiTurnParams(p) for p in inputs["evaluation_params"]],
        rubric=[Rubric(**r) for r in rubric] if rubric else None,
        model=_prompt_judge(),
        **kwargs,
    )


def _render_conversational_g_eval_steps(inputs):
    # ConversationalGEval._generate_evaluation_steps, up to the judge call;
    # the constructor appends CONTENT and ROLE to the evaluation params.
    metric = _conversational_g_eval(inputs, criteria=inputs["criteria"])
    return metric._get_prompt(
        "generate_evaluation_steps",
        criteria=metric.criteria,
        parameters=construct_conversational_g_eval_turn_params_string(metric.evaluation_params),
    )


def _render_conversational_g_eval_results(inputs):
    metric = _conversational_g_eval(inputs, evaluation_steps=inputs["evaluation_steps"])
    prompt, audio = metric._evaluation_prompt(build_test_case(inputs["test_case"]))
    assert audio == []
    return prompt


def _prompt(metric_cls, method, multimodal=False, **kwargs):
    return metric_cls(model=_prompt_judge())._get_prompt(method, multimodal=multimodal, **kwargs)


def _mm(inputs):
    """The case's multimodal flag, the test case's `multimodal`, after
    creating its `images` so their placeholders resolve."""
    register_images(inputs.get("images", []))
    return inputs.get("multimodal", False)


def _step_efficiency(method, inputs, **kwargs):
    # StepEfficiencyMetric passes the test case's multimodal flag.
    return StepEfficiencyMetric(model=_prompt_judge())._get_prompt(
        method, multimodal=inputs.get("multimodal", False), **kwargs,
    )


def _turn_dicts(turns):
    # The turns as the conversational metrics print them: each one's content
    # and role (convert_turn_to_dict's defaults).
    return [convert_turn_to_dict(build_turn(t)) for t in turns]


def _turn_relevancy(method, **kwargs):
    # TurnRelevancyMetric passes its template_class (None) and no
    # multimodal flag; its templates print the multimodal rules regardless.
    return TurnRelevancyMetric(model=_prompt_judge())._get_prompt(
        method, template_class=None, **kwargs
    )


def _conversation_completeness(method, inputs, **kwargs):
    # ConversationCompletenessMetric passes the test case's multimodal flag.
    return ConversationCompletenessMetric(model=_prompt_judge())._get_prompt(
        method, multimodal=inputs.get("multimodal", False), **kwargs
    )


def _knowledge_retention(method, **kwargs):
    # KnowledgeRetentionMetric passes no multimodal flag; its verdict and
    # reason templates print the multimodal rules regardless.
    return KnowledgeRetentionMetric(model=_prompt_judge())._get_prompt(method, **kwargs)


def _role_adherence(method, **kwargs):
    # RoleAdherenceMetric passes no multimodal flag; its LLM templates print
    # the multimodal rules regardless.
    return RoleAdherenceMetric(model=_prompt_judge())._get_prompt(method, **kwargs)


def _goal_accuracy(method, inputs, **kwargs):
    # GoalAccuracyMetric passes the test case's multimodal flag.
    return GoalAccuracyMetric(model=_prompt_judge())._get_prompt(
        method, multimodal=inputs.get("multimodal", False), **kwargs
    )


def _goal_accuracy_evaluations(scores, suffix):
    # GoalAccuracyMetric._generate_reason: each score and reason, the plan's
    # followed by " \n", the goal's by nothing.
    return "".join(f"Score: {s['score']}, Reason: {s['reason']}{suffix}" for s in scores)


def _tool_use(method, **kwargs):
    # ToolUseMetric passes the test case's multimodal flag, which none of
    # its templates reads.
    return ToolUseMetric(available_tools=[], model=_prompt_judge())._get_prompt(
        method, multimodal=False, **kwargs
    )


def _tool_reprs(tools):
    # ToolUseMetric joins its tools' ToolCall.__repr__ with commas.
    return ",".join(repr(ToolCall(**t)) for t in tools)


def _tool_use_scores_and_reasons(scores):
    # ToolUseMetric's reason prompts: each sub-score and its reason.
    return "".join(f"\nScore: {s['score']} \nReason: {s['reason']} \n" for s in scores)


def _tool_use_score(method, i):
    return _tool_use(
        method,
        user_input=i["user_messages"],
        assistant_messages=i["assistant_messages"],
        tools_called=_tool_reprs(i["tools_called"]),
        available_tools=_tool_reprs(i["available_tools"]),
    )


def _tool_use_reason(method, i):
    return _tool_use(
        method,
        all_scores_and_reasons=_tool_use_scores_and_reasons(i["scores"]),
        final_score=i["final_score"],
        threshold=i["threshold"],
    )


def _turn_rag(metric_cls, method, inputs, **kwargs):
    # The Turn RAG metrics pass the test case's multimodal flag, except to
    # generate_final_reason, which takes none.
    return metric_cls(model=_prompt_judge())._get_prompt(
        method, multimodal=inputs.get("multimodal", False), **kwargs
    )


def _turn_final_reason(metric_cls, inputs):
    # generate_final_reason: the final score unformatted, as the metric
    # passes it, and no multimodal flag.
    return metric_cls(model=_prompt_judge())._get_prompt(
        "generate_final_reason",
        final_score=inputs["final_score"],
        success=inputs["success"],
        reasons=inputs["reasons"],
    )


def _turn_contextual_precision_reason_verdicts(verdicts):
    # The node verdicts as the metric passes them: Verdict members, each
    # with its node's rank.
    return [
        {"verdict": Verdict(v["verdict"]), "reason": v["reason"], "node": f"Node {i + 1}"}
        for i, v in enumerate(verdicts)
    ]


def _prompt_alignment(method, inputs, **kwargs):
    # PromptAlignmentMetric requires its prompt instructions at construction.
    metric = PromptAlignmentMetric(
        prompt_instructions=inputs["prompt_instructions"], model=_prompt_judge()
    )
    return metric._get_prompt(method, multimodal=False, **kwargs)


def _summarization_reason(inputs):
    # SummarizationMetric._generate_reason appends to its rendered template
    # the questions the summary cannot answer, when there are any, and
    # "JSON:\n".
    questions = inputs["questions"]
    prompt = _prompt(
        SummarizationMetric, "generate_reason",
        contradictions=inputs["contradictions"],
        redundancies=inputs["redundancies"],
        questions=questions,
        score=_score(inputs),
    )
    if len(questions) > 0:
        prompt += f"""Questions the original text can answer but not the summary:
{questions}

"""
    prompt += """JSON:
"""
    return prompt


def _json_correctness_reason(inputs):
    # JsonCorrectnessMetric requires its expected schema at construction, and
    # prints it as serialize_to_json(model_json_schema(), indent=4).
    schema = build_expected_schema(inputs["expected_schema"])
    metric = JsonCorrectnessMetric(expected_schema=schema, model=_prompt_judge())
    return metric._get_prompt(
        "generate_reason",
        multimodal=False,
        actual_output=inputs["actual_output"],
        expected_schema=serialize_to_json(schema.model_json_schema(), indent=4),
        is_valid_json=inputs["is_valid_json"],
    )


PROMPT_RENDERERS = {
    "GEval.generate_evaluation_steps": _render_g_eval_steps,
    "GEval.generate_evaluation_results": lambda i: _render_g_eval_results(i, False),
    "GEval.generate_strict_evaluation_results": lambda i: _render_g_eval_results(i, True),
    "GEval.generate_trace_evaluation_steps": _render_g_eval_trace_steps,
    "GEval.generate_trace_evaluation_results": lambda i: _render_g_eval_trace_results(i, False),
    "GEval.generate_strict_trace_evaluation_results":
        lambda i: _render_g_eval_trace_results(i, True),
    "ConversationalGEval.generate_evaluation_steps": _render_conversational_g_eval_steps,
    "ConversationalGEval.generate_evaluation_results": _render_conversational_g_eval_results,
    "FaithfulnessMetric.generate_claims": lambda i: _prompt(
        FaithfulnessMetric, "generate_claims",
        multimodal=_mm(i),
        actual_output=i["actual_output"],
        multimodal_instruction=_faithfulness_claims_multimodal_instruction(_mm(i)),
    ),
    "FaithfulnessMetric.generate_truths": lambda i: _prompt(
        FaithfulnessMetric, "generate_truths",
        multimodal=_mm(i),
        retrieval_context="\n\n".join(i["retrieval_context"]),
        limit=_faithfulness_truths_limit_phrase(i["truths_extraction_limit"]),
        multimodal_instruction=_faithfulness_truths_multimodal_instruction(_mm(i)),
    ),
    "FaithfulnessMetric.generate_verdicts": lambda i: _prompt(
        FaithfulnessMetric, "generate_verdicts",
        multimodal=_mm(i),
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
        multimodal=_mm(i),
        actual_output=i["actual_output"],
    ),
    "AnswerRelevancyMetric.generate_verdicts": lambda i: _prompt(
        AnswerRelevancyMetric, "generate_verdicts",
        multimodal=_mm(i),
        input=i["input"],
        statements=i["statements"],
    ),
    "AnswerRelevancyMetric.generate_reason": lambda i: _prompt(
        AnswerRelevancyMetric, "generate_reason",
        multimodal=_mm(i),
        irrelevant_statements=i["irrelevant_statements"],
        input=i["input"],
        score=_score(i),
    ),
    "ContextualPrecisionMetric.generate_verdicts": lambda i: _prompt(
        ContextualPrecisionMetric, "generate_verdicts",
        multimodal=_mm(i),
        input=i["input"],
        expected_output=i["expected_output"],
        **dict(zip(
            ("document_count_str", "context_to_display", "multimodal_note"),
            _contextual_precision_verdict_fields(i["retrieval_context"], _mm(i)),
        )),
    ),
    "ContextualPrecisionMetric.generate_reason": lambda i: _prompt(
        ContextualPrecisionMetric, "generate_reason",
        multimodal=_mm(i),
        input=i["input"],
        verdicts=[{"verdict": v["verdict"], "reason": v["reason"]} for v in i["verdicts"]],
        score=_score(i),
    ),
    "ContextualRecallMetric.generate_verdicts": lambda i: _prompt(
        ContextualRecallMetric, "generate_verdicts",
        multimodal=_mm(i),
        expected_output=i["expected_output"],
        **_contextual_recall_verdict_kwargs(i["retrieval_context"], _mm(i)),
    ),
    "ContextualRecallMetric.generate_reason": lambda i: _prompt(
        ContextualRecallMetric, "generate_reason",
        multimodal=_mm(i),
        expected_output=i["expected_output"],
        supportive_reasons=i["supportive_reasons"],
        unsupportive_reasons=i["unsupportive_reasons"],
        score=_score(i),
        content_type="sentence or image" if _mm(i) else "sentence",
    ),
    # One prompt per retrieval context node, as the metric judges each alone.
    "ContextualRelevancyMetric.generate_verdicts": lambda i: _prompt(
        ContextualRelevancyMetric, "generate_verdicts",
        multimodal=_mm(i),
        input=i["input"],
        context=i["context"],
        **_contextual_relevancy_verdict_kwargs(_mm(i)),
    ),
    "ContextualRelevancyMetric.generate_reason": lambda i: _prompt(
        ContextualRelevancyMetric, "generate_reason",
        input=i["input"],
        irrelevant_statements=i["irrelevant_statements"],
        relevant_statements=i["relevant_statements"],
        score=_score(i),
    ),
    "BiasMetric.generate_opinions": lambda i: _prompt(
        BiasMetric, "generate_opinions",
        multimodal=_mm(i),
        actual_output=i["actual_output"],
    ),
    "BiasMetric.generate_verdicts": lambda i: _prompt(
        BiasMetric, "generate_verdicts",
        multimodal=_mm(i),
        opinions=i["opinions"],
    ),
    "BiasMetric.generate_reason": lambda i: _prompt(
        BiasMetric, "generate_reason",
        biases=i["biases"],
        score=_score(i),
    ),
    "ToxicityMetric.generate_opinions": lambda i: _prompt(
        ToxicityMetric, "generate_opinions",
        actual_output=i["actual_output"],
    ),
    "ToxicityMetric.generate_verdicts": lambda i: _prompt(
        ToxicityMetric, "generate_verdicts",
        opinions=i["opinions"],
    ),
    "ToxicityMetric.generate_reason": lambda i: _prompt(
        ToxicityMetric, "generate_reason",
        toxics=i["toxics"],
        score=_score(i),
    ),
    "PIILeakageMetric.extract_pii": lambda i: _prompt(
        PIILeakageMetric, "extract_pii",
        actual_output=i["actual_output"],
    ),
    "PIILeakageMetric.generate_verdicts": lambda i: _prompt(
        PIILeakageMetric, "generate_verdicts",
        extracted_pii=i["extracted_pii"],
    ),
    "PIILeakageMetric.generate_reason": lambda i: _prompt(
        PIILeakageMetric, "generate_reason",
        privacy_violations=i["privacy_violations"],
        score=_score(i),
    ),
    "PromptAlignmentMetric.generate_verdicts": lambda i: _prompt_alignment(
        "generate_verdicts", i,
        prompt_instructions=i["prompt_instructions"],
        input=i["input"],
        actual_output=i["actual_output"],
    ),
    "PromptAlignmentMetric.generate_reason": lambda i: _prompt_alignment(
        "generate_reason", i,
        unalignment_reasons=i["unalignment_reasons"],
        input=i["input"],
        actual_output=i["actual_output"],
        score=_score(i),
    ),
    # ArgumentCorrectness prints the ToolCalls themselves: Jinja's str() of
    # the list, each its ToolCall.__repr__.
    "ArgumentCorrectnessMetric.generate_verdicts": lambda i: _prompt(
        ArgumentCorrectnessMetric, "generate_verdicts",
        multimodal=_mm(i),
        input=i["input"],
        stringified_tools_called=[ToolCall(**t) for t in i["tools_called"]],
    ),
    "ArgumentCorrectnessMetric.generate_reason": lambda i: _prompt(
        ArgumentCorrectnessMetric, "generate_reason",
        multimodal=_mm(i),
        incorrect_tool_calls_reasons=i["incorrect_tool_calls_reasons"],
        input=i["input"],
        score=_score(i),
    ),
    "JsonCorrectnessMetric.generate_reason": _json_correctness_reason,
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
    "ContextualRelevancyMetric._experimental_system_one_questions": lambda i: _prompt(
        ContextualRelevancyMetric, "_experimental_system_one_questions",
    ),
    "ContextualRelevancyMetric._experimental_system_one_verdict": lambda i: _prompt(
        ContextualRelevancyMetric, "_experimental_system_one_verdict",
    ),
    "BiasMetric._experimental_system_one_questions": lambda i: _prompt(
        BiasMetric, "_experimental_system_one_questions",
    ),
    "BiasMetric._experimental_system_one_verdict": lambda i: _prompt(
        BiasMetric, "_experimental_system_one_verdict",
    ),
    "ToxicityMetric._experimental_system_one_questions": lambda i: _prompt(
        ToxicityMetric, "_experimental_system_one_questions",
    ),
    "ToxicityMetric._experimental_system_one_verdict": lambda i: _prompt(
        ToxicityMetric, "_experimental_system_one_verdict",
    ),
    "SummarizationMetric.generate_questions": lambda i: _prompt(
        SummarizationMetric, "generate_questions",
        text=i["text"],
        n=i["n"],
    ),
    "SummarizationMetric.generate_answers": lambda i: _prompt(
        SummarizationMetric, "generate_answers",
        questions=i["questions"],
        text=i["text"],
    ),
    # The truths are joined with blank lines, as the metric joins them.
    "SummarizationMetric.generate_alignment_verdicts": lambda i: _prompt(
        SummarizationMetric, "generate_alignment_verdicts",
        summary_claims=i["summary_claims"],
        original_text="\n\n".join(i["truths"]),
    ),
    "SummarizationMetric.generate_reason": _summarization_reason,
    # Summarization's questions end with one Noul per assessment question.
    "SummarizationMetric._experimental_system_one_questions": lambda i: _prompt(
        SummarizationMetric, "_experimental_system_one_questions",
        assessment_questions=i["assessment_questions"],
    ),
    "SummarizationMetric._experimental_system_one_verdict": lambda i: _prompt(
        SummarizationMetric, "_experimental_system_one_verdict",
    ),
    "PIILeakageMetric._experimental_system_one_questions": lambda i: _prompt(
        PIILeakageMetric, "_experimental_system_one_questions",
    ),
    "PIILeakageMetric._experimental_system_one_verdict": lambda i: _prompt(
        PIILeakageMetric, "_experimental_system_one_verdict",
    ),
    # PromptAlignment's questions are one Noul per prompt instruction.
    "PromptAlignmentMetric._experimental_system_one_questions": lambda i: _prompt_alignment(
        "_experimental_system_one_questions", i,
        prompt_instructions=i["prompt_instructions"],
    ),
    "PromptAlignmentMetric._experimental_system_one_verdict": lambda i: _prompt_alignment(
        "_experimental_system_one_verdict", i,
    ),
    "ArgumentCorrectnessMetric._experimental_system_one_questions": lambda i: _prompt(
        ArgumentCorrectnessMetric, "_experimental_system_one_questions",
    ),
    "ArgumentCorrectnessMetric._experimental_system_one_verdict": lambda i: _prompt(
        ArgumentCorrectnessMetric, "_experimental_system_one_verdict",
    ),
    "HallucinationMetric._experimental_system_one_questions": lambda i: _prompt(
        HallucinationMetric, "_experimental_system_one_questions",
    ),
    "HallucinationMetric._experimental_system_one_verdict": lambda i: _prompt(
        HallucinationMetric, "_experimental_system_one_verdict",
    ),
    # TurnRelevancy and ConversationCompleteness print the score unformatted,
    # as the metric passes it.
    "TurnRelevancyMetric.generate_verdicts": lambda i: _turn_relevancy(
        "generate_verdicts", sliding_window=_turn_dicts(i["sliding_window"]),
    ),
    "TurnRelevancyMetric.generate_reason": lambda i: _turn_relevancy(
        "generate_reason", score=i["score"], irrelevancies=i["irrelevancies"],
    ),
    "TurnRelevancyMetric._experimental_system_one_questions": lambda i: _turn_relevancy(
        "_experimental_system_one_questions",
    ),
    "TurnRelevancyMetric._experimental_system_one_verdict": lambda i: _turn_relevancy(
        "_experimental_system_one_verdict",
    ),
    "ConversationCompletenessMetric.extract_user_intentions": lambda i: _conversation_completeness(
        "extract_user_intentions", i, turns=_turn_dicts(i["turns"]),
    ),
    "ConversationCompletenessMetric.generate_verdicts": lambda i: _conversation_completeness(
        "generate_verdicts", i, turns=_turn_dicts(i["turns"]), intention=i["intention"],
    ),
    "ConversationCompletenessMetric.generate_reason": lambda i: _conversation_completeness(
        "generate_reason", i,
        score=i["score"],
        incompletenesses=i["incompletenesses"],
        intentions=i["intentions"],
    ),
    "ConversationCompletenessMetric._experimental_system_one_questions": lambda i: _prompt(
        ConversationCompletenessMetric, "_experimental_system_one_questions",
    ),
    "ConversationCompletenessMetric._experimental_system_one_verdict": lambda i: _prompt(
        ConversationCompletenessMetric, "_experimental_system_one_verdict",
    ),
    # KnowledgeRetention formats the reason's score to two decimals;
    # RoleAdherence prints it unformatted, as the metric passes it.
    "KnowledgeRetentionMetric.extract_data": lambda i: _knowledge_retention(
        "extract_data",
        user_message=i["user_message"],
        previous_turns=_turn_dicts(i["previous_turns"]),
    ),
    "KnowledgeRetentionMetric.generate_verdict": lambda i: _knowledge_retention(
        "generate_verdict",
        llm_message=i["llm_message"],
        accumulated_knowledge=i["accumulated_knowledge"],
    ),
    "KnowledgeRetentionMetric.generate_reason": lambda i: _knowledge_retention(
        "generate_reason", attritions=i["attritions"], score=format(i["score"], ".2f"),
    ),
    "KnowledgeRetentionMetric._experimental_system_one_questions": lambda i: _knowledge_retention(
        "_experimental_system_one_questions",
    ),
    "KnowledgeRetentionMetric._experimental_system_one_verdict": lambda i: _knowledge_retention(
        "_experimental_system_one_verdict",
    ),
    "RoleAdherenceMetric.extract_out_of_character_response_verdicts": lambda i: _role_adherence(
        "extract_out_of_character_response_verdicts",
        turns=_turn_dicts(i["turns"]),
        role=i["role"],
    ),
    "RoleAdherenceMetric.generate_reason": lambda i: _role_adherence(
        "generate_reason",
        score=i["score"],
        role=i["role"],
        out_of_character_responses=i["out_of_character_responses"],
    ),
    "RoleAdherenceMetric._experimental_system_one_questions": lambda i: _role_adherence(
        "_experimental_system_one_questions",
    ),
    "RoleAdherenceMetric._experimental_system_one_verdict": lambda i: _role_adherence(
        "_experimental_system_one_verdict",
    ),
    # The Turn RAG metrics format a window's reason score to two decimals
    # and print the final score unformatted, as the metric passes them.
    "TurnFaithfulnessMetric.generate_truths": lambda i: _turn_rag(
        TurnFaithfulnessMetric, "generate_truths", i,
        reference_context="\n\n".join(i["retrieval_context"]),
        limit_description=_turn_faithfulness_limit_description(i["truths_extraction_limit"]),
    ),
    "TurnFaithfulnessMetric.generate_claims": lambda i: _turn_rag(
        TurnFaithfulnessMetric, "generate_claims", i,
        input=i["input"], assistant_output=i["assistant_output"],
    ),
    "TurnFaithfulnessMetric.generate_verdicts": lambda i: _turn_rag(
        TurnFaithfulnessMetric, "generate_verdicts", i,
        claims=i["claims"], reference_context="\n\n".join(i["truths"]),
    ),
    "TurnFaithfulnessMetric.generate_reason": lambda i: _turn_rag(
        TurnFaithfulnessMetric, "generate_reason", i,
        contradictions=i["contradictions"], score=_score(i),
    ),
    "TurnFaithfulnessMetric.generate_final_reason": lambda i: _turn_final_reason(
        TurnFaithfulnessMetric, i,
    ),
    "TurnFaithfulnessMetric._experimental_system_one_questions": lambda i: _prompt(
        TurnFaithfulnessMetric, "_experimental_system_one_questions",
    ),
    "TurnFaithfulnessMetric._experimental_system_one_verdict": lambda i: _prompt(
        TurnFaithfulnessMetric, "_experimental_system_one_verdict",
    ),
    "TurnContextualPrecisionMetric.generate_verdicts": lambda i: _turn_rag(
        TurnContextualPrecisionMetric, "generate_verdicts", i,
        input=i["input"], expected_outcome=i["expected_outcome"],
        **dict(zip(
            ("document_count_str", "context_to_display", "multimodal_note"),
            _turn_contextual_precision_verdict_fields(
                i["retrieval_context"], i.get("multimodal", False)
            ),
        )),
    ),
    "TurnContextualPrecisionMetric.generate_reason": lambda i: _turn_rag(
        TurnContextualPrecisionMetric, "generate_reason", i,
        input=i["input"], score=_score(i),
        verdicts=_turn_contextual_precision_reason_verdicts(i["verdicts"]),
    ),
    "TurnContextualPrecisionMetric.generate_final_reason": lambda i: _turn_final_reason(
        TurnContextualPrecisionMetric, i,
    ),
    "TurnContextualPrecisionMetric._experimental_system_one_questions": lambda i: _prompt(
        TurnContextualPrecisionMetric, "_experimental_system_one_questions",
    ),
    "TurnContextualPrecisionMetric._experimental_system_one_verdict": lambda i: _prompt(
        TurnContextualPrecisionMetric, "_experimental_system_one_verdict",
    ),
    "TurnContextualRecallMetric.generate_verdicts": lambda i: _turn_rag(
        TurnContextualRecallMetric, "generate_verdicts", i,
        expected_outcome=i["expected_outcome"],
        **_turn_contextual_recall_verdict_kwargs(i["retrieval_context"], i.get("multimodal", False)),
    ),
    "TurnContextualRecallMetric.generate_reason": lambda i: _turn_rag(
        TurnContextualRecallMetric, "generate_reason", i,
        expected_outcome=i["expected_outcome"],
        supportive_reasons=i["supportive_reasons"],
        unsupportive_reasons=i["unsupportive_reasons"],
        score=_score(i),
        content_type="sentence or image" if i.get("multimodal", False) else "sentence",
    ),
    "TurnContextualRecallMetric.generate_final_reason": lambda i: _turn_final_reason(
        TurnContextualRecallMetric, i,
    ),
    "TurnContextualRecallMetric._experimental_system_one_questions": lambda i: _prompt(
        TurnContextualRecallMetric, "_experimental_system_one_questions",
    ),
    "TurnContextualRecallMetric._experimental_system_one_verdict": lambda i: _prompt(
        TurnContextualRecallMetric, "_experimental_system_one_verdict",
    ),
    "TurnContextualRelevancyMetric.generate_verdicts": lambda i: _turn_rag(
        TurnContextualRelevancyMetric, "generate_verdicts", i,
        input=i["input"], context=i["context"],
        **_turn_contextual_relevancy_verdict_kwargs(i.get("multimodal", False)),
    ),
    "TurnContextualRelevancyMetric.generate_reason": lambda i: _turn_rag(
        TurnContextualRelevancyMetric, "generate_reason", i,
        input=i["input"],
        irrelevant_statements=i["irrelevant_statements"],
        relevant_statements=i["relevant_statements"],
        score=_score(i),
    ),
    "TurnContextualRelevancyMetric.generate_final_reason": lambda i: _turn_final_reason(
        TurnContextualRelevancyMetric, i,
    ),
    "TurnContextualRelevancyMetric._experimental_system_one_questions": lambda i: _prompt(
        TurnContextualRelevancyMetric, "_experimental_system_one_questions",
    ),
    "TurnContextualRelevancyMetric._experimental_system_one_verdict": lambda i: _prompt(
        TurnContextualRelevancyMetric, "_experimental_system_one_verdict",
    ),
    # GoalAccuracy joins a unit's steps with newlines, and prints the final
    # score and threshold unformatted, as the metric passes them.
    "GoalAccuracyMetric.get_accuracy_score": lambda i: _goal_accuracy(
        "get_accuracy_score", i, task=i["task"], steps_taken="\n".join(i["steps_taken"]),
    ),
    "GoalAccuracyMetric.get_plan_evaluation_score": lambda i: _goal_accuracy(
        "get_plan_evaluation_score", i, task=i["task"], steps_taken="\n".join(i["steps_taken"]),
    ),
    "GoalAccuracyMetric.get_final_reason": lambda i: _goal_accuracy(
        "get_final_reason", i,
        final_score=i["final_score"],
        threshold=i["threshold"],
        goal_evaluations=_goal_accuracy_evaluations(i["goal_scores"], ""),
        plan_evalautions=_goal_accuracy_evaluations(i["plan_scores"], " \n"),
    ),
    "GoalAccuracyMetric._experimental_system_one_goal_score": lambda i: _prompt(
        GoalAccuracyMetric, "_experimental_system_one_goal_score",
    ),
    "GoalAccuracyMetric._experimental_system_one_plan_score": lambda i: _prompt(
        GoalAccuracyMetric, "_experimental_system_one_plan_score",
    ),
    "GoalAccuracyMetric._experimental_system_one_questions": lambda i: _prompt(
        GoalAccuracyMetric, "_experimental_system_one_questions",
    ),
    # ToolUse explains both of its scores with get_tool_selection_final_reason;
    # get_tool_argument_final_reason is bundled but never rendered by deepeval.
    "ToolUseMetric.get_tool_selection_score": lambda i: _tool_use_score(
        "get_tool_selection_score", i,
    ),
    "ToolUseMetric.get_argument_correctness_score": lambda i: _tool_use_score(
        "get_argument_correctness_score", i,
    ),
    "ToolUseMetric.get_tool_selection_final_reason": lambda i: _tool_use_reason(
        "get_tool_selection_final_reason", i,
    ),
    "ToolUseMetric.get_tool_argument_final_reason": lambda i: _tool_use_reason(
        "get_tool_argument_final_reason", i,
    ),
    "ToolUseMetric._experimental_system_one_tool_selection_score": lambda i: _tool_use(
        "_experimental_system_one_tool_selection_score",
    ),
    "ToolUseMetric._experimental_system_one_argument_correctness_score": lambda i: _tool_use(
        "_experimental_system_one_argument_correctness_score",
    ),
    "ToolUseMetric._experimental_system_one_questions": lambda i: _tool_use(
        "_experimental_system_one_questions",
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
    # TaskCompletion and StepEfficiency print the nested trace dict with
    # serialize_to_json(indent=2); TaskCompletion without a trace prints the
    # tools called as print_tools_called does.
    "TaskCompletionMetric.extract_goal_and_outcome": lambda i: _prompt(
        TaskCompletionMetric, "extract_goal_and_outcome",
        input=i["input"],
        actual_output=i["actual_output"],
        tools_called_formatted=print_tools_called(
            [ToolCall(**t) for t in i.get("tools_called", [])]
        ),
    ),
    "TaskCompletionMetric.extract_task_and_outcome_from_trace": lambda i: _prompt(
        TaskCompletionMetric, "extract_task_and_outcome_from_trace",
        trace_json=serialize_to_json(i["trace"], indent=2),
    ),
    "TaskCompletionMetric.generate_verdict": lambda i: _prompt(
        TaskCompletionMetric, "generate_verdict",
        task=i["task"], actual_outcome=i["outcome"],
    ),
    "TaskCompletionMetric._experimental_system_one_score": lambda i: _prompt(
        TaskCompletionMetric, "_experimental_system_one_score",
    ),
    "TaskCompletionMetric._experimental_system_one_questions": lambda i: _prompt(
        TaskCompletionMetric, "_experimental_system_one_questions",
        has_trace=i["has_trace"], has_task=i["has_task"],
    ),
    "StepEfficiencyMetric.extract_task_from_trace": lambda i: _step_efficiency(
        "extract_task_from_trace", i,
        trace_json=serialize_to_json(i["trace"], indent=2),
    ),
    "StepEfficiencyMetric.get_execution_efficiency": lambda i: _step_efficiency(
        "get_execution_efficiency", i,
        task=i["task"],
        trace_json_str=serialize_to_json(i["trace"], indent=2),
    ),
    "StepEfficiencyMetric._experimental_system_one_score": lambda i: _prompt(
        StepEfficiencyMetric, "_experimental_system_one_score",
    ),
    "StepEfficiencyMetric._experimental_system_one_questions": lambda i: _prompt(
        StepEfficiencyMetric, "_experimental_system_one_questions",
        has_trace=i["has_trace"],
    ),
    # PlanQuality and PlanAdherence print the plan one step per line and the
    # nested trace dict with serialize_to_json(indent=2). PlanQuality
    # borrows PlanAdherence's extract_plan_from_trace (and StepEfficiency's
    # extract_task_from_trace) with an explicit template_class.
    "PlanQualityMetric.evaluate_plan_quality": lambda i: _prompt(
        PlanQualityMetric, "evaluate_plan_quality",
        user_task=i["task"], agent_plan="\n".join(i["plan"]),
    ),
    "PlanQualityMetric._experimental_system_one_score": lambda i: _prompt(
        PlanQualityMetric, "_experimental_system_one_score",
    ),
    "PlanQualityMetric._experimental_system_one_questions": lambda i: _prompt(
        PlanQualityMetric, "_experimental_system_one_questions",
        has_trace=i["has_trace"],
    ),
    "PlanAdherenceMetric.extract_plan_from_trace": lambda i: _prompt(
        PlanAdherenceMetric, "extract_plan_from_trace",
        trace_json_str=serialize_to_json(i["trace"], indent=2),
    ),
    "PlanAdherenceMetric.evaluate_adherence": lambda i: _prompt(
        PlanAdherenceMetric, "evaluate_adherence",
        user_task=i["task"], agent_plan="\n".join(i["plan"]),
        execution_trace_json=serialize_to_json(i["trace"], indent=2),
    ),
    "PlanAdherenceMetric._experimental_system_one_score": lambda i: _prompt(
        PlanAdherenceMetric, "_experimental_system_one_score",
    ),
    "PlanAdherenceMetric._experimental_system_one_questions": lambda i: _prompt(
        PlanAdherenceMetric, "_experimental_system_one_questions",
        has_trace=i["has_trace"],
    ),
}

# Bundled templates of these metrics that no prompt case renders: none. The
# System One (`DEEPEVAL_EVAL_MODE`) `_experimental_*` templates are private
# methods, which `iter_base_template_methods` leaves out; the cases below
# render those of the metrics DeepEvalEx runs on System One.
UNRENDERED_TEMPLATES = set()

PARK_TEXT = (
    "The city council approved a new riverside park on Monday. Construction starts in "
    "March and the park opens in May. It will have a lake, a playground and 200 new trees."
)

PARIS_CONTEXT = [
    "Paris is the capital and largest city of France.",
    "The Louvre, the world's most-visited museum, opened in 1793.",
    "France's café culture dates back to the 17th century.",
]

GOLDEN_TOOLS = [
    {"name": "get_weather", "description": "Fetch current weather for a city"},
    {"name": "search_web", "description": "Search the web"},
]

# A pydantic model's model_json_schema(), as JsonCorrectness takes it: a
# nested model in $defs, an optional field, a list and a non-ASCII
# description, which the reason prompt escapes as json.dumps does.
PERSON_SCHEMA = {
    "$defs": {
        "Address": {
            "properties": {
                "city": {"title": "City", "type": "string"},
                "postcode": {"title": "Postcode", "type": "string"},
            },
            "required": ["city", "postcode"],
            "title": "Address",
            "type": "object",
        },
    },
    "properties": {
        "name": {"description": "Full name, e.g. José Saramago", "title": "Name", "type": "string"},
        "age": {"title": "Age", "type": "integer"},
        "tags": {"items": {"type": "string"}, "title": "Tags", "type": "array"},
        "address": {"$ref": "#/$defs/Address"},
        "nickname": {
            "anyOf": [{"type": "string"}, {"type": "null"}],
            "default": None,
            "title": "Nickname",
        },
    },
    "required": ["name", "age", "tags", "address"],
    "title": "Person",
    "type": "object",
}

# A nested trace dict (create_nested_spans_dict's shape, made JSON as
# serialize_to_json does) for the trace metrics' prompts: an agent span
# with a tool call (every ToolCall field, as vars() gives them), a tool
# child and an LLM child, and a non-ASCII character json.dumps escapes.
AGENT_TRACE = {
    "name": "booking_agent",
    "type": "agent",
    "input": {"query": "Book a table for two at Café Odéon on Saturday."},
    "output": "Booked: Saturday at 19:00, for two.",
    "tools_called": [{
        "name": "book_table",
        "type": "FUNCTION",
        "description": None,
        "reasoning": None,
        "output": "Booked for Saturday at 19:00",
        "input_parameters": {"day": "Saturday", "restaurant": "Café Odéon"},
    }],
    "available_tools": ["book_table", "search_web"],
    "agent_handoffs": [],
    "children": [
        {
            "name": "book_table",
            "type": "tool",
            "input": {"day": "Saturday", "restaurant": "Café Odéon"},
            "output": "Booked for Saturday at 19:00",
            "description": "Book a restaurant table",
            "children": [],
        },
        {
            "name": "confirm",
            "type": "llm",
            "input": "Confirm the booking.",
            "output": "Booked: Saturday at 19:00, for two.",
            "model": "gpt-4o-mini",
            "input_token_count": 42.0,
            "output_token_count": 9.0,
            "children": [],
        },
    ],
}

# The images of the multimodal fixtures, as MLLMImage keyword arguments: a
# base64 PNG and a remote URL, which is never fetched, so no file is read.
RED_DOT_IMAGE = {
    "dataBase64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==",
    "mimeType": "image/png",
    "_id": "red-dot",
}
CHART_IMAGE = {"url": "https://example.com/charts/sales.png", "_id": "sales-chart"}
RED_DOT = "[DEEPEVAL:IMAGE:red-dot]"
CHART = "[DEEPEVAL:IMAGE:sales-chart]"
MULTIMODAL = {"multimodal": True, "images": [RED_DOT_IMAGE, CHART_IMAGE]}

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
    "g_eval_generate_trace_evaluation_steps": {
        "template": "GEval.generate_trace_evaluation_steps",
        "inputs": {
            "criteria": "Determine whether the agent booked what the user asked for, "
                        "using the tool results it got.",
        },
    },
    "g_eval_generate_trace_evaluation_results": {
        "template": "GEval.generate_trace_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Check that the agent called book_table with the day and restaurant asked for.",
                "Check that the root output agrees with what book_table returned.",
            ],
            "trace": AGENT_TRACE,
        },
    },
    "g_eval_generate_trace_evaluation_results_rubric": {
        "template": "GEval.generate_trace_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Check that the agent called book_table with the day and restaurant asked for.",
                "Check that the root output agrees with what book_table returned.",
            ],
            "rubric": [
                {"score_range": [0, 3], "expected_outcome": "Wrong booking or no tool call."},
                {"score_range": [4, 7], "expected_outcome": "Right booking, output disagrees."},
                {"score_range": [8, 10], "expected_outcome": "Right booking, faithful output."},
            ],
            "trace": AGENT_TRACE,
        },
    },
    "g_eval_generate_strict_trace_evaluation_results": {
        "template": "GEval.generate_strict_trace_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Check that the root output agrees with what book_table returned.",
            ],
            "trace": AGENT_TRACE,
        },
    },
    "conversational_g_eval_generate_evaluation_steps": {
        "template": "ConversationalGEval.generate_evaluation_steps",
        "inputs": {
            "criteria": "Determine whether the assistant resolves the user's request politely.",
            "evaluation_params": ["content"],
        },
    },
    "conversational_g_eval_generate_evaluation_steps_case_params": {
        "template": "ConversationalGEval.generate_evaluation_steps",
        "inputs": {
            "criteria": "Check that the conversation plays out the scenario and reaches the expected outcome.",
            "evaluation_params": ["scenario", "expected_outcome", "role", "content"],
        },
    },
    "conversational_g_eval_generate_evaluation_results": {
        "template": "ConversationalGEval.generate_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Read the scenario and the tags.",
                "Check that each assistant turn answers the user turn before it.",
            ],
            "evaluation_params": ["scenario", "metadata", "tags", "content"],
            "test_case": {
                "scenario": "A customer asks for a refund on a late order. café ✓",
                "metadata": {"channel": "chat", "priority": 2, "escalated": False},
                "tags": ["refunds", "support"],
                "turns": [
                    {"role": "user", "content": "My order is late, I want a refund."},
                    {"role": "assistant", "content": "Sorry! I've started a refund for order 42."},
                    {"role": "user", "content": "Thanks, that's all."},
                ],
            },
        },
    },
    "conversational_g_eval_generate_evaluation_results_rubric": {
        "template": "ConversationalGEval.generate_evaluation_results",
        "inputs": {
            "evaluation_steps": [
                "Check that the assistant's answers are grounded in its retrieval context.",
                "Check that the assistant called the right tools.",
            ],
            "evaluation_params": ["role", "content", "retrieval_context", "tools_called"],
            "rubric": [
                {"score_range": [0, 3], "expected_outcome": "Ungrounded answers or wrong tools."},
                {"score_range": [4, 7], "expected_outcome": "Partly grounded answers."},
                {"score_range": [8, 10], "expected_outcome": "Grounded answers and the right tools."},
            ],
            "test_case": {
                "expected_outcome": "Not an evaluation param, so not in the prompt.",
                "turns": [
                    {"role": "user", "content": "Where is order 42?"},
                    {
                        "role": "assistant",
                        "content": "It shipped on 1 October.",
                        "retrieval_context": [
                            "Orders ship within 2 days.",
                            {"context": "Order 42 shipped on 1 October.", "source": "orders.db"},
                        ],
                        "tools_called": [
                            {
                                "name": "lookup_order",
                                "description": "Find an order",
                                "input_parameters": {"order": 42},
                                "output": {"status": "shipped"},
                            },
                        ],
                    },
                ],
            },
        },
    },
    "turn_relevancy_generate_verdicts": {
        "template": "TurnRelevancyMetric.generate_verdicts",
        "inputs": {
            "sliding_window": [
                {"role": "user", "content": "My order is late. Where's my café au lait set?"},
                {"role": "assistant", "content": 'It\'s "on its way": order 42 ships today.'},
                {"role": "user", "content": "Thanks!\nAnything else I need to do?"},
                {"role": "assistant", "content": "Have you tried our new pizza?"},
            ],
        },
    },
    "turn_relevancy_generate_reason": {
        "template": "TurnRelevancyMetric.generate_reason",
        "inputs": {
            "score": 0.6666666666666666,
            "irrelevancies": [
                {"message number": "3", "reason": "The pizza advert ignores the question."},
                {"message number": "5", "reason": None},
            ],
        },
    },
    "turn_relevancy_generate_reason_no_irrelevancies": {
        "template": "TurnRelevancyMetric.generate_reason",
        "inputs": {"score": 1, "irrelevancies": []},
    },
    "turn_relevancy_experimental_system_one_questions": {
        "template": "TurnRelevancyMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_relevancy_experimental_system_one_verdict": {
        "template": "TurnRelevancyMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "conversation_completeness_extract_user_intentions": {
        "template": "ConversationCompletenessMetric.extract_user_intentions",
        "inputs": {
            "turns": [
                {"role": "user", "content": "Book a table for two in Zürich on Friday."},
                {"role": "assistant", "content": "Done: Café Odéon, Friday at 8pm."},
                {"role": "user", "content": "And what's the dress code?"},
            ],
        },
    },
    "conversation_completeness_generate_verdicts": {
        "template": "ConversationCompletenessMetric.generate_verdicts",
        "inputs": {
            "turns": [
                {"role": "user", "content": "Book a table for two in Zürich on Friday."},
                {"role": "assistant", "content": "Done: Café Odéon, Friday at 8pm."},
            ],
            "intention": "User wants to book a table for two on Friday",
        },
    },
    "conversation_completeness_generate_reason": {
        "template": "ConversationCompletenessMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "incompletenesses": ["The LLM never says what the dress code is.", None],
            "intentions": ["User wants to book a table", "User wants to know the dress code"],
        },
    },
    "conversation_completeness_generate_reason_multimodal": {
        "template": "ConversationCompletenessMetric.generate_reason",
        "inputs": {
            "multimodal": True,
            "score": 1,
            "incompletenesses": [],
            "intentions": ["User wants to know what is in the picture"],
        },
    },
    "conversation_completeness_experimental_system_one_questions": {
        "template": "ConversationCompletenessMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "conversation_completeness_experimental_system_one_verdict": {
        "template": "ConversationCompletenessMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "knowledge_retention_extract_data": {
        "template": "KnowledgeRetentionMetric.extract_data",
        "inputs": {
            "user_message": "It's \"Zoë\", and I'm allergic to peanuts.",
            "previous_turns": [
                {"role": "user", "content": "Hi, I'd like to book a table."},
                {"role": "assistant", "content": "Sure! What's your name?"},
            ],
        },
    },
    "knowledge_retention_extract_data_first_turn": {
        "template": "KnowledgeRetentionMetric.extract_data",
        "inputs": {"user_message": "I'm flying to Lisbon on 3 May.", "previous_turns": []},
    },
    "knowledge_retention_generate_verdict": {
        "template": "KnowledgeRetentionMetric.generate_verdict",
        "inputs": {
            "llm_message": "Shall I add a peanut satay to your order, Zoë?",
            "accumulated_knowledge": [
                {"Name": "Zoë"},
                {"Allergies": ["Peanuts", "Shellfish"], "Party Size": "2"},
            ],
        },
    },
    "knowledge_retention_generate_reason": {
        "template": "KnowledgeRetentionMetric.generate_reason",
        "inputs": {
            "score": 0.3333333333333333,
            "attritions": ["The LLM offers peanuts to a user allergic to them.", None],
        },
    },
    "knowledge_retention_generate_reason_no_attritions": {
        "template": "KnowledgeRetentionMetric.generate_reason",
        "inputs": {"score": 1, "attritions": []},
    },
    "knowledge_retention_experimental_system_one_questions": {
        "template": "KnowledgeRetentionMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "knowledge_retention_experimental_system_one_verdict": {
        "template": "KnowledgeRetentionMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "role_adherence_extract_out_of_character_response_verdicts": {
        "template": "RoleAdherenceMetric.extract_out_of_character_response_verdicts",
        "inputs": {
            "role": "A humble wizard who's never sure his spells work.",
            "turns": [
                {"role": "user", "content": "Show me a spell!"},
                {"role": "assistant", "content": "Oh, it's only a little spark… I'm still learning."},
                {"role": "user", "content": "Something \"bigger\"!"},
                {"role": "assistant", "content": "Behold, the greatest wizard alive!"},
            ],
        },
    },
    "role_adherence_generate_reason": {
        "template": "RoleAdherenceMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "role": "A humble wizard who's never sure his spells work.",
            "out_of_character_responses": ["Behold, the greatest wizard alive! (turn #4)", None],
        },
    },
    "role_adherence_generate_reason_in_character": {
        "template": "RoleAdherenceMetric.generate_reason",
        "inputs": {"score": 1, "role": "A pirate.", "out_of_character_responses": []},
    },
    "role_adherence_experimental_system_one_questions": {
        "template": "RoleAdherenceMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "role_adherence_experimental_system_one_verdict": {
        "template": "RoleAdherenceMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "goal_accuracy_get_accuracy_score": {
        "template": "GoalAccuracyMetric.get_accuracy_score",
        "inputs": {
            "task": "User messages: \nBook a table for two at \"Café Odéon\" on Saturday.\n",
            "steps_taken": [
                "Assistant messages: \nLet me check Saturday's availability. \n",
                "Assistant messages: \nLet me check Saturday's availability. \n"
                "Booked: Café Odéon, Saturday at 19:00, for two. \nTools called: \n[\n"
                "  {\n      \"name\": \"book_table\"\n  }\n] \n",
            ],
        },
    },
    "goal_accuracy_get_accuracy_score_multimodal": {
        "template": "GoalAccuracyMetric.get_accuracy_score",
        "inputs": {
            "multimodal": True,
            "task": "User messages: \nWhat breed is the dog in this photo?\n",
            "steps_taken": ["Assistant messages: \nIt looks like a beagle. \n"],
        },
    },
    "goal_accuracy_get_plan_evaluation_score": {
        "template": "GoalAccuracyMetric.get_plan_evaluation_score",
        "inputs": {
            "task": "User messages: \nPlan my trip to Lisbon: flight, hotel and an agenda.\n",
            "steps_taken": [
                "Assistant messages: \nFirst the flight, then the hotel, then the agenda. \n",
            ],
        },
    },
    "goal_accuracy_get_plan_evaluation_score_multimodal": {
        "template": "GoalAccuracyMetric.get_plan_evaluation_score",
        "inputs": {"multimodal": True, "task": "User messages: \n", "steps_taken": []},
    },
    "goal_accuracy_get_final_reason": {
        "template": "GoalAccuracyMetric.get_final_reason",
        "inputs": {
            "final_score": 0.625,
            "threshold": 0.5,
            "goal_scores": [
                {"score": 1.0, "reason": "The table was booked."},
                {"score": 0.5, "reason": "The user's agenda is missing."},
            ],
            "plan_scores": [
                {"score": 0.75, "reason": "A clear plan."},
                {"score": 0.25, "reason": "No plan for the agenda."},
            ],
        },
    },
    "goal_accuracy_get_final_reason_strict_multimodal": {
        "template": "GoalAccuracyMetric.get_final_reason",
        "inputs": {
            "multimodal": True,
            "final_score": 0,
            "threshold": 1,
            "goal_scores": [{"score": 0.25, "reason": "Weak."}],
            "plan_scores": [],
        },
    },
    "goal_accuracy_experimental_system_one_goal_score": {
        "template": "GoalAccuracyMetric._experimental_system_one_goal_score",
        "inputs": {},
    },
    "goal_accuracy_experimental_system_one_plan_score": {
        "template": "GoalAccuracyMetric._experimental_system_one_plan_score",
        "inputs": {},
    },
    "goal_accuracy_experimental_system_one_questions": {
        "template": "GoalAccuracyMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "task_completion_extract_goal_and_outcome": {
        "template": "TaskCompletionMetric.extract_goal_and_outcome",
        "inputs": {
            "input": "Book a table for two at Café Odéon on Saturday.",
            "actual_output": "Booked: Saturday at 19:00, for two.",
            "tools_called": [{"name": "book_table",
                              "input_parameters": {"day": "Saturday", "restaurant": "Café Odéon"},
                              "output": "Booked for Saturday at 19:00"}],
        },
    },
    "task_completion_extract_goal_and_outcome_no_tools": {
        "template": "TaskCompletionMetric.extract_goal_and_outcome",
        "inputs": {"input": "What is 2 + 2?", "actual_output": "4"},
    },
    "task_completion_extract_task_and_outcome_from_trace": {
        "template": "TaskCompletionMetric.extract_task_and_outcome_from_trace",
        "inputs": {"trace": AGENT_TRACE},
    },
    "task_completion_generate_verdict": {
        "template": "TaskCompletionMetric.generate_verdict",
        "inputs": {"task": "Book a table for two on Saturday.",
                   "outcome": "The system booked a table for two on Saturday at 19:00."},
    },
    "task_completion_experimental_system_one_score": {
        "template": "TaskCompletionMetric._experimental_system_one_score",
        "inputs": {},
    },
    "task_completion_experimental_system_one_questions": {
        "template": "TaskCompletionMetric._experimental_system_one_questions",
        "inputs": {"has_trace": False, "has_task": False},
    },
    "task_completion_experimental_system_one_questions_task": {
        "template": "TaskCompletionMetric._experimental_system_one_questions",
        "inputs": {"has_trace": False, "has_task": True},
    },
    "task_completion_experimental_system_one_questions_trace": {
        "template": "TaskCompletionMetric._experimental_system_one_questions",
        "inputs": {"has_trace": True, "has_task": False},
    },
    "task_completion_experimental_system_one_questions_trace_task": {
        "template": "TaskCompletionMetric._experimental_system_one_questions",
        "inputs": {"has_trace": True, "has_task": True},
    },
    "step_efficiency_extract_task_from_trace": {
        "template": "StepEfficiencyMetric.extract_task_from_trace",
        "inputs": {"trace": AGENT_TRACE},
    },
    "step_efficiency_extract_task_from_trace_no_trace": {
        "template": "StepEfficiencyMetric.extract_task_from_trace",
        "inputs": {"trace": None},
    },
    "step_efficiency_get_execution_efficiency": {
        "template": "StepEfficiencyMetric.get_execution_efficiency",
        "inputs": {"task": "Book a table for two at Café Odéon on Saturday.", "trace": AGENT_TRACE},
    },
    "step_efficiency_get_execution_efficiency_multimodal": {
        "template": "StepEfficiencyMetric.get_execution_efficiency",
        "inputs": {"task": "Book a table for two on Saturday.", "trace": AGENT_TRACE,
                   "multimodal": True},
    },
    "step_efficiency_experimental_system_one_score": {
        "template": "StepEfficiencyMetric._experimental_system_one_score",
        "inputs": {},
    },
    "step_efficiency_experimental_system_one_questions": {
        "template": "StepEfficiencyMetric._experimental_system_one_questions",
        "inputs": {"has_trace": False},
    },
    "step_efficiency_experimental_system_one_questions_trace": {
        "template": "StepEfficiencyMetric._experimental_system_one_questions",
        "inputs": {"has_trace": True},
    },
    "plan_quality_evaluate_plan_quality": {
        "template": "PlanQualityMetric.evaluate_plan_quality",
        "inputs": {"task": "Book a table for two at Café Odéon on Saturday.",
                   "plan": ["Search for Café Odéon", "Book a table for two on Saturday",
                            "Confirm the booking"]},
    },
    "plan_quality_experimental_system_one_score": {
        "template": "PlanQualityMetric._experimental_system_one_score",
        "inputs": {},
    },
    "plan_quality_experimental_system_one_questions": {
        "template": "PlanQualityMetric._experimental_system_one_questions",
        "inputs": {"has_trace": False},
    },
    "plan_quality_experimental_system_one_questions_trace": {
        "template": "PlanQualityMetric._experimental_system_one_questions",
        "inputs": {"has_trace": True},
    },
    "plan_adherence_extract_plan_from_trace": {
        "template": "PlanAdherenceMetric.extract_plan_from_trace",
        "inputs": {"trace": AGENT_TRACE},
    },
    "plan_adherence_extract_plan_from_trace_no_trace": {
        "template": "PlanAdherenceMetric.extract_plan_from_trace",
        "inputs": {"trace": None},
    },
    "plan_adherence_evaluate_adherence": {
        "template": "PlanAdherenceMetric.evaluate_adherence",
        "inputs": {"task": "Book a table for two at Café Odéon on Saturday.",
                   "plan": ["Search for Café Odéon", "Book a table for two on Saturday"],
                   "trace": AGENT_TRACE},
    },
    "plan_adherence_experimental_system_one_score": {
        "template": "PlanAdherenceMetric._experimental_system_one_score",
        "inputs": {},
    },
    "plan_adherence_experimental_system_one_questions": {
        "template": "PlanAdherenceMetric._experimental_system_one_questions",
        "inputs": {"has_trace": False},
    },
    "plan_adherence_experimental_system_one_questions_trace": {
        "template": "PlanAdherenceMetric._experimental_system_one_questions",
        "inputs": {"has_trace": True},
    },
    "tool_use_get_tool_selection_score": {
        "template": "ToolUseMetric.get_tool_selection_score",
        "inputs": {
            "user_messages": "What's the weather in Paris? \nAnd in Zürich? \n",
            "assistant_messages": "It is 18°C in Paris. \nIt is 12°C in Zürich. \n",
            "tools_called": [
                {"name": "get_weather", "input_parameters": {"city": "Paris"},
                 "output": {"temp_c": 18}},
                {"name": "search_web", "input_parameters": {"query": "Zürich weather"}},
            ],
            "available_tools": GOLDEN_TOOLS,
        },
    },
    "tool_use_get_argument_correctness_score": {
        "template": "ToolUseMetric.get_argument_correctness_score",
        "inputs": {
            "user_messages": "Book a table at \"Café Odéon\" on Saturday. \n",
            "assistant_messages": "Booked for Saturday at 19:00. \n",
            "tools_called": [
                {"name": "book_table",
                 "input_parameters": {"day": "Saturday", "restaurant": "Café Odéon"}},
            ],
            "available_tools": [
                {"name": "book_table", "description": "Book a restaurant table"},
            ],
        },
    },
    "tool_use_get_tool_selection_final_reason": {
        "template": "ToolUseMetric.get_tool_selection_final_reason",
        "inputs": {
            "final_score": 0.75,
            "threshold": 0.5,
            "scores": [
                {"score": 1.0, "reason": "get_weather was the right tool."},
                {"score": 0.5, "reason": "search_web was used where get_weather fits."},
            ],
        },
    },
    "tool_use_get_tool_selection_final_reason_strict": {
        "template": "ToolUseMetric.get_tool_selection_final_reason",
        "inputs": {"final_score": 0, "threshold": 1, "scores": []},
    },
    "tool_use_get_tool_argument_final_reason": {
        "template": "ToolUseMetric.get_tool_argument_final_reason",
        "inputs": {
            "final_score": 0.5,
            "threshold": 0.5,
            "scores": [{"score": 0.5, "reason": "The 'day' argument is right, the time missing."}],
        },
    },
    "tool_use_experimental_system_one_tool_selection_score": {
        "template": "ToolUseMetric._experimental_system_one_tool_selection_score",
        "inputs": {},
    },
    "tool_use_experimental_system_one_argument_correctness_score": {
        "template": "ToolUseMetric._experimental_system_one_argument_correctness_score",
        "inputs": {},
    },
    "tool_use_experimental_system_one_questions": {
        "template": "ToolUseMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_faithfulness_generate_truths": {
        "template": "TurnFaithfulnessMetric.generate_truths",
        "inputs": {
            "retrieval_context": [
                "Refunds take 5 business days.",
                "Order 42 shipped on 1 October from Zürich.",
            ],
            "truths_extraction_limit": None,
        },
    },
    "turn_faithfulness_generate_truths_limit_one": {
        "template": "TurnFaithfulnessMetric.generate_truths",
        "inputs": {"retrieval_context": ["Refunds take 5 business days."],
                   "truths_extraction_limit": 1},
    },
    "turn_faithfulness_generate_truths_multimodal": {
        "template": "TurnFaithfulnessMetric.generate_truths",
        "inputs": {
            "multimodal": True,
            "retrieval_context": ["Refunds take 5 business days.", "Returns are free."],
            "truths_extraction_limit": 3,
        },
    },
    "turn_faithfulness_generate_claims": {
        "template": "TurnFaithfulnessMetric.generate_claims",
        "inputs": {
            "input": "\nMy order is late. \nWhere's my café au lait set? ",
            "assistant_output": "\nIt's \"on its way\": order 42 shipped on 1 October."
                                "\nRefunds take 5 days.",
        },
    },
    "turn_faithfulness_generate_claims_multimodal": {
        "template": "TurnFaithfulnessMetric.generate_claims",
        "inputs": {"multimodal": True, "input": "\nWhat is in the picture? ",
                   "assistant_output": "\nA red bicycle."},
    },
    "turn_faithfulness_generate_verdicts": {
        "template": "TurnFaithfulnessMetric.generate_verdicts",
        "inputs": {
            "claims": ["Order 42 shipped on 1 October.", "Refunds take 2 days.",
                       "The café is open late."],
            "truths": ["Refunds take 5 business days.", "Order 42 shipped on 1 October."],
        },
    },
    "turn_faithfulness_generate_verdicts_multimodal": {
        "template": "TurnFaithfulnessMetric.generate_verdicts",
        "inputs": {"multimodal": True, "claims": ["The bicycle is red."],
                   "truths": ["The picture shows a red bicycle."]},
    },
    "turn_faithfulness_generate_reason": {
        "template": "TurnFaithfulnessMetric.generate_reason",
        "inputs": {
            "score": 0.3333333333333333,
            "contradictions": ["Refunds take 5 business days, not 2.", None],
        },
    },
    "turn_faithfulness_generate_reason_multimodal": {
        "template": "TurnFaithfulnessMetric.generate_reason",
        "inputs": {"multimodal": True, "score": 1, "contradictions": []},
    },
    "turn_faithfulness_generate_final_reason": {
        "template": "TurnFaithfulnessMetric.generate_final_reason",
        "inputs": {
            "final_score": 0.6666666666666666,
            "success": True,
            "reasons": ["The refund time contradicts the context.", None, "<no claims to verify>"],
        },
    },
    "turn_faithfulness_generate_final_reason_failed": {
        "template": "TurnFaithfulnessMetric.generate_final_reason",
        "inputs": {"final_score": 0.0, "success": False, "reasons": ["Zürich is wrong."]},
    },
    "turn_faithfulness_experimental_system_one_questions": {
        "template": "TurnFaithfulnessMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_faithfulness_experimental_system_one_verdict": {
        "template": "TurnFaithfulnessMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "turn_contextual_precision_generate_verdicts": {
        "template": "TurnContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            "input": "\nWhere's my café au lait set? ",
            "expected_outcome": "The assistant says order 42 ships today.",
            "retrieval_context": ["Rome is the capital of Italy.",
                                  "Order 42 ships today from Zürich."],
        },
    },
    "turn_contextual_precision_generate_verdicts_one_document": {
        "template": "TurnContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            "input": "\nWhen does it ship? ",
            "expected_outcome": "It ships today.",
            "retrieval_context": ["Order 42 ships today."],
        },
    },
    "turn_contextual_precision_generate_verdicts_multimodal": {
        "template": "TurnContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            "multimodal": True,
            "input": "\nWhat is in the picture? ",
            "expected_outcome": "A red bicycle.",
            "retrieval_context": ["The picture shows a red bicycle.", "Bicycles have two wheels."],
        },
    },
    "turn_contextual_precision_generate_reason": {
        "template": "TurnContextualPrecisionMetric.generate_reason",
        "inputs": {
            "input": "\nWhere's my café au lait set? ",
            "score": 0.5,
            "verdicts": [
                {"verdict": "no", "reason": "Rome is irrelevant to the order."},
                {"verdict": "yes", "reason": "It says 'Order 42 ships today'."},
            ],
        },
    },
    "turn_contextual_precision_generate_reason_multimodal": {
        "template": "TurnContextualPrecisionMetric.generate_reason",
        "inputs": {
            "multimodal": True,
            "input": "\nWhat is in the picture? ",
            "score": 1,
            "verdicts": [{"verdict": "yes", "reason": "It describes the picture."}],
        },
    },
    "turn_contextual_precision_generate_final_reason": {
        "template": "TurnContextualPrecisionMetric.generate_final_reason",
        "inputs": {
            "final_score": 0.75,
            "success": True,
            "reasons": ["The relevant node is ranked second.",
                        "There were no retrieval contexts in the given turns to evaluate the "
                        "contextual precision."],
        },
    },
    "turn_contextual_precision_experimental_system_one_questions": {
        "template": "TurnContextualPrecisionMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_contextual_precision_experimental_system_one_verdict": {
        "template": "TurnContextualPrecisionMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "turn_contextual_recall_generate_verdicts": {
        "template": "TurnContextualRecallMetric.generate_verdicts",
        "inputs": {
            "expected_outcome": "Order 42 ships today. A refund takes 5 days.",
            "retrieval_context": ["Order 42 ships today from Zürich.", "Returns are free."],
        },
    },
    "turn_contextual_recall_generate_verdicts_multimodal": {
        "template": "TurnContextualRecallMetric.generate_verdicts",
        "inputs": {
            "multimodal": True,
            "expected_outcome": "A red bicycle.",
            "retrieval_context": ["The picture shows a red bicycle."],
        },
    },
    "turn_contextual_recall_generate_reason": {
        "template": "TurnContextualRecallMetric.generate_reason",
        "inputs": {
            "expected_outcome": "Order 42 ships today. A refund takes 5 days.",
            "score": 0.5,
            "supportive_reasons": ["The 1st node says 'Order 42 ships today'."],
            "unsupportive_reasons": ["No node mentions refunds.", None],
        },
    },
    "turn_contextual_recall_generate_reason_multimodal": {
        "template": "TurnContextualRecallMetric.generate_reason",
        "inputs": {
            "multimodal": True,
            "expected_outcome": "A red bicycle.",
            "score": 1,
            "supportive_reasons": ["The 1st node shows the bicycle."],
            "unsupportive_reasons": [],
        },
    },
    "turn_contextual_recall_generate_final_reason": {
        "template": "TurnContextualRecallMetric.generate_final_reason",
        "inputs": {"final_score": 1.0, "success": True,
                   "reasons": ["Every sentence is attributed to the café's notes."]},
    },
    "turn_contextual_recall_experimental_system_one_questions": {
        "template": "TurnContextualRecallMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_contextual_recall_experimental_system_one_verdict": {
        "template": "TurnContextualRecallMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "turn_contextual_relevancy_generate_verdicts": {
        "template": "TurnContextualRelevancyMetric.generate_verdicts",
        "inputs": {
            "input": "\nWhere's my café au lait set? \nIs it late? ",
            "context": "Order 42 ships today. Rome is the capital of Italy.",
        },
    },
    "turn_contextual_relevancy_generate_verdicts_multimodal": {
        "template": "TurnContextualRelevancyMetric.generate_verdicts",
        "inputs": {
            "multimodal": True,
            "input": "\nWhat is in the picture? ",
            "context": "The picture shows a red bicycle.",
        },
    },
    "turn_contextual_relevancy_generate_reason": {
        "template": "TurnContextualRelevancyMetric.generate_reason",
        "inputs": {
            "input": "\nWhere's my café au lait set? ",
            "score": 0.5,
            "irrelevant_statements": ["Rome is the capital of Italy.: It is about Italy.",
                                      "Returns are free.: None"],
            "relevant_statements": ["Order 42 ships today."],
        },
    },
    "turn_contextual_relevancy_generate_reason_multimodal": {
        "template": "TurnContextualRelevancyMetric.generate_reason",
        "inputs": {
            "multimodal": True,
            "input": "\nWhat is in the picture? ",
            "score": 1,
            "irrelevant_statements": [],
            "relevant_statements": ["A red bicycle."],
        },
    },
    "turn_contextual_relevancy_generate_final_reason": {
        "template": "TurnContextualRelevancyMetric.generate_final_reason",
        "inputs": {"final_score": 0.25, "success": False,
                   "reasons": ["Most statements are about Rome.", None]},
    },
    "turn_contextual_relevancy_experimental_system_one_questions": {
        "template": "TurnContextualRelevancyMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "turn_contextual_relevancy_experimental_system_one_verdict": {
        "template": "TurnContextualRelevancyMetric._experimental_system_one_verdict",
        "inputs": {},
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
    "contextual_relevancy_generate_verdicts": {
        "template": "ContextualRelevancyMetric.generate_verdicts",
        "inputs": {
            "input": "What is the capital of France?",
            "context": "Paris is the capital of France. There was a cat.",
        },
    },
    "contextual_relevancy_generate_reason": {
        "template": "ContextualRelevancyMetric.generate_reason",
        "inputs": {
            "score": 0.3333,
            "input": "What is the capital of France?",
            "irrelevant_statements": [
                "The context mentions 'There was a cat', which is unrelated.",
                None,
            ],
            "relevant_statements": ["Paris is the capital of France."],
        },
    },
    "bias_generate_opinions": {
        "template": "BiasMetric.generate_opinions",
        "inputs": {
            "actual_output": "I think the new mayor is doing a terrible job. "
                             "Paris is the capital of France.",
        },
    },
    "bias_generate_verdicts": {
        "template": "BiasMetric.generate_verdicts",
        "inputs": {
            "opinions": [
                "I think the new mayor is doing a terrible job.",
                "Engineers from that country can't be trusted.",
            ],
        },
    },
    "bias_generate_reason": {
        "template": "BiasMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "biases": [
                "'Engineers from that country can't be trusted' stereotypes a nationality.",
                None,
            ],
        },
    },
    "toxicity_generate_opinions": {
        "template": "ToxicityMetric.generate_opinions",
        "inputs": {
            "actual_output": "Only an idiot would ask that. The meeting is at noon.",
        },
    },
    "toxicity_generate_verdicts": {
        "template": "ToxicityMetric.generate_verdicts",
        "inputs": {
            "opinions": [
                "Only an idiot would ask that.",
                "I'd rather meet in the morning.",
            ],
        },
    },
    "toxicity_generate_reason": {
        "template": "ToxicityMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "toxics": ["'Only an idiot would ask that' insults the reader.", None],
        },
    },
    "pii_leakage_extract_pii": {
        "template": "PIILeakageMetric.extract_pii",
        "inputs": {
            "actual_output": "Jane Doe lives at 12 Elm Street and her SSN is 123-45-6789. "
                             "The office opens at nine.",
        },
    },
    "pii_leakage_generate_verdicts": {
        "template": "PIILeakageMetric.generate_verdicts",
        "inputs": {
            "extracted_pii": [
                "Jane Doe lives at 12 Elm Street.",
                "Her SSN is 123-45-6789.",
            ],
        },
    },
    "pii_leakage_generate_reason": {
        "template": "PIILeakageMetric.generate_reason",
        "inputs": {
            "score": 0.5,
            "privacy_violations": ["It reveals Jane Doe's home address.", None],
        },
    },
    "prompt_alignment_generate_verdicts": {
        "template": "PromptAlignmentMetric.generate_verdicts",
        "inputs": {
            "prompt_instructions": [
                "Reply in English.",
                "Never mention the user's 'account' number.",
            ],
            "input": "Où est ma commande ?",
            "actual_output": "Your order ships tomorrow.",
        },
    },
    "prompt_alignment_generate_reason": {
        "template": "PromptAlignmentMetric.generate_reason",
        "inputs": {
            "prompt_instructions": ["Reply in English.", "End with a question."],
            "score": 0.5,
            "unalignment_reasons": [None],
            "input": "Où est ma commande ?",
            "actual_output": "Your order ships tomorrow.",
        },
    },
    # Each tool call is its ToolCall.__repr__: the set fields, `type` always,
    # input_parameters and a dict output as json.dumps(indent=4,
    # ensure_ascii=False), any other output as its repr(). Keys are sorted
    # so the golden does not depend on dict order.
    "argument_correctness_generate_verdicts": {
        "template": "ArgumentCorrectnessMetric.generate_verdicts",
        "inputs": {
            "input": "Book a table for two in Zürich on Friday.",
            "tools_called": [
                {
                    "name": "restaurant_search",
                    "description": "Finds \"open\" restaurants",
                    "reasoning": "I need a restaurant in Zürich first.",
                    "input_parameters": {
                        "city": "Zürich",
                        "filters": {"cuisine": ["swiss", "italian"], "open": True},
                        "party_size": 2,
                    },
                    "output": {"results": [{"name": "Café Odéon", "rating": 4.5}]},
                },
                {
                    "name": "book_table",
                    "type": "MCP",
                    "input_parameters": {"day": "Saturday", "restaurant": "Café Odéon"},
                    "output": "Booked for Saturday at 19:00",
                },
                {"name": "get_time", "output": 3},
            ],
        },
    },
    "argument_correctness_generate_reason": {
        "template": "ArgumentCorrectnessMetric.generate_reason",
        "inputs": {
            "score": 0.3333333333333333,
            "incorrect_tool_calls_reasons": ["It books Saturday, not Friday.", None],
            "input": "Book a table for two in Zürich on Friday.",
        },
    },
    "json_correctness_generate_reason": {
        "template": "JsonCorrectnessMetric.generate_reason",
        "inputs": {
            "actual_output": '{"name": "José", "age": "forty-one", "tags": ["a", 2]}',
            "expected_schema": PERSON_SCHEMA,
            "is_valid_json": False,
        },
    },
    # Multimodal test cases: the templates' `multimodal` branches, with
    # image placeholders in the inputs.
    "answer_relevancy_generate_statements_multimodal": {
        "template": "AnswerRelevancyMetric.generate_statements",
        "inputs": {**MULTIMODAL, "actual_output": f"The chart {CHART} shows sales doubling."},
    },
    "answer_relevancy_generate_verdicts_multimodal": {
        "template": "AnswerRelevancyMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "input": f"What does {CHART} show?",
            "statements": ["Sales doubled.", "The chart is blue."],
        },
    },
    "answer_relevancy_generate_reason_multimodal": {
        "template": "AnswerRelevancyMetric.generate_reason",
        "inputs": {
            **MULTIMODAL,
            "score": 0.5,
            "input": f"What does {CHART} show?",
            "irrelevant_statements": ["The colour of the chart does not answer the question."],
        },
    },
    "argument_correctness_generate_verdicts_multimodal": {
        "template": "ArgumentCorrectnessMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "input": f"Find a restaurant like the one in {RED_DOT}.",
            "tools_called": [
                {"name": "restaurant_search", "input_parameters": {"query": "red dot"}},
            ],
        },
    },
    "argument_correctness_generate_reason_multimodal": {
        "template": "ArgumentCorrectnessMetric.generate_reason",
        "inputs": {
            **MULTIMODAL,
            "score": 0.0,
            "incorrect_tool_calls_reasons": ["The query ignores the image."],
            "input": f"Find a restaurant like the one in {RED_DOT}.",
        },
    },
    "bias_generate_opinions_multimodal": {
        "template": "BiasMetric.generate_opinions",
        "inputs": {**MULTIMODAL, "actual_output": f"I think {RED_DOT} is ugly."},
    },
    "bias_generate_verdicts_multimodal": {
        "template": "BiasMetric.generate_verdicts",
        "inputs": {**MULTIMODAL, "opinions": ["I think the dot is ugly."]},
    },
    "contextual_precision_generate_verdicts_multimodal": {
        "template": "ContextualPrecisionMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "input": "How did sales change?",
            "expected_output": "Sales doubled.",
            "retrieval_context": [f"Sales doubled in 2024. {CHART}", RED_DOT, "There was a cat."],
        },
    },
    "contextual_precision_generate_reason_multimodal": {
        "template": "ContextualPrecisionMetric.generate_reason",
        "inputs": {
            **MULTIMODAL,
            "score": 1.0,
            "input": "How did sales change?",
            "verdicts": [{"verdict": "yes", "reason": "The chart shows sales doubling."}],
        },
    },
    "contextual_recall_generate_verdicts_multimodal": {
        "template": "ContextualRecallMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "expected_output": f"Sales doubled. {CHART}",
            "retrieval_context": [f"Sales doubled in 2024. {CHART}", "There was a cat."],
        },
    },
    "contextual_recall_generate_reason_multimodal": {
        "template": "ContextualRecallMetric.generate_reason",
        "inputs": {
            **MULTIMODAL,
            "score": 1.0,
            "expected_output": f"Sales doubled. {CHART}",
            "supportive_reasons": ["The 1st node says sales doubled."],
            "unsupportive_reasons": [],
        },
    },
    "contextual_relevancy_generate_verdicts_multimodal": {
        "template": "ContextualRelevancyMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "input": "How did sales change?",
            "context": f"Sales doubled in 2024. {CHART}",
        },
    },
    "faithfulness_generate_claims_multimodal": {
        "template": "FaithfulnessMetric.generate_claims",
        "inputs": {**MULTIMODAL, "actual_output": f"Sales doubled, as {CHART} shows."},
    },
    "faithfulness_generate_truths_multimodal": {
        "template": "FaithfulnessMetric.generate_truths",
        "inputs": {
            **MULTIMODAL,
            "retrieval_context": [f"Sales doubled in 2024. {CHART}", "There was a cat."],
            "truths_extraction_limit": None,
        },
    },
    "faithfulness_generate_verdicts_multimodal": {
        "template": "FaithfulnessMetric.generate_verdicts",
        "inputs": {
            **MULTIMODAL,
            "claims": ["Sales doubled."],
            "truths": ["Sales doubled in 2024."],
        },
    },
    "g_eval_generate_evaluation_steps_multimodal": {
        "template": "GEval.generate_evaluation_steps",
        "inputs": {
            **MULTIMODAL,
            "criteria": "Determine whether the actual output describes the image in the input.",
            "evaluation_params": ["input", "actual_output"],
        },
    },
    "g_eval_generate_evaluation_results_multimodal": {
        "template": "GEval.generate_evaluation_results",
        "inputs": {
            **MULTIMODAL,
            "evaluation_steps": ["Check that the actual output describes the image."],
            "evaluation_params": ["input", "actual_output"],
            "test_case": {
                "input": f"Describe {RED_DOT}",
                "actual_output": "A red dot.",
                "images": [RED_DOT_IMAGE],
            },
        },
    },
    "g_eval_generate_strict_evaluation_results_multimodal": {
        "template": "GEval.generate_strict_evaluation_results",
        "inputs": {
            **MULTIMODAL,
            "evaluation_steps": ["Check that the actual output describes the image."],
            "evaluation_params": ["input", "actual_output"],
            "test_case": {
                "input": f"Describe {RED_DOT}",
                "actual_output": "A red dot.",
                "images": [RED_DOT_IMAGE],
            },
        },
    },
    "g_eval_generate_trace_evaluation_steps_multimodal": {
        "template": "GEval.generate_trace_evaluation_steps",
        "inputs": {**MULTIMODAL, "criteria": "Determine whether the agent booked the right table."},
    },
    "g_eval_generate_trace_evaluation_results_multimodal": {
        "template": "GEval.generate_trace_evaluation_results",
        "inputs": {
            **MULTIMODAL,
            "evaluation_steps": ["Check that the agent called book_table."],
            "trace": AGENT_TRACE,
        },
    },
    "g_eval_generate_strict_trace_evaluation_results_multimodal": {
        "template": "GEval.generate_strict_trace_evaluation_results",
        "inputs": {
            **MULTIMODAL,
            "evaluation_steps": ["Check that the agent called book_table."],
            "trace": AGENT_TRACE,
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
    "contextual_relevancy_experimental_system_one_questions": {
        "template": "ContextualRelevancyMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "contextual_relevancy_experimental_system_one_verdict": {
        "template": "ContextualRelevancyMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "bias_experimental_system_one_questions": {
        "template": "BiasMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "bias_experimental_system_one_verdict": {
        "template": "BiasMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "toxicity_experimental_system_one_questions": {
        "template": "ToxicityMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "toxicity_experimental_system_one_verdict": {
        "template": "ToxicityMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    "pii_leakage_experimental_system_one_questions": {
        "template": "PIILeakageMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "pii_leakage_experimental_system_one_verdict": {
        "template": "PIILeakageMetric._experimental_system_one_verdict",
        "inputs": {},
    },
    # Each instruction goes through Jinja's `tojson`: JSON with non-ASCII,
    # `<`, `>`, `&` and `'` escaped as \uXXXX.
    "prompt_alignment_experimental_system_one_questions": {
        "template": "PromptAlignmentMetric._experimental_system_one_questions",
        "inputs": {
            "prompt_instructions": [
                "Reply in English.",
                "Wrap code in <code> & never say \"can't\" \u2014 or \\n.",
            ],
        },
    },
    "prompt_alignment_experimental_system_one_verdict": {
        "template": "PromptAlignmentMetric._experimental_system_one_verdict",
        "inputs": {"prompt_instructions": ["Reply in English."]},
    },
    "argument_correctness_experimental_system_one_questions": {
        "template": "ArgumentCorrectnessMetric._experimental_system_one_questions",
        "inputs": {},
    },
    "argument_correctness_experimental_system_one_verdict": {
        "template": "ArgumentCorrectnessMetric._experimental_system_one_verdict",
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
    "summarization_generate_questions": {
        "template": "SummarizationMetric.generate_questions",
        "inputs": {"text": PARK_TEXT, "n": 3},
    },
    "summarization_generate_answers": {
        "template": "SummarizationMetric.generate_answers",
        "inputs": {
            "questions": ["Was a riverside park approved?", "Does the park's café open in May?"],
            "text": "The council approved a riverside park with a lake. It opens in May.",
        },
    },
    "summarization_generate_alignment_verdicts": {
        "template": "SummarizationMetric.generate_alignment_verdicts",
        "inputs": {
            "truths": [
                "The city council approved a new riverside park.",
                "The park opens in May.",
            ],
            "summary_claims": ["The council approved a riverside park.", "The park's café opens in June."],
        },
    },
    # The questions the summary cannot answer follow the redundancies.
    "summarization_generate_reason": {
        "template": "SummarizationMetric.generate_reason",
        "inputs": {
            "score": 0.3333333333333333,
            "contradictions": ["The park opens in May, not June.", None],
            "redundancies": [None],
            "questions": ["Will the park have a playground?"],
        },
    },
    # Without such questions, "JSON:" directly follows the redundancies.
    "summarization_generate_reason_all_answered": {
        "template": "SummarizationMetric.generate_reason",
        "inputs": {
            "score": 1,
            "contradictions": [],
            "redundancies": [],
            "questions": [],
        },
    },
    # Each assessment question goes through Jinja's `tojson`.
    "summarization_experimental_system_one_questions": {
        "template": "SummarizationMetric._experimental_system_one_questions",
        "inputs": {
            "assessment_questions": [
                "Does the park open in May?",
                "Is the caf\u00e9 <open> & \"busy\"?",
            ],
        },
    },
    "summarization_experimental_system_one_questions_none": {
        "template": "SummarizationMetric._experimental_system_one_questions",
        "inputs": {"assessment_questions": []},
    },
    "summarization_experimental_system_one_verdict": {
        "template": "SummarizationMetric._experimental_system_one_verdict",
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
    """Fails unless every bundled template of the thirty metrics is rendered
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


def generate_prompts(names=None):
    """Writes the prompt goldens: every case, or only the named ones."""
    check_prompt_coverage()
    unknown = sorted(set(names or []) - set(PROMPT_CASES))
    if unknown:
        sys.exit(f"unknown prompt cases: {', '.join(unknown)}")
    for name, case in PROMPT_CASES.items():
        if names and name not in names:
            continue
        run_prompt_case(name, case)
        print(f"wrote {os.path.relpath(os.path.join(PROMPTS, name), ROOT)}")


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


###############################################################################
# Traced scenarios (`generate_fixtures.py traced`)
###############################################################################
#
# Each scenario of `TRACED_SCENARIOS` is an agent script: `functions`, each
# an @observe'd function (span `type`, `params` as [name] or [name, default],
# `observe` keyword arguments, span `metrics` and `metric_collection`, a
# `body` of steps and the value it `returns`), and `app`, the steps user code
# runs for every golden. The script is interpreted twice, as plain functions
# and as coroutines, so the same call tree runs under deepeval's sync and
# async evals_iterator. Its steps:
#
# - {"call": f, "args": [...], "kwargs": {...}, "as": name, "catch": bool}
#   calls function f, binds its result to `name`, and with `catch` swallows
#   the exception it raises
# - {"update_current_span" | "update_current_trace" | "update_llm_span" |
#   "update_agent_span" | "update_tool_span" | "update_retriever_span": kwargs}
# - {"with": "next_span" | "next_agent_span" | ..., "kwargs": kwargs,
#   "body": [steps]} runs `body` inside that context manager
# - {"drop_current_span": true}, deepeval's `current_span_context.drop()`
# - {"raise": {"type": "ValueError" | "RuntimeError", "message": text}}
#
# A value is resolved against the function's arguments and bound results
# (the golden's `input` for `app`): "$name" is that value, and any other
# string is formatted with them (`str.format`). In kwargs, `test_case` is an
# LLMTestCase's keyword arguments, `tools_called` and `expected_tools`
# ToolCall keyword arguments, `prompt` a Prompt (`alias`, `version`,
# `label`, `hash`), `token_intervals` keys perf_counter values as strings,
# and `metrics` metric specs (`traced_metric`).
#
# For every scenario this writes, under test/fixtures/deepeval/traced/<name>/:
#
# - input.json        - the scenario
# - trace_api.json    - outside evaluation (EvalMode.OFF), for every trace
#                       the plain-function app started, in order: the body
#                       deepeval would post, `create_trace_api(trace)` dumped
#                       by alias without None values (what end_trace hands
#                       trace_testing_manager)
# - nested.json       - for the same traces, `create_nested_spans_dict` of
#                       the trace's root span, made JSON-serialisable as
#                       `serialize_to_json` does (the `_trace_dict` trace
#                       metrics read)
# - compact.json      - `compact_trace` of each nested dict (the trace System
#                       One reads)
# - test_run_<mode>.json - for every mode in `modes`, the test run deepeval's
#                       evals_iterator wrote with AsyncConfig(run_async=False)
#                       ("sync") or run_async=True ("async")
# - prompts_<mode>.json - when a metric has a ScriptedJudge: every prompt it
#                       was sent during that run, with its step
#
# Async runs use only metrics that never suspend, so asyncio's span order is
# deterministic. Uuids and timestamps differ between runs; see the README.

TRACED = os.path.join(FIXTURES, "traced")

TRACED_GOLDEN = {
    "input": "How do I reset my password?",
    "expected_output": "Use the 'Forgot password' link.",
    "name": "password-reset",
}

TRACED_GOLDEN_DE = {"input": "Wo ist meine Rechnung?", "expected_output": "Unter Konto › Rechnungen."}

# An LLM call: tokens and per-token costs reported with update_llm_span.
TRACED_GENERATE = {
    "type": "llm",
    "params": [["query"], ["documents"]],
    "observe": {"model": "gpt-4o-mini", "cost_per_input_token": 1.5e-07},
    "body": [{"update_llm_span": {"input_token_count": 42, "output_token_count": 7,
                                  "cost_per_output_token": 6e-07}}],
    "returns": "Answer to {query}",
}

LOOP_DETECTION = {"kind": "agent_loop_detection", "params": {"threshold": 0.5}}

# TaskCompletion judged from the trace: one task-and-outcome extraction and
# one verdict per measure.
TASK_COMPLETION = {
    "kind": "task_completion",
    "judge_model": "mock-model",
    "params": {"threshold": 0.5},
    "responses": {
        "outcome,task": [{"task": "Tell the user how to reset their password",
                          "outcome": "The agent searched twice, then answered."}],
        "reason,verdict": [{"verdict": 0.8,
                            "reason": "The agent answered, after repeating a search."}],
    },
}

# StepEfficiency judged from a span's trace dict: one task extraction and
# one efficiency score per measure.
STEP_EFFICIENCY = {
    "kind": "step_efficiency",
    "judge_model": "mock-model",
    "params": {"threshold": 0.5},
    "responses": {
        "task": [{"task": "Tell the user how to reset their password"}],
        "reason,score": [{"score": 0.75,
                          "reason": "The agent repeated its search once before answering."}],
    },
}

# GEval without evaluation_params, judged from the trace: one steps call
# (from its criteria) and one score per measure.
G_EVAL_TRACE = {
    "kind": "g_eval",
    "judge_model": "mock-model",
    "params": {
        "name": "Trajectory",
        "criteria": "Determine whether the agent answered from what its search returned, "
                    "without redundant calls.",
        "threshold": 0.5,
    },
    "responses": {
        "steps": [{"steps": ["Check that generate answers from search's results.",
                             "Check for repeated search calls."]}],
        "reason,score": [{"score": 6,
                          "reason": "agent answered via generate, but called search twice."}],
    },
}

# The plan an agent states in an LLM span's output, extracted by the plan
# metrics: one task extraction, one plan extraction and one score per measure.
TRACED_PLAN = ["Search the help centre for password resets", "Answer with the steps found"]

PLAN_QUALITY = {
    "kind": "plan_quality",
    "judge_model": "mock-model",
    "params": {"threshold": 0.5},
    "responses": {
        "task": [{"task": "Tell the user how to reset their password"}],
        "plan": [{"plan": TRACED_PLAN}],
        "reason,score": [{"score": 0.75,
                          "reason": "The plan does not say which help centre article to use."}],
    },
}

PLAN_ADHERENCE = {
    "kind": "plan_adherence",
    "judge_model": "mock-model",
    "params": {"threshold": 0.5},
    "responses": {
        "task": [{"task": "Tell the user how to reset their password"}],
        "plan": [{"plan": TRACED_PLAN}],
        "reason,score": [{"score": 0.5,
                          "reason": "Step 1 was carried out twice; step 2 matches the answer."}],
    },
}


def traced_planner(metrics, span_metrics):
    """A planning agent: an LLM span states the plan, then the agent
    searches and answers. `metrics` judge the trace, `span_metrics` the
    agent span."""
    return {
        "goldens": [TRACED_GOLDEN],
        "metrics": metrics,
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "observe": {"available_tools": ["search"]},
                "metrics": span_metrics,
                "body": [
                    {"call": "plan", "args": ["$query"]},
                    {"call": "search", "args": ["$query"]},
                    {"call": "search", "args": ["$query"]},
                    {"call": "generate", "args": ["$query", []], "as": "answer"},
                    # The sync iterator's trace has no output of its own.
                    {"update_current_trace": {"output": "$answer"}},
                ],
                "returns": "$answer",
            },
            "plan": {"type": "llm", "params": [["query"]],
                     "observe": {"model": "gpt-4o-mini"},
                     "returns": "My plan: 1. " + TRACED_PLAN[0] + ". 2. " + TRACED_PLAN[1] + "."},
            "search": {"type": "tool", "params": [["query"]], "returns": ["result for {query}"]},
            "generate": TRACED_GENERATE,
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    }


TRACED_SCENARIOS = {
    "nested_spans": {
        "description": "An agent calling a retriever, a tool and an LLM, over two goldens: "
                       "span types and their fields, the tool's call auto-filled into the "
                       "agent's toolsCalled, trace attributes, span and trace metrics",
        "goldens": [TRACED_GOLDEN, TRACED_GOLDEN_DE],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "answer": {
                "type": "agent",
                "params": [["query"]],
                "observe": {"available_tools": ["search_docs"], "agent_handoffs": ["billing"]},
                "body": [
                    {"call": "retrieve", "args": ["$query"], "as": "documents"},
                    {"call": "search_docs", "kwargs": {"query": "$query"}},
                    {"call": "generate", "args": ["$query", "$documents"], "as": "answer"},
                    {"update_current_trace": {"name": "support", "tags": ["parity"],
                                              "metadata": {"channel": "chat"},
                                              "thread_id": "thread-1", "user_id": "user-1"}},
                ],
                "returns": "$answer",
            },
            "retrieve": {
                "type": "retriever",
                "params": [["query"], ["k", 2]],
                "observe": {"embedder": "text-embedding-3-small"},
                "metrics": [SPAN_JUDGE],
                "body": [{"update_retriever_span": {"top_k": 2, "chunk_size": 512}},
                         {"update_current_span": {"retrieval_context": ["FAQ: {query}"],
                                                  "metadata": {"index": "faq"}}}],
                "returns": ["FAQ: {query}", "Policy: answers cite the help centre."],
            },
            "search_docs": {
                "type": "tool",
                "params": [["query"]],
                "observe": {"description": "Searches the help centre"},
                "returns": {"hits": 2, "query": "$query"},
            },
            "generate": {**TRACED_GENERATE, "metrics": [STRICT_JUDGE]},
        },
        "app": [{"call": "answer", "args": ["{input}"]}],
    },
    "function_kwargs": {
        "description": "Default span inputs from the call's arguments: a zero-argument function "
                       "({}), and arguments bound in signature order whatever the call order, "
                       "with defaults applied, and their Python str() as the span test case input",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"call": "clock", "as": "now"},
                    {"call": "lookup", "kwargs": {"mid": True, "zeta": "$query", "alpha": 3}},
                ],
                "returns": "Looked up at {now}",
            },
            "clock": {"returns": "noon"},
            "lookup": {
                "type": "tool",
                "params": [["zeta"], ["alpha"], ["mid", False], ["omega", None], ["beta", [1, 2]]],
                "metrics": [SPAN_JUDGE],
                "returns": {"found": True},
            },
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "metrics_without_input": {
        "description": "Span metrics on a zero-argument span, whose input is {}: sync builds "
                       "a test case from it (`is not None`), async does not (truthiness) and "
                       "reports the missing LLMTestCase",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [{"call": "ping"}],
                "returns": "pong for {query}",
            },
            "ping": {"metrics": [SPAN_JUDGE], "returns": "pong"},
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "raised_caught": {
        "description": "A tool that raises inside an agent that catches it: the tool span is "
                       "ERRORED with str(exception) and its metrics skipped, the agent and "
                       "the trace succeed",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [{"call": "flaky_tool", "args": ["$query"], "catch": True}],
                "returns": "Recovered from a failed lookup",
            },
            "flaky_tool": {
                "type": "tool",
                "params": [["query"]],
                "metrics": [SPAN_JUDGE],
                "body": [{"raise": {"type": "ValueError", "message": "upstream timeout"}}],
            },
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "errored_trace": {
        "description": "A root span that raises, caught by the app: in async (and outside "
                       "evaluation) the root marks the trace ERRORED, which skips every trace "
                       "and span metric; in sync the root is the wrapper span's child, so the "
                       "trace stays SUCCESS",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "metrics": [SPAN_JUDGE],
                "body": [
                    {"call": "search", "args": ["$query"]},
                    {"raise": {"type": "RuntimeError", "message": "planner crashed"}},
                ],
            },
            "search": {
                "type": "tool",
                "params": [["query"]],
                "metrics": [SPAN_JUDGE],
                "returns": ["result for {query}"],
            },
        },
        "app": [{"call": "agent", "args": ["{input}"], "catch": True}],
    },
    "raised_uncaught": {
        "description": "The app's coroutine raises out of the root span: the async iterator "
                       "marks the trace and its root ERRORED with format_error_text. Async "
                       "only: in sync the exception leaves the user's loop and no run is saved",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["async"],
        "uncaught": True,
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"call": "search", "args": ["$query"]},
                    {"raise": {"type": "RuntimeError", "message": "agent gave up"}},
                ],
            },
            "search": {
                "type": "tool",
                "params": [["query"]],
                "metrics": [SPAN_JUDGE],
                "returns": ["result for {query}"],
            },
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "span_test_case": {
        "description": "update_current_span(test_case=...) setting a span's input, output, "
                       "expected output, contexts and tools, judged by span metrics, and "
                       "update_current_trace(test_case=...) doing the same for the trace",
        "goldens": [TRACED_GOLDEN],
        "metrics": [{"kind": "exact_match"}, STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"call": "retrieve", "args": ["$query"], "as": "documents"},
                    {"update_current_trace": {"test_case": {
                        "input": "$query",
                        "actual_output": "Use the 'Forgot password' link.",
                        "expected_output": "Use the 'Forgot password' link.",
                        "retrieval_context": "$documents",
                        "tools_called": [{"name": "retrieve"}],
                    }}},
                ],
                "returns": "Use the 'Forgot password' link.",
            },
            "retrieve": {
                "type": "retriever",
                "params": [["query"]],
                "metrics": [{"kind": "exact_match"}, SPAN_JUDGE],
                "body": [{"update_current_span": {"test_case": {
                    "input": "$query",
                    "actual_output": "FAQ: reset",
                    "expected_output": "FAQ: reset",
                    "context": ["Accounts have passwords."],
                    "retrieval_context": ["FAQ: reset", "FAQ: billing"],
                    "tools_called": [{"name": "index", "input_parameters": {"q": "$query"}}],
                    "expected_tools": [{"name": "index"}],
                }}}],
                "returns": ["FAQ: reset", "FAQ: billing"],
            },
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "next_span_staging": {
        "description": "next_llm_span and next_span: staged fields land on the next span of "
                       "the type only (the second LLM call gets none), typed slots win over "
                       "the base slot, staged metrics run",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"with": "next_span", "kwargs": {"metadata": {"staged": "base"},
                                                     "metric_collection": "base-collection"},
                     "body": [
                         {"with": "next_llm_span",
                          "kwargs": {"model": "gpt-4o", "input_token_count": 10,
                                     "metadata": {"staged": "llm"}, "name": "staged_call",
                                     "metrics": [SPAN_JUDGE]},
                          "body": [
                              {"call": "generate", "args": ["$query", []]},
                              {"call": "generate", "args": ["again", []]},
                          ]},
                     ]},
                    {"with": "next_tool_span", "kwargs": {"description": "Staged description"},
                     "body": [{"call": "lookup", "args": ["$query"]}]},
                ],
                "returns": "done",
            },
            "generate": TRACED_GENERATE,
            "lookup": {"type": "tool", "params": [["query"]], "returns": "found"},
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "dropped_span": {
        "description": "A span that drops itself: outside evaluation create_trace_api skips "
                       "it and re-parents its children; the evaluation walkers keep it",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [{"call": "plan", "args": ["$query"]}],
                "returns": "planned",
            },
            "plan": {
                "params": [["query"]],
                "body": [{"drop_current_span": True},
                         {"call": "search", "args": ["$query"]},
                         {"call": "search", "args": ["more {query}"]}],
                "returns": "plan",
            },
            "search": {"type": "tool", "params": [["query"]], "returns": "hit for {query}"},
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "two_top_level": {
        "description": "Two top-level spans per golden: sync keeps the wrapper span's first "
                       "child only (root_spans[0].children[0]); async evaluates each trace "
                       "as its own test case",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "first": {
                "type": "agent",
                "params": [["query"]],
                "metrics": [SPAN_JUDGE],
                "returns": "first answer to {query}",
            },
            "second": {
                "type": "agent",
                "params": [["query"]],
                "metrics": [STRICT_JUDGE],
                "returns": "second answer to {query}",
            },
        },
        "app": [{"call": "first", "args": ["{input}"]}, {"call": "second", "args": ["{input}"]}],
    },
    "requires_trace": {
        "description": "Metrics that read the trace (requires_trace): AgentLoopDetection on the "
                       "trace, on a span and on a zero-argument span (whose test case is the "
                       "input=\"None\" placeholder in async), and TaskCompletion judged by a "
                       "ScriptedJudge from the nested trace dict",
        "goldens": [TRACED_GOLDEN],
        "metrics": [LOOP_DETECTION, TASK_COMPLETION],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "observe": {"available_tools": ["search"]},
                "metrics": [LOOP_DETECTION],
                "body": [
                    {"call": "search", "args": ["$query"]},
                    {"call": "search", "args": ["$query"]},
                    {"call": "think"},
                    {"call": "generate", "args": ["$query", []], "as": "answer"},
                    # The sync iterator's trace has no output of its own.
                    {"update_current_trace": {"output": "$answer"}},
                ],
                "returns": "$answer",
            },
            "search": {"type": "tool", "params": [["query"]], "returns": ["result for {query}"]},
            "think": {"type": "llm", "metrics": [LOOP_DETECTION], "returns": "I will search."},
            "generate": TRACED_GENERATE,
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "llm_prompt_fields": {
        "description": "LlmSpan prompt fields: from observe(prompt=...), from "
                       "update_llm_span(prompt=...) over it, and from next_llm_span(prompt=...); "
                       "token_intervals keys as microsecond timestamps",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"call": "draft", "args": ["$query"]},
                    {"call": "polish", "args": ["$query"]},
                    {"with": "next_llm_span",
                     "kwargs": {"prompt": {"alias": "staged-prompt", "version": "00.00.02",
                                           "label": "staging", "hash": "bbb222"}},
                     "body": [{"call": "draft", "args": ["staged"]}]},
                ],
                "returns": "drafted",
            },
            "draft": {
                "type": "llm",
                "params": [["query"]],
                "observe": {"model": "claude-3-5-sonnet",
                            "prompt": {"alias": "draft-prompt", "version": "00.00.01",
                                       "label": "production", "hash": "aaa111"}},
                "returns": "draft of {query}",
            },
            "polish": {
                "type": "llm",
                "params": [["query"]],
                "observe": {"model": "gpt-4o",
                            "prompt": {"alias": "draft-prompt", "version": "00.00.01",
                                       "label": "production", "hash": "aaa111"}},
                "body": [{"update_llm_span": {
                    "prompt": {"alias": "polish-prompt", "version": "00.00.07", "hash": "ccc333"},
                    "token_intervals": {"1.25": "Hel", "1.5": "lo", "2.000001": "!"},
                }}],
                "returns": "polished {query}",
            },
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "provider_normalisation": {
        "description": "LlmSpan providers: normalised to deepeval's Provider values outside "
                       "evaluation (exact, case and separator variants, a model path, an "
                       "unknown provider kept), exported raw by the evaluation walkers",
        "goldens": [TRACED_GOLDEN],
        "metrics": [STUB_JUDGE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "body": [
                    {"call": "call_openai"},
                    {"call": "call_anthropic"},
                    {"call": "call_vertex"},
                    {"call": "call_custom"},
                    {"call": "call_updated"},
                ],
                "returns": "called",
            },
            "call_openai": {"type": "llm", "observe": {"model": "gpt-4o", "provider": "openai"},
                            "returns": "a"},
            "call_anthropic": {"type": "llm",
                               "observe": {"model": "claude-3-haiku",
                                           "provider": "anthropic/claude-3-haiku"},
                               "returns": "b"},
            "call_vertex": {"type": "llm", "observe": {"model": "gemini-1.5", "provider": "Vertex AI"},
                            "returns": "c"},
            "call_custom": {"type": "llm", "observe": {"model": "local", "provider": "My Lab"},
                            "returns": "d"},
            "call_updated": {"type": "llm", "observe": {"model": "grok-2"},
                             "body": [{"update_current_span": {"provider": "x_ai"}}],
                             "returns": "e"},
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "trace_metrics": {
        "description": "The trace metrics judged by ScriptedJudges from nested trace dicts: "
                       "TaskCompletion on the trace and StepEfficiency on the agent span",
        "goldens": [TRACED_GOLDEN],
        "metrics": [TASK_COMPLETION],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "observe": {"available_tools": ["search"]},
                "metrics": [STEP_EFFICIENCY],
                "body": [
                    {"call": "search", "args": ["$query"]},
                    {"call": "search", "args": ["$query"]},
                    {"call": "generate", "args": ["$query", []], "as": "answer"},
                    # The sync iterator's trace has no output of its own.
                    {"update_current_trace": {"output": "$answer"}},
                ],
                "returns": "$answer",
            },
            "search": {"type": "tool", "params": [["query"]], "returns": ["result for {query}"]},
            "generate": TRACED_GENERATE,
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "g_eval_trace": {
        "description": "GEval without evaluation_params on the trace, judged by a ScriptedJudge "
                       "from the nested trace dict with its trace prompts",
        "goldens": [TRACED_GOLDEN],
        "metrics": [G_EVAL_TRACE],
        "modes": ["sync", "async"],
        "functions": {
            "agent": {
                "type": "agent",
                "params": [["query"]],
                "observe": {"available_tools": ["search"]},
                "body": [
                    {"call": "search", "args": ["$query"]},
                    {"call": "search", "args": ["$query"]},
                    {"call": "generate", "args": ["$query", []], "as": "answer"},
                    # The sync iterator's trace has no output of its own.
                    {"update_current_trace": {"output": "$answer"}},
                ],
                "returns": "$answer",
            },
            "search": {"type": "tool", "params": [["query"]], "returns": ["result for {query}"]},
            "generate": TRACED_GENERATE,
        },
        "app": [{"call": "agent", "args": ["{input}"]}],
    },
    "plan_quality": {
        "description": "PlanQuality on the trace, judged by a ScriptedJudge from the nested "
                       "dict of a trace whose LLM span states a plan",
        **traced_planner([PLAN_QUALITY], []),
    },
    "plan_adherence": {
        "description": "PlanAdherence on the agent span, judged by a ScriptedJudge from the "
                       "nested dict of the span that states a plan and then carries it out",
        **traced_planner([], [PLAN_ADHERENCE]),
    },
}

TRACED_EXCEPTIONS = {"ValueError": ValueError, "RuntimeError": RuntimeError}

TRACED_UPDATES = {
    "update_current_span": update_current_span,
    "update_current_trace": update_current_trace,
    "update_llm_span": update_llm_span,
    "update_agent_span": update_agent_span,
    "update_tool_span": update_tool_span,
    "update_retriever_span": update_retriever_span,
}

TRACED_NEXT = {
    "next_span": next_span,
    "next_agent_span": next_agent_span,
    "next_llm_span": next_llm_span,
    "next_tool_span": next_tool_span,
    "next_retriever_span": next_retriever_span,
}


class TracedRun:
    """What one interpretation of a script produced: the traces its spans
    belonged to (read from deepeval's trace context, in start order) and
    the ScriptedJudges its metrics were built with."""

    def __init__(self):
        self.traces = []
        self.judges = []

    def saw_trace(self):
        trace = current_trace_context.get()
        if trace is not None and all(t is not trace for t in self.traces):
            self.traces.append(trace)

    def metric(self, spec):
        kind = spec["kind"]
        if kind == "agent_loop_detection":
            return AgentLoopDetectionMetric(**spec.get("params", {}))
        if kind in ("task_completion", "step_efficiency", "plan_quality", "plan_adherence",
                    "g_eval"):
            judge = ScriptedJudge(spec["judge_model"], spec["responses"])
            self.judges.append(judge)
            return SCRIPTED_METRICS[kind](model=judge, **spec.get("params", {}))
        return build_metric(spec)

    def metrics(self, specs):
        return [self.metric(spec) for spec in specs] if specs else None


def build_prompt(spec):
    """A Prompt as pull() leaves it: alias, version, label and hash set."""
    prompt = Prompt(alias=spec.get("alias"), text_template=spec.get("text_template", "{input}"))
    prompt.version = spec.get("version")
    prompt.label = spec.get("label")
    prompt.hash = spec.get("hash")
    return prompt


def resolve(value, env):
    if isinstance(value, str):
        if value.startswith("$") and value[1:] in env:
            return env[value[1:]]
        return value.format(**env) if "{" in value else value
    if isinstance(value, list):
        return [resolve(item, env) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item, env) for key, item in value.items()}
    return value


def tracing_kwargs(kwargs, run):
    kwargs = dict(kwargs)
    if "test_case" in kwargs:
        kwargs["test_case"] = build_test_case(kwargs["test_case"])
    for key in ("tools_called", "expected_tools"):
        if kwargs.get(key):
            kwargs[key] = [ToolCall(**tool_call) for tool_call in kwargs[key]]
    if "prompt" in kwargs:
        kwargs["prompt"] = build_prompt(kwargs["prompt"])
    if "token_intervals" in kwargs:
        kwargs["token_intervals"] = {float(k): v for k, v in kwargs["token_intervals"].items()}
    if "metrics" in kwargs:
        kwargs["metrics"] = run.metrics(kwargs["metrics"])
    return kwargs


def run_traced_step(step, env, run):
    """Runs a step that calls no function; False for one that does."""
    for name, update in TRACED_UPDATES.items():
        if name in step:
            update(**tracing_kwargs(resolve(step[name], env), run))
            return True
    if step.get("drop_current_span"):
        current_span_context.drop()
        return True
    if "raise" in step:
        raise TRACED_EXCEPTIONS[step["raise"]["type"]](step["raise"]["message"])
    return False


def traced_call(step, env, functions):
    function = functions[step["call"]]
    return function(*resolve(step.get("args", []), env), **resolve(step.get("kwargs", {}), env))


def run_traced_steps(steps, env, functions, run):
    for step in steps:
        if run_traced_step(step, env, run):
            continue
        if "with" in step:
            kwargs = tracing_kwargs(resolve(step.get("kwargs", {}), env), run)
            with TRACED_NEXT[step["with"]](**kwargs):
                run_traced_steps(step["body"], env, functions, run)
            continue
        try:
            result = traced_call(step, env, functions)
        except Exception:
            if not step.get("catch"):
                raise
            result = None
        if "as" in step:
            env[step["as"]] = result


async def a_run_traced_steps(steps, env, functions, run):
    for step in steps:
        if run_traced_step(step, env, run):
            continue
        if "with" in step:
            kwargs = tracing_kwargs(resolve(step.get("kwargs", {}), env), run)
            with TRACED_NEXT[step["with"]](**kwargs):
                await a_run_traced_steps(step["body"], env, functions, run)
            continue
        try:
            result = await traced_call(step, env, functions)
        except Exception:
            if not step.get("catch"):
                raise
            result = None
        if "as" in step:
            env[step["as"]] = result


def build_traced_functions(script, run, is_async):
    """The script's functions, @observe'd, as plain functions or coroutines.
    Each gets the script's name and signature, which observe reads for the
    span name and the default input (the bound arguments, defaults
    applied)."""
    functions = {}
    for name, spec in script["functions"].items():
        signature = inspect.Signature([
            inspect.Parameter(param[0], inspect.Parameter.POSITIONAL_OR_KEYWORD,
                              **({"default": param[1]} if len(param) > 1 else {}))
            for param in spec.get("params", [])
        ])

        def env_of(args, kwargs, signature=signature):
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            return dict(bound.arguments)

        if is_async:
            async def function(*args, _spec=spec, _env_of=env_of, **kwargs):
                run.saw_trace()
                env = _env_of(args, kwargs)
                await a_run_traced_steps(_spec.get("body", []), env, functions, run)
                return resolve(_spec.get("returns"), env)
        else:
            def function(*args, _spec=spec, _env_of=env_of, **kwargs):
                run.saw_trace()
                env = _env_of(args, kwargs)
                run_traced_steps(_spec.get("body", []), env, functions, run)
                return resolve(_spec.get("returns"), env)

        function.__name__ = function.__qualname__ = name
        function.__signature__ = signature
        observe_kwargs = dict(spec.get("observe", {}))
        if "prompt" in observe_kwargs:
            observe_kwargs["prompt"] = build_prompt(observe_kwargs["prompt"])
        functions[name] = observe(
            function,
            type=spec.get("type"),
            metrics=run.metrics(spec.get("metrics")),
            metric_collection=spec.get("metric_collection"),
            **observe_kwargs,
        )
    return functions


def build_goldens(specs):
    goldens = []
    for spec in specs:
        spec = dict(spec)
        for key in ("tools_called", "expected_tools"):
            if key in spec:
                spec[key] = [ToolCall(**tool_call) for tool_call in spec[key]]
        goldens.append(Golden(**spec))
    return goldens


def capture_untraced(script):
    """Runs the plain-function app outside evaluation, one golden after the
    other, and returns the TraceApi bodies deepeval built as each trace
    ended, with the traces themselves. trace_testing_manager is deepeval's
    own hook for this: with a test name set, end_trace stores the body it
    would post instead of posting it."""
    if trace_manager.is_evaluating or trace_manager.environment != "development":
        raise RuntimeError("traced: the OFF-mode capture must run before any evaluation")
    run = TracedRun()
    functions = build_traced_functions(script, run, is_async=False)
    bodies = []
    for golden in script["goldens"]:
        env = {"input": golden["input"]}
        for step in script["app"]:
            trace_testing_manager.test_name = "deepeval_ex_parity"
            trace_testing_manager.test_dict = None
            try:
                traced_call(step, env, functions)
            except Exception:
                if not step.get("catch") and not script.get("uncaught"):
                    raise
            finally:
                bodies.append(trace_testing_manager.test_dict)
                trace_testing_manager.test_name = None
                trace_testing_manager.test_dict = None
    if any(body is None for body in bodies) or len(bodies) != len(run.traces):
        raise RuntimeError("traced: expected one trace per top-level call")
    return bodies, run.traces


def run_traced_mode(script, mode, results_folder):
    run = TracedRun()
    is_async = mode == "async"
    functions = build_traced_functions(script, run, is_async=is_async)
    dataset = EvaluationDataset()
    dataset.goldens = build_goldens(script["goldens"])

    async def a_app(golden):
        env = {"input": golden.input}
        await a_run_traced_steps(script["app"], env, functions, run)

    iterator = dataset.evals_iterator(
        metrics=run.metrics(script.get("metrics")),
        identifier=script.get("identifier"),
        async_config=AsyncConfig(run_async=is_async),
        display_config=DisplayConfig(show_indicator=False, print_results=False,
                                     inspect_after_run=False,
                                     results_folder=results_folder),
        cache_config=CacheConfig(write_cache=False, use_cache=False),
        error_config=ErrorConfig(ignore_errors=True),
    )
    for golden in iterator:
        if is_async:
            # evals_iterator patches asyncio.create_task to collect the task.
            asyncio.create_task(a_app(golden))
        else:
            run_traced_steps(script["app"], {"input": golden.input}, functions, run)
    for judge in run.judges:
        judge.assert_exhausted()
    return run


def run_traced_scenario(name, script):
    out_dir = os.path.join(TRACED, name)
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    write_json(os.path.join(out_dir, "input.json"), script)

    bodies, traces = capture_untraced(script)
    nested, compact = [], []
    for trace in traces:
        if len(trace.root_spans) != 1:
            raise RuntimeError(f"{name}: expected one root span, found {len(trace.root_spans)}")
        # The dict holds deepeval objects (ToolCalls): serialize_to_json
        # turns them into dicts, compact_trace into their str().
        trace_dict = trace_manager.create_nested_spans_dict(trace.root_spans[0])
        nested.append(json.loads(serialize_to_json(trace_dict)))
        compact.append(compact_trace(trace_dict))
    write_json(os.path.join(out_dir, "trace_api.json"), bodies)
    write_json(os.path.join(out_dir, "nested.json"), nested)
    write_json(os.path.join(out_dir, "compact.json"), compact)
    return out_dir


def run_traced_evaluations(name, script):
    out_dir = os.path.join(TRACED, name)
    for mode in script["modes"]:
        results_folder = tempfile.mkdtemp(prefix=f"traced_{name}_{mode}_", dir=WORK_DIR)
        run = run_traced_mode(script, mode, results_folder)
        [path] = glob.glob(os.path.join(results_folder, "test_run_*.json"))
        shutil.copyfile(path, os.path.join(out_dir, f"test_run_{mode}.json"))
        if run.judges:
            write_json(os.path.join(out_dir, f"prompts_{mode}.json"),
                       [prompt for judge in run.judges for prompt in judge.prompts])


# Epoch times in microseconds, deepeval's span timestamps after
# perf_counter_to_datetime, with the edges of to_zod_compatible_iso's
# truncation (never rounding) to milliseconds and of its microsecond form
# for token interval keys.
ISO_TABLE_INPUTS = [
    0,
    1,
    999,
    1_000,
    1_499,
    1_500,
    999_499,
    999_500,
    999_999,
    1_000_000,
    1_700_000_000_000_000,
    1_700_000_000_000_999,
    1_700_000_000_999_500,
    1_700_000_000_999_999,
    1_709_251_199_999_999,  # 2024-02-29T23:59:59.999999, a leap day
    1_761_177_600_123_456,
    2_147_483_647_999_999,  # past the 32-bit time_t limit
    4_102_444_799_999_999,  # 2099-12-31T23:59:59.999999
    253_402_300_799_999_999,  # 9999-12-31T23:59:59.999999, the last datetime
]


def write_iso_table():
    """traced/iso_table.json: what to_zod_compatible_iso makes of each epoch
    time, in milliseconds (span and trace times) and microseconds (token
    interval keys). Built from the exact microsecond count, as
    perf_counter_to_datetime's datetime holds one."""
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    rows = []
    for epoch_us in ISO_TABLE_INPUTS:
        dt = epoch + timedelta(microseconds=epoch_us)
        rows.append({
            "epoch_us": epoch_us,
            "milliseconds": to_zod_compatible_iso(dt),
            "microseconds": to_zod_compatible_iso(dt, microsecond_precision=True),
        })
    os.makedirs(TRACED, exist_ok=True)
    write_json(os.path.join(TRACED, "iso_table.json"), rows)


def generate_traced(names=None):
    """Every traced scenario's untraced capture first: a sync evaluation
    switches trace_manager's environment to "testing" for good, and
    create_trace_api exports it. `names` regenerates only those scenarios
    (and not iso_table.json)."""
    unknown = sorted(set(names or []) - set(TRACED_SCENARIOS))
    if unknown:
        sys.exit(f"unknown traced scenarios: {', '.join(unknown)}")
    scenarios = {name: script for name, script in TRACED_SCENARIOS.items()
                 if not names or name in names}
    if not names:
        write_iso_table()
        print(f"wrote {os.path.relpath(os.path.join(TRACED, 'iso_table.json'), ROOT)}")
    for name, script in scenarios.items():
        run_traced_scenario(name, script)
    for name, script in scenarios.items():
        run_traced_evaluations(name, script)
        print(f"wrote {os.path.relpath(os.path.join(TRACED, name), ROOT)}")


LOOP_DETECTION_DIR = os.path.join(FIXTURES, "loop_detection")

# The isjunk functions a sequence_matcher.json row may name.
SEQUENCE_MATCHER_JUNK = {None: None, "space": lambda c: c == " "}

LOOP_WORDS = [
    "search", "results", "query", "password", "reset", "account", "settings",
    "email", "link", "user", "answer", "check", "again", "documents", "help",
    "centre", "forgot", "login", "page", "steps", "confirm", "retry", "tool",
]


def _mutate(rng, text, alphabet, edits):
    """`text` after `edits` random insertions, deletions and substitutions."""
    chars = list(text)
    for _ in range(edits):
        op = rng.choice("ids") if chars else "i"
        at = rng.randrange(len(chars) + (op == "i"))
        if op == "i":
            chars.insert(at, rng.choice(alphabet))
        elif op == "d":
            del chars[at]
        else:
            chars[at] = rng.choice(alphabet)
    return "".join(chars)


def _sequence_matcher_pairs():
    """(a, b, isjunk, autojunk) pairs: fixed edge cases, then seeded random
    strings over small alphabets (many equal elements), mutated copies
    (high ratios), junk-heavy texts with a space isjunk, texts of 190 to 260
    elements around autojunk's 200-element popularity cut, and word texts
    like the cleaned LLM outputs AgentLoopDetection compares."""
    pairs = [
        ("", "", None, True),
        ("", "abc", None, True),
        ("abc", "", None, True),
        ("abcd", "bcde", None, True),
        ("abcd", "abcd", None, True),
        ("qabxcd", "abycdf", None, True),
        ("private Thread currentThread;", "private volatile Thread currentThread;", None, True),
        ("private Thread currentThread;", "private volatile Thread currentThread;", "space", True),
        (" abcd", "abcd abcd", None, True),
        (" abcd", "abcd abcd", "space", True),
        ("café crème brûlée", "cafe creme brulee", None, True),
        ("naïve é \U0001F600 ok", "naive é \U0001F600 ok", None, True),
        ("a" * 199, "a" * 199, None, True),
        ("a" * 200, "a" * 200, None, True),
        ("a" * 200, "a" * 200, None, False),
        ("b" + "a" * 199, "a" * 199 + "b", None, True),
        ("x" * 50 + "a" * 150, "a" * 150 + "x" * 50, None, True),
        ("x" * 50 + "a" * 150, "a" * 150 + "x" * 50, None, False),
    ]
    rng = random.Random(431)
    for _ in range(30):
        alphabet = rng.choice(["ab", "abc", "abcd"])
        pairs.append((
            "".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 40))),
            "".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 40))),
            None,
            True,
        ))
    for _ in range(15):
        alphabet = "abcdefgh "
        b = "".join(rng.choice(alphabet) for _ in range(rng.randrange(20, 120)))
        pairs.append((_mutate(rng, b, alphabet, rng.randrange(1, 12)), b, None, True))
    for _ in range(10):
        alphabet = "ab     "
        pairs.append((
            "".join(rng.choice(alphabet) for _ in range(rng.randrange(40, 160))),
            "".join(rng.choice(alphabet) for _ in range(rng.randrange(40, 160))),
            "space",
            True,
        ))
    for _ in range(12):
        alphabet = rng.choice(["abcde ", "ab", "abcdefghijklmnopqrstuvwxyz  "])
        b = "".join(rng.choice(alphabet) for _ in range(rng.randrange(190, 261)))
        a = _mutate(rng, b, alphabet, rng.randrange(5, 60))
        autojunk = rng.random() < 0.75
        pairs.append((a, b, None, autojunk))
    for _ in range(12):
        b = " ".join(rng.choice(LOOP_WORDS) for _ in range(rng.randrange(20, 60)))
        if rng.random() < 0.5:
            words = b.split()
            rng.shuffle(words)
            a = " ".join(words)
        else:
            a = _mutate(rng, b, "abcdefghijklmnopqrstuvwxyz ", rng.randrange(0, 30))
        pairs.append((a, b, None, True))
    return pairs


def write_loop_detection_tables():
    """loop_detection/sequence_matcher.json: for each pair,
    SequenceMatcher(isjunk, a, b, autojunk).ratio() and its matching blocks
    (AgentLoopDetection compares texts with SequenceMatcher(None, a, b));
    loop_detection/input_hash.json: AgentLoopDetectionMetric._input_hash of
    nested-dict spans, the input part of its cycle labels (sorted-keys JSON,
    or str(), truncated to 64 characters)."""
    rows = []
    for a, b, junk, autojunk in _sequence_matcher_pairs():
        matcher = SequenceMatcher(SEQUENCE_MATCHER_JUNK[junk], a, b, autojunk)
        rows.append({
            "a": a,
            "b": b,
            "isjunk": junk,
            "autojunk": autojunk,
            "ratio": matcher.ratio(),
            "matching_blocks": [list(block) for block in matcher.get_matching_blocks()],
        })
    spans = [
        {"name": "search"},
        {"name": "search", "input": None},
        {"name": "search", "input": ""},
        {"name": "search", "input": "short query"},
        {"name": "search", "input": "q" * 63 + "é" + "z" * 10},
        {"name": "search", "input": "é" * 40},
        {"name": "search", "input": {}},
        {"name": "search", "input": {"query": "reset password"}},
        {"name": "search", "input": {"z": 1, "a": [1, 2.5, None, True], "m": {"y": "x", "b": False}}},
        {"name": "search", "input": {"query": "Café Odéon, table for two on Saturday at 19:00 please"}},
        {"name": "search", "input": {"text": "\U0001F600   \"quoted\" \\ back\nslash"}},
        {"name": "search", "input": {"k" * 70: "v"}},
        {"name": "search", "input": ["a", {"b": 1}, 2.0]},
        {"name": "search", "input": 42},
        {"name": "search", "input": 1.5e-07},
        {"name": "search", "input": True},
    ]
    hashes = [{"span": span, "input_hash": AgentLoopDetectionMetric._input_hash(span)}
              for span in spans]
    os.makedirs(LOOP_DETECTION_DIR, exist_ok=True)
    write_json(os.path.join(LOOP_DETECTION_DIR, "sequence_matcher.json"), rows)
    write_json(os.path.join(LOOP_DETECTION_DIR, "input_hash.json"), hashes)


def generate_scripted(names=None):
    """The scripted-judge scenarios' outputs, or only those of `names`."""
    available = sorted(name for name in os.listdir(SCRIPTED)
                       if os.path.isfile(os.path.join(SCRIPTED, name, "script.json")))
    unknown = sorted(set(names or []) - set(available))
    if unknown:
        sys.exit(f"unknown scripted scenarios: {', '.join(unknown)}")
    for name in available:
        if not names or name in names:
            run_scripted_scenario(name)
            print(f"wrote {os.path.relpath(os.path.join(SCRIPTED, name), ROOT)}")


# Multimodal content parts: how deepeval's OpenAI, Anthropic and Ollama
# models turn a prompt holding image placeholders into their messages'
# content (to_openai_content, AnthropicModel._prompt_content and
# OllamaModel._prompt_messages), for base64, remote and local images. A
# remote image is left out of the Ollama case, which downloads it. A prompt
# without placeholders is not a case: DeepEvalEx sends it as the plain
# string it sent before, where deepeval's OpenAI and Anthropic models send
# a one-part list.
MULTIMODAL_DIR = os.path.join(FIXTURES, "multimodal")
LOCAL_DOT_IMAGE = {"url": "test/fixtures/deepeval/multimodal/red_dot.png", "_id": "local-dot"}
CONTENT_PART_CASES = {
    "base64_and_remote": {
        "prompt": f"Compare {RED_DOT} with {CHART}.",
        "images": [RED_DOT_IMAGE, CHART_IMAGE],
        "remote": True,
    },
    "local_file": {
        "prompt": "[DEEPEVAL:IMAGE:local-dot] is a dot",
        "images": [LOCAL_DOT_IMAGE],
    },
}


def write_content_parts():
    """Writes multimodal/content_parts.json: for each case its prompt and
    images, and the content each model builds from them. The local image's
    path is relative to the repository root, as for the tests."""
    from deepeval.models.llms.anthropic_model import AnthropicModel
    from deepeval.models.llms.multimodal import to_openai_content
    from deepeval.models.llms.ollama_model import OllamaModel

    os.chdir(ROOT)
    # The content builders use no model state, so no client is created.
    anthropic = AnthropicModel.__new__(AnthropicModel)
    ollama = OllamaModel.__new__(OllamaModel)
    cases = {}
    for name, case in CONTENT_PART_CASES.items():
        register_images(case["images"])
        prompt = case["prompt"]
        cases[name] = {
            "prompt": prompt,
            "images": case["images"],
            "openai": to_openai_content(prompt),
            "anthropic": anthropic._prompt_content(prompt),
            "ollama": None if case.get("remote") else ollama._prompt_messages(prompt),
        }
    os.makedirs(MULTIMODAL_DIR, exist_ok=True)
    write_json(os.path.join(MULTIMODAL_DIR, "content_parts.json"), cases)


def main():
    if deepeval.__version__ != DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {DEEPEVAL_VERSION}, found {deepeval.__version__}")
    if sys.argv[1:2] == ["traced"]:
        try:
            generate_traced(sys.argv[2:])
        finally:
            shutil.rmtree(WORK_DIR, ignore_errors=True)
        return
    if sys.argv[1:2] == ["scripted"]:
        try:
            generate_scripted(sys.argv[2:])
        finally:
            shutil.rmtree(WORK_DIR, ignore_errors=True)
        return
    if sys.argv[1:2] == ["prompts"]:
        try:
            generate_prompts(sys.argv[2:])
        finally:
            shutil.rmtree(WORK_DIR, ignore_errors=True)
        return
    if sys.argv[1:] == ["multimodal"]:
        write_content_parts()
        shutil.rmtree(WORK_DIR, ignore_errors=True)
        print(f"wrote {os.path.relpath(MULTIMODAL_DIR, ROOT)}")
        return
    if sys.argv[1:] == ["loop_detection"]:
        write_loop_detection_tables()
        shutil.rmtree(WORK_DIR, ignore_errors=True)
        print(f"wrote {os.path.relpath(LOOP_DETECTION_DIR, ROOT)}")
        return
    if sys.argv[1:]:
        sys.exit(f"usage: {os.path.basename(__file__)} "
                 "[traced [scenario ...] | scripted [scenario ...] | prompts [case ...] | "
                 "loop_detection | multimodal]")
    try:
        for name, scenario in SCENARIOS.items():
            run_scenario(name, scenario)
            print(f"wrote {os.path.relpath(os.path.join(FIXTURES, name), ROOT)}")
        run_round_trip_traced_dataset()
        print(f"wrote {os.path.relpath(os.path.join(ROUND_TRIP, 'traced_dataset'), ROOT)}")
        generate_scripted()
        write_loop_detection_tables()
        print(f"wrote {os.path.relpath(LOOP_DETECTION_DIR, ROOT)}")
        write_content_parts()
        print(f"wrote {os.path.relpath(MULTIMODAL_DIR, ROOT)}")
        generate_prompts()
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
