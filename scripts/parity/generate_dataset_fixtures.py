"""Generate the dataset fixtures DeepEvalEx's dataset loader tests compare against.

For every case in `CASES` below this script writes, under
test/fixtures/deepeval/datasets/<case>/:

- the case's source files: either written by deepeval's own
  `EvaluationDataset.save_as` (`saved.csv`, `saved.json`, `saved.jsonl`), or
  written verbatim from the case's `files` (files deepeval's `save_as` does
  not produce, such as other column names, pandas' missing-value markers,
  tool calls with trailing commas or JSONL lines of either shape)
- loads.json - one entry per deepeval loader call over those files: the
  `loader` (the `EvaluationDataset` method name), the `file`, its
  positional `args` and keyword `kwargs`, and what it produced: `goldens`
  or `test_cases` (see `dump_golden` and `dump_test_case`), or `raised`,
  the exception's Python `type` name and `message`

test/deep_eval_ex/dataset/loader_parity_test.exs makes the same calls with
DeepEvalEx.Dataset.EvaluationDataset and compares what it loads.

deepeval reads CSV files with pandas, which its Docker image does not
install; install it into the deepeval virtualenv first:

    devcontainer exec --workspace-folder . pip install pandas

Then run it inside the devcontainer, from the repository root:

    devcontainer exec --workspace-folder . \
      env DEEPEVAL_TELEMETRY_OPT_OUT=1 python3 -I scripts/parity/generate_dataset_fixtures.py

See test/fixtures/deepeval/README.md.
"""

import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATASETS = os.path.join(ROOT, "test", "fixtures", "deepeval", "datasets")

# Before deepeval is imported: no telemetry, no Confident AI.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"
os.environ["DEEPEVAL_LOCAL_STORE"] = "json"
os.environ.pop("CONFIDENT_API_KEY", None)

# deepeval may write under ./.deepeval; keep it out of the repository.
WORK_DIR = tempfile.mkdtemp(prefix="deepeval_datasets_")
os.chdir(WORK_DIR)

import deepeval  # noqa: E402
from deepeval.dataset import EvaluationDataset, Golden  # noqa: E402
from deepeval.dataset.expectations import Expectations  # noqa: E402
from deepeval.test_case import LLMTestCase, RetrievedContextData, ToolCall  # noqa: E402

try:
    import pandas  # noqa: E402,F401
except ModuleNotFoundError:
    sys.exit("deepeval's CSV loaders need pandas: pip install pandas")

DEEPEVAL_VERSION = "4.3.1"


def full_golden():
    """A golden setting every field deepeval's save_as writes."""
    return Golden(
        input="What is the refund window, in days?",
        actual_output="30 days, from delivery.",
        expected_output="30 days",
        context=["Refunds: 30 days from delivery.", "Exchanges: 60 days."],
        retrieval_context=[
            "Plain retrieved chunk",
            RetrievedContextData(source="policy.md#refunds",
                                 context="Refunds are accepted within 30 days."),
        ],
        name="refund-window",
        comments="Checked against the 2026 policy.",
        source_file="policy.md",
        tools_called=[
            ToolCall(name="search_policy", description="Searches the policy",
                     reasoning="Needs the refund rule",
                     input_parameters={"query": "refund window", "limit": 3},
                     output=["Refunds: 30 days"]),
        ],
        expected_tools=[ToolCall(name="search_policy", type="MCP")],
        additional_metadata={"locale": "en-GB", "priority": 2,
                             "tags": ["refunds", "policy"]},
        custom_column_key_values={"team": "support"},
        expectations=Expectations(must=["Cite the policy"],
                                  must_not=["Promise exceptions"],
                                  model="gpt-4o-mini", eval_mode="llm"),
    )


def csv_hostile_golden():
    """Commas, quotes, newlines and non-ASCII text in every cell kind."""
    return Golden(
        input='Say "hello", then\na new line',
        expected_output="Grüße, “quoted”; done",
        context=["one, with comma", 'two "quoted"'],
        retrieval_context=[RetrievedContextData(source="a,b", context="x|y")],
    )


def test_case_with_counts():
    """A test case: save_as(include_test_cases=True) writes its token cost and
    counts, which it drops from goldens."""
    return LLMTestCase(
        input="Summarise the order",
        actual_output="Two items, shipped.",
        expected_output="Two items",
        token_cost=0.25,
        input_token_count=120,
        output_token_count=8,
        metadata={"order_id": "A-1"},
        tools_called=[ToolCall(name="get_order", input_parameters={"id": "A-1"})],
    )


def saved_dataset():
    dataset = EvaluationDataset(goldens=[full_golden(), Golden(input="Minimal golden"),
                                         csv_hostile_golden()])
    dataset.add_test_case(test_case_with_counts())
    return dataset


GOLDEN_LOADS = [
    ("add_goldens_from_csv_file", "saved.csv", [], {}),
    ("add_goldens_from_json_file", "saved.json", [], {}),
    ("add_goldens_from_jsonl_file", "saved.jsonl", [], {}),
]

