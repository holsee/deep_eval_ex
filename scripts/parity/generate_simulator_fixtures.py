"""Generate the simulator fixtures DeepEvalEx's conversation simulator tests compare against.

Writes, under test/fixtures/deepeval/simulator/:

- templates.json - one entry per render of a simulator template: the
  deepeval `template` (`Class.method`), its keyword `args` (a golden as its
  constructor fields, turns as dicts) and the `prompt` it rendered
- scenarios/<name>.json - one file per run of deepeval's
  `ConversationSimulator` with a scripted judge (see `ScriptedJudge`) and a
  scripted chatbot (see `ScriptedChatbot`): the `simulator` options
  (`language`, `max_concurrent`, the `simulation_graph` as a spec, see
  `build_node`, and the `stopping_controller`, see `build_controller`), the
  `goldens`, `max_user_simulations`, the judge `script` and the chatbot's
  `replies`, then what deepeval did with them: the `prompts` the judge was
  sent, in order, each with its step, the `callback_calls` (each reply's
  input and how many turns the chatbot was given), the `on_turn` calls (the
  conversation's index and length), the `completed` indexes, and the
  `test_cases` it returned (see `dump_test_case`), or what it `raised`

test/deep_eval_ex/simulator/templates_test.exs renders the same templates
with DeepEvalEx.Simulator's template modules and
test/deep_eval_ex/simulator/conversation_simulator_parity_test.exs replays
the same scripts through DeepEvalEx.ConversationSimulator, comparing
prompts, calls and test cases.

Scenarios with several goldens run with `max_concurrent=1`, so deepeval
simulates them one after the other and the scripts are consumed in the same
order by both.

Run it inside the devcontainer, from the repository root:

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_simulator_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "test", "fixtures", "deepeval", "simulator")

# Before deepeval is imported: no telemetry, no Confident AI.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"
os.environ["DEEPEVAL_LOCAL_STORE"] = "json"
os.environ.pop("CONFIDENT_API_KEY", None)

# deepeval may write under ./.deepeval; keep it out of the repository.
WORK_DIR = tempfile.mkdtemp(prefix="deepeval_simulator_")
os.chdir(WORK_DIR)

import deepeval  # noqa: E402
from deepeval.dataset import ConversationalGolden  # noqa: E402
from deepeval.models import DeepEvalBaseLLM  # noqa: E402
from deepeval.simulator import (  # noqa: E402
    ConversationSimulator,
    SimulationNode,
    SimulationTemplate,
    default_simulation_node,
)
from deepeval.simulator.controller import end, proceed  # noqa: E402
from deepeval.simulator.controller.template import (  # noqa: E402
    SimulatorControllerTemplate,
)
from deepeval.simulator.simulation_graph.template import (  # noqa: E402
    SimulationGraphTemplate,
)
from deepeval.test_case import Turn  # noqa: E402

DEEPEVAL_VERSION = "4.3.1"
MODEL = "scripted-judge"


class ScriptedJudge(DeepEvalBaseLLM):
    """A custom judge replaying canned responses, as generate_fixtures.py's.

    `responses` maps a step, the sorted field names of the schema deepeval
    asks for joined with commas, to the responses of its successive calls.
    """

    def __init__(self, responses):
        self.responses = responses
        self.calls = {}
        self.prompts = []
        super().__init__(MODEL)

    def load_model(self):
        return self

    def get_model_name(self):
        return MODEL

    def generate(self, prompt, schema=None):
        step = "text" if schema is None else ",".join(sorted(schema.model_fields))
        index = self.calls.get(step, 0)
        self.calls[step] = index + 1
        self.prompts.append({"step": step, "prompt": prompt})
        try:
            response = self.responses[step][index]
        except (KeyError, IndexError):
            raise RuntimeError(f"script has no response {index} for step {step!r}") from None
        if schema is None or isinstance(response, str):
            return response
        return schema.model_validate(response)

    async def a_generate(self, prompt, schema=None):
        return self.generate(prompt, schema)

    def assert_exhausted(self):
        for step, responses in self.responses.items():
            used = self.calls.get(step, 0)
            if used != len(responses):
                raise RuntimeError(f"step {step!r} used {used} of {len(responses)} responses")


class ScriptedChatbot:
    """The chatbot under test: replies in order, recording what it was given."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, input, turns, thread_id):
        assert isinstance(thread_id, str) and thread_id
        if len(self.calls) >= len(self.replies):
            raise RuntimeError(f"no reply {len(self.calls)}")
        reply = self.replies[len(self.calls)]
        self.calls.append({"input": input, "turns": len(turns)})
        return Turn(role="assistant", content=reply)


