"""Generate the expected outputs for DeepEvalEx.Prompts.Python's number tests.

deepeval's System One reasons and verbose logs format numbers with
f-strings: `f"{weight:g}"`, `f"{p:.2f}"`, `f"{v:.3f}"`, and
`{k: round(v, 3) ...}` printed through `repr()`. This script records what
CPython produces so the Elixir helpers can be checked byte for byte.

Regenerate (from the repository root, inside the devcontainer) with:

    python3 test/fixtures/python_format/generate.py

Outputs, next to this script:

- format_g.json - [[bits, text]]: `bits` is the IEEE 754 binary64 bit
  pattern as an unsigned integer, `text` is `format(float, "g")`
- format_g_ints.json - [[int, text]]: `text` is `format(int, "g")`
- format_fixed.json - [[bits, decimals, text]]: `text` is
  `format(float, f".{decimals}f")`
- round.json - [[bits, ndigits, result_bits, repr]]: `result_bits` is the
  bit pattern of `round(float, ndigits)` and `repr` its `repr()`
- round_ints.json - [[int, ndigits, result]]: `result` is
  `round(int, ndigits)`, an int
"""

import json
import os
import random
import struct

HERE = os.path.dirname(os.path.abspath(__file__))


def bits(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def corpus(rng):
    values = [
        0.0, -0.0, 1.0, -1.0, 0.5, 2.0, 0.25, 1.5, 0.1, 0.2, 0.3,
        0.1 + 0.2, 1 / 3, 2 / 3, 0.125, 0.375, 2.675, 0.0005, 0.00015,
        0.0001, 0.00001, 0.000123456, 123456.0, 999999.0, 999999.5,
        1000000.0, 1234567.0, 9999995.0, 0.9999995, 0.99999949999,
        1e16, 1e-5, 5e-324, 2.2250738585072014e-308, 1.7976931348623157e308,
        2.0**53, 2.0**53 + 2, 100.0, 1e22, 1e100, 3.14159265, -273.15,
        0.19999999999999996, 0.6, 0.65, 0.35, 0.15, 0.85, 0.0625,
    ]
    for exp in range(-20, 25):
        values.append(10.0 ** exp)
        values.append(1.5 * 10.0 ** exp)
        values.append(-(10.0 ** exp))
        values.append(9.999995 * 10.0 ** exp)
        values.append(5.0 * 10.0 ** exp)
    for _ in range(600):
        value = struct.unpack("<d", struct.pack("<Q", rng.getrandbits(64)))[0]
        if value != value or value in (float("inf"), float("-inf")):
            continue
        values.append(value)
    for _ in range(600):
        values.append(round(rng.uniform(-1000, 1000), rng.randint(0, 12)))
    for _ in range(400):
        values.append(rng.random())
    # Exact decimal ties at 2 and 3 places (k / 2^n is exact in binary).
    for n in range(1, 9):
        for k in range(1, 2**n, 2):
            values.append(k / 2**n)
    return values


def main():
    rng = random.Random(20261022)
    values = corpus(rng)

    format_g = [[bits(v), format(v, "g")] for v in values]

    ints = [0, 1, -1, 2, 3, 10, 100, 123456, 999999, 1000000, 1234567,
            -9876543, 2**53, 2**53 + 1, 10**20]
    ints += [rng.randint(-10**9, 10**9) for _ in range(200)]
    format_g_ints = [[i, format(i, "g")] for i in ints]

    format_fixed = [
        [bits(v), d, format(v, f".{d}f")]
        for v in values
        if abs(v) < 1e30
        for d in (0, 2, 3)
    ]

    round_cases = []
    for v in values:
        for n in (0, 2, 3, -1):
            r = round(v, n)
            round_cases.append([bits(v), n, bits(r), repr(r)])
    for v in (1.5, -2.5, 123.456, 5e-324, 1.7976931348623157e308):
        for n in (400, 323, 322, -308, -309, -400):
            try:
                r = round(v, n)
            except OverflowError:
                continue
            round_cases.append([bits(v), n, bits(r), repr(r)])

    round_ints = [
        [i, n, round(i, n)]
        for i in ints + [5, 15, 25, -15, -25, 150, 250, 1250, 1350]
        for n in (0, 2, -1, -2, -3)
    ]

    outputs = {
        "format_g.json": format_g,
        "format_g_ints.json": format_g_ints,
        "format_fixed.json": format_fixed,
        "round.json": round_cases,
        "round_ints.json": round_ints,
    }
    for name, data in outputs.items():
        with open(os.path.join(HERE, name), "w", encoding="utf-8") as f:
            json.dump(data, f)
            f.write("\n")


if __name__ == "__main__":
    main()
