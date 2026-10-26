defmodule DeepEvalEx.Metrics.Utils.VerboseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Schemas.ToolCall
  alias Jason.OrderedObject

  doctest Verbose

  describe "construct_verbose_logs/3" do
    test "joins every step but the last with deepeval's separator" do
      assert Verbose.construct_verbose_logs("M", ["A", "B", "Score: 1\nReason: r"], []) ==
               "A \n \nB"
    end

    test "is empty for a single step, as deepeval's" do
      assert Verbose.construct_verbose_logs("M", ["Score: 1"], []) == ""
    end

    test "prints nothing without verbose mode" do
      assert capture_io(fn ->
               Verbose.construct_verbose_logs("M", ["A", "Score: 1"], verbose_mode: false)
             end) == ""
    end

    test "prints the logs and the last step in verbose mode, as print_verbose_logs" do
      output =
        capture_io(fn ->
          assert Verbose.construct_verbose_logs("Faithfulness", ["A", "B", "Score: 1"],
                   verbose_mode: true
                 ) == "A \n \nB"
        end)

      stars = String.duplicate("*", 50)

      assert output ==
               "#{stars}\nFaithfulness Verbose Logs\n#{stars}\n\n" <>
                 "A \n \nB\n \nScore: 1\n\n#{String.duplicate("=", 70)}\n"
    end
  end

  describe "prettify_list/1" do
    test "prints an empty list as []" do
      assert Verbose.prettify_list([]) == "[]"
    end

    test "quotes strings without escaping them, as deepeval's f-string" do
      assert Verbose.prettify_list(["Paris", ~s(say "hi" in café)]) ==
               ~s([\n    "Paris",\n    "say "hi" in café"\n])
    end

    test "dumps models as indented ASCII JSON in field order" do
      verdict = OrderedObject.new(verdict: :no, reason: "Not in café")

      assert Verbose.prettify_list([verdict, OrderedObject.new(verdict: :yes, reason: nil)]) ==
               """
               [
                   {
                       "verdict": "no",
                       "reason": "Not in caf\\u00e9"
                   },
                   {
                       "verdict": "yes",
                       "reason": null
                   }
               ]\
               """
    end

    test "prints other values as Python's repr" do
      assert Verbose.prettify_list([1, 0.5, nil]) == "[\n    1,\n    0.5,\n    None\n]"
    end
  end

  describe "format_tools/2" do
    test "lists tool call reprs indented by four spaces" do
      tool = %ToolCall{name: "search", input_parameters: %{"q" => "x"}}

      assert Verbose.format_tools("Tools Called", [tool]) ==
               """
               Tools Called:
               [
                   ToolCall(
                       name="search",
                       type="FUNCTION",
                       input_parameters={
                           "q": "x"
                       }
                   )
               ]\
               """
    end

    test "keeps the brackets on their own lines for an empty list" do
      assert Verbose.format_tools("Expected Tools", []) == "Expected Tools:\n[\n\n]"
    end
  end

  describe "verbose_mode?/1" do
    test "reads :verbose_mode, false by default" do
      refute Verbose.verbose_mode?([])
      refute Verbose.verbose_mode?(verbose_mode: nil)
      assert Verbose.verbose_mode?(verbose_mode: true)
    end
  end
end