# ---------------------------------------------------------------------------
# Templates

PERSONA = {
    "name": "Ann",
    "characteristics": "A busy parent.\n\nShort on patience, types in lowercase.",
    "metadata": {"orders": [1, 2], "plan": "premium"},
}

GOLDEN = {
    "scenario": "A customer wants a refund for a late order.",
    "expected_outcome": "The refund is issued.",
    "persona": PERSONA,
}

TURNS = [
    {"role": "user", "content": "my order is late"},
    {"role": "assistant", "content": "Sorry! Could you share the order number?",
     "metadata": {"intent": "ask_order"}},
]

TEMPLATE_CASES = [
    ("SimulationTemplate.simulate_first_user_turn",
     {"golden": GOLDEN, "language": "English"}),
    ("SimulationTemplate.simulate_first_user_turn",
     {"golden": {"scenario": "Un client veut annuler son abonnement."}, "language": "French"}),
    ("SimulationTemplate.simulate_first_user_turn",
     {"golden": {"scenario": "Line one\nline two, unindented",
                 "persona": {"characteristics": "  Terse.  "}},
      "language": "English"}),
    ("SimulationTemplate.simulate_user_turn",
     {"golden": GOLDEN, "turns": TURNS, "language": "English"}),
    ("SimulationTemplate.simulate_user_turn",
     {"golden": {"scenario": "Café opening hours — “quoted”"}, "turns": TURNS[:1],
      "language": "English"}),
    ("SimulationTemplate.simulate_user_turn",
     {"golden": {"scenario": "No turns yet"}, "turns": [], "language": "Spanish"}),
    ("SimulatorControllerTemplate.check_expected_outcome",
     {"previous_conversation": "[]", "expected_outcome": "The refund is issued."}),
    ("SimulatorControllerTemplate.check_expected_outcome",
     {"previous_conversation": json.dumps(TURNS, indent=4),
      "expected_outcome": "Line one\nline two"}),
    ("SimulationGraphTemplate.classify_edge",
     {"assistant_reply": "Sure, I can refund that.", "choices": ["The assistant offered a refund"]}),
    ("SimulationGraphTemplate.classify_edge",
     {"assistant_reply": "Two lines:\nsecond line",
      "choices": ["Offered a refund", "Asked for the order number", "Escalated"]}),
]

TEMPLATE_CLASSES = {
    "SimulationTemplate": SimulationTemplate,
    "SimulatorControllerTemplate": SimulatorControllerTemplate,
    "SimulationGraphTemplate": SimulationGraphTemplate,
}


def build_args(args):
    built = dict(args)
    if "golden" in built:
        built["golden"] = ConversationalGolden(**built["golden"])
    if "turns" in built:
        built["turns"] = [Turn(**turn) for turn in built["turns"]]
    return built


def render_templates():
    entries = []
    for template, args in TEMPLATE_CASES:
        class_name, method = template.split(".")
        prompt = getattr(TEMPLATE_CLASSES[class_name], method)(**build_args(args))
        entries.append({"template": template, "args": args, "prompt": prompt})
    return entries


# ---------------------------------------------------------------------------
# Scenarios


def build_node(spec):
    """A SimulationNode from its spec.

    `{"default": true}` is `default_simulation_node()`; `{"text": s}` a node
    whose action always says `s`. Both take `terminal`, `max_visits` and
    `name`, and `edges`, a list of `{"when": ..., "node": spec}`.
    """
    options = {key: spec[key] for key in ("terminal", "max_visits", "name") if key in spec}
    if spec.get("default"):
        node = default_simulation_node(**options)
    else:
        text = spec["text"]
        node = SimulationNode(lambda: text, **options)
    for edge in spec.get("edges", []):
        node.add_node(build_node(edge["node"]), when=edge["when"])
    return node


def build_controller(spec):
    """`{"end_after": n, "reason": r}`: ends once n user turns were simulated."""

    def controller(simulated_user_turns, last_assistant_turn):
        assert last_assistant_turn is None or last_assistant_turn.role == "assistant"
        if simulated_user_turns >= spec["end_after"]:
            return end(spec.get("reason"))
        return proceed()

    return controller


