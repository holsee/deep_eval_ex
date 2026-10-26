defmodule DeepEvalEx.Metrics.StepEfficiencyTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.StepEfficiency
  alias DeepEvalEx.Prompts.StepEfficiency, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{NestedDict, Span}

  @task %{"task" => [%{"task" => "Book a table for two."}]}

  @responses Map.put(@task, "reason,score", [
               %{"score" => 0.5, "reason" => "The search was repeated."}
             ])

  defp test_case do
    TestCase.new!(input: "Book a table for two.", actual_output: "Booked for 19:00.")
  end

  defp traced_test_case do
    search = Span.new!(uuid: "s2", type: :tool, name: "search", input: %{"q" => "Café"})

    agent =
      Span.new!(
        uuid: "s1",
        type: :agent,
        name: "booker",
        input: %{"query" => "Book a table for two."},
        output: "Booked for 19:00.",
        children: [search, %{search | uuid: "s3"}]
      )

    %{test_case() | trace_dict: NestedDict.build(agent)}
  end

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    StepEfficiency.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0, required_params/0 and requires_trace?/0" do
    test "are deepeval's __name__, _required_params and requires_trace" do
      assert StepEfficiency.metric_name() == "Step Efficiency"
      assert StepEfficiency.required_params() == [:input, :actual_output]
      assert StepEfficiency.default_threshold() == 0.5
      assert StepEfficiency.requires_trace?()
    end
  end

  describe "measure/2" do
    test "extracts the task from the trace, then scores the execution's efficiency" do
      test_case = traced_test_case()
      assert {:ok, result} = measure(test_case, @responses)

      assert result.metric == "Step Efficiency"
      assert result.score === 0.5
      assert result.success
      assert result.reason == "The search was repeated."
      assert result.metadata == %{task: "Book a table for two."}

      trace_json = NestedDict.to_json(test_case.trace_dict)
      assert trace_json =~ ~s|"Caf\\u00e9"|

      [task] = prompts("task")
      assert task =~ "TRACE DATA:\n\n#{trace_json}\n\n---\n\n### JSON:"

      [score] = prompts("reason,score")
      assert score =~ "TASK:\nBook a table for two.\n\nTRACE:\n#{trace_json}\n\nJSON:"
    end

    test "prints a missing trace as null, as deepeval does" do
      assert {:ok, _result} = measure(test_case(), @responses)

      [task] = prompts("task")
      assert task =~ "TRACE DATA:\n\nnull\n\n---"
    end

    test "clamps a score below 1 to the integer 0 in strict mode" do
      assert {:ok, result} = measure(traced_test_case(), @responses, strict_mode: true)

      assert result.score === 0
      assert result.threshold == 1
    end

    test "writes deepeval's verbose logs: the task and the score" do
      assert {:ok, result} = measure(traced_test_case(), @responses)

      assert result.verbose_logs ==
               "Task: Book a table for two. \n \n \nEfficiency Score: 0.5"
    end
  end

  describe "prompts" do
    test "always print the multimodal input rules, as deepeval's templates do" do
      assert Prompts.get_execution_efficiency(task: "T", trace_json_str: "{}") =~
               "--- MULTIMODAL INPUT RULES ---"

      assert Prompts.extract_task_from_trace(trace_json: "{}") =~
               "--- MULTIMODAL INPUT RULES ---"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about the compacted trace when there is one" do
      assert %EvalSpec{
               evaluation_params: [],
               questions: [
                 %Scored.Noul{weight: 2.0},
                 %Scored.Noul{},
                 %Scored.Score{levels: ["Highly inefficient" | _]}
               ],
               extra_state: [trace: %Jason.OrderedObject{}]
             } = StepEfficiency.system_one_eval_spec(traced_test_case(), [])
    end

    test "system_one_eval_spec/2 asks about the test case without a trace" do
      assert %EvalSpec{
               evaluation_params: [:input, :actual_output, :tools_called],
               extra_state: [trace: nil]
             } = StepEfficiency.system_one_eval_spec(test_case(), [])
    end

    test "hybrid scores the efficiency with one Score about the task and the trace" do
      answers = %Answers{
        scores: %{
          "verdict" => %Answers.Score{
            score: 2,
            probabilities: for(level <- 0..4, do: {level, 0.2}),
            confidence: 0.5
          }
        }
      }

      system_one = SystemOneMock.new(answers: [answers])

      assert {:ok, result} =
               measure(traced_test_case(), @task,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.5
      assert result.reason =~ ": step efficiency 0.50, confidence 0.50."

      assert [%{state: state}] = SystemOneMock.calls(system_one)
      assert state |> Jason.encode!() |> Jason.decode!() |> Map.keys() == ["task", "trace"]
    end

    test "hybrid asks the LLM without a trace" do
      system_one = SystemOneMock.new(answers: [])

      assert {:ok, result} =
               measure(test_case(), @responses, eval_mode: :hybrid, system_one_model: system_one)

      assert result.score === 0.5
      assert SystemOneMock.calls(system_one) == []
    end

    test "hybrid falls back to the LLM's score when the request fails" do
      system_one =
        SystemOneMock.new(
          raises: %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
        )

      assert {:ok, result} =
               measure(traced_test_case(), @responses,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.5
      assert result.reason == "The search was repeated."
      assert result.system_one_fallback_reason =~ "ConnectionError: Jev is down"
    end
  end
end
