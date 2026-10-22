"""Generate the expected outputs for DeepEvalEx.TestRun.JSON's tests.

deepeval writes test runs with `json.dump(body, f, cls=TestRunEncoder)`,
i.e. Python's `json` defaults: ", " / ": " separators, `ensure_ascii=True`
and `repr()` floats. This script records what Python produces so the Elixir
encoder can be checked byte for byte.

Regenerate (from the repository root, inside the devcontainer) with:

    python3 test/fixtures/python_json/generate.py

Outputs, next to this script:

- cases.json  - [{"name", "input", "expected"}]: `input` is the value as JSON
  text (decode it keeping object key order), `expected` is
  `json.dumps(value)`
- floats.json - [[bits, repr]]: `bits` is the IEEE 754 binary64 bit pattern
  as an unsigned integer, `repr` is `json.dumps(float)`
"""

import json
import os
import random
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

CASES = {
    "null": None,
    "true": True,
    "false": False,
    "zero": 0,
    "negative_int": -42,
    "big_int": 2**70,
    "float_one": 1.0,
    "float_half": 0.5,
    "float_tenth_sum": 0.1 + 0.2,
    "negative_zero": -0.0,
    "empty_string": "",
    "empty_list": [],
    "empty_object": {},
    "ascii_string": "Hello, world! /path?a=1&b=2 <tag> ~",
    "quotes_and_backslash": 'say "hi" \\ there',
    "short_escapes": "\b\f\n\r\t",
    "control_chars": "".join(chr(c) for c in range(0x00, 0x20)),
    "delete_char": "a\x7fb",
    "latin1": "café naïve",
    "bmp": "✓ — “quoted” € 中文   ",
    "astral": "emoji 😀 and 𝄞",
    "lone_ascii_object_keys": {"z": 1, "a": 2, "m": 3},
    "unicode_keys": {"clé": "valeur", "✓": True},
    "nested": {
        "testCases": [
            {
                "name": "test_case_0",
                "input": "What is 1+1?",
                "metricsData": [
                    {"name": "M1", "threshold": 0.5, "success": True, "score": 1.0},
                    {"name": "M2", "threshold": 0.7, "success": False, "score": 0.25},
                ],
                "runDuration": 0.0,
                "order": 0,
                "metadata": {"k": [1, 2.0, None, True, {"x": []}]},
            }
        ],
        "conversationalTestCases": [],
        "metricsScores": [
            {"metric": "M1", "scores": [1.0, 0.9], "passes": 2, "fails": 0, "errors": 0}
        ],
        "prompts": [],
        "official": False,
    },
    "list_of_mixed": [1, -1.5, "two", None, False, [[]], {}],
    "float_values": [
        1e16, 1e15, 1e17, 123456789012345678.0, 1e-5, 1e-4, 0.0001234,
        2.5e-07, 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308,
        0.001, 0.003, 0.006, 3.14159, -273.15, 100.0, 1e22, 9007199254740993.0,
    ],
}


def float_corpus():
    rng = random.Random(20261022)
    values = []
    for exp in range(-20, 25):
        values.append(10.0 ** exp)
        values.append(1.5 * 10.0 ** exp)
        values.append(-(10.0 ** exp))
    for _ in range(1500):
        bits = rng.getrandbits(64)
        value = struct.unpack("<d", struct.pack("<Q", bits))[0]
        if value != value or value in (float("inf"), float("-inf")):
            continue
        values.append(value)
    for _ in range(1500):
        values.append(round(rng.uniform(-1000, 1000), rng.randint(0, 12)))
    for _ in range(500):
        values.append(rng.random())
    values += [0.0, -0.0, 5e-324, 1.7976931348623157e308, 2.0**53, 2.0**53 + 2]
    out = []
    for value in values:
        bits = struct.unpack("<Q", struct.pack("<d", value))[0]
        out.append([bits, json.dumps(value)])
    return out


def main():
    cases = [
        {
            "name": name,
            "input": json.dumps(value, ensure_ascii=False),
            "expected": json.dumps(value),
        }
        for name, value in CASES.items()
    ]
    with open(os.path.join(HERE, "cases.json"), "w", encoding="utf-8") as f:
        json.dump(cases, f, indent=1, ensure_ascii=False)
        f.write("\n")
    with open(os.path.join(HERE, "floats.json"), "w", encoding="utf-8") as f:
        json.dump(float_corpus(), f)
        f.write("\n")


if __name__ == "__main__":
    main()