def reply(*texts):
    return [{"simulated_input": text} for text in texts]


def complete(*flags):
    return [{"is_complete": flag, "reason": "Done." if flag else "Not yet."} for flag in flags]


def edge(index):
    return {"index": index, "reason": "Matched." if index else "None matched."}


SCENARIOS = {
    # The opening turn without a completion check, a check that says to go
    # on, then one that says the outcome was reached.
    "outcome_reached": {
        "goldens": [GOLDEN],
        "max_user_simulations": 5,
        "script": {
            "simulated_input": reply("my order is late", "it's 1234, where's my refund?"),
            "is_complete,reason": complete(False, True),
        },
        "replies": ["Sorry! What is the order number?", "Refunded — you'll see it in 3 days."],
    },
    # No expected outcome: no completion check, the cap ends it.
    "max_user_simulations": {
        "goldens": [{"scenario": "Small talk about the weather.",
                     "persona": {"characteristics": "Chatty."}}],
        "max_user_simulations": 2,
        "script": {"simulated_input": reply("Lovely day, isn't it?", "Will it rain later?")},
        "replies": ["It is!", "Maybe this evening."],
    },
    # Seeded turns ending with a user turn: answered first, not simulated
    # nor counted; metadata, context, name and comments carried over.
    "seeded_user_last": {
        "goldens": [{
            "scenario": "Checking a delivery date.",
            "expected_outcome": "The date is given.",
            "user_description": "A shopper.",
            "context": ["Deliveries take 3 days."],
            "name": "delivery",
            "comments": "seeded",
            "additional_metadata": {"source": "support"},
            "turns": [{"role": "user", "content": "When will it arrive?"}],
        }],
        "max_user_simulations": 1,
        "script": {
            "is_complete,reason": complete(False, False),
            "simulated_input": reply("Can you be more precise?"),
        },
        "replies": ["In about 3 days.", "Thursday."],
    },
    # Seeded turns ending with the assistant: the next user turn is
    # simulated from them.
    "seeded_assistant_last": {
        "goldens": [{
            "scenario": "Changing a password.",
            "turns": [
                {"role": "user", "content": "I need a new password"},
                {"role": "assistant", "content": "Sure, which account?"},
            ],
        }],
        "max_user_simulations": 1,
        "simulator": {"language": "German"},
        "script": {"simulated_input": reply("Mein Mail-Konto.")},
        "replies": ["Ich habe einen Link gesendet."],
    },
    # A custom stopping controller ending after two simulated user turns.
    "custom_controller": {
        "goldens": [GOLDEN],
        "max_user_simulations": 5,
        "simulator": {"stopping_controller": {"end_after": 2, "reason": "Enough."}},
        "script": {"simulated_input": reply("hi", "still there?")},
        "replies": ["Hello!", "Yes."],
    },
    # Two goldens, one after the other.
    "multiple_goldens": {
        "goldens": [
            {"scenario": "Booking a table.", "expected_outcome": "A table is booked."},
            {"scenario": "Cancelling a booking."},
        ],
        "max_user_simulations": 2,
        "simulator": {"max_concurrent": 1},
        "script": {
            "simulated_input": reply("A table for two?", "At 8pm.", "Cancel my booking.",
                                     "Booking 42."),
            "is_complete,reason": complete(False),
        },
        "replies": ["For when?", "Booked!", "Which booking?", "Cancelled."],
    },
    # A graph: the default node routes on the reply. Edge 2 is followed to a
    # fixed-text node with no edges, which stays put until its max_visits
    # runs out and ends the conversation without another turn.
    "graph_max_visits": {
        "goldens": [{"scenario": "Asking for a refund."}],
        "max_user_simulations": 10,
        "simulator": {"simulation_graph": {
            "default": True,
            "edges": [
                {"when": "The assistant offered a refund", "node": {"text": "Yes please."}},
                {"when": "The assistant asked for an order number",
                 "node": {"text": "It's 1234.", "max_visits": 2, "name": "order"}},
            ],
        }},
        "script": {
            "simulated_input": reply("I want a refund"),
            "index,reason": [edge(2)],
        },
        "replies": ["What is the order number?", "Hmm, which order?", "Still checking."],
    },
    # Edge choices out of range and null stay on the node; a terminal node
    # ends the conversation after the assistant's reply.
    "graph_terminal": {
        "goldens": [{"scenario": "Asking for a refund.", "expected_outcome": "Refunded."}],
        "max_user_simulations": 10,
        "simulator": {"simulation_graph": {
            "default": True,
            "edges": [
                {"when": "The assistant refunded the order",
                 "node": {"text": "Thanks, bye!", "terminal": True}},
            ],
        }},
        "script": {
            "simulated_input": reply("refund please", "hello?", "so?"),
            "index,reason": [edge(None), edge(7), edge(1)],
            "is_complete,reason": complete(False, False, False),
        },
        "replies": ["Let me check.\nOne moment.", "Still checking.", "Refunded!", "Bye!"],
    },
    # A root with max_visits exhausted after one turn: the second entry
    # emits nothing.
    "graph_root_max_visits": {
        "goldens": [{"scenario": "One question only."}],
        "max_user_simulations": 3,
        "simulator": {"simulation_graph": {"default": True, "max_visits": 1}},
        "script": {"simulated_input": reply("Just one question.")},
        "replies": ["Sure."],
    },
    "max_user_simulations_zero": {
        "goldens": [{"scenario": "Never simulated."}],
        "max_user_simulations": 0,
        "script": {},
        "replies": [],
    },
}


