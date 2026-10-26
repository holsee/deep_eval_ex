defmodule DeepEvalEx.Metrics.TaskCompletionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.{BaseMetric, TaskCompletion}
  alias DeepEvalEx.Prompts.TaskCompletion, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{NestedDict, Span}

  @extracted %{
    "outcome,task" => [%{"task" => "Book a table.", "outcome" => "The system booked a table."}]
  }

  @responses Map.put(@extracted, "reason,verdict", [
               %{"verdict" => 0.8, "reason" => "Booked, but no confirmation sent."}
             ])

  defp test_case(fields \\ []) do
    TestCase.new!([input: "Book a table for two.", actual_output: "Booked for 19:00."] ++ fields)
  end

  # A traced test case: the agent span's nested trace dict, as
  # DeepEvalEx.Evaluator.Agentic attaches it.
  defp traced_test_case do
    tool = Span.new!(uuid: "s2", type: :tool, name: "book_table", input: %{"day" => "Sat"})

    agent =
      Span.new!(
        uuid: "s1",
        type: :agent,
        name: "booker",
        input: %{"query" => "Book a table for two."},
        output: "Booked for 19:00.",
        children: [tool]
      )

    %{test_case() | trace_dict: NestedDict.build(agent)}
  end

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    TaskCompletion.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0, required_params/0 and requires_trace?/0" do
    test "are deepeval's __name__, _required_params and requires_trace" do
      assert TaskCompletion.metric_name() == "Task Completion"
      assert TaskCompletion.required_params() == [:input, :actual_output]
      assert TaskCompletion.default_threshold() == 0.5
      assert TaskCompletion.requires_trace?()
      assert BaseMetric.requires_trace?({TaskCompletion, task: "T"})
    end
  end

  describe "measure/2" do
    test "scores the judge's verdict on the extracted task and outcome" do
      assert {:ok, result} = measure(test_case(), @responses)

      assert result.metric == "Task Completion"
      assert result.score === 0.8
      assert result.success
      assert result.reason == "Booked, but no confirmation sent."
      assert result.metadata == %{task: "Book a table.", outcome: "The system booked a table."}

      [verdict] = prompts("reason,verdict")
      assert verdict =~ "Task:\nBook a table.\n\nActual outcome:\nThe system booked a table.\n"
    end

    test "without a trace, extracts from the input, output and tools called" do
      tools = [%{name: "book_table", input_parameters: %{"day" => "Sat"}}]
      assert {:ok, _result} = measure(test_case(tools_called: tools), @responses)

      [extract] = prompts("outcome,task")
      assert extract =~ "input: Book a table for two.\ntools called:\n[\n  {\n"
      assert extract =~ "\"name\": \"book_table\""
      assert extract =~ "response: Booked for 19:00.\n\nJSON:"
    end

    test "with a trace, extracts from the nested trace dict, printed as deepeval does" do
      test_case = traced_test_case()
      assert {:ok, _result} = measure(test_case, @responses)

      [extract] = prompts("outcome,task")
      assert extract =~ "trace:\n#{NestedDict.to_json(test_case.trace_dict)}\n\nJSON:"
    end

    test "judges its own task, not the extracted one" do
      assert {:ok, result} = measure(test_case(), @responses, task: "Book a table for four.")

      [verdict] = prompts("reason,verdict")
      assert verdict =~ "Task:\nBook a table for four.\n"
      assert result.metadata.task == "Book a table for four."
    end

    test "takes a verdict without a reason, as deepeval's optional field" do
      responses = Map.put(@extracted, "reason,verdict", [%{"verdict" => 1}])
      assert {:ok, result} = measure(test_case(), responses)

      assert result.score === 1.0
      assert result.reason == nil
    end

    test "clamps a verdict below 1 to the integer 0 in strict mode" do
      assert {:ok, result} = measure(test_case(), @responses, strict_mode: true)

      assert result.score === 0
      assert result.threshold == 1
      refute result.success
    end

    test "writes deepeval's verbose logs: the task and the outcome" do
      assert {:ok, result} = measure(test_case(), @responses)

      assert result.verbose_logs ==
               "Task: Book a table. \n \nOutcome: The system booked a table."
    end

    test "returns the judge's error" do
      Mock.script(%{}, model: "scripted-judge")
      assert {:error, _reason} = TaskCompletion.measure(test_case(), adapter: :mock)
    end
  end

  describe "prompts" do
    test "ask System One about the trace or the test case, and the task when given" do
      assert Prompts.system_one_questions(has_trace: true, has_task: false) =~
               ~S|"The agent run in `trace` fully accomplishes the user\u0027s task (the root|

      assert Prompts.system_one_questions(has_trace: false, has_task: true) =~
               ~s|"`actual_output` (with the tools in `tools_called`) fully accomplishes `task`."|
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about the compacted trace when there is one" do
      assert %EvalSpec{
               evaluation_params: [],
               questions: [
                 %Scored.Noul{weight: 2.0},
                 %Scored.Noul{},
                 %Scored.Score{levels: ["Not achieved" | _]}
               ],
               extra_state: [trace: %Jason.OrderedObject{} = trace, task: nil]
             } = TaskCompletion.system_one_eval_spec(traced_test_case(), [])

      assert trace["name"] == "booker"
      assert [%{} = _tool] = trace["children"]
    end

    test "system_one_eval_spec/2 asks about the test case and its own task without a trace" do
      assert %EvalSpec{
               evaluation_params: [:input, :actual_output, :tools_called],
               extra_state: [trace: nil, task: "T"]
             } = TaskCompletion.system_one_eval_spec(test_case(), task: "T")
    end

    test "hybrid scores the verdict with one Score about the task and outcome" do
      answers = %Answers{
        scores: %{
          "verdict" => %Answers.Score{
            score: 3,
            probabilities: for(level <- 0..3, do: {level, 0.25}),
            confidence: 0.7
          }
        }
      }

      system_one = SystemOneMock.new(answers: [answers])

      assert {:ok, result} =
               measure(test_case(), @extracted, eval_mode: :hybrid, system_one_model: system_one)

      assert result.score === 1.0
      assert result.reason =~ ": task completion 1.00, confidence 0.70."
      assert prompts("reason,verdict") == []

      assert [%{state: state}] = SystemOneMock.calls(system_one)
      assert state |> Jason.encode!() |> Jason.decode!() |> Map.keys() == ["outcome", "task"]
    end

    test "hybrid gives no reason with include_reason: false" do
      answers = %Answers{
        scores: %{
          "verdict" => %Answers.Score{score: 0, probabilities: [{0, 1.0}], confidence: 0.9}
        }
      }

      system_one = SystemOneMock.new(answers: [answers])

      assert {:ok, result} =
               measure(test_case(), @extracted,
                 eval_mode: :hybrid,
                 system_one_model: system_one,
                 include_reason: false
               )

      assert result.score === 0.0
      assert result.reason == nil
    end

    test "hybrid falls back to the LLM's verdict when the request fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(test_case(), @responses, eval_mode: :hybrid, system_one_model: system_one)

      assert result.score === 0.8
      assert result.system_one_fallback_reason =~ "ConnectionError: Jev is down"
    end
  end
end
