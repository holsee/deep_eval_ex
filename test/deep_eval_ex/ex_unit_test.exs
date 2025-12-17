# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ExUnitTest do
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.{AnswerRelevancy, ExactMatch, Faithfulness}
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "assert_passes/2" do
    test "passes when metric evaluation succeeds" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_passes(test_case, ExactMatch)
      assert result.success
      assert result.score == 1.0
    end

    test "fails when metric evaluation fails" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Metric evaluation failed unexpectedly/i, fn ->
        assert_passes(test_case, ExactMatch)
      end
    end

    test "fails with missing params error" do
      test_case = %TestCase{
        input: "Question",
        actual_output: nil,
        expected_output: "Answer"
      }

      assert_raise ExUnit.AssertionError, ~r/Missing required parameters/i, fn ->
        assert_passes(test_case, ExactMatch)
      end
    end
  end

  describe "assert_passes/3 with options" do
    test "respects custom threshold" do
      # Mock responses for Faithfulness with correct patterns
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial support."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context"]
        )

      # Score of 0.5 passes with threshold 0.5
      result = assert_passes(test_case, Faithfulness, adapter: :mock, threshold: 0.5)
      assert result.score == 0.5

      Mock.clear_responses()

      # Re-mock for higher threshold test
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial support."}
      )

      # Score of 0.5 fails with threshold 0.8
      assert_raise ExUnit.AssertionError, ~r/FAIL.*expected PASS/i, fn ->
        assert_passes(test_case, Faithfulness, adapter: :mock, threshold: 0.8)
      end
    end
  end

  describe "assert_fails/2" do
    test "passes when metric evaluation fails" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "5",
          expected_output: "4"
        )

      result = assert_fails(test_case, ExactMatch)
      assert not result.success
      assert result.score == 0.0
    end

    test "fails when metric evaluation passes" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Metric evaluation passed unexpectedly/i, fn ->
        assert_fails(test_case, ExactMatch)
      end
    end
  end

  describe "assert_score/3 with :min" do
    test "passes when score meets minimum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, min: 0.5)
      assert result.score >= 0.5
    end

    test "fails when score is below minimum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score is below minimum/i, fn ->
        assert_score(test_case, ExactMatch, min: 0.5)
      end
    end
  end

  describe "assert_score/3 with :max" do
    test "passes when score is at or below maximum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, max: 0.5)
      assert result.score <= 0.5
    end

    test "fails when score exceeds maximum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score exceeds maximum/i, fn ->
        assert_score(test_case, ExactMatch, max: 0.5)
      end
    end
  end

  describe "assert_score/3 with :exact" do
    test "passes when score matches exactly" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, exact: 1.0)
      assert result.score == 1.0
    end

    test "fails when score doesn't match" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score does not match expected/i, fn ->
        assert_score(test_case, ExactMatch, exact: 1.0)
      end
    end

    test "respects delta tolerance" do
      # Create a test case that would give a score close to but not exactly 0.5
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["C"]
        )

      # Score of 0.5 should pass with delta 0.01
      result = assert_score(test_case, Faithfulness, [exact: 0.5, delta: 0.01], adapter: :mock)
      assert_in_delta result.score, 0.5, 0.01
    end
  end

  describe "assert_score/3 with :min and :max range" do
    test "passes when score is within range" do
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["C"]
        )

      result = assert_score(test_case, Faithfulness, [min: 0.4, max: 0.6], adapter: :mock)
      assert result.score >= 0.4 and result.score <= 0.6
    end

    test "fails when score is outside range" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score is outside expected range/i, fn ->
        assert_score(test_case, ExactMatch, min: 0.2, max: 0.8)
      end
    end
  end

  describe "assert_evaluation/2" do
    test "passes when all metrics pass" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      # ExactMatch will pass with score 1.0
      results = assert_evaluation(test_case, [ExactMatch])
      assert length(results) == 1
      assert Enum.all?(results, & &1.success)
    end

    test "fails when any metric fails" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Multiple metric evaluations failed/i, fn ->
        assert_evaluation(test_case, [ExactMatch])
      end
    end

    test "fails when metric returns error" do
      test_case = %TestCase{
        input: "Q",
        actual_output: nil,
        expected_output: "A"
      }

      assert_raise ExUnit.AssertionError, ~r/Multiple metric evaluations failed/i, fn ->
        assert_evaluation(test_case, [ExactMatch])
      end
    end
  end

  describe "assert_evaluation/3 with options" do
    test "passes options to all metrics" do
      # Mock statements extraction
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["Statement 1"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "Good."}
      )

      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer with a statement."
        )

      results = assert_evaluation(test_case, [AnswerRelevancy], adapter: :mock)
      assert length(results) == 1
      assert Enum.all?(results, & &1.success)
    end
  end

  describe "error messages" do
    test "includes metric name and score in failure message" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch)
        end

      assert error.message =~ "ExactMatch"
      assert error.message =~ "0.0"
      assert error.message =~ "0%"
    end

    test "includes reason when available" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "Different answer",
          expected_output: "Expected answer"
        )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch)
        end

      assert error.message =~ "Reason:"
    end
  end

  describe "use DeepEvalEx.ExUnit" do
    test "imports all assertion macros" do
      # This test verifies that using the module makes all macros available
      # Macros are imported, not exported as functions, so we check the source module
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_passes, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_passes, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_fails, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_fails, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_score, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_score, 4)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_evaluation, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_evaluation, 3)
    end
  end
end
