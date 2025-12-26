# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.ContextualPrecisionTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ContextualPrecision
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "metric_name/0" do
    test "returns Contextual Precision" do
      assert ContextualPrecision.metric_name() == "Contextual Precision"
    end
  end

  describe "required_params/0" do
    test "requires input, retrieval_context, and expected_output" do
      assert ContextualPrecision.required_params() == [
               :input,
               :retrieval_context,
               :expected_output
             ]
    end
  end

  describe "calculate_score/1" do
    test "returns 1.0 when all relevant nodes are first" do
      # [yes, yes, no] - relevant nodes ranked first
      verdicts = [
        %{verdict: :yes, reason: "Relevant"},
        %{verdict: :yes, reason: "Relevant"},
        %{verdict: :no, reason: "Irrelevant"}
      ]

      # Position 1: precision@1 = 1/1 = 1.0
      # Position 2: precision@2 = 2/2 = 1.0
      # Score = (1.0 + 1.0) / 2 = 1.0
      assert ContextualPrecision.calculate_score(verdicts) == 1.0
    end

    test "returns lower score when irrelevant node is first" do
      # [no, yes, yes] - irrelevant node ranked first
      verdicts = [
        %{verdict: :no, reason: "Irrelevant"},
        %{verdict: :yes, reason: "Relevant"},
        %{verdict: :yes, reason: "Relevant"}
      ]

      # Position 2: precision@2 = 1/2 = 0.5
      # Position 3: precision@3 = 2/3 = 0.666...
      # Score = (0.5 + 0.666...) / 2 = 0.583...
      score = ContextualPrecision.calculate_score(verdicts)
      assert_in_delta score, 0.583, 0.01
    end

    test "returns intermediate score when irrelevant node is in middle" do
      # [yes, no, yes] - irrelevant node in middle
      verdicts = [
        %{verdict: :yes, reason: "Relevant"},
        %{verdict: :no, reason: "Irrelevant"},
        %{verdict: :yes, reason: "Relevant"}
      ]

      # Position 1: precision@1 = 1/1 = 1.0
      # Position 3: precision@3 = 2/3 = 0.666...
      # Score = (1.0 + 0.666...) / 2 = 0.833...
      score = ContextualPrecision.calculate_score(verdicts)
      assert_in_delta score, 0.833, 0.01
    end

    test "returns 0.0 when all nodes are irrelevant" do
      verdicts = [
        %{verdict: :no, reason: "Irrelevant"},
        %{verdict: :no, reason: "Irrelevant"}
      ]

      assert ContextualPrecision.calculate_score(verdicts) == 0.0
    end

    test "returns 0.0 when no verdicts" do
      assert ContextualPrecision.calculate_score([]) == 0.0
    end

    test "returns 1.0 when single relevant node" do
      verdicts = [%{verdict: :yes, reason: "Relevant"}]
      assert ContextualPrecision.calculate_score(verdicts) == 1.0
    end
  end

  describe "measure/2 with perfect ranking" do
    test "returns score 1.0 when all relevant nodes are ranked first" do
      # Mock verdicts - relevant nodes first
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{
              "verdict" => "yes",
              "reason" => "Contains information about Einstein winning Nobel Prize."
            },
            %{
              "verdict" => "yes",
              "reason" => "Contains information about the photoelectric effect."
            },
            %{"verdict" => "no", "reason" => "Cat is not relevant to Nobel Prize question."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{"reason" => "The score is 1.0 because all relevant nodes are ranked at the top."}
      )

      test_case =
        TestCase.new!(
          input: "Who won the Nobel Prize in 1921?",
          expected_output: "Einstein won the Nobel Prize in 1921 for the photoelectric effect.",
          retrieval_context: [
            "Einstein won the Nobel Prize in 1921.",
            "The prize was for the photoelectric effect.",
            "There was a cat."
          ]
        )

      assert {:ok, result} = ContextualPrecision.measure(test_case, adapter: :mock)
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "Contextual Precision"
    end
  end

  describe "measure/2 with poor ranking" do
    test "returns score 0.0 when all nodes are irrelevant" do
      # Mock verdicts - all irrelevant
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "Not related to the question."},
            %{"verdict" => "no", "reason" => "Off topic."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{"reason" => "The score is 0.0 because no nodes are relevant to the expected output."}
      )

      test_case =
        TestCase.new!(
          input: "What is the capital of France?",
          expected_output: "Paris is the capital of France.",
          retrieval_context: [
            "The weather is nice today.",
            "I like coffee."
          ]
        )

      assert {:ok, result} = ContextualPrecision.measure(test_case, adapter: :mock)
      assert result.score == 0.0
      # 0.0 < 0.5 threshold
      assert result.success == false
    end

    test "returns lower score when irrelevant nodes are ranked higher" do
      # Mock verdicts - irrelevant node first
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "Cat is not relevant."},
            %{"verdict" => "yes", "reason" => "Contains Nobel Prize info."},
            %{"verdict" => "yes", "reason" => "Contains photoelectric effect info."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{
          "reason" => "The score is lower because an irrelevant node about a cat is ranked first."
        }
      )

      test_case =
        TestCase.new!(
          input: "Who won the Nobel Prize?",
          expected_output: "Einstein won for the photoelectric effect.",
          retrieval_context: [
            "There was a cat.",
            "Einstein won the Nobel Prize.",
            "The prize was for the photoelectric effect."
          ]
        )

      assert {:ok, result} = ContextualPrecision.measure(test_case, adapter: :mock)
      assert_in_delta result.score, 0.583, 0.01
      # 0.58 >= 0.5 threshold
      assert result.success == true
    end
  end

  describe "measure/2 with empty context" do
    test "returns error when retrieval_context is empty" do
      test_case =
        TestCase.new!(
          input: "Question",
          expected_output: "Answer",
          retrieval_context: []
        )

      assert {:error, {:missing_params, [:retrieval_context]}} =
               ContextualPrecision.measure(test_case, adapter: :mock)
    end
  end

  describe "measure/2 with threshold" do
    test "success is based on score >= threshold" do
      # Mock verdicts - partial relevance
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Relevant."},
            %{"verdict" => "no", "reason" => "Irrelevant."},
            %{"verdict" => "yes", "reason" => "Relevant."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{"reason" => "Score is 0.83."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          retrieval_context: ["C1", "C2", "C3"]
        )

      # With threshold 0.5, score of ~0.83 should pass
      assert {:ok, result} =
               ContextualPrecision.measure(test_case, adapter: :mock, threshold: 0.5)

      assert_in_delta result.score, 0.833, 0.01
      assert result.success == true

      Mock.clear_responses()

      # Re-mock for second test
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Relevant."},
            %{"verdict" => "no", "reason" => "Irrelevant."},
            %{"verdict" => "yes", "reason" => "Relevant."}
          ]
        }
      )

      Mock.set_schema_response(~r/provide a CONCISE summary for the score/i, %{
        "reason" => "Score is 0.83."
      })

      # With threshold 0.9, score of ~0.83 should fail
      assert {:ok, result2} =
               ContextualPrecision.measure(test_case, adapter: :mock, threshold: 0.9)

      assert_in_delta result2.score, 0.833, 0.01
      assert result2.success == false
    end
  end

  describe "measure/2 without reason" do
    test "skips reason generation when include_reason is false" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Relevant."}]}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          retrieval_context: ["Context"]
        )

      assert {:ok, result} =
               ContextualPrecision.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 1.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes verdicts and context_count in metadata" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Relevant to question."},
            %{"verdict" => "no", "reason" => "Not relevant."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{"reason" => "Partial precision."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          retrieval_context: ["Context 1", "Context 2"]
        )

      assert {:ok, result} = ContextualPrecision.measure(test_case, adapter: :mock)
      assert result.metadata.context_count == 2
      assert length(result.metadata.verdicts) == 2
      assert Enum.at(result.metadata.verdicts, 0).verdict == :yes
      assert Enum.at(result.metadata.verdicts, 1).verdict == :no
    end
  end

  describe "measure/2 with context alias" do
    test "accepts context as alias for retrieval_context" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each node in the retrieval context was remotely useful/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Relevant."}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE summary for the score/i,
        %{"reason" => "Good."}
      )

      # Using context instead of retrieval_context
      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          context: ["Context via alias"]
        )

      assert {:ok, result} = ContextualPrecision.measure(test_case, adapter: :mock)
      assert result.score == 1.0
    end
  end

  describe "measure/2 validation" do
    test "returns error when expected_output is missing" do
      test_case = %DeepEvalEx.TestCase{
        input: "Some input",
        actual_output: "Some output",
        retrieval_context: ["Context"],
        expected_output: nil
      }

      assert {:error, {:missing_params, [:expected_output]}} =
               ContextualPrecision.measure(test_case, adapter: :mock)
    end

    test "returns error when retrieval_context is missing" do
      test_case = %DeepEvalEx.TestCase{
        input: "Some input",
        expected_output: "Expected output",
        retrieval_context: nil
      }

      assert {:error, {:missing_params, [:retrieval_context]}} =
               ContextualPrecision.measure(test_case, adapter: :mock)
    end
  end
end