def dump_test_case(test_case):
    """The fields the simulator sets."""
    return {
        "turns": [turn.model_dump_for_prompt() for turn in test_case.turns],
        "scenario": test_case.scenario,
        "expected_outcome": test_case.expected_outcome,
        "user_description": test_case.user_description,
        "context": test_case.context,
        "name": test_case.name,
        "comments": test_case.comments,
        "additional_metadata": test_case.metadata,
    }


def run_scenario(name, case):
    judge = ScriptedJudge(case["script"])
    chatbot = ScriptedChatbot(case["replies"])
    options = dict(case.get("simulator", {}))
    kwargs = {"model_callback": chatbot, "simulator_model": judge}
    if "language" in options:
        kwargs["language"] = options["language"]
    if "max_concurrent" in options:
        kwargs["max_concurrent"] = options["max_concurrent"]
    if "simulation_graph" in options:
        kwargs["simulation_graph"] = build_node(options["simulation_graph"])
    if "stopping_controller" in options:
        kwargs["stopping_controller"] = build_controller(options["stopping_controller"])
    simulator = ConversationSimulator(**kwargs)

    on_turn = []
    completed = []
    entry = {
        "simulator": options,
        "goldens": case["goldens"],
        "max_user_simulations": case["max_user_simulations"],
        "script": case["script"],
        "replies": case["replies"],
    }
    try:
        test_cases = simulator.simulate(
            [ConversationalGolden(**g) for g in case["goldens"]],
            max_user_simulations=case["max_user_simulations"],
            on_turn=lambda turns, index: on_turn.append({"index": index, "turns": len(turns)}),
            on_simulation_complete=lambda test_case, index: completed.append(index),
        )
    except Exception as e:  # noqa: BLE001 - recorded as the expected outcome
        entry["prompts"] = judge.prompts
        entry["raised"] = {"type": type(e).__name__, "message": str(e)}
        return entry
    judge.assert_exhausted()
    if len(chatbot.calls) != len(chatbot.replies):
        raise RuntimeError(f"{name}: used {len(chatbot.calls)} of {len(chatbot.replies)} replies")
    if simulator.simulation_cost is not None:
        raise RuntimeError(f"{name}: a custom model has no simulation cost")
    entry["prompts"] = judge.prompts
    entry["callback_calls"] = chatbot.calls
    entry["on_turn"] = on_turn
    entry["completed"] = completed
    entry["test_cases"] = [dump_test_case(t) for t in test_cases]
    return entry


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    if deepeval.__version__ != DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {DEEPEVAL_VERSION}, found {deepeval.__version__}")
    try:
        shutil.rmtree(OUT, ignore_errors=True)
        os.makedirs(os.path.join(OUT, "scenarios"))
        write_json(os.path.join(OUT, "templates.json"), render_templates())
        print(f"wrote {os.path.relpath(os.path.join(OUT, 'templates.json'), ROOT)}")
        for name, case in SCENARIOS.items():
            path = os.path.join(OUT, "scenarios", f"{name}.json")
            write_json(path, run_scenario(name, case))
            print(f"wrote {os.path.relpath(path, ROOT)}")
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
