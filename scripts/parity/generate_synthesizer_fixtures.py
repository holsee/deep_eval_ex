"""Generate the synthesizer fixtures DeepEvalEx's synthesizer tests compare against.

Writes, under test/fixtures/deepeval/synthesizer/:

- templates.json - one entry per render of a synthesizer template: the
  deepeval `template` (`Class.method`), its keyword `args` and the `prompt`
  it rendered
- scenarios/<name>.json - one file per run of deepeval's `Synthesizer` with
  a scripted judge (see `ScriptedJudge`): the `method` called, the
  `synthesizer` configuration (styling, evolution and filtration configs,
  as their dataclass fields, evolutions by their enum value), the method's
  keyword `args`, the judge `script`, then what deepeval did with it: the
  `prompts` the judge was sent, in order, each with its step, and the
  `goldens` it returned (see `dump_golden`) with the synthesizer's
  `styling_config` afterwards, or what it `raised`

test/deep_eval_ex/synthesizer/templates_test.exs renders the same templates
with DeepEvalEx.Synthesizer.Templates and
test/deep_eval_ex/synthesizer/synthesizer_parity_test.exs replays the same
scripts through DeepEvalEx.Synthesizer, comparing prompts and goldens.

Every scenario picks its evolutions from a distribution with a single
evolution (or, for `generate_goldens_from_scratch`, a single one left once
Multi-context is dropped), and `generate_goldens_from_goldens` extracts the
styling from a single golden, so deepeval's `random.choices` and
`random.sample` pick the same in both.

Run it inside the devcontainer, from the repository root:

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_synthesizer_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "test", "fixtures", "deepeval", "synthesizer")

# Before deepeval is imported: no telemetry, no Confident AI.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"
os.environ["DEEPEVAL_LOCAL_STORE"] = "json"
os.environ.pop("CONFIDENT_API_KEY", None)

# deepeval may write under ./.deepeval; keep it out of the repository.
WORK_DIR = tempfile.mkdtemp(prefix="deepeval_synthesizer_")
os.chdir(WORK_DIR)

import deepeval  # noqa: E402
from deepeval.dataset import Golden  # noqa: E402
from deepeval.models import DeepEvalBaseLLM  # noqa: E402
from deepeval.synthesizer import Synthesizer  # noqa: E402
from deepeval.synthesizer.config import (  # noqa: E402
    EvolutionConfig,
    FiltrationConfig,
    StylingConfig,
)
from deepeval.synthesizer.templates import (  # noqa: E402
    EvolutionTemplate,
    ExtractionTemplate,
    FilterTemplate,
    PromptEvolutionTemplate,
    PromptSynthesizerTemplate,
    SynthesizerTemplate,
)
from deepeval.synthesizer.types import Evolution  # noqa: E402

DEEPEVAL_VERSION = "4.3.1"
MODEL = "scripted-judge"


class ScriptedJudge(DeepEvalBaseLLM):
    """A custom judge replaying canned responses, as generate_fixtures.py's.

    `responses` maps a step, the sorted field names of the schema deepeval
    asks for joined with commas ("text" for a call without one), to the
    responses of its successive calls. The synthesizer asks a custom judge
    for its free-text answers with the `Response` schema, step "response".
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


# ---------------------------------------------------------------------------
# Templates

CONTEXT = [
    "The Eiffel Tower was completed in 1889 for the World's Fair.",
    'It is 330 metres tall and nicknamed "La dame de fer" — the iron lady.',
]

STYLING = {
    "scenario": "Tourists planning a trip to Paris",
    "task": "Travel assistant answering landmark questions",
    "input_format": "A short question in English",
}

