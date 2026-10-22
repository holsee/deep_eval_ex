defmodule DeepEvalEx.Prompts.PythonTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Schemas.ToolCall

  doctest Python

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
  end
end
