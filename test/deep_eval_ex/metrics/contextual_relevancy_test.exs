# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.ContextualRelevancyTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ContextualRelevancy
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @verdicts_prompt ~r/indicate whether each statement found in the context is relevant/
  @reason_prompt ~r/please generate a CONCISE reason for the score/

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case(retrieval_context) do
    TestCase.new!(
      input: "What is the capital of France?",
      actual_output: "Paris.",
      retrieval_context: retrieval_context
    )
  end

  describe "metric_name/0" do
    test "returns Contextual Relevancy" do
      assert ContextualRelevancy.metric_name() == "Contextual Relevancy"
    end
  end

  describe "required_params/0" do
    test "requires input and retrieval_context, as deepeval 4.3.1" do
      assert ContextualRelevancy.required_params() == [:input, :retrieval_context]
    end
  end

  describe "measure/2" do
    test "judges each retrieval context node in its own prompt, in order" do
      Mock.set_schema_response(~r/Context:\nParis/, %{
        "verdicts" => [
          %{"statement" => "Paris is the capital of France.", "verdict" => "yes"},
          %{
            "statement" => "There was a cat.",
            "verdict" => "no",
            "reason" => "'There was a cat' is unrelated."
          }
        ]
      })

      Mock.set_schema_response(~r/Context:\nRome/, %{
        "verdicts" => [
          %{
            "statement" => "Rome is the capital of Italy.",
            "verdict" => "no",
            "reason" => "Rome is in Italy."
          }
        ]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.33."})

      assert {:ok, result} =
               ContextualRelevancy.measure(
                 test_case([
                   "Paris is the capital of France. There was a cat.",
                   "Rome is the capital of Italy."
                 ]),
                 adapter: :mock
               )

      assert result.metric == "Contextual Relevancy"
      assert result.score == 1 / 3
      assert result.success == false
      assert result.reason == "The score is 0.33."

      assert [
               [
                 %{statement: "Paris is the capital of France.", verdict: :yes, reason: nil},
                 %{statement: "There was a cat.", verdict: :no}
               ],
               [%{statement: "Rome is the capital of Italy.", verdict: :no}]
             ] = result.metadata.verdicts

      prompts = Mock.get_recorded_prompts()
      verdict_prompts = Enum.filter(prompts, &(&1 =~ @verdicts_prompt))
      assert length(verdict_prompts) == 2

      assert Enum.at(verdict_prompts, 0) =~
               "Context:\nParis is the capital of France. There was a cat."

      assert Enum.at(verdict_prompts, 1) =~ "Context:\nRome is the capital of Italy."

      [reason_prompt] = Enum.filter(prompts, &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Contextual Relevancy Score:\n0.33"
      assert reason_prompt =~ ~s(["'There was a cat' is unrelated.", 'Rome is in Italy.'])
      assert reason_prompt =~ "['Paris is the capital of France.']"
    end

    test "scores the integer 0 when no node holds a statement, as deepeval does" do
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => []})

      assert {:ok, result} =
               ContextualRelevancy.measure(test_case(["..."]),
                 adapter: :mock,
                 include_reason: false
               )

      assert result.score === 0
      assert result.success == false
      assert result.reason == nil
      assert result.metadata.verdicts == [[]]
    end

    test "drops verdicts outside yes and no and reads verbose ones by their leading word" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"statement" => "Paris is the capital.", "verdict" => "Yes, it is"},
          %{"statement" => "Maybe.", "verdict" => "idk"}
        ]
      })

      assert {:ok, result} =
               ContextualRelevancy.measure(test_case(["Paris is the capital."]),
                 adapter: :mock,
                 include_reason: false
               )

      assert result.score === 1.0
      assert [[%{statement: "Paris is the capital.", verdict: :yes}]] = result.metadata.verdicts
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"statement" => "A.", "verdict" => "yes"},
          %{"statement" => "B.", "verdict" => "no", "reason" => "Off topic."}
        ]
      })

      assert {:ok, result} =
               ContextualRelevancy.measure(test_case(["A. B."]),
                 adapter: :mock,
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.threshold == 1
    end

    test "writes deepeval's verbose logs: one verdicts model per node" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"statement" => "Paris is the capital.", "verdict" => "yes"}]
      })

      assert {:ok, result} =
               ContextualRelevancy.measure(test_case(["Paris is the capital."]),
                 adapter: :mock,
                 include_reason: false
               )

      assert result.verbose_logs ==
               """
               Verdicts:
               [
                   {
                       "verdicts": [
                           {
                               "statement": "Paris is the capital.",
                               "verdict": "yes",
                               "reason": null
                           }
                       ]
                   }
               ]\
               """
    end

    test "returns an error when retrieval_context is missing" do
      test_case = %TestCase{input: "Q", actual_output: "A", retrieval_context: nil}

      assert {:error, {:missing_params, [:retrieval_context]}} =
               ContextualRelevancy.measure(test_case, adapter: :mock)
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the input and context" do
      assert %EvalSpec{
               evaluation_params: [:input, :retrieval_context],
               questions: [
                 %Scored.Noul{statement: "Every statement in" <> _, weight: 2.0},
                 %Scored.Noul{statement: "Every node in" <> _, weight: 1.0},
                 %Scored.Score{
                   levels: ["None of it", "Less than half", "Most of it", "All of it"]
                 }
               ]
             } = ContextualRelevancy.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid asks one request per node about its sentences, with deepeval's reasons" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.49))

      assert {:ok, result} =
               ContextualRelevancy.measure(
                 test_case(["Rome is in Italy. Cats purr!", "Bonjour."]),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0

      assert [
               [
                 %{
                   statement: "Rome is in Italy.",
                   verdict: :no,
                   reason: "'Rome is in Italy.' is not relevant to the input (P(yes)=0.49)."
                 },
                 %{statement: "Cats purr!", verdict: :no}
               ],
               [%{statement: "Bonjour.", verdict: :no}]
             ] = result.metadata.verdicts

      assert [first, second] = SystemOneMock.calls(system_one)
      assert Enum.map(first.questions, &elem(&1, 0)) == ["statement_0", "statement_1"]
      assert Enum.map(second.questions, &elem(&1, 0)) == ["statement_0"]
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "hybrid gives a relevant statement only its P(yes) as the reason" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 1.00."})
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.5))

      assert {:ok, result} =
               ContextualRelevancy.measure(test_case(["Paris is the capital."]),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert [[%{statement: "Paris is the capital.", verdict: :yes, reason: "P(yes)=0.50"}]] =
               result.metadata.verdicts
    end
  end

  describe "measure/2 with RetrievedContextData" do
    # deepeval 4.3.1 raises a TypeError splitting a RetrievedContextData into
    # sentences; DeepEvalEx judges its serialised form instead.
    test "judges each RetrievedContextData as 'source: context'" do
      Mock.script(%{
        "verdicts" => [
          %{"verdicts" => [%{"statement" => "Paris is in France.", "verdict" => "yes"}]},
          %{"verdicts" => [%{"statement" => "Lyon is in France.", "verdict" => "yes"}]}
        ],
        "reason" => [%{"reason" => "The score is 1.00 because every statement is relevant."}]
      })

      test_case =
        TestCase.new!(
          input: "Where is Paris?",
          retrieval_context: [
            %DeepEvalEx.Schemas.RetrievedContextData{
              context: "Paris is in France.",
              source: "wiki"
            },
            "Lyon is in France."
          ]
        )

      assert {:ok, result} = ContextualRelevancy.measure(test_case, adapter: :mock)
      assert result.score == 1.0

      assert [first, second] =
               for(%{step: "verdicts", prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

      assert first =~ "Context:\nwiki: Paris is in France."
      assert second =~ "Context:\nLyon is in France."
    end
  end
end
