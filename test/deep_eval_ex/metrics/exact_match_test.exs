defmodule DeepEvalEx.Metrics.ExactMatchTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.TestCase

  describe "measure/2" do
    test "returns score 1.0 for exact match" do
      test_case = %TestCase{
        input: "What is 2 + 2?",
        actual_output: "4",
        expected_output: "4"
      }

      assert {:ok, result} = ExactMatch.measure(test_case)
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "ExactMatch"
      assert result.reason =~ "exact match"
    end

    test "returns score 0.0 for no match" do
      test_case = %TestCase{
        input: "What is 2 + 2?",
        actual_output: "5",
        expected_output: "4"
      }

      assert {:ok, result} = ExactMatch.measure(test_case)
      assert result.score == 0.0
      assert result.success == false
      assert result.reason =~ "different"
    end

    test "trims whitespace before comparing" do
      test_case = %TestCase{
        input: "test",
        actual_output: "  hello world  ",
        expected_output: "hello world"
      }

      assert {:ok, result} = ExactMatch.measure(test_case)
      assert result.score == 1.0
    end

    test "case sensitive by default" do
      test_case = %TestCase{
        input: "test",
        actual_output: "Hello",
        expected_output: "hello"
      }

      assert {:ok, result} = ExactMatch.measure(test_case)
      assert result.score == 0.0
    end

    test "supports case insensitive option" do
      test_case = %TestCase{
        input: "test",
        actual_output: "Hello",
        expected_output: "hello"
      }

      assert {:ok, result} = ExactMatch.measure(test_case, case_sensitive: false)
      assert result.score == 1.0
    end

    test "supports whitespace normalization" do
      test_case = %TestCase{
        input: "test",
        actual_output: "hello    world",
        expected_output: "hello world"
      }

      # Without normalization
      assert {:ok, result1} = ExactMatch.measure(test_case)
      assert result1.score == 0.0

      # With normalization
      assert {:ok, result2} = ExactMatch.measure(test_case, normalize_whitespace: true)
      assert result2.score == 1.0
    end

    test "returns error for missing required params" do
      test_case = %TestCase{
        input: "test",
        actual_output: "hello"
        # missing expected_output
      }

      assert {:error, {:missing_params, [:expected_output]}} = ExactMatch.measure(test_case)
    end

    test "includes latency in result" do
      test_case = %TestCase{
        input: "test",
        actual_output: "hello",
        expected_output: "hello"
      }

      assert {:ok, result} = ExactMatch.measure(test_case)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end
  end

  describe "metric_name/0" do
    test "returns correct name" do
      assert ExactMatch.metric_name() == "ExactMatch"
    end
  end

  describe "required_params/0" do
    test "returns required parameters" do
      assert ExactMatch.required_params() == [:input, :actual_output, :expected_output]
    end
  end

  describe "default_threshold/0" do
    test "returns 1.0 for exact match metric" do
      assert ExactMatch.default_threshold() == 1.0
    end
  end
end