CASES = {
    # deepeval's save_as output, loaded back by each loader.
    "saved": {
        "save_as": saved_dataset,
        "loads": GOLDEN_LOADS + [
            ("add_test_cases_from_csv_file", "saved.csv", ["input", "actual_output"], {}),
            ("add_test_cases_from_json_file", "saved.json", ["input", "actual_output"], {}),
            # Every key named: the minimal golden's null tools_called is not a
            # list of tool calls.
            ("add_test_cases_from_json_file", "saved.json", ["input", "actual_output"], {
                "expected_output_key_name": "expected_output",
                "context_key_name": "context",
                "retrieval_context_key_name": "retrieval_context",
                "tools_called_key_name": "tools_called",
                "expected_tools_key_name": "expected_tools",
            }),
        ],
    },
    # pandas' missing-value markers, its number parsing, trailing commas in
    # tool call JSON, empty list cells and a short row.
    "csv_cells": {
        "files": {
            "goldens.csv": (
                "input,actual_output,expected_output,context,retrieval_context,"
                "tools_called,expected_tools,token_cost,input_token_count,"
                "output_token_count,additional_metadata,custom_column_key_values,"
                "comments,name,source_file,expectations\r\n"
                "First,  padded  ,NA,a|b|,\"deepeval_source=s.md,deepeval_context=c|plain\","
                "\"[{\"\"name\"\": \"\"search\"\", \"\"inputParameters\"\": {\"\"q\"\": \"\"x\"\"},}]\","
                "\"[{\"\"name\"\": \"\"lookup\"\", \"\"type\"\": \"\"MCP\"\", \"\"output\"\": 3}]\","
                "0.5,10,,\"{\"\"flag\"\": true, \"\"none\"\": null, \"\"n\"\": 1.5}\","
                "\"{\"\"team\"\": \"\"qa\"\"}\",null,N/A,src.txt,"
                "\"{\"\"must\"\": [\"\" Be brief \"\"], \"\"mustNot\"\": []}\"\r\n"
                "Second,,,,,,,2,7,3,,,None,second,,\r\n"
                "\r\n"
                "Third,out\r\n"
            ),
        },
        "loads": [
            ("add_goldens_from_csv_file", "goldens.csv", [], {}),
        ],
    },
    # Columns named otherwise, ';'-delimited context, columns left out.
    "csv_columns": {
        "files": {
            "data.csv": (
                "question,answer,ideal,ctx,meta\n"
                "What is 2 + 2?,Four,four,one;two,\"{\"\"k\"\": \"\"v\"\"}\"\n"
                "What is 3 + 3?,Six,,,\n"
            ),
        },
        "loads": [
            ("add_goldens_from_csv_file", "data.csv", [], {
                "input_col_name": "question",
                "actual_output_col_name": "answer",
                "expected_output_col_name": "ideal",
                "context_col_name": "ctx",
                "context_col_delimiter": ";",
                "additional_metadata_col_name": "meta",
            }),
            ("add_test_cases_from_csv_file", "data.csv", ["question", "answer"], {
                "expected_output_col_name": "ideal",
                "context_col_name": "ctx",
                "context_col_delimiter": ";",
                "additional_metadata_col_name": "meta",
            }),
        ],
    },
    # JSONL lines of either shape: lists or delimited strings, tool calls as
    # lists or JSON strings, blank lines and surrounding whitespace.
    "jsonl_lines": {
        "files": {
            "goldens.jsonl": (
                json.dumps({"input": "lists", "context": ["a", "b"],
                            "retrieval_context": ["deepeval_source=s,deepeval_context=c", "r"],
                            "tools_called": [{"name": "t", "input_parameters": {"x": 1}}],
                            "token_cost": 1, "input_token_count": 4}) + "\n"
                "\n"
                "   " + json.dumps({"input": "strings", "context": "a|b",
                                   "retrieval_context": "",
                                   "tools_called": "[{\"name\": \"t\",}]",
                                   "expected_tools": [],
                                   "expectations": {"must": ["x"]}}) + "  \n"
                + json.dumps({"input": "nulls", "context": None, "tools_called": None,
                              "output_token_count": 2.0}) + "\n"
            ),
            "custom.jsonl": json.dumps({"q": "custom", "ctx": "one;two"}) + "\n",
        },
        "loads": [
            ("add_goldens_from_jsonl_file", "goldens.jsonl", [], {}),
            ("add_goldens_from_jsonl_file", "custom.jsonl", [], {
                "input_key_name": "q", "context_key_name": "ctx",
                "context_col_delimiter": ";",
            }),
        ],
    },
    # add_test_cases_from_json_file with its own key names: it ignores the
    # metadata key, and defaults absent tool calls to [].
    "json_test_cases": {
        "files": {
            "cases.json": json.dumps([
                {"q": "Where is my parcel?", "a": "In transit.", "e": "In transit",
                 "ctx": ["Shipped Monday"],
                 "rc": ["deepeval_source=crm,deepeval_context=Order 7", "Tracking: in transit"],
                 "tools": [{"name": "track", "inputParameters": {"id": 7}}],
                 "meta": {"ignored": True}, "expectations": {"must_not": ["Guess"]}},
                {"q": "Hi", "a": "Hello"},
            ], indent=2, ensure_ascii=False),
        },
        "loads": [
            ("add_test_cases_from_json_file", "cases.json", ["q", "a"], {
                "expected_output_key_name": "e",
                "context_key_name": "ctx",
                "retrieval_context_key_name": "rc",
                "tools_called_key_name": "tools",
                "addtional_metadata_key_name": "meta",
            }),
            # A required key missing from an object.
            ("add_test_cases_from_json_file", "cases.json", ["q", "e"], {}),
        ],
    },
    # Malformed files.
    "invalid": {
        "files": {
            "bad.json": "[{\"input\": \"x\"",
            "bad.jsonl": json.dumps({"input": "ok"}) + "\n\n{not json}\n",
        },
        "loads": [
            ("add_goldens_from_json_file", "bad.json", [], {}),
            ("add_goldens_from_jsonl_file", "bad.jsonl", [], {}),
        ],
    },
}


