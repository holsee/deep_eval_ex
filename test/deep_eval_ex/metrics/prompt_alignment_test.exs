# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.PromptAlignmentTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.PromptAlignment
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @verdicts_prompt ~r/determine whether each instruction has been followed/
  @reason_prompt ~r/Given the prompt alignment score/

  @instructions ["Reply in English.", "Respond in all upper case."]

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case do
    TestCase.new!(
      input: "What is the capital of France?",
      actual_output: "The capital of France is Paris."
    )
  end

  describe "metric_name/0" do
    test "returns deepeval's name, Prompt Alignment" do
      assert PromptAlignment.metric_name() == "Prompt Alignment"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output, as deepeval 4.3.1" do
      assert PromptAlignment.required_params() == [:input, :actual_output]
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert PromptAlignment.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the share of instructions followed" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"verdict" => "yes"},
          %{"verdict" => "no", "reason" => "Not upper case."}
        ]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.50."})

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions
               )

      assert result.metric == "Prompt Alignment"
      assert result.score === 0.5
      assert result.success == true
      assert result.reason == "The score is 0.50."
      assert result.metadata.prompt_instructions == @instructions

      assert [%{verdict: :yes, reason: nil}, %{verdict: :no, reason: "Not upper case."}] =
               result.metadata.verdicts

      prompts = Mock.get_recorded_prompts()
      [verdicts_prompt] = Enum.filter(prompts, &(&1 =~ @verdicts_prompt))

      assert verdicts_prompt =~
               "Prompt Instructions:\n['Reply in English.', 'Respond in all upper case.']\n\n" <>
                 "Input:\nWhat is the capital of France?\n\n" <>
                 "LLM Actual Output:\nThe capital of France is Paris.\n\nJSON:"

      [reason_prompt] = Enum.filter(prompts, &(&1 =~ @reason_prompt))

      assert reason_prompt =~
               "Prompt Alignment Score:\n0.50\n\nReasons for unalignment:\n['Not upper case.']"
    end

    test "lists a broken instruction without a reason as None in the reason prompt" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "no"}, %{"verdict" => "no", "reason" => "Lower case."}]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions
               )

      assert result.score === 0.0
      assert result.success == false

      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Reasons for unalignment:\n[None, 'Lower case.']"
    end

    test "scores the integer 1 when the judge returns no verdicts" do
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => []})

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions,
                 include_reason: false
               )

      assert result.score === 1
      assert result.success == true
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no", "reason" => "Lower case."}]
      })

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions,
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.threshold == 1
    end

    test "writes deepeval's verbose logs: the prompt instructions, then the verdicts" do
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => [%{"verdict" => "yes"}]})

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: ["Reply in English."],
                 include_reason: false
               )

      assert result.verbose_logs ==
               "Prompt Instructions:\n[\n    \"Reply in English.\"\n] \n \nVerdicts:\n" <>
                 "[\n    {\n        \"verdict\": \"yes\",\n        \"reason\": null\n    }\n]"
    end

    test "raises ArgumentError, as deepeval's constructor raises ValueError, without instructions" do
      for opts <- [[], [prompt_instructions: []]] do
        assert_raise ArgumentError, "'prompt_instructions' must not be empty.", fn ->
          PromptAlignment.measure(test_case(), [adapter: :mock] ++ opts)
        end
      end
    end
  end

  describe "new/1" do
    test "builds a metric evaluate/3 measures with its own instructions" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no", "reason" => "Lower case."}]
      })

      metric = PromptAlignment.new(prompt_instructions: @instructions, include_reason: false)

      assert %PromptAlignment{prompt_instructions: @instructions, threshold: 0.5} = metric

      assert {[[result]], _test_run, _path} =
               DeepEvalEx.evaluate_run([test_case()], [metric], adapter: :mock)

      assert result.metric == "Prompt Alignment"
      assert result.score === 0.5
      assert result.reason == nil

      [verdicts_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
      assert verdicts_prompt =~ "['Reply in English.', 'Respond in all upper case.']"
    end

    test "raises ArgumentError without instructions" do
      assert_raise ArgumentError, "'prompt_instructions' must not be empty.", fn ->
        PromptAlignment.new(prompt_instructions: [])
      end
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks one Noul per instruction about input and actual_output" do
      assert %EvalSpec{
               evaluation_params: [:input, :actual_output],
               questions: [
                 %Scored.Noul{statement: first, weight: 1.0},
                 %Scored.Noul{statement: second}
               ]
             } =
               PromptAlignment.system_one_eval_spec(%TestCase{},
                 prompt_instructions: ["Use <b> & 'quotes'.", "Be brief."]
               )

      assert first ==
               "`actual_output` completely follows this prompt instruction when responding " <>
                 "to `input`: Use <b> & 'quotes'."

      assert second =~ ~r/: Be brief\.$/
    end

    test "hybrid asks whether each instruction is followed; P(yes) of 0.5 and above follows it" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 1.00."})

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.5))

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0

      assert [%{verdict: :yes, reason: "P(yes)=0.50"}, %{verdict: :yes}] =
               result.metadata.verdicts

      assert [%SystemOneMock.Call{state: state, questions: questions}] =
               SystemOneMock.calls(system_one)

      assert Enum.map(questions, &elem(&1, 0)) == ["instruction_0", "instruction_1"]

      assert state |> Jason.encode!() |> Jason.decode!() == %{
               "input" => "What is the capital of France?",
               "actual_output" => "The capital of France is Paris.",
               "instructions" => @instructions
             }

      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "system_one answers the whole metric without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               PromptAlignment.measure(test_case(),
                 adapter: :mock,
                 prompt_instructions: @instructions,
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      assert result.success
      assert result.evaluation_model == "fake-jev"
      assert [%SystemOneMock.Call{questions: questions}] = SystemOneMock.calls(system_one)
      assert length(questions) == 2
    end
  end
end
