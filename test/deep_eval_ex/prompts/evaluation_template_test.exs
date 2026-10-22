# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Prompts.EvaluationTemplateTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Faithfulness
  alias DeepEvalEx.Prompts
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  # Overrides two Faithfulness templates, one with and one without
  # arguments; the others fall back to the defaults.
  defmodule ClaimsOverride do
    @behaviour DeepEvalEx.Prompts.Faithfulness

    alias DeepEvalEx.Prompts.Faithfulness

    @impl true
    def generate_claims(opts), do: "CUSTOM CLAIMS\n" <> Faithfulness.generate_claims(opts)

    @impl true
    def system_one_verdict, do: "CUSTOM VERDICT: is `claim` in `retrieval_context`?"
  end

  defmodule QuestionsOverride do
    @behaviour DeepEvalEx.Prompts.Faithfulness

    @impl true
    def system_one_questions,
      do: ~s([{"type": "noul", "statement": "CUSTOM: `actual_output` is grounded."}])
  end

  # Every prompt module with templates a metric renders, and those templates.
  @prompt_modules %{
    Prompts.AnswerRelevancy => [
      generate_statements: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.ArgumentCorrectness => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.Bias => [
      generate_opinions: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.ContextualPrecision => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.ContextualRecall => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.ContextualRelevancy => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.Faithfulness => [
      generate_claims: 1,
      generate_truths: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.GEval => [
      generate_evaluation_steps: 1,
      generate_evaluation_results: 1,
      generate_strict_evaluation_results: 1
    ],
    Prompts.Hallucination => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.JsonCorrectness => [generate_reason: 1],
    Prompts.PIILeakage => [
      extract_pii: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ],
    Prompts.PromptAlignment => [
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 1
    ],
    Prompts.Summarization => [
      generate_questions: 1,
      generate_answers: 1,
      generate_alignment_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 1
    ],
    Prompts.ToolCorrectness => [get_tool_selection_score: 1, system_one_tool_selection_score: 0],
    Prompts.Toxicity => [
      generate_opinions: 1,
      generate_verdicts: 1,
      generate_reason: 1,
      system_one_verdict: 0,
      system_one_questions: 0
    ]
  }

  setup do
    Mock.clear_responses()
    Mock.clear_recorded_prompts()
    :ok
  end

  describe "prompt behaviours" do
    test "every prompt module's templates are its optional callbacks, with defaults" do
      for {module, templates} <- @prompt_modules do
        callbacks = module.behaviour_info(:callbacks)

        assert Enum.sort(callbacks) == Enum.sort(templates), inspect(module)
        assert Enum.sort(module.behaviour_info(:optional_callbacks)) == Enum.sort(templates)

        for {name, arity} <- templates do
          assert function_exported?(module, name, arity), "#{inspect(module)}.#{name}/#{arity}"
        end
      end
    end

    test "formatting helpers are not templates" do
      refute {:format_params, 1} in Prompts.GEval.behaviour_info(:callbacks)
      refute {:format_tools, 1} in Prompts.ToolCorrectness.behaviour_info(:callbacks)
    end
  end

  describe "render/3 and render/4" do
    test "renders the default without an :evaluation_template" do
      assert EvaluationTemplate.render([], Prompts.Faithfulness, :generate_claims,
               actual_output: "Paris is in France."
             ) == Prompts.Faithfulness.generate_claims(actual_output: "Paris is in France.")

      assert EvaluationTemplate.render(
               [evaluation_template: nil],
               Prompts.Faithfulness,
               :system_one_verdict
             ) == Prompts.Faithfulness.system_one_verdict()
    end

    test "renders the override's template where it defines one" do
      opts = [evaluation_template: ClaimsOverride]

      assert "CUSTOM CLAIMS\n" <> rest =
               EvaluationTemplate.render(opts, Prompts.Faithfulness, :generate_claims,
                 actual_output: "Paris is in France."
               )

      assert rest == Prompts.Faithfulness.generate_claims(actual_output: "Paris is in France.")

      assert EvaluationTemplate.render(opts, Prompts.Faithfulness, :system_one_verdict) ==
               "CUSTOM VERDICT: is `claim` in `retrieval_context`?"
    end

    test "falls back to the default, template by template, where the override has none" do
      opts = [evaluation_template: ClaimsOverride]

      assert EvaluationTemplate.render(opts, Prompts.Faithfulness, :generate_truths,
               retrieval_context: "Paris is in France."
             ) == Prompts.Faithfulness.generate_truths(retrieval_context: "Paris is in France.")

      assert EvaluationTemplate.render(opts, Prompts.Faithfulness, :system_one_questions) ==
               Prompts.Faithfulness.system_one_questions()
    end

    test "raises for an :evaluation_template that is not a loadable module" do
      assert_raise ArgumentError, ~r/could not be loaded/, fn ->
        EvaluationTemplate.render(
          [evaluation_template: NoSuchTemplate],
          Prompts.Faithfulness,
          :system_one_verdict
        )
      end

      assert_raise ArgumentError, ~r/must be a module/, fn ->
        EvaluationTemplate.render(
          [evaluation_template: "MyTemplate"],
          Prompts.Faithfulness,
          :system_one_verdict
        )
      end
    end
  end

  describe "a metric with an :evaluation_template" do
    defp test_case do
      TestCase.new!(
        input: "What is the vacation policy?",
        actual_output: "Employees get 20 days of PTO per year.",
        retrieval_context: ["Employees receive 20 days paid time off annually."]
      )
    end

    defp script_judge do
      Mock.set_schema_response(~r/generate a comprehensive list of.*truths/i, %{
        "truths" => ["Employees receive 20 days paid time off annually."]
      })

      Mock.set_schema_response(~r/extract a comprehensive list of FACTUAL/i, %{
        "claims" => ["Employees get 20 days of PTO per year."]
      })

      Mock.set_schema_response(~r/indicate whether EACH claim contradicts/i, %{
        "verdicts" => [%{"verdict" => "yes"}]
      })

      Mock.set_schema_response(~r/CONCISELY summarize the contradictions/i, %{
        "reason" => "The score is 1.00 because the claim is supported."
      })
    end

    test "sends the overridden prompts to the LLM and the defaults for the rest" do
      script_judge()

      assert {:ok, result} =
               Faithfulness.measure(test_case(),
                 adapter: :mock,
                 evaluation_template: ClaimsOverride
               )

      assert result.score == 1.0

      prompts = Mock.get_recorded_prompts()
      assert [claims] = Enum.filter(prompts, &(&1 =~ "CUSTOM CLAIMS"))
      assert claims =~ "extract a comprehensive list of FACTUAL"
      assert Enum.any?(prompts, &(&1 =~ "generate a comprehensive list of FACTUAL"))
      assert length(prompts) == 4
    end

    test "asks System One the overridden verdict under :hybrid" do
      script_judge()
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

      assert {:ok, _result} =
               Faithfulness.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one,
                 evaluation_template: ClaimsOverride
               )

      assert [%SystemOneMock.Call{questions: questions}] = SystemOneMock.calls(system_one)
      assert inspect(questions) =~ "CUSTOM VERDICT"
    end

    test "asks the overridden questions under :system_one" do
      assert %EvalSpec{questions: [%Scored.Noul{statement: "CUSTOM: " <> _}]} =
               Faithfulness.system_one_eval_spec(%TestCase{},
                 evaluation_template: QuestionsOverride
               )

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               Faithfulness.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :system_one,
                 system_one_model: system_one,
                 evaluation_template: QuestionsOverride
               )

      assert result.score == 0.9
      assert [%SystemOneMock.Call{questions: [_question]}] = SystemOneMock.calls(system_one)
      assert Mock.get_recorded_prompts() == []
    end
  end
end