def dump_tool_call(tool):
    return {
        "name": tool.name,
        "type": tool.type.value,
        "description": tool.description,
        "reasoning": tool.reasoning,
        "input_parameters": tool.input_parameters,
        "output": tool.output,
    }


def dump_tools(tools):
    return None if tools is None else [dump_tool_call(t) for t in tools]


def dump_retrieval_context(items):
    if items is None:
        return None
    return [
        {"source": i.source, "context": i.context} if isinstance(i, RetrievedContextData) else i
        for i in items
    ]


def dump_expectations(expectations):
    if expectations is None:
        return None
    return {"model": expectations.model, "eval_mode": expectations.eval_mode,
            "must": expectations.must, "must_not": expectations.must_not}


def dump_golden(golden):
    """Every field DeepEvalEx.Dataset.Golden has, by its field name."""
    return {
        "input": golden.input,
        "actual_output": golden.actual_output,
        "expected_output": golden.expected_output,
        "context": golden.context,
        "retrieval_context": dump_retrieval_context(golden.retrieval_context),
        "additional_metadata": golden.additional_metadata,
        "comments": golden.comments,
        "tools_called": dump_tools(golden.tools_called),
        "expected_tools": dump_tools(golden.expected_tools),
        "token_cost": golden.token_cost,
        "input_token_count": golden.input_token_count,
        "output_token_count": golden.output_token_count,
        "source_file": golden.source_file,
        "name": golden.name,
        "custom_column_key_values": golden.custom_column_key_values,
        "expectations": dump_expectations(golden.expectations),
        "expected_labels": golden.expected_labels,
    }


def dump_test_case(test_case):
    """The DeepEvalEx.TestCase fields a loader sets, and the dataset rank."""
    return {
        "input": test_case.input,
        "actual_output": test_case.actual_output,
        "expected_output": test_case.expected_output,
        "context": test_case.context,
        "retrieval_context": dump_retrieval_context(test_case.retrieval_context),
        "tools_called": dump_tools(test_case.tools_called),
        "expected_tools": dump_tools(test_case.expected_tools),
        "metadata": test_case.metadata,
        "expectations": dump_expectations(test_case.expectations),
        "dataset_rank": test_case._dataset_rank,
    }


def run_load(out_dir, loader, file, args, kwargs):
    dataset = EvaluationDataset()
    entry = {"loader": loader, "file": file, "args": args, "kwargs": kwargs}
    try:
        getattr(dataset, loader)(os.path.join(out_dir, file), *args, **kwargs)
    except Exception as e:  # noqa: BLE001 - recorded as the expected outcome
        message = str(e).replace(out_dir + os.sep, "")
        entry["raised"] = {"type": type(e).__name__, "message": message}
        return entry
    if "golden" in loader:
        entry["goldens"] = [dump_golden(g) for g in dataset.goldens]
    else:
        entry["test_cases"] = [dump_test_case(t) for t in dataset.test_cases]
    return entry


def run_case(name, case):
    out_dir = os.path.join(DATASETS, name)
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir)
    if "save_as" in case:
        dataset = case["save_as"]()
        for file_type in ("csv", "json", "jsonl"):
            dataset.save_as(file_type, out_dir, file_name="saved", include_test_cases=True)
    for file, content in case.get("files", {}).items():
        with open(os.path.join(out_dir, file), "w", encoding="utf-8", newline="") as f:
            f.write(content)
    loads = [run_load(out_dir, *load) for load in case["loads"]]
    with open(os.path.join(out_dir, "loads.json"), "w", encoding="utf-8") as f:
        json.dump(loads, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    if deepeval.__version__ != DEEPEVAL_VERSION:
        sys.exit(f"expected deepeval {DEEPEVAL_VERSION}, found {deepeval.__version__}")
    try:
        for name, case in CASES.items():
            run_case(name, case)
            print(f"wrote {os.path.relpath(os.path.join(DATASETS, name), ROOT)}")
    finally:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


if __name__ == "__main__":
    main()
