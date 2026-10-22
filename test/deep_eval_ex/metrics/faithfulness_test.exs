# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.FaithfulnessTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Faithfulness
  alias DeepEvalEx.TestCase

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "metric_name/0" do
    test "returns Faithfulness" do
      assert Faithfulness.metric_name() == "Faithfulness"
    end
  end

  describe "required_params/0" do
    test "requires input, actual_output, and retrieval_context" do
      assert Faithfulness.required_params() == [:input, :actual_output, :retrieval_context]
    end
  end

  describe "measure/2 with perfect faithfulness" do
    test "returns score 1.0 when all claims are supported" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{
          "truths" => [
            "Employees receive 20 days paid time off annually.",
            "PTO can be carried over up to 5 days."
          ]
        }
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{
          "claims" => [
            "Employees get 20 days of PTO per year."
          ]
        }
      )

      # Mock verdicts - claim is supported
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "The score is 1.0 because all claims are supported by the context."}
      )

      test_case =
        TestCase.new!(
          input: "What is the company's vacation policy?",
          actual_output: "Employees get 20 days of PTO per year.",
          retrieval_context: [
            "Section 3.2: Full-time employees receive 20 days paid time off annually.",
            "Section 3.3: PTO can be carried over up to 5 days."
          ]
        )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.score == 1.0
      assert result.metric == "Faithfulness"
      assert result.reason =~ "1.0"
    end
  end

  describe "measure/2 with unfaithful claims" do
    test "returns score 0.0 when all claims contradict context" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{
          "truths" => [
            "The company was founded in 2010.",
            "Headquarters are in San Francisco."
          ]
        }
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{
          "claims" => [
            "The company was founded in 1995."
          ]
        }
      )

      # Mock verdicts - claim contradicts context
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "The context says 2010, not 1995."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{
          "reason" =>
            "The score is 0.0 because the claim about founding year contradicts the context."
        }
      )

      test_case =
        TestCase.new!(
          input: "When was the company founded?",
          actual_output: "The company was founded in 1995.",
          retrieval_context: [
            "The company was founded in 2010.",
            "Headquarters are located in San Francisco."
          ]
        )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.score == 0.0

      assert result.metadata.verdicts == [
               %{verdict: :no, reason: "The context says 2010, not 1995."}
             ]
    end

    test "returns partial score when some claims are supported" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{
          "truths" => [
            "Python is a programming language.",
            "Python was created by Guido van Rossum."
          ]
        }
      )

      # Mock claims extraction - 2 claims
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{
          "claims" => [
            "Python is a programming language.",
            "Python was created in 2020."
          ]
        }
      )

      # Mock verdicts - first supported, second not
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "no", "reason" => "Context says Guido created it, no mention of 2020."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "The score is 0.5 because one of two claims contradicts the context."}
      )

      test_case =
        TestCase.new!(
          input: "What is Python?",
          actual_output: "Python is a programming language created in 2020.",
          retrieval_context: [
            "Python is a programming language.",
            "Python was created by Guido van Rossum."
          ]
        )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      # 1 supported out of 2
      assert result.score == 0.5
    end
  end

  describe "measure/2 with borderline verdicts" do
    setup do
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["The API supports JSON responses."]}
      )

      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{
          "claims" => [
            "The API supports JSON responses.",
            "The API also supports XML."
          ]
        }
      )

      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{
          "reason" =>
            "The score is 1.0. One claim is supported, and another cannot be verified but doesn't contradict."
        }
      )

      test_case =
        TestCase.new!(
          input: "What formats does the API support?",
          actual_output: "The API supports JSON and XML responses.",
          retrieval_context: ["The API supports JSON responses."]
        )

      %{test_case: test_case}
    end

    test "treats borderline verdicts as faithful (not contradicting)", %{test_case: test_case} do
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{
              "verdict" => "borderline",
              "reason" => "XML support is not mentioned in the context."
            }
          ]
        }
      )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.score === 1.0
      assert [%{verdict: :yes}, %{verdict: :borderline}] = result.metadata.verdicts
    end

    test "reads the legacy idk verdict as borderline", %{test_case: test_case} do
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "no", "reason" => "Contradicts."},
            %{"verdict" => "idk", "reason" => "XML support is not mentioned in the context."}
          ]
        }
      )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.score === 0.5
      assert [%{verdict: :no}, %{verdict: :borderline}] = result.metadata.verdicts
    end

    test "counts borderline verdicts as unfaithful with penalize_ambiguous_claims", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{
              "verdict" => "borderline",
              "reason" => "XML support is not mentioned in the context."
            }
          ]
        }
      )

      assert {:ok, result} =
               Faithfulness.measure(test_case, adapter: :mock, penalize_ambiguous_claims: true)

      assert result.score === 0.5
    end

    test "lists ambiguous claims as contradictions in the reason prompt only when penalized", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "borderline", "reason" => "XML is not mentioned."},
            %{"verdict" => "no", "reason" => "Contradicts."},
            %{"verdict" => "borderline"}
          ]
        }
      )

      reason_prompt = fn opts ->
        Mock.clear_recorded_prompts()
        assert {:ok, _result} = Faithfulness.measure(test_case, [adapter: :mock] ++ opts)
        Enum.find(Mock.get_recorded_prompts(), &(&1 =~ "CONCISELY summarize"))
      end

      penalized = reason_prompt.(penalize_ambiguous_claims: true)

      # In verdict order, with deepeval's f-string of a missing reason.
      assert penalized =~
               ~s"['(Ambiguous) XML is not mentioned.', 'Contradicts.', '(Ambiguous) None']"

      assert reason_prompt.([]) =~ ~s"['Contradicts.']"
      refute reason_prompt.([]) =~ "Ambiguous"
    end

    test "drops unknown verdicts instead of counting them as faithful", %{
      test_case: test_case
    } do
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "No, the context says otherwise.", "reason" => "Contradicts."},
            %{"verdict" => "unsure", "reason" => "?"}
          ]
        }
      )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.score === 0.0
      assert [%{verdict: :no}] = result.metadata.verdicts
    end
  end

  describe "measure/2 with no claims" do
    test "returns score 1 when no claims extracted" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{
          "truths" => [
            "Some fact from context."
          ]
        }
      )

      # Mock claims extraction - no claims
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => []}
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "The score is 1.0 because there are no claims to verify."}
      )

      test_case =
        TestCase.new!(
          input: "Hello",
          # No factual claims
          actual_output: "Hi there!",
          retrieval_context: ["Some fact from context."]
        )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      # No claims = perfectly faithful; deepeval's QAG scoring returns the integer 1
      assert result.score === 1
    end
  end

  describe "measure/2 with threshold" do
    test "result success is based on threshold" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Fact 1"]}
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )

      # Mock verdicts - 1 supported, 1 contradicted
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{
          "verdicts" => [
            %{"verdict" => "yes"},
            %{"verdict" => "no", "reason" => "Contradicts context."}
          ]
        }
      )

      # Mock reason generation
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Score is 0.5."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context"]
        )

      # With default threshold 0.5, score of 0.5 should pass
      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock, threshold: 0.5)
      assert result.score == 0.5
      assert result.success == true

      Mock.clear_responses()

      # Re-mock everything for second assertion
      Mock.set_schema_response(~r/generate a comprehensive list of.*truths/i, %{
        "truths" => ["Fact 1"]
      })

      Mock.set_schema_response(~r/extract a comprehensive list of FACTUAL/i, %{
        "claims" => ["Claim 1", "Claim 2"]
      })

      Mock.set_schema_response(~r/indicate whether EACH claim contradicts/i, %{
        "verdicts" => [
          %{"verdict" => "yes"},
          %{"verdict" => "no", "reason" => "Contradicts context."}
        ]
      })

      Mock.set_schema_response(~r/CONCISELY summarize the contradictions/i, %{
        "reason" => "Score is 0.5."
      })

      # With threshold 0.7, score of 0.5 should fail
      assert {:ok, result2} = Faithfulness.measure(test_case, adapter: :mock, threshold: 0.7)
      assert result2.score == 0.5
      assert result2.success == false
    end
  end

  describe "measure/2 without reason" do
    test "skips reason generation when include_reason is false" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Fact"]}
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context"]
        )

      assert {:ok, result} =
               Faithfulness.measure(test_case, adapter: :mock, include_reason: false)

      assert result.score == 1.0
      assert is_nil(result.reason)
    end
  end

  describe "measure/2 metadata" do
    test "includes truths, claims, and verdicts in metadata" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1", "Truth 2"]}
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "All good."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context"]
        )

      assert {:ok, result} = Faithfulness.measure(test_case, adapter: :mock)
      assert result.metadata.truths == ["Truth 1", "Truth 2"]
      assert result.metadata.claims == ["Claim 1"]
      assert result.metadata.verdicts == [%{verdict: :yes, reason: nil}]
    end
  end

  describe "measure/2 with truths_extraction_limit" do
    test "respects truths_extraction_limit option" do
      # Mock truths extraction
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Limited truth"]}
      )

      # Mock claims extraction
      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Good."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Lots of context here."]
        )

      assert {:ok, result} =
               Faithfulness.measure(test_case,
                 adapter: :mock,
                 truths_extraction_limit: 5
               )

      assert result.metadata.truths_extraction_limit == 5
    end
  end

  describe "measure/2 validation" do
    test "returns error when retrieval_context is missing" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A"
          # No retrieval_context
        )

      assert {:error, {:missing_params, [:retrieval_context]}} =
               Faithfulness.measure(test_case, adapter: :mock)
    end
  end

  describe "measure/2 with context only" do
    test "does not use context as the retrieval context, as deepeval 4.3.1" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          context: ["Context, not retrieval context"]
        )

      assert {:error, {:missing_params, [:retrieval_context]}} =
               Faithfulness.measure(test_case, adapter: :mock)
    end
  end

  describe "measure/2 usage" do
    setup do
      saved = Application.get_env(:deep_eval_ex, :model_pricing)

      Application.put_env(:deep_eval_ex, :model_pricing, %{
        "mock-model" => %{input: 1.0, output: 2.0}
      })

      on_exit(fn ->
        if saved,
          do: Application.put_env(:deep_eval_ex, :model_pricing, saved),
          else: Application.delete_env(:deep_eval_ex, :model_pricing)
      end)
    end

    test "accumulates tokens and cost across every LLM call, including concurrent ones" do
      Mock.set_schema_response(~r/generate a comprehensive list of.*truths/i, %{"truths" => ["T"]})

      Mock.set_schema_response(~r/extract a comprehensive list of FACTUAL/i, %{"claims" => ["C"]})

      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      Mock.set_schema_response(~r/CONCISELY summarize the contradictions/i, %{"reason" => "Ok."})

      test_case = TestCase.new!(input: "Q", actual_output: "A", retrieval_context: ["C"])

      assert {:ok, result} =
               Faithfulness.measure(test_case,
                 adapter: :mock,
                 mock_usage: [input_tokens: 100_000, output_tokens: 10_000]
               )

      # truths + claims (concurrent tasks) + verdicts + reason = 4 calls
      assert result.evaluation_model == "mock-model"
      assert result.input_tokens == 400_000
      assert result.output_tokens == 40_000
      assert_in_delta result.evaluation_cost, 4 * (0.1 + 0.02), 1.0e-9
    end

    test "reports the judge model with unknown tokens and cost when usage is not reported" do
      Mock.set_schema_response(~r/generate a comprehensive list of.*truths/i, %{"truths" => ["T"]})

      Mock.set_schema_response(~r/extract a comprehensive list of FACTUAL/i, %{"claims" => []})

      test_case = TestCase.new!(input: "Q", actual_output: "A", retrieval_context: ["C"])

      assert {:ok, result} =
               Faithfulness.measure(test_case, adapter: :mock, include_reason: false)

      assert result.evaluation_model == "mock-model"
      assert result.input_tokens == nil
      assert result.output_tokens == nil
      assert result.evaluation_cost == nil
    end
  end
end