TEMPLATE_CASES = [
    ("SynthesizerTemplate.generate_synthetic_expected_output",
     {"input": "How tall is it?", "context": "\n".join(CONTEXT),
      "expected_output_format": None}),
    ("SynthesizerTemplate.generate_synthetic_expected_output",
     {"input": "How tall is it?", "context": "\n".join(CONTEXT),
      "expected_output_format": "One sentence, in metres"}),
    ("SynthesizerTemplate.generate_synthetic_inputs",
     {"context": CONTEXT, "max_goldens_per_context": 2, "scenario": None,
      "task": None, "input_format": None}),
    ("SynthesizerTemplate.generate_synthetic_inputs",
     {"context": CONTEXT, "max_goldens_per_context": 3, **STYLING}),
    ("SynthesizerTemplate.generate_synthetic_inputs",
     {"context": ["[SOURCE: a.md] Alpha.", "[SOURCE: b.md] Beta's."],
      "max_goldens_per_context": 1, "scenario": None, "task": None,
      "input_format": None, "available_source_files": ["a.md", "b.md", "c.md"],
      "target_files_per_context": None}),
    ("SynthesizerTemplate.generate_synthetic_inputs",
     {"context": ["[SOURCE: a.md] Alpha.", "[SOURCE: b.md] Beta."],
      "max_goldens_per_context": 2, **STYLING,
      "available_source_files": ["a.md", "b.md"], "target_files_per_context": 2}),
    ("SynthesizerTemplate.generate_synthetic_inputs",
     {"context": CONTEXT, "max_goldens_per_context": 2, "scenario": None,
      "task": None, "input_format": None, "available_source_files": ["only.md"],
      "target_files_per_context": 1}),
    ("SynthesizerTemplate.rewrite_evolved_input",
     {"evolved_input": "Why is it called the iron lady?"}),
    ("SynthesizerTemplate.rewrite_evolved_input",
     {"evolved_input": "Why is it called the iron lady?", **STYLING}),
    ("SynthesizerTemplate.rewrite_evolved_input",
     {"evolved_input": "Why?", "scenario": None, "task": STYLING["task"],
      "input_format": None}),
    ("SynthesizerTemplate.rewrite_synthetic_inputs",
     {"context": CONTEXT, "original_query": "When was it built?",
      "feedback": "Say which tower."}),
    ("FilterTemplate.evaluate_synthetic_inputs",
     {"query": "When was the Eiffel Tower completed?"}),
    ("PromptSynthesizerTemplate.generate_synthetic_prompts",
     {**STYLING, "num_goldens": 4}),
    ("ExtractionTemplate.extract_prompt_structure_from_inputs",
     {"inputs": ["How tall is the Eiffel Tower?", "What's open on Sundays?"]}),
] + [
    (f"EvolutionTemplate.{name}", {"input": "How tall is it?", "context": CONTEXT})
    for name in [
        "multi_context_evolution",
        "reasoning_evolution",
        "concretizing_evolution",
        "constrained_evolution",
        "comparative_question_evolution",
        "hypothetical_scenario_evolution",
        "in_breadth_evolution",
    ]
] + [
    (f"PromptEvolutionTemplate.{name}", {"input": "How tall is it?"})
    for name in [
        "reasoning_evolution",
        "concretizing_evolution",
        "constrained_evolution",
        "comparative_question_evolution",
        "hypothetical_scenario_evolution",
        "in_breadth_evolution",
    ]
]

TEMPLATE_CLASSES = {
    "SynthesizerTemplate": SynthesizerTemplate,
    "FilterTemplate": FilterTemplate,
    "EvolutionTemplate": EvolutionTemplate,
    "PromptEvolutionTemplate": PromptEvolutionTemplate,
    "PromptSynthesizerTemplate": PromptSynthesizerTemplate,
    "ExtractionTemplate": ExtractionTemplate,
}


def render_templates():
    entries = []
    for template, args in TEMPLATE_CASES:
        class_name, method = template.split(".")
        prompt = getattr(TEMPLATE_CLASSES[class_name], method)(**args)
        entries.append({"template": template, "args": args, "prompt": prompt})
    return entries


# ---------------------------------------------------------------------------
# Scenarios


def feedback(score, text="Clear."):
    return {"feedback": text, "score": score}


def data(*inputs):
    return {"data": [i if isinstance(i, dict) else {"input": i} for i in inputs]}


def response(text):
    return {"response": text}


def evolution_scenario(evolution):
    """One context, one input, one evolution of the given type."""
    return {
        "method": "generate_goldens_from_contexts",
        "evolutions": {evolution: 1},
        "args": {"contexts": [CONTEXT], "max_goldens_per_context": 1},
        "script": {
            "data": [data("How tall is the Eiffel Tower?")],
            "feedback,score": [feedback(0.9)],
            "response": [response(f"{evolution.value} evolved input?"),
                         response("330 metres.")],
        },
    }


def prompt_evolution_scenario(evolution):
    """From scratch: one input, one evolution of the given type."""
    return {
        "method": "generate_goldens_from_scratch",
        "styling": STYLING,
        "evolutions": {evolution: 1},
        "args": {"num_goldens": 1},
        "script": {
            "data": [data("Is the Louvre open on Mondays?")],
            "response": [response(f"{evolution.value} evolved prompt?")],
        },
    }


