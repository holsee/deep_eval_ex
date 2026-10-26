# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.PatternMatchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.Metrics.PatternMatch
  alias DeepEvalEx.TestCase

  defp test_case(actual_output) do
    TestCase.new!(input: "What is the store's phone number?", actual_output: actual_output)
  end

  defp measure(actual_output, opts) do
    PatternMatch.measure(test_case(actual_output), opts)
  end

  describe "metric_name/0" do
    test "returns deepeval's name, Pattern Match" do
      assert PatternMatch.metric_name() == "Pattern Match"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output, as deepeval 4.3.1" do
      assert PatternMatch.required_params() == [:input, :actual_output]
    end
  end

  describe "default threshold" do
    test "is the float 1.0, as in deepeval" do
      assert PatternMatch.default_threshold() === 1.0
    end
  end

  describe "measure/2" do
    test "scores 1.0 when the whole output matches the pattern" do
      assert {:ok, result} = measure("555-1234", pattern: ~S"\d{3}-\d{4}")

      assert result.metric == "Pattern Match"
      assert result.score === 1.0
      assert result.success == true
      assert result.threshold === 1.0
      assert result.reason == "The actual output fully matches the pattern."
      assert result.verbose_logs == nil
      assert result.evaluation_model == nil
    end

    test "scores 0.0 when the pattern matches part of the output only, as re.fullmatch" do
      for output <- ["Call 555-1234", "555-1234 now", "555-12345"] do
        assert {:ok, result} = measure(output, pattern: ~S"\d{3}-\d{4}")
        assert result.score === 0.0
        assert result.success == false
        assert result.reason == "The actual output does not match the pattern."
      end
    end

    test "anchors the whole pattern, not its first and last alternatives" do
      assert {:ok, %{score: 1.0}} = measure("yes, definitely", pattern: "yes|yes, definitely")
      assert {:ok, %{score: +0.0}} = measure("yes, maybe", pattern: "yes|maybe")
    end

    test "does not let $ match before a trailing newline inside the output" do
      # deepeval strips the output first; an inner newline still counts.
      assert {:ok, %{score: +0.0}} = measure("a\nb", pattern: "a$")
    end

    test "strips the pattern and the output, as deepeval does" do
      assert {:ok, result} = measure("  555-1234\n", pattern: ~S"  \d{3}-\d{4} ")
      assert result.score === 1.0
      assert result.metadata == %{pattern: ~S"\d{3}-\d{4}", ignore_case: false}
    end

    test "matches \\w and \\d against Unicode, as Python's str patterns do" do
      assert {:ok, %{score: 1.0}} = measure("café ٣", pattern: ~S"\w+ \d")
    end

    test "is case-sensitive unless :ignore_case is set" do
      assert {:ok, %{score: +0.0}} = measure("YES", pattern: "yes")
      assert {:ok, %{score: 1.0}} = measure("YES", pattern: "yes", ignore_case: true)
    end

    test "succeeds against a lower :threshold only when the score reaches it" do
      assert {:ok, result} = measure("no", pattern: "yes", threshold: 0.0)
      assert result.score === 0.0
      assert result.success == true
    end

    test "writes deepeval's verbose logs only in verbose mode, and prints them" do
      printed =
        capture_io(fn ->
          assert {:ok, result} =
                   measure(" YES ", pattern: "yes", ignore_case: true, verbose_mode: true)

          assert result.verbose_logs == "Pattern: yes \n \nActual: YES \n \nScore: 1.00"
        end)

      assert printed =~ "Pattern Match Verbose Logs"
      assert printed =~ "Reason: The actual output fully matches the pattern."
    end

    test "raises ArgumentError, as deepeval's constructor raises ValueError, for an invalid pattern" do
      assert_raise ArgumentError, ~r/^Invalid regex pattern: \(unclosed — /, fn ->
        measure("x", pattern: "(unclosed")
      end
    end

    test "rejects a pattern that is only valid once wrapped in the anchoring group" do
      assert_raise ArgumentError, ~r/^Invalid regex pattern: a\)\(b — /, fn ->
        measure("ab", pattern: "a)(b")
      end
    end

    test "raises ArgumentError without a pattern" do
      assert_raise ArgumentError,
                   "PatternMatch requires a :pattern (a regular expression).",
                   fn ->
                     measure("x", [])
                   end
    end

    test "returns an error for missing required params" do
      assert {:error, {:missing_params, [:input]}} =
               PatternMatch.measure(%TestCase{actual_output: "x"}, pattern: "x")
    end
  end

  describe "new/1" do
    test "builds a metric evaluate/3 measures with its own pattern" do
      metric = PatternMatch.new(pattern: " yes ", ignore_case: true)

      assert %PatternMatch{pattern: "yes", ignore_case: true, threshold: 1.0} = metric

      assert {[[yes, no]], _test_run, _path} =
               DeepEvalEx.evaluate_run([test_case("Yes")], [
                 metric,
                 PatternMatch.new(pattern: "no")
               ])

      assert {yes.metric, yes.score} == {"Pattern Match", 1.0}
      assert {no.metric, no.score} == {"Pattern Match", 0.0}
    end

    test "raises ArgumentError for an invalid pattern, as deepeval's constructor" do
      assert_raise ArgumentError, ~r/^Invalid regex pattern: \[a-/, fn ->
        PatternMatch.new(pattern: "[a-")
      end
    end
  end

  describe "system_one?/0" do
    test "is false: like deepeval's, the metric ignores the eval mode" do
      refute PatternMatch.system_one?()

      assert {:ok, %{score: 1.0}} =
               measure("yes", pattern: "yes", eval_mode: :system_one)
    end
  end
end
