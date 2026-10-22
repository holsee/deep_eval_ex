# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.ContextualRecallTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ContextualRecall
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "metric_name/0" do
    test "returns Contextual Recall" do
      assert ContextualRecall.metric_name() == "Contextual Recall"
    end
  end

  describe "required_params/0" do
    test "requires input, retrieval_context, and expected_output" do
      assert ContextualRecall.required_params() == [:input, :retrieval_context, :expected_output]
    end
  end

  describe "measure/2 with full coverage" do
    test "returns score 1.0 when all sentences are attributable" do
      # Mock verdicts - all sentences attributable
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{
              "verdict" => "yes",
              "reason" => "Attributed to 1st node: 'Paris is the capital...'"
            },
            %{
              "verdict" => "yes",
              "reason" => "Attributed to 2nd node: 'Eiffel Tower is located...'"
            }
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{
          "reason" =>
            "The score is 1.0 because all sentences in the expected output can be attributed to nodes in the retrieval context."
        }
      )

      test_case =
        TestCase.new!(
          input: "What is the capital of France?",
          expected_output: "Paris is the capital of France. It is known for the Eiffel Tower.",
          retrieval_context: [
            "Paris is the capital city of France.",
            "The Eiffel Tower is located in Paris."
          ]
        )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.score == 1.0
      assert result.success == true
      assert result.metric == "Contextual Recall"
    end
  end

  describe "measure/2 with no coverage" do
    test "returns score 0.0 when no sentences are attributable" do
      # Mock verdicts - no sentences attributable
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "No context about weather."},
            %{"verdict" => "no", "reason" => "No context about coffee."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{
          "reason" =>
            "The score is 0.0 because no sentences can be attributed to the retrieval context."
        }
      )

      test_case =
        TestCase.new!(
          input: "What is the weather?",
          expected_output: "The weather is sunny. I like coffee.",
          retrieval_context: [
            "Paris is the capital of France.",
            "The Eiffel Tower is in Paris."
          ]
        )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.score == 0.0
      # 0.0 < 0.5 threshold
      assert result.success == false
    end
  end

  describe "measure/2 with partial coverage" do
    test "returns partial score when some sentences are attributable" do
      # Mock verdicts - one attributable, one not
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Attributed to 1st node about Paris."},
            %{"verdict" => "no", "reason" => "No context about population."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{"reason" => "The score is 0.5 because only one of two sentences is attributable."}
      )

      test_case =
        TestCase.new!(
          input: "Tell me about Paris",
          expected_output: "Paris is the capital of France. It has a population of 2 million.",
          retrieval_context: [
            "Paris is the capital city of France."
          ]
        )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.score == 0.5
      # 0.5 >= 0.5 threshold
      assert result.success == true
    end
  end

  describe "measure/2 with empty context" do
    test "accepts an empty retrieval_context list, as deepeval only rejects a missing one" do
      test_case =
        TestCase.new!(
          input: "Question",
          expected_output: "Answer",
          retrieval_context: []
        )

      assert {:ok, result} =
               ContextualRecall.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 0
      assert result.metadata.context_count == 0
    end
  end

  describe "measure/2 with threshold" do
    test "success is based on score >= threshold" do
      # Mock verdicts - 2 out of 3 attributable
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Attributable."},
            %{"verdict" => "yes", "reason" => "Attributable."},
            %{"verdict" => "no", "reason" => "Not attributable."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{"reason" => "Score is 0.67."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "Sentence 1. Sentence 2. Sentence 3.",
          retrieval_context: ["Context"]
        )

      # With threshold 0.5, score of ~0.67 should pass
      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock, threshold: 0.5)
      assert_in_delta result.score, 0.667, 0.01
      assert result.success == true

      Mock.clear_responses()

      # Re-mock for second test
      Mock.set_schema_response(~r/determine whether the sentence can be attributed/i, %{
        "verdicts" => [
          %{"verdict" => "yes", "reason" => "Attributable."},
          %{"verdict" => "yes", "reason" => "Attributable."},
          %{"verdict" => "no", "reason" => "Not attributable."}
        ]
      })

      Mock.set_schema_response(~r/summarize a CONCISE reason for the score/i, %{
        "reason" => "Score is 0.67."
      })

      # With threshold 0.8, score of ~0.67 should fail
      assert {:ok, result2} = ContextualRecall.measure(test_case, adapter: :mock, threshold: 0.8)
      assert_in_delta result2.score, 0.667, 0.01
      assert result2.success == false
    end
  end

  describe "measure/2 without reason" do
    test "skips reason generation when include_reason is false" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{"verdicts" => [%{"verdict" => "yes", "reason" => "Attributable."}]}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          retrieval_context: ["Context"]
        )

      assert {:ok, result} =
               ContextualRecall.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 1.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes verdicts, sentence_count, and context_count in metadata" do
      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes", "reason" => "Attributed to node 1."},
            %{"verdict" => "no", "reason" => "Not found in context."}
          ]
        }
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{"reason" => "Partial recall."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "Sentence 1. Sentence 2.",
          retrieval_context: ["Context 1", "Context 2", "Context 3"]
        )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.metadata.sentence_count == 2
      assert result.metadata.context_count == 3
      assert length(result.metadata.verdicts) == 2
      assert Enum.at(result.metadata.verdicts, 0).verdict == :yes
      assert Enum.at(result.metadata.verdicts, 1).verdict == :no
    end
  end

  describe "measure/2 with context only" do
    test "does not use context as the retrieval context, as deepeval 4.3.1" do
      test_case =
        TestCase.new!(
          input: "Q",
          expected_output: "A",
          context: ["Context, not retrieval context"]
        )

      assert {:error, {:missing_params, [:retrieval_context]}} =
               ContextualRecall.measure(test_case, adapter: :mock)
    end
  end

  describe "measure/2 verdict normalisation" do
    setup do
      Mock.set_schema_response(
        ~r/summarize a CONCISE reason for the score/i,
        %{"reason" => "The score is 0.00."}
      )

      test_case =
        TestCase.new!(
          input: "Tell me about Paris",
          expected_output: "Paris is the capital of France. It has a population of 2 million.",
          retrieval_context: ["Paris is the capital city of France."]
        )

      %{test_case: test_case}
    end

    test "reads verbose verdicts by their leading word and drops unknown ones", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{
          "verdicts" => [
            %{"verdict" => "YES - node 1", "reason" => "Attributed to 1st node."},
            %{"verdict" => "partially", "reason" => "Unsure."}
          ]
        }
      )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.score === 1.0
      assert [%{verdict: :yes}] = result.metadata.verdicts
    end

    test "scores the integer 0 when no verdicts remain, as deepeval does", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/determine whether the sentence can be attributed/i,
        %{"verdicts" => [%{"verdict" => "unknown", "reason" => "?"}]}
      )

      assert {:ok, result} = ContextualRecall.measure(test_case, adapter: :mock)
      assert result.score === 0
      assert result.success == false
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
               ContextualRecall.measure(test_case, adapter: :mock)
    end

    test "returns error when retrieval_context is missing" do
      test_case = %DeepEvalEx.TestCase{
        input: "Some input",
        expected_output: "Expected output",
        retrieval_context: nil
      }

      assert {:error, {:missing_params, [:retrieval_context]}} =
               ContextualRecall.measure(test_case, adapter: :mock)
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the expected output and context" do
      assert %EvalSpec{
               evaluation_params: [:expected_output, :retrieval_context],
               questions: [
                 %Scored.Noul{statement: "Every sentence in" <> _, weight: 2.0},
                 %Scored.Noul{statement: "`retrieval_context` contains" <> _, weight: 1.0},
                 %Scored.Score{
                   levels: ["None of it", "Less than half", "Most of it", "All of it"]
                 }
               ]
             } = ContextualRecall.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid judges each sentence of the expected output yes or no" do
      Mock.set_schema_response(~r/summarize a CONCISE reason for the score/i, %{
        "reason" => "The score is 0.00 because no sentence is supported."
      })

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.49))

      test_case =
        TestCase.new!(
          input: "What is the vacation policy?",
          expected_output: "Employees get 20 days. Up to 5 days carry over!",
          retrieval_context: ["Employees receive 20 days of paid time off."]
        )

      assert {:ok, result} =
               ContextualRecall.measure(test_case,
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0
      assert [%{verdict: :no, reason: "P(yes)=0.49"}, %{verdict: :no}] = result.metadata.verdicts

      assert [%SystemOneMock.Call{questions: questions}] = SystemOneMock.calls(system_one)
      assert Enum.map(questions, &elem(&1, 0)) == ["sentence_0", "sentence_1"]
    end
  end
end