SCENARIOS = {
    # Two contexts, two inputs each (the judge offers three for the first,
    # one too many), filtration that passes, rewrites once, and rewrites
    # until the retries run out; no styling.
    "contexts_filtration": {
        "method": "generate_goldens_from_contexts",
        "evolutions": {Evolution.REASONING: 1},
        "filtration": {"synthetic_input_quality_threshold": 0.7, "max_quality_retries": 2},
        "args": {
            "contexts": [CONTEXT, ["Paris has 20 arrondissements.", "The Louvre is in the 1st."]],
            "max_goldens_per_context": 2,
        },
        "script": {
            "data": [
                data("How tall is it?", "Tell me about the tower", "Dropped input"),
                data("Where is the Louvre?", "How many arrondissements?"),
            ],
            "feedback,score": [
                feedback(0.9),
                feedback(0.2, "Which tower?"),
                feedback(1),
                feedback(0.5, "Too vague."),
                feedback(0.6, "Still vague."),
                feedback(0.75),
            ],
            "rewritten_input": [
                {"rewritten_input": "Tell me about the Eiffel Tower"},
                {"rewritten_input": "Which arrondissement holds the Louvre?"},
                {"rewritten_input": "In which arrondissement is the Louvre?"},
            ],
            "response": [
                response("Why is the Eiffel Tower 330 metres tall?"),
                response("It is 330 metres tall."),
                response("What led to the Eiffel Tower's 1889 completion?"),
                response("It was built for the 1889 World's Fair."),
                response("How does the Louvre's arrondissement relate to Paris's 20?"),
                response("The 1st."),
                response("Given 20 arrondissements, where is the Louvre?"),
                response("In the 1st arrondissement."),
            ],
        },
    },
    # Every styling field, two evolutions in a row, source files as a string
    # and as None, no expected output.
    "contexts_styled": {
        "method": "generate_goldens_from_contexts",
        "styling": {**STYLING, "expected_output_format": "One sentence"},
        "evolutions": {Evolution.MULTICONTEXT: 1},
        "num_evolutions": 2,
        "args": {
            "contexts": [CONTEXT, ["Le Louvre est ouvert de 9h à 18h."]],
            "max_goldens_per_context": 1,
            "source_files": ["eiffel.md", None],
        },
        "script": {
            "data": [data("How tall is it?"), data("When does the Louvre open?")],
            "feedback,score": [feedback(0.8), feedback(0.95)],
            "response": [
                response("First evolution?"),
                response("Second evolution?"),
                response("The tower is 330 metres tall."),
                response("Louvre, first?"),
                response("Louvre, second?"),
                response("At 9am."),
            ],
            "input,used_source_files": [
                {"input": "How tall is the Eiffel Tower, in metres?"},
                {"input": "What time does the Louvre open?", "used_source_files": None},
            ],
        },
    },
    # A context spanning two files: chunks labelled with their source, the
    # available source files in the prompt, the files the judge says it
    # used; no filtration retries and no expected output.
    "contexts_cross_file": {
        "method": "generate_goldens_from_contexts",
        "evolutions": {Evolution.CONCRETIZING: 1},
        "filtration": {"max_quality_retries": 0},
        "args": {
            "contexts": [["Alpha opens at 9.", "Beta closes at 5."]],
            "max_goldens_per_context": 2,
            "include_expected_output": False,
            "source_files": [["alpha.md", "beta.md"]],
            "context_chunk_source_files": [["alpha.md", "beta.md"]],
            "target_files_per_context": 2,
        },
        "script": {
            "data": [data(
                {"input": "How long are Alpha and Beta both open?",
                 "used_source_files": ["alpha.md", "beta.md"]},
                {"input": "When does Alpha open?"},
            )],
            "response": [response("Alpha and Beta hours?"), response("Alpha at 9?")],
        },
    },
    # From scratch: Multi-context is dropped from the distribution, so every
    # evolution is Reasoning; two evolutions per input.
    "scratch": {
        "method": "generate_goldens_from_scratch",
        "styling": STYLING,
        "evolutions": {Evolution.MULTICONTEXT: 1, Evolution.REASONING: 1},
        "num_evolutions": 2,
        "args": {"num_goldens": 2},
        "script": {
            "data": [data("Is the Louvre open on Mondays?", "Best time to see the tower?",
                          "A third the judge adds")],
            "response": [response(f"Evolution {i}") for i in range(1, 7)],
        },
    },
    "scratch_without_styling": {
        "method": "generate_goldens_from_scratch",
        "styling": {"scenario": "Tourists", "task": "Travel assistant"},
        "args": {"num_goldens": 1},
        "script": {},
    },
    # From a golden without context: the styling is extracted from its
    # input, then goldens are generated from scratch.
    "goldens_extracted": {
        "method": "generate_goldens_from_goldens",
        "evolutions": {Evolution.HYPOTHETICAL: 1},
        "args": {"goldens": [{"input": "How tall is the Eiffel Tower?"}],
                 "max_goldens_per_golden": 2},
        "script": {
            "input_format,scenario,task": [{
                "scenario": "Tourists asking about Paris landmarks.",
                "task": "Answering landmark questions.",
                "input_format": "Short questions in English.",
            }],
            "data": [data("Is the Louvre big?", "When is Notre-Dame open?")],
            "response": [response("Hypothetical one?"), response("Hypothetical two?")],
        },
    },
    # From goldens with context, styling set: no extraction; the goldens'
    # contexts and source files feed generate_goldens_from_contexts and the
    # golden without context is skipped.
    "goldens_with_contexts": {
        "method": "generate_goldens_from_goldens",
        "styling": STYLING,
        "evolutions": {Evolution.IN_BREADTH: 1},
        "args": {
            "goldens": [
                {"input": "How tall is it?", "context": CONTEXT, "source_file": "eiffel.md"},
                {"input": "No context here"},
                {"input": "Louvre hours?", "context": ["The Louvre opens at 9."]},
            ],
            "max_goldens_per_golden": 1,
            "include_expected_output": True,
        },
        "script": {
            "data": [data("Eiffel height?"), data("Louvre opening?")],
            "feedback,score": [feedback(1.0), feedback(0.9)],
            "response": [
                response("Rare Eiffel question?"),
                response("330 m."),
                response("Rare Louvre question?"),
                response("9am."),
            ],
            "input,used_source_files": [
                {"input": "How tall is the Eiffel Tower?"},
                {"input": "When does the Louvre open?"},
            ],
        },
    },
}

