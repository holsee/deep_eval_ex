# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.HallucinationTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Hallucination
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "metric_name/0" do
    test "returns Hallucination" do
      assert Hallucination.metric_name() == "Hallucination"
    end
  end

  describe "required_params/0" do
    test "requires input, actual_output, and context" do
      assert Hallucination.required_params() == [:input, :actual_output, :context]
    end
  end

  describe "measure/2 with no hallucinations" do
    test "returns score 0.0 when all contexts agree" do
      # Mock verdicts - all agree
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [
          %{"verdict" => "yes", "reason" => "The output agrees with context about Einstein's Nobel Prize."},
          %{"verdict" => "yes", "reason" => "The output correctly states the photoelectric effect."}
        ]}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 0.0 because the output aligns with all provided contexts."}
      )

      test_case =
        TestCase.new!(
          input: "What did Einstein win the Nobel Prize for?",
          actual_output: "Einstein won the Nobel Prize for the photoelectric effect.",
          context: [
            "Einstein won the Nobel Prize in Physics.",
            "Einstein won it for his discovery of the photoelectric effect."
          ]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.score == 0.0
      assert result.success == true
      assert result.metric == "Hallucination"
    end
  end

  describe "measure/2 with hallucinations" do
    test "returns score 1.0 when all contexts contradict" do
      # Mock verdicts - all contradict
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [
          %{"verdict" => "no", "reason" => "The output says 1969, but context says 1921."},
          %{"verdict" => "no", "reason" => "The output contradicts the context."}
        ]}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 1.0 because the output contradicts all contexts."}
      )

      test_case =
        TestCase.new!(
          input: "When did Einstein win the Nobel Prize?",
          actual_output: "Einstein won the Nobel Prize in 1969.",
          context: [
            "Einstein won the Nobel Prize in 1921.",
            "The Nobel Prize was awarded to Einstein in 1921."
          ]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.score == 1.0
      assert result.success == false  # 1.0 > 0.5 threshold
    end

    test "returns partial score when some contexts contradict" do
      # Mock verdicts - one agrees, one contradicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [
          %{"verdict" => "yes", "reason" => "The output correctly mentions the photoelectric effect."},
          %{"verdict" => "no", "reason" => "The output says 1969, but context says 1921."}
        ]}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 0.5 because one of two contexts was contradicted."}
      )

      test_case =
        TestCase.new!(
          input: "Tell me about Einstein's Nobel Prize.",
          actual_output: "Einstein won the Nobel Prize in 1969 for the photoelectric effect.",
          context: [
            "Einstein won the Nobel Prize for the photoelectric effect.",
            "Einstein won the Nobel Prize in 1921."
          ]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.score == 0.5
      assert result.success == true  # 0.5 <= 0.5 threshold
    end
  end

  describe "measure/2 with empty context" do
    test "returns error when context is empty list" do
      test_case =
        TestCase.new!(
          input: "What is the capital of France?",
          actual_output: "Paris is the capital of France.",
          context: []
        )

      # Empty context is treated as missing for required params
      assert {:error, {:missing_params, [:context]}} =
               Hallucination.measure(test_case, adapter: :mock)
    end
  end

  describe "measure/2 with threshold" do
    test "success is based on score <= threshold" do
      # Mock verdicts - partial hallucination
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [
          %{"verdict" => "yes", "reason" => "Agrees."},
          %{"verdict" => "no", "reason" => "Contradicts."}
        ]}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "Score is 0.5."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          context: ["Context 1", "Context 2"]
        )

      # With threshold 0.5, score of 0.5 should pass (<=)
      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock, threshold: 0.5)
      assert result.score == 0.5
      assert result.success == true

      Mock.clear_responses()

      # Re-mock for second test
      Mock.set_schema_response(~r/indicate whether the given 'actual output' agrees/i, %{"verdicts" => [
        %{"verdict" => "yes", "reason" => "Agrees."},
        %{"verdict" => "no", "reason" => "Contradicts."}
      ]})
      Mock.set_schema_response(~r/provide a reason for the hallucination score/i, %{"reason" => "Score is 0.5."})

      # With threshold 0.3, score of 0.5 should fail (0.5 > 0.3)
      assert {:ok, result2} = Hallucination.measure(test_case, adapter: :mock, threshold: 0.3)
      assert result2.score == 0.5
      assert result2.success == false
    end
  end

  describe "measure/2 without reason" do
    test "skips reason generation when include_reason is false" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Agrees."}]}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          context: ["Context"]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock, include_reason: false)
      assert result.score == 0.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes verdicts and context_count in metadata" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [
          %{"verdict" => "yes", "reason" => "Agrees with first context."},
          %{"verdict" => "no", "reason" => "Contradicts second context."}
        ]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "Partial hallucination."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          context: ["Context 1", "Context 2"]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.metadata.context_count == 2
      assert length(result.metadata.verdicts) == 2
      assert Enum.at(result.metadata.verdicts, 0).verdict == :yes
      assert Enum.at(result.metadata.verdicts, 1).verdict == :no
    end
  end

  describe "measure/2 with retrieval_context alias" do
    test "accepts retrieval_context as alias for context" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Agrees."}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "Good."}
      )

      # Using retrieval_context instead of context
      test_case = TestCase.new!(
        input: "Q",
        actual_output: "A",
        retrieval_context: ["Context via retrieval_context"]
      )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.score == 0.0
    end
  end

  describe "measure/2 validation" do
    test "returns error when context is missing" do
      test_case = TestCase.new!(
        input: "Q",
        actual_output: "A"
        # No context
      )

      assert {:error, {:missing_params, [:context]}} =
        Hallucination.measure(test_case, adapter: :mock)
    end
  end
end
