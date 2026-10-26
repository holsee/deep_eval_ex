# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.SummarizationTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.Evaluator
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Summarization
  alias DeepEvalEx.Prompts.Faithfulness, as: FaithfulnessPrompts
  alias DeepEvalEx.Prompts.Summarization, as: SummarizationPrompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @original "The council approved a new park. It opens in May and has a lake."
  @summary "The council approved a park with a lake."

  @truths_prompt ~r/please generate a comprehensive list of/
  @claims_prompt ~r/inferred from the provided actual AI output/
  @questions_prompt ~r/closed-ended questions that can be answered/
  @original_answers_prompt ~r/Text:\nThe council approved a new park\. It opens in May and has a lake\.\n\nQuestions:/
  @summary_answers_prompt ~r/Text:\nThe council approved a park with a lake\.\n\nQuestions:/
  @verdicts_prompt ~r/whether EACH piece of info contradicts any facts in the original text/
  @reason_prompt ~r/Your task is to explain the quality of this summarization task/

  @questions ["Was a new park approved?", "Does it open in May?", "Does it have a lake?"]

  setup do
    Mock.clear_responses()
    Mock.clear_recorded_prompts()
    :ok
  end

  defp test_case(summary \\ @summary) do
    TestCase.new!(input: @original, actual_output: summary)
  end

  # The judge's answers for the original text and the summary, a truth and
  # claims and their verdicts, and the reason.
  defp script_judge(opts \\ []) do
    Mock.set_schema_response(@truths_prompt, %{
      "truths" => ["The council approved a new park.", "The park opens in May."]
    })

    Mock.set_schema_response(@claims_prompt, %{
      "claims" => Keyword.get(opts, :claims, ["The council approved a park.", "It has a lake."])
    })

    Mock.set_schema_response(@questions_prompt, %{"questions" => @questions})

    Mock.set_schema_response(@original_answers_prompt, %{
      "answers" => Keyword.get(opts, :original_answers, ["yes", "yes", "yes"])
    })

    Mock.set_schema_response(@summary_answers_prompt, %{
      "answers" => Keyword.get(opts, :summary_answers, [" Yes", "no", "yes"])
    })

    Mock.set_schema_response(@verdicts_prompt, %{
      "verdicts" =>
        Keyword.get(opts, :verdicts, [
          %{"verdict" => "yes"},
          %{"verdict" => "borderline", "reason" => "The lake is not mentioned."}
        ])
    })

    Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.50."})
  end

  defp prompt(pattern) do
    [prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ pattern))
    prompt
  end

  describe "metric_name/0" do
    test "returns deepeval's name, Summarization" do
      assert Summarization.metric_name() == "Summarization"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output, as deepeval 4.3.1" do
      assert Summarization.required_params() == [:input, :actual_output]
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert Summarization.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the lower of the alignment and coverage scores" do
      script_judge()

      assert {:ok, result} = Summarization.measure(test_case(), adapter: :mock)

      # Alignment: 1 of 2 claims agrees (borderline fails). Coverage: 2 of 3
      # questions the original answers, the summary answers too.
      assert result.metric == "Summarization"
      assert result.score === 0.5
      assert result.score_breakdown == %{"Alignment" => 0.5, "Coverage" => 2 / 3}
      assert result.success == true
      assert result.reason == "The score is 0.50."

      assert result.metadata.assessment_questions == @questions

      assert result.metadata.coverage_verdicts == [
               %{summary_verdict: " Yes", original_verdict: "yes", question: hd(@questions)},
               %{
                 summary_verdict: "no",
                 original_verdict: "yes",
                 question: "Does it open in May?"
               },
               %{
                 summary_verdict: "yes",
                 original_verdict: "yes",
                 question: "Does it have a lake?"
               }
             ]

      assert [%{verdict: :yes}, %{verdict: :borderline}] = result.metadata.alignment_verdicts
    end

    test "builds its prompts as deepeval's metric does" do
      script_judge()

      assert {:ok, _result} = Summarization.measure(test_case(), adapter: :mock, n: 3)

      # The truths of the input, not joined: deepeval borrows Faithfulness's
      # template with the input as the retrieval context.
      assert prompt(@truths_prompt) =~ "Text:\n#{@original}\n\nJSON:"
      assert prompt(@claims_prompt) =~ "AI Output:\n#{@summary}\n\nJSON:"
      assert prompt(@questions_prompt) =~ "generate 3 closed-ended questions"
      assert prompt(@questions_prompt) =~ "Text:\n#{@original}\n\nJSON:"

      assert prompt(@original_answers_prompt) =~
               "Questions:\n['Was a new park approved?', 'Does it open in May?', " <>
                 "'Does it have a lake?']\n\nJSON:"

      assert prompt(@verdicts_prompt) =~
               "Original Text:\nThe council approved a new park.\n\nThe park opens in May.\n\n" <>
                 "Summary Claims:\n['The council approved a park.', 'It has a lake.']\n\nJSON:"

      assert String.ends_with?(
               prompt(@reason_prompt),
               "Summarization Score:\n0.50\n\n" <>
                 "Contradicting Information in the original text:\n[]\n\n" <>
                 "Extra Information not mentioned in the original text:\n" <>
                 "['The lake is not mentioned.']" <>
                 "Questions the original text can answer but not the summary:\n" <>
                 "['Does it open in May?']\n\nJSON:\n"
             )
    end

    test "asks no questions when given assessment questions" do
      script_judge()

      assert {:ok, result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 assessment_questions: @questions
               )

      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @questions_prompt))
      assert result.metadata.assessment_questions == @questions
    end

    test "generates questions when given an empty list, as deepeval reads [] as None" do
      script_judge()

      assert {:ok, _result} =
               Summarization.measure(test_case(), adapter: :mock, assessment_questions: [])

      assert prompt(@questions_prompt) =~ "generate 5 closed-ended questions"
    end

    test "scores alignment the integer 0 when the summary has no claims" do
      script_judge(claims: [])

      assert {:ok, result} = Summarization.measure(test_case(), adapter: :mock)

      assert result.score === 0
      assert result.score_breakdown == %{"Alignment" => 0, "Coverage" => 2 / 3}
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "scores coverage the integer 0 when the original answers no question" do
      script_judge(original_answers: ["no", "no", "no"])

      assert {:ok, result} = Summarization.measure(test_case(), adapter: :mock)

      assert result.score_breakdown == %{"Alignment" => 0.5, "Coverage" => 0}
      assert result.score === 0
    end

    test "keeps the alignment score when both are equal, as Python's min" do
      script_judge(
        verdicts: [%{"verdict" => "yes"}, %{"verdict" => "yes"}],
        summary_answers: ["yes", "yes", "yes"]
      )

      assert {:ok, result} = Summarization.measure(test_case(), adapter: :mock)

      assert result.score_breakdown == %{"Alignment" => 1.0, "Coverage" => 1.0}
      assert result.score === 1.0
    end

    test "clamps scores below the threshold to 0 in strict mode" do
      script_judge()

      assert {:ok, result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.score_breakdown == %{"Alignment" => 0, "Coverage" => 0}
      assert result.threshold == 1
      assert result.reason == nil
    end

    test "lists contradictions and redundancies, None included, in the reason prompt" do
      script_judge(
        verdicts: [
          %{"verdict" => "no"},
          %{"verdict" => "borderline", "reason" => "Not in the original."}
        ],
        summary_answers: ["yes", "yes", "yes"]
      )

      assert {:ok, _result} = Summarization.measure(test_case(), adapter: :mock)

      assert String.ends_with?(
               prompt(@reason_prompt),
               "Contradicting Information in the original text:\n[None]\n\n" <>
                 "Extra Information not mentioned in the original text:\n" <>
                 "['Not in the original.']JSON:\n"
             )
    end

    test "errors when the two lists of answers differ in length, as deepeval" do
      script_judge(summary_answers: ["yes"])

      assert {:error, %ArgumentError{message: "Number of verdicts generated does not equal."}} =
               Summarization.measure(test_case(), adapter: :mock)
    end

    test "writes deepeval's verbose logs" do
      script_judge()

      assert {:ok, result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 include_reason: false,
                 truths_extraction_limit: -2
               )

      assert result.verbose_logs ==
               ~s|Truths (limit=0):\n[\n    "The council approved a new park.",\n| <>
                 ~s|    "The park opens in May."\n] \n \n| <>
                 ~s|Claims:\n[\n    "The council approved a park.",\n    "It has a lake."\n] \n \n| <>
                 ~s|Assessment Questions:\n[\n    "Was a new park approved?",\n| <>
                 ~s|    "Does it open in May?",\n    "Does it have a lake?"\n] \n \n| <>
                 ~s|Coverage Verdicts:\n[\n    {\n        "summary_verdict": " Yes",\n| <>
                 ~s|        "original_verdict": "yes",\n| <>
                 ~s|        "question": "Was a new park approved?"\n    },\n| <>
                 ~s|    {\n        "summary_verdict": "no",\n| <>
                 ~s|        "original_verdict": "yes",\n| <>
                 ~s|        "question": "Does it open in May?"\n    },\n| <>
                 ~s|    {\n        "summary_verdict": "yes",\n| <>
                 ~s|        "original_verdict": "yes",\n| <>
                 ~s|        "question": "Does it have a lake?"\n    }\n] \n \n| <>
                 ~s|Alignment Verdicts:\n[\n    {\n        "verdict": "yes",\n| <>
                 ~s|        "reason": null\n    },\n    {\n        "verdict": "borderline",\n| <>
                 ~s|        "reason": "The lake is not mentioned."\n    }\n]|

      assert prompt(@truths_prompt) =~ " the 0 most important FACTUAL, undisputed truths"
    end

    test "returns an error when actual_output is missing" do
      test_case = %TestCase{input: "Q", actual_output: nil}

      assert {:error, {:missing_params, [:actual_output]}} =
               Summarization.measure(test_case, adapter: :mock)
    end
  end

  describe "new/1" do
    test "builds a configured metric whose fields override the run's options" do
      script_judge()
      metric = Summarization.new(assessment_questions: @questions, n: 2)

      assert %Summarization{assessment_questions: @questions, n: 2, threshold: 0.5} = metric

      result =
        Evaluator.evaluate_metric(test_case(), metric,
          adapter: :mock,
          assessment_questions: ["Ignored?"]
        )

      assert result.metadata.assessment_questions == @questions
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @questions_prompt))
    end
  end

  defmodule TemplateOverride do
    @behaviour SummarizationPrompts

    @impl true
    def generate_questions(opts),
      do: "CUSTOM QUESTIONS\n" <> SummarizationPrompts.generate_questions(opts)

    # Not a Summarization template: the claims prompt is borrowed from
    # Faithfulness, which an override must not hijack.
    def generate_claims(_opts), do: "HIJACKED CLAIMS"
  end

  describe ":evaluation_template" do
    test "overrides Summarization templates but not those borrowed from Faithfulness" do
      script_judge()

      assert {:ok, _result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 evaluation_template: TemplateOverride
               )

      assert prompt(@questions_prompt) =~ ~r/^CUSTOM QUESTIONS\n/

      assert prompt(@claims_prompt) ==
               FaithfulnessPrompts.generate_claims(actual_output: @summary)

      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ "HIJACKED"))
    end

    test "configures a metric built with new/1" do
      script_judge()
      metric = Summarization.new(evaluation_template: TemplateOverride)

      assert %Summarization{evaluation_template: TemplateOverride} = metric
      Evaluator.evaluate_metric(test_case(), metric, adapter: :mock)

      assert prompt(@questions_prompt) =~ ~r/^CUSTOM QUESTIONS\n/
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions, one Noul per assessment question" do
      assert %EvalSpec{
               evaluation_params: [:input, :actual_output],
               questions: [
                 %Scored.Noul{statement: "Every claim in the summary" <> _, weight: 2.0},
                 %Scored.Noul{statement: "The summary `actual_output` covers" <> _},
                 %Scored.Score{
                   levels: ["Almost none", "Less than half", "Most of it", "All of it"]
                 },
                 %Scored.Noul{statement: statement}
               ]
             } =
               Summarization.system_one_eval_spec(%TestCase{},
                 assessment_questions: ["Is it <ok>?"]
               )

      assert statement ==
               "Reading only the summary `actual_output`, this question can be answered the " <>
                 "same way as from the original text `input`: Is it <ok>?"

      assert %EvalSpec{questions: [_, _, _]} = Summarization.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid asks whether each claim agrees with the truths; coverage stays with the LLM" do
      script_judge()
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      assert {:ok, result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert [%{verdict: :yes, reason: "P(yes)=0.90"}, %{verdict: :yes}] =
               result.metadata.alignment_verdicts

      assert result.score_breakdown == %{"Alignment" => 1.0, "Coverage" => 2 / 3}

      assert [%SystemOneMock.Call{state: state, questions: questions}] =
               SystemOneMock.calls(system_one)

      assert Enum.map(questions, &elem(&1, 0)) == ["summary_claim_0", "summary_claim_1"]

      assert state |> Jason.encode!() |> Jason.decode!() == %{
               "original_text" => ["The council approved a new park.", "The park opens in May."],
               "summary_claims" => ["The council approved a park.", "It has a lake."]
             }

      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "system_one answers the whole metric without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               Summarization.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      assert result.success
      assert result.evaluation_model == "fake-jev"
      assert [%SystemOneMock.Call{}] = SystemOneMock.calls(system_one)
      assert Mock.get_recorded_prompts() == []
    end
  end
end