for _evolution in Evolution:
    SCENARIOS[f"evolution_{_evolution.name.lower()}"] = evolution_scenario(_evolution)
    if _evolution != Evolution.MULTICONTEXT:
        SCENARIOS[f"prompt_evolution_{_evolution.name.lower()}"] = prompt_evolution_scenario(
            _evolution)


def dump_golden(golden):
    """The fields a synthesizer sets."""
    return {
        "input": golden.input,
        "expected_output": golden.expected_output,
        "context": golden.context,
        "source_file": golden.source_file,
        "additional_metadata": golden.additional_metadata,
    }


def dump_styling(styling):
    return {
        "scenario": styling.scenario,
        "task": styling.task,
        "input_format": styling.input_format,
        "expected_output_format": styling.expected_output_format,
    }


def run_scenario(name, case):
    judge = ScriptedJudge(case["script"])
    filtration = case.get("filtration", {})
    synthesizer = Synthesizer(
        model=judge,
        filtration_config=FiltrationConfig(critic_model=judge, **filtration),
        evolution_config=EvolutionConfig(
            num_evolutions=case.get("num_evolutions", 1),
            evolutions=case.get("evolutions", {Evolution.REASONING: 1}),
        ),
        styling_config=StylingConfig(**case["styling"]) if "styling" in case else None,
    )
    args = dict(case["args"])
    if "goldens" in args:
        args["goldens"] = [Golden(**g) for g in args["goldens"]]

    entry = {
        "method": case["method"],
        "synthesizer": {
            "styling_config": dump_styling_args(case["styling"]) if "styling" in case else None,
            "evolution_config": {
                "num_evolutions": synthesizer.evolution_config.num_evolutions,
                "evolutions": {e.value: w for e, w in synthesizer.evolution_config.evolutions.items()},
            },
            "filtration_config": {
                "synthetic_input_quality_threshold":
                    synthesizer.filtration_config.synthetic_input_quality_threshold,
                "max_quality_retries": synthesizer.filtration_config.max_quality_retries,
            },
        },
        "args": case["args"],
        "script": case["script"],
    }
    try:
        goldens = getattr(synthesizer, case["method"])(**args)
    except Exception as e:  # noqa: BLE001 - recorded as the expected outcome
        entry["prompts"] = judge.prompts
        entry["raised"] = {"type": type(e).__name__, "message": str(e)}
        return entry
    judge.assert_exhausted()
    entry["prompts"] = judge.prompts
    entry["goldens"] = [dump_golden(g) for g in goldens]
    entry["styling_config"] = dump_styling(synthesizer.styling_config)
    return entry


def dump_styling_args(styling):
    return dump_styling(StylingConfig(**styling))


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
