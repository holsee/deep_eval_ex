defmodule DeepEvalEx.Metrics.ToolUseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ToolUse
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}

  @tools [
    %ToolCall{name: "get_weather", description: "Fetch current weather for a city"},
    %ToolCall{name: "search_web", description: "Search the web"}
  ]

  @turns [
    %{role: :user, content: "Weather in Paris?"},
    %{
      role: :assistant,
      content: "It is 18°C.",
      tools_called: [%{name: "get_weather", input_parameters: %{"city" => "Paris"}}]
    },
    %{role: :user, content: "Thanks!"},
    %{role: :assistant, content: "You're welcome!"}
  ]

  @scores %{
    "reason,score" => [
      %{"score" => 1.0, "reason" => "Right tool."},
      %{"score" => 0.5, "reason" => "No tool needed."},
      %{"score" => 1, "reason" => "Right city."}
    ],
    "reason" => [%{"reason" => "Selection."}, %{"reason" => "Arguments."}]
  }

  defp test_case(turns \\ @turns), do: ConversationalTestCase.new!(turns: turns)

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    ToolUse.measure(test_case, [adapter: :mock, available_tools: @tools] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0 and required_params/0" do
    test "are deepeval's __name__ and _required_test_case_params" do
      assert ToolUse.metric_name() == "Tool Use"
      assert ToolUse.required_params() == [:role, :content]
      assert ToolUse.default_threshold() == 0.5
    end
  end

  describe "new/1" do
    test "keeps the available tools, as deepeval's constructor" do
      assert %ToolUse{available_tools: @tools, threshold: 1} =
               ToolUse.new(available_tools: @tools, strict_mode: true)
    end

    test "requires the available tools" do
      assert_raise ArgumentError, ~r/requires :available_tools/, fn -> ToolUse.new([]) end
    end
  end

  describe "measure/2" do
    test "scores the lower of the mean tool selection and mean argument correctness scores" do
      assert {:ok, result} = measure(test_case(), @scores)

      assert result.metric == "Tool Use"
      # min((1.0 + 0.5) / 2, 1.0)
      assert result.score === 0.75
      assert result.reason == "Selection.\nArguments."

      assert result.metadata.argument_correctness_scores == [
               %{score: 1.0, reason: "Right city."}
             ]
    end

    test "leaves success unset, as deepeval's measure() does; evaluate reports score >= threshold" do
      assert {:ok, result} = measure(test_case(), @scores)
      assert result.success == nil

      Mock.script(@scores, model: "scripted-judge")

      assert [[evaluated]] =
               DeepEvalEx.Evaluator.evaluate(
                 [test_case()],
                 [ToolUse.new(available_tools: @tools)],
                 adapter: :mock
               )

      assert evaluated.success == true
    end

    test "asks about each unit's messages and tools, the tools as ToolCall.__repr__" do
      assert {:ok, _result} = measure(test_case(), @scores)

      [selection, no_tool, arguments] = prompts("reason,score")

      assert selection =~ "**Tool Selection Quality**"

      assert selection =~
               ~s|USER INPUT:\nWeather in Paris? \n\n\nASSISTANT MESSAGES:\nIt is 18°C. \n\n\n| <>
                 ~s|TOOLS CALLED:\nToolCall(\n    name="get_weather",\n    type="FUNCTION",\n| <>
                 ~s|    input_parameters={\n        "city": "Paris"\n    }\n)\n\n| <>
                 ~s|AVAILABLE TOOLS:\nToolCall(\n    name="get_weather",\n|

      assert no_tool =~ "TOOLS CALLED:\n\n\nAVAILABLE TOOLS:"
      assert arguments =~ "**Tool Argument Quality**"
    end

    test "explains both scores with the tool selection reason template, as deepeval does" do
      assert {:ok, _result} = measure(test_case(), @scores)

      [selection, arguments] = prompts("reason")

      assert selection =~
               "All Tool Selection Sub-Scores and Reasons:\n\nScore: 1.0 \nReason: Right tool. \n" <>
                 "\nScore: 0.5 \nReason: No tool needed. \n\n\nFinal Score: 0.75\nThreshold: 0.5\n" <>
                 "Result: PASS\n"

      assert arguments =~
               "All Tool Selection Sub-Scores and Reasons:\n\nScore: 1.0 \nReason: Right city. \n\n\n"
    end

    test "scores 0.0 without a tool call, as deepeval's empty argument mean" do
      assert {:ok, result} =
               measure(
                 test_case([
                   %{role: :user, content: "Hi!"},
                   %{role: :assistant, content: "Hello!"}
                 ]),
                 %{
                   "reason,score" => [%{"score" => 1.0, "reason" => "No tool needed."}],
                   "reason" => [%{"reason" => "S."}, %{"reason" => "A."}]
                 }
               )

      assert result.score === 0.0
    end

    test "clamps a score below the threshold to the integer 0 in strict mode" do
      assert {:ok, result} = measure(test_case(), @scores, strict_mode: true)

      assert result.score === 0
      assert result.threshold == 1
      assert [selection, _] = prompts("reason")
      assert selection =~ "Final Score: 0\nThreshold: 1\nResult: FAIL\n"
    end

    test "writes deepeval's verbose logs" do
      assert {:ok, result} = measure(test_case(), @scores)

      assert result.verbose_logs ==
               ~s|Tool Selection Scores: [\n    {\n        "score": 1.0,\n        "reason": "Right tool."\n| <>
                 ~s|    },\n    {\n        "score": 0.5,\n        "reason": "No tool needed."\n    }\n] \n| <>
                 ~s| \n \nArgument Correctness Scores: [\n    {\n        "score": 1.0,\n| <>
                 ~s|        "reason": "Right city."\n    }\n] \n \n \nFinal Score: 0.75|
    end

    test "raises without the available tools" do
      assert_raise ArgumentError, ~r/requires :available_tools/, fn ->
        ToolUse.measure(test_case(), adapter: :mock)
      end
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions, with the available tools" do
      assert %EvalSpec{
               evaluation_params: [:role, :content, :tools_called],
               questions: [
                 %Scored.Noul{statement: "In every assistant turn of `turns`" <> _},
                 %Scored.Noul{statement: "Every tool call in the `tools_called`" <> _}
               ],
               extra_state: [available_tools: @tools]
             } = ToolUse.system_one_eval_spec(test_case(), available_tools: @tools)
    end

    test "has no System One form for a multimodal conversation" do
      multimodal = %{test_case() | multimodal: true}
      assert ToolUse.system_one_eval_spec(multimodal, available_tools: @tools) == nil
    end

    test "hybrid takes each score from one Score request about the unit's texts" do
      answer = %Answers{
        scores: %{
          "verdict" => %Answers.Score{
            score: 3,
            probabilities: for(level <- 0..4, do: {level, 0.2}),
            confidence: 0.5
          }
        }
      }

      system_one = SystemOneMock.new(answers: [answer, answer, answer])

      assert {:ok, result} =
               measure(test_case(), %{"reason" => [%{"reason" => "S."}, %{"reason" => "A."}]},
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.75
      assert prompts("reason,score") == []

      assert [%{reason: "Decided by " <> reason} | _] = result.metadata.tool_selection_scores
      assert reason =~ ": tool selection 0.75, confidence 0.50."

      assert [first | _] = SystemOneMock.calls(system_one)

      assert %{"tools_called" => "ToolCall(\n    name=\"get_weather\"" <> _} =
               first.state |> Jason.encode!() |> Jason.decode!()
    end

    test "hybrid falls back to the LLM per score when the request fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(test_case(), @scores, eval_mode: :hybrid, system_one_model: system_one)

      assert result.score === 0.75
      assert length(SystemOneMock.calls(system_one)) == 3
    end
  end
end
