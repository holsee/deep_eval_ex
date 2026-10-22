defmodule DeepEvalEx.Prompts.PythonTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Schemas.ToolCall

  doctest Python

  # Expected outputs were produced by CPython 3.11 (see
  # test/fixtures/python_format/generate.py).
  @fixtures Path.expand("../../fixtures/python_format", __DIR__)
  @external_resource Path.join(@fixtures, "format_g.json")
  @external_resource Path.join(@fixtures, "format_g_ints.json")
  @external_resource Path.join(@fixtures, "format_fixed.json")
  @external_resource Path.join(@fixtures, "round.json")
  @external_resource Path.join(@fixtures, "round_ints.json")

  @format_g @fixtures |> Path.join("format_g.json") |> File.read!() |> Jason.decode!()
  @format_g_ints @fixtures |> Path.join("format_g_ints.json") |> File.read!() |> Jason.decode!()
  @format_fixed @fixtures |> Path.join("format_fixed.json") |> File.read!() |> Jason.decode!()
  @round @fixtures |> Path.join("round.json") |> File.read!() |> Jason.decode!()
  @round_ints @fixtures |> Path.join("round_ints.json") |> File.read!() |> Jason.decode!()

  # Expected strings are what Python 3.11 prints for the same values.
  describe "repr/1 on strings" do
    test "quotes with single quotes unless only a single quote appears" do
      assert Python.repr("plain") == "'plain'"
      assert Python.repr("it's") == ~S("it's")
      assert Python.repr(~S(say "hi")) == ~S('say "hi"')
      assert Python.repr(~S(both ' and ")) == ~S('both \' and "')
    end

    test "escapes backslashes, tabs, newlines and carriage returns" do
      assert Python.repr("back\\slash") == ~S('back\\slash')
      assert Python.repr("tab\tnew\nret\r") == ~S('tab\tnew\nret\r')
    end

    test "keeps printable non-ASCII characters" do
      assert Python.repr("café → 😀") == "'café → 😀'"
    end

    test "escapes non-printable characters by code point size" do
      assert Python.repr("bell\a del\x7F") == ~S('bell\x07 del\x7f')
      assert Python.repr("nbsp\u00A0x") == ~S('nbsp\xa0x')
      assert Python.repr("zw\u200B") == "'zw\\u200b'"
      assert Python.repr("\u{E0001}") == ~S('\U000e0001')
    end
  end

  describe "repr/1 on other terms" do
    test "prints lists and dicts like Python" do
      assert Python.repr([]) == "[]"
      assert Python.repr(["a", "b'c"]) == ~S(['a', "b'c"])

      assert Python.repr([1, 2.5, true, false, nil, 1.0e-5]) ==
               "[1, 2.5, True, False, None, 1e-05]"

      assert Python.repr(%Jason.OrderedObject{values: [{"verdict", "yes"}, {"reason", nil}]}) ==
               "{'verdict': 'yes', 'reason': None}"
    end

    test "prints atoms as strings" do
      assert Python.repr([:yes, :no]) == "['yes', 'no']"
    end

    test "prints enum members like Python's Enum.__repr__" do
      member = %Python.EnumMember{class: "Verdict", name: "YES", value: "yes"}
      assert Python.repr([member]) == "[<Verdict.YES: 'yes'>]"
    end

    test "prints tool calls like deepeval's ToolCall.__repr__" do
      tool_call = %ToolCall{
        name: "get_weather",
        description: "Fetch the weather",
        input_parameters: %{"city" => "Paris"},
        output: %{"temp_c" => 18}
      }

      assert Python.repr([tool_call, %ToolCall{name: "search", output: "sunny"}]) ==
               """
               [ToolCall(
                   name="get_weather",
                   type="FUNCTION",
                   description="Fetch the weather",
                   input_parameters={
                       "city": "Paris"
                   },
                   output={
                       "temp_c": 18
                   }
               ), ToolCall(
                   name="search",
                   type="FUNCTION",
                   output='sunny'
               )]\
               """
    end

    test "prints an ordered object output as JSON, like a dict" do
      output = Jason.OrderedObject.new([{"temp_c", 18}, {"sky", "clear"}])

      assert Python.repr(%ToolCall{name: "get_weather", output: output}) ==
               """
               ToolCall(
                   name="get_weather",
                   type="FUNCTION",
                   output={
                       "temp_c": 18,
                       "sky": "clear"
                   }
               )\
               """
    end
  end

  # Expected strings are what Jinja 3's `{{ x | tojson }}` renders.
  describe "tojson/1" do
    test "writes JSON with <, >, & and ' escaped for HTML" do
      assert Python.tojson("plain") == ~S("plain")

      assert Python.tojson(~S(Wrap <code> & say "can't")) ==
               ~S("Wrap \u003ccode\u003e \u0026 say \"can\u0027t\"")
    end

    test "escapes non-ASCII characters as json.dumps does, astral ones as surrogate pairs" do
      assert Python.tojson("café — 😀") == ~S("caf\u00e9 \u2014 \ud83d\ude00")
    end

    test "escapes control characters and backslashes" do
      assert Python.tojson("tab\tnew\nline\\\\back") == ~S("tab\tnew\nline\\\\back")
    end
  end

  describe "format_fixed/2" do
    test "formats like Python's format(x, \".2f\")" do
      assert Python.format_fixed(0.5, 2) == "0.50"
      assert Python.format_fixed(1, 2) == "1.00"
      assert Python.format_fixed(0.6667, 2) == "0.67"
      assert Python.format_fixed(0.8333, 2) == "0.83"
      assert Python.format_fixed(0.0, 2) == "0.00"
    end

    test "rounds exact ties to even, as Python does" do
      assert Python.format_fixed(0.125, 2) == "0.12"
      assert Python.format_fixed(0.375, 2) == "0.38"
      # 2.675 is just below the tie in binary.
      assert Python.format_fixed(2.675, 2) == "2.67"
    end

    test "keeps the sign of a negative number rounded to zero, as Python does" do
      assert Python.format_fixed(-0.001, 2) == "-0.00"
      assert Python.format_fixed(-0.0, 2) == "-0.00"
    end

    test "matches CPython's format(x, \".<n>f\") for every float in the table" do
      mismatches =
        for [bits, decimals, expected] <- @format_fixed,
            float = float(bits),
            (actual = Python.format_fixed(float, decimals)) != expected,
            do: {float, decimals, actual, expected}

      assert length(@format_fixed) > 5_000
      assert mismatches == []
    end
  end

  describe "format_g/1" do
    test "formats like Python's format(x, \"g\")" do
      assert Python.format_g(1.0) == "1"
      assert Python.format_g(0.5) == "0.5"
      assert Python.format_g(2) == "2"
      assert Python.format_g(1 / 3) == "0.333333"
      assert Python.format_g(1_234_567) == "1.23457e+06"
      assert Python.format_g(0.0001) == "0.0001"
      assert Python.format_g(0.00001) == "1e-05"
      assert Python.format_g(-0.0) == "-0"
      assert Python.format_g(999_999.5) == "1e+06"
      assert Python.format_g(1.0e100) == "1e+100"
    end

    test "matches CPython for every float in the table" do
      mismatches =
        for [bits, expected] <- @format_g,
            float = float(bits),
            (actual = Python.format_g(float)) != expected,
            do: {float, actual, expected}

      assert length(@format_g) > 2_000
      assert mismatches == []
    end

    test "matches CPython for every integer in the table" do
      mismatches =
        for [int, expected] <- @format_g_ints,
            (actual = Python.format_g(int)) != expected,
            do: {int, actual, expected}

      assert mismatches == []
    end
  end

  describe "round/2" do
    test "rounds like Python's round(x, n)" do
      assert Python.round(0.123456, 3) == 0.123
      assert Python.round(2.675, 2) == 2.67
      assert Python.round(0.125, 2) == 0.12
      assert Python.round(0.375, 2) == 0.38
      assert Python.round(2.5, 0) == 2.0
      assert Python.round(15.0, -1) == 20.0
      assert Python.round(25.0, -1) == 20.0
      assert Python.round(0.6666666666666666, 3) |> Python.repr() == "0.667"
    end

    test "keeps the sign of a value rounded to zero" do
      assert <<1::1, _::63>> = <<Python.round(-0.0001, 2)::float>>
      assert <<0::1, _::63>> = <<Python.round(0.0001, 2)::float>>
    end

    test "returns an integer unchanged for non-negative ndigits and rounds it half to even otherwise" do
      assert Python.round(7, 3) === 7
      assert Python.round(15, -1) === 20
      assert Python.round(25, -1) === 20
      assert Python.round(-25, -1) === -20
    end

    test "raises like Python when the result overflows" do
      assert_raise ArgumentError, "rounding overflowed", fn ->
        Python.round(1.797_693_134_862_315_7e308, -308)
      end
    end

    test "matches CPython for every float in the table, bit for bit" do
      mismatches =
        for [bits, ndigits, expected_bits, expected_repr] <- @round,
            float = float(bits),
            result = Python.round(float, ndigits),
            {<<actual_bits::unsigned-64>>, actual_repr} =
              {<<result::float>>, Python.repr(result)},
            actual_bits != expected_bits or actual_repr != expected_repr,
            do: {float, ndigits, result, expected_repr}

      assert length(@round) > 8_000
      assert mismatches == []
    end

    test "matches CPython for every integer in the table" do
      mismatches =
        for [int, ndigits, expected] <- @round_ints,
            (actual = Python.round(int, ndigits)) !== expected,
            do: {int, ndigits, actual, expected}

      assert mismatches == []
    end
  end

  defp float(bits) do
    <<float::float-64>> = <<bits::unsigned-64>>
    float
  end
end
