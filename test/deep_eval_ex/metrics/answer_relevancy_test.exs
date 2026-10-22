# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.AnswerRelevancyTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.AnswerRelevancy
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "metric_name/0" do
    test "returns Answer Relevancy" do
      assert AnswerRelevancy.metric_name() == "Answer Relevancy"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output" do
      assert AnswerRelevancy.required_params() == [:input, :actual_output]
    end
  end

  describe "measure/2 with fully relevant output" do
    test "returns score 1.0 when all statements are relevant" do
      # Mock statements extraction
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{
          "statements" => [
            "The laptop has a Retina display.",
            "It has a 12-hour battery life."
          ]
        }
      )

      # Mock verdicts - all relevant
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "yes"}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{
          "reason" =>
            "The score is 1.0 because all statements directly address the question about laptop features."
        }
      )

      test_case =
        TestCase.new!(
          input: "What are the features of the new laptop?",
          actual_output: "The laptop has a Retina display and 12-hour battery life."
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "Answer Relevancy"
    end
  end

  describe "measure/2 with irrelevant statements" do
    test "returns score 0.0 when all statements are irrelevant" do
      # Mock statements extraction
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{
          "statements" => [
            "The weather is nice today.",
            "I like coffee."
          ]
        }
      )

      # Mock verdicts - all irrelevant
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "Weather has nothing to do with laptop features."},
            %{
              "verdict" => "no",
              "reason" => "Personal preferences are not relevant to the question."
            }
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{
          "reason" =>
            "The score is 0.0 because none of the statements address the question about laptop features."
        }
      )

      test_case =
        TestCase.new!(
          input: "What are the features of the new laptop?",
          actual_output: "The weather is nice today. I like coffee."
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.score == 0.0
      # 0.0 < 0.5 threshold
      assert result.success == false
    end

    test "returns partial score when some statements are irrelevant" do
      # Mock statements extraction
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{
          "statements" => [
            "The laptop has a Retina display.",
            "The weather is nice today."
          ]
        }
      )

      # Mock verdicts - one relevant, one irrelevant
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "no", "reason" => "Weather has nothing to do with laptop features."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "The score is 0.5 because one of two statements is relevant."}
      )

      test_case =
        TestCase.new!(
          input: "What are the features of the new laptop?",
          actual_output: "The laptop has a Retina display. The weather is nice today."
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.score == 0.5
      # 0.5 >= 0.5 threshold
      assert result.success == true
    end
  end

  describe "measure/2 with borderline statements" do
    setup do
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{
          "statements" => [
            "The laptop has a Retina display.",
            "Our company was founded in 2010."
          ]
        }
      )

      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{
          "reason" =>
            "The score is 1.0 because all statements provide relevant or supporting information."
        }
      )

      test_case =
        TestCase.new!(
          input: "What are the features of the new laptop?",
          actual_output: "The laptop has a Retina display. Our company was founded in 2010."
        )

      %{test_case: test_case}
    end

    test "treats borderline verdicts as relevant (supporting information)", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "borderline", "reason" => "Company history is tangentially related."}
          ]
        }
      )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.score === 1.0
      assert result.success == true

      assert [%{verdict: :yes}, %{verdict: :borderline}] = result.metadata.verdicts
    end

    test "reads the legacy idk verdict as borderline", %{test_case: test_case} do
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "Not a feature."},
            %{"verdict" => "idk", "reason" => "Company history is tangentially related."}
          ]
        }
      )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.score === 0.5
      assert [%{verdict: :no}, %{verdict: :borderline}] = result.metadata.verdicts
    end
  end

  describe "measure/2 verdict normalisation" do
    test "reads verbose verdicts by their leading word and drops unknown ones" do
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["Retina display.", "Founded in 2010.", "Nice weather."]}
      )

      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "Yes, it is relevant."},
            %{"verdict" => "No", "reason" => "Not a feature."},
            %{"verdict" => "maybe", "reason" => "Unsure."}
          ]
        }
      )

      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "The score is 0.50."}
      )

      test_case =
        TestCase.new!(
          input: "What are the features of the new laptop?",
          actual_output: "Retina display. Founded in 2010. Nice weather."
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      # The unknown verdict is dropped, not counted as irrelevant: 1 / 2
      assert result.score === 0.5
      assert [%{verdict: :yes}, %{verdict: :no}] = result.metadata.verdicts
    end
  end

  describe "measure/2 with no statements" do
    test "returns score 1 when no statements extracted" do
      # Mock statements extraction - empty
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => []}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "The score is 1.0 because there are no statements to evaluate."}
      )

      test_case =
        TestCase.new!(
          input: "What are the features?",
          actual_output: "I don't know."
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      # deepeval's shared QAG scoring returns the integer 1 for no verdicts
      assert result.score === 1
      assert result.success == true
    end
  end

  describe "measure/2 with threshold" do
    test "success is based on score >= threshold" do
      # Mock statements
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["Statement 1", "Statement 2", "Statement 3", "Statement 4"]}
      )

      # Mock verdicts - 3 relevant, 1 irrelevant = 0.75
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "yes"},
            %{"verdict" => "yes"},
            %{"verdict" => "no", "reason" => "Irrelevant."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "Score is 0.75."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A"
        )

      # With threshold 0.5, score of 0.75 should pass
      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock, threshold: 0.5)
      assert result.score == 0.75
      assert result.success == true

      Mock.clear_responses()

      # Re-mock for second test
      Mock.set_schema_response(~r/breakdown and generate a list of statements/i, %{
        "statements" => ["S1", "S2", "S3", "S4"]
      })

      Mock.set_schema_response(~r/determine whether each statement is relevant/i, %{
        "verdicts" => [
          %{"verdict" => "yes"},
          %{"verdict" => "yes"},
          %{"verdict" => "yes"},
          %{"verdict" => "no", "reason" => "Irrelevant."}
        ]
      })

      Mock.set_schema_response(~r/provide a CONCISE reason for the score/i, %{
        "reason" => "Score is 0.75."
      })

      # With threshold 0.8, score of 0.75 should fail
      assert {:ok, result2} = AnswerRelevancy.measure(test_case, adapter: :mock, threshold: 0.8)
      assert result2.score == 0.75
      assert result2.success == false
    end
  end

  describe "measure/2 without reason" do
    test "skips reason generation when include_reason is false" do
      # Mock statements
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["The laptop has a Retina display."]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      test_case =
        TestCase.new!(
          input: "What are the features?",
          actual_output: "The laptop has a Retina display."
        )

      assert {:ok, result} =
               AnswerRelevancy.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 1.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes statements, verdicts, and statement_count in metadata" do
      # Mock statements
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["Statement 1", "Statement 2"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "no", "reason" => "Irrelevant to input."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "Partial relevancy."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A"
        )

      assert {:ok, result} = AnswerRelevancy.measure(test_case, adapter: :mock)
      assert result.metadata.statement_count == 2
      assert length(result.metadata.statements) == 2
      assert length(result.metadata.verdicts) == 2
      assert Enum.at(result.metadata.verdicts, 0).verdict == :yes
      assert Enum.at(result.metadata.verdicts, 1).verdict == :no
    end
  end

  describe "measure/2 validation" do
    test "returns error when actual_output is missing" do
      # Create a test case struct directly with nil actual_output
      test_case = %DeepEvalEx.TestCase{
        input: "Some input",
        actual_output: nil
      }

      assert {:error, {:missing_params, [:actual_output]}} =
               AnswerRelevancy.measure(test_case, adapter: :mock)
    end

    test "returns error when actual_output is empty string" do
      # Create a test case struct directly with empty actual_output
      test_case = %DeepEvalEx.TestCase{
        input: "Some input",
        actual_output: ""
      }

      assert {:error, {:empty_param, :actual_output}} =
               AnswerRelevancy.measure(test_case, adapter: :mock)
    end
  end
end
