# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.ArgumentCorrectnessTest do
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ArgumentCorrectness
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @verdicts_prompt ~r/determine whether each tool call input parameter/
  @reason_prompt ~r/Given the argument correctness score/

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case(tools_called \\ default_tools()) do
    TestCase.new!(input: "Book a table for two on Friday.", tools_called: tools_called)
  end

  defp default_tools do
    [
      %ToolCall{name: "restaurant_search", input_parameters: %{"party_size" => 2}},
      %ToolCall{
        name: "book_table",
        input_parameters: %{"day" => "Saturday"},
        output: "Booked"
      }
    ]
  end

  describe "metric_name/0" do
    test "returns deepeval's name, Argument Correctness" do
      assert ArgumentCorrectness.metric_name() == "Argument Correctness"
    end
  end

  describe "required_params/0" do
    test "requires input and tools_called, as deepeval 4.3.1" do
      assert ArgumentCorrectness.required_params() == [:input, :tools_called]
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert ArgumentCorrectness.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the share of tool calls with correct arguments, higher is better" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"verdict" => "yes"},
          %{"verdict" => "no", "reason" => "It books Saturday, not Friday."}
        ]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.50."})

      assert {:ok, result} = ArgumentCorrectness.measure(test_case(), adapter: :mock)

      assert result.metric == "Argument Correctness"
      assert result.score === 0.5
      assert result.success == true
      assert result.reason == "The score is 0.50."

      assert [
               %{verdict: :yes, reason: nil},
               %{verdict: :no, reason: "It books Saturday, not Friday."}
             ] = result.metadata.verdicts

      prompts = Mock.get_recorded_prompts()
      [verdicts_prompt] = Enum.filter(prompts, &(&1 =~ @verdicts_prompt))

      # Each tool call as deepeval's ToolCall.__repr__, in a Python list.
      assert verdicts_prompt =~
               ~s"""
               Tool Calls:
               [ToolCall(
                   name="restaurant_search",
                   type="FUNCTION",
                   input_parameters={
                       "party_size": 2
                   }
               ), ToolCall(
                   name="book_table",
                   type="FUNCTION",
                   input_parameters={
                       "day": "Saturday"
                   },
                   output='Booked'
               )]

               JSON:\
               """

      [reason_prompt] = Enum.filter(prompts, &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Argument Correctness Score:\n0.50\n"
      assert reason_prompt =~ "incorrect tool calls:\n['It books Saturday, not Friday.']\n"
    end

    test "lists a no verdict without a reason as None in the reason prompt" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "no"}, %{"verdict" => "no", "reason" => "Wrong day."}]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      assert {:ok, result} = ArgumentCorrectness.measure(test_case(), adapter: :mock)

      assert result.score === 0.0
      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "incorrect tool calls:\n[None, 'Wrong day.']\n"
    end

    test "scores the float 1.0 with deepeval's reason and calls no judge for no tool calls" do
      assert {:ok, result} = ArgumentCorrectness.measure(test_case([]), adapter: :mock)

      assert result.score === 1.0
      assert result.success == true
      assert result.reason == "No tool calls provided"
      assert result.metadata.verdicts == []
      assert result.verbose_logs == "Verdicts:\n[]"
      assert Mock.get_recorded_prompts() == []
    end

    test "decides no tool calls itself under system_one, without a System One request" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.1))

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case([]),
                 adapter: :mock,
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert result.reason == "No tool calls provided"
      assert SystemOneMock.calls(system_one) == []
    end

    test "scores the integer 1 when the judge returns no verdicts" do
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => []})

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.score === 1
      assert result.reason == nil
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no", "reason" => "Wrong."}]
      })

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case(),
                 adapter: :mock,
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.threshold == 1
      assert result.success == false
    end

    test "writes deepeval's verbose logs: the verdicts" do
      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "yes"}]
      })

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.verbose_logs ==
               ~s"""
               Verdicts:
               [
                   {
                       "verdict": "yes",
                       "reason": null
                   },
                   {
                       "verdict": "yes",
                       "reason": null
                   }
               ]\
               """
    end

    test "returns an error when tools_called is not given, as deepeval's None" do
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:error, {:missing_params, [:tools_called]}} =
               ArgumentCorrectness.measure(test_case, adapter: :mock)

      assert Mock.get_recorded_prompts() == []
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about input and tools_called" do
      assert %EvalSpec{
               evaluation_params: [:input, :tools_called],
               questions: [
                 %Scored.Noul{statement: "Every tool call in `tools_called`" <> _, weight: 2.0},
                 %Scored.Noul{statement: "No tool call in `tools_called`" <> _},
                 %Scored.Score{
                   levels: ["None of them", "Less than half", "Most of them", "All of them"]
                 }
               ]
             } = ArgumentCorrectness.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid asks about each tool call's repr with the input; P(yes) of 0.5 and above passes" do
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 1.00."})

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.5))

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0

      assert [%{verdict: :yes, reason: "P(yes)=0.50"}, %{verdict: :yes}] =
               result.metadata.verdicts

      assert [%SystemOneMock.Call{state: state, questions: questions}] =
               SystemOneMock.calls(system_one)

      assert Enum.map(questions, &elem(&1, 0)) == ["tool_call_0", "tool_call_1"]

      assert %{"input" => "Book a table for two on Friday.", "tool_calls" => [first, _]} =
               state |> Jason.encode!() |> Jason.decode!()

      assert first ==
               ~s"""
               ToolCall(
                   name="restaurant_search",
                   type="FUNCTION",
                   input_parameters={
                       "party_size": 2
                   }
               )\
               """

      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "system_one answers the whole metric without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               ArgumentCorrectness.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      # No LLM response is scripted, so any judge call would fail the metric.
      assert result.success
      assert result.evaluation_model == "fake-jev"
      assert [%SystemOneMock.Call{}] = SystemOneMock.calls(system_one)
    end
  end
end
