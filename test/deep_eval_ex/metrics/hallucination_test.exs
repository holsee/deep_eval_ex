# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.HallucinationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # The first measure on the node logs the score direction warning.
  @moduletag :capture_log

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
    test "returns score 1.0 when all contexts agree" do
      # Mock verdicts - all agree
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{
              "verdict" => "yes",
              "reason" => "The output agrees with context about Einstein's Nobel Prize."
            },
            %{
              "verdict" => "yes",
              "reason" => "The output correctly states the photoelectric effect."
            }
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 1.00 because the output aligns with all provided contexts."}
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
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "Hallucination"
    end
  end

  describe "measure/2 with hallucinations" do
    test "returns score 0.0 when all contexts contradict" do
      # Mock verdicts - all contradict
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "The output says 1969, but context says 1921."},
            %{"verdict" => "no", "reason" => "The output contradicts the context."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 0.00 because the output contradicts all contexts."}
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
      assert result.score == 0.0
      # 0.0 < 0.5 threshold
      assert result.success == false
    end

    test "scores the fraction of contexts the output agrees with" do
      # Mock verdicts - one agrees, one contradicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{
              "verdict" => "yes",
              "reason" => "The output correctly mentions the photoelectric effect."
            },
            %{"verdict" => "no", "reason" => "The output says 1969, but context says 1921."},
            %{"verdict" => "no", "reason" => "The output says Germany, but context says Sweden."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 0.33 because two of three contexts were contradicted."}
      )

      test_case =
        TestCase.new!(
          input: "Tell me about Einstein's Nobel Prize.",
          actual_output: "Einstein won the Nobel Prize in 1969 for the photoelectric effect.",
          context: [
            "Einstein won the Nobel Prize for the photoelectric effect.",
            "Einstein won the Nobel Prize in 1921.",
            "The Nobel Prize ceremony is held in Sweden."
          ]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      # 1 aligned context out of 3, the way deepeval 4.3.1 scores it
      assert result.score == 1 / 3
      # 0.33 < 0.5 threshold
      assert result.success == false
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
    test "success is based on score >= threshold" do
      # Mock verdicts - partial hallucination
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Agrees."},
            %{"verdict" => "no", "reason" => "Contradicts."}
          ]
        }
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

      # With threshold 0.5, score of 0.5 should pass (>=)
      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock, threshold: 0.5)
      assert result.score == 0.5
      assert result.success == true

      Mock.clear_responses()

      # Re-mock for second test
      Mock.set_schema_response(~r/indicate whether the given 'actual output' agrees/i, %{
        "verdicts" => [
          %{"verdict" => "yes", "reason" => "Agrees."},
          %{"verdict" => "no", "reason" => "Contradicts."}
        ]
      })

      Mock.set_schema_response(~r/provide a reason for the hallucination score/i, %{
        "reason" => "Score is 0.5."
      })

      # With threshold 0.7, score of 0.5 should fail (0.5 < 0.7)
      assert {:ok, result2} = Hallucination.measure(test_case, adapter: :mock, threshold: 0.7)
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

      assert {:ok, result} =
               Hallucination.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 1.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes verdicts and context_count in metadata" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Agrees with first context."},
            %{"verdict" => "no", "reason" => "Contradicts second context."}
          ]
        }
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
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context via retrieval_context"]
        )

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      assert result.score == 1.0
    end
  end

  describe "measure/2 with no verdicts" do
    test "scores 1 and passes, as deepeval scores an empty verdict list" do
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => []}
      )

      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "Nothing to contradict."}
      )

      test_case = TestCase.new!(input: "Q", actual_output: "A", context: ["Context"])

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      # deepeval's shared QAG scoring returns the integer 1
      assert result.score === 1
      assert result.success == true
    end
  end

  describe "measure/2 verdict normalisation" do
    test "reads verbose verdicts by their leading word and drops unknown ones" do
      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{
          "verdicts" => [
            %{"verdict" => "Yes.", "reason" => "Agrees."},
            %{"verdict" => "unclear", "reason" => "Cannot tell."},
            %{"verdict" => "borderline", "reason" => "Not in Hallucination's vocabulary."}
          ]
        }
      )

      Mock.set_schema_response(
        ~r/provide a reason for the hallucination score/i,
        %{"reason" => "The score is 1.00."}
      )

      test_case =
        TestCase.new!(input: "Q", actual_output: "A", context: ["C1", "C2", "C3"])

      assert {:ok, result} = Hallucination.measure(test_case, adapter: :mock)
      # Unknown verdicts used to count as contradictions (1 / 3)
      assert result.score === 1.0
      assert [%{verdict: :yes, reason: "Agrees."}] = result.metadata.verdicts
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert Hallucination.default_threshold() == 0.5
    end
  end

  describe "score direction warning" do
    test "warns once per node that the score direction flipped" do
      :persistent_term.erase({DeepEvalEx.Metrics.Utils.ScoreDirection, "Hallucination"})

      Mock.set_schema_response(
        ~r/indicate whether the given 'actual output' agrees/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Agrees."}]}
      )

      test_case = TestCase.new!(input: "Q", actual_output: "A", context: ["Context"])

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Hallucination.measure(test_case, adapter: :mock, include_reason: false)

          assert {:ok, _} =
                   Hallucination.measure(test_case, adapter: :mock, include_reason: false)
        end)

      assert log =~ "'Hallucination' now scores in the same direction as every other"
      assert log =~ "'threshold' is the MINIMUM passing score"
      assert length(String.split(log, "now scores in the same direction")) == 2
    end
  end

  describe "measure/2 validation" do
    test "returns error when context is missing" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A"
          # No context
        )

      assert {:error, {:missing_params, [:context]}} =
               Hallucination.measure(test_case, adapter: :mock)
    end
  end
end
