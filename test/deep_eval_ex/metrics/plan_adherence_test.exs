defmodule DeepEvalEx.Metrics.PlanAdherenceTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.PlanAdherence
  alias DeepEvalEx.Prompts.PlanAdherence, as: Prompts
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{Answers, Error, EvalSpec, Scored}
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{NestedDict, Span}

  @extracted %{
    "task" => [%{"task" => "Book a table for two."}],
    "plan" => [%{"plan" => ["Search for the restaurant", "Book the table"]}]
  }

  @responses Map.put(@extracted, "reason,score", [
               %{"score" => 0.5, "reason" => "Step 2 was never carried out."}
             ])

  @no_plan %{
    "task" => [%{"task" => "Book a table for two."}],
    "plan" => [%{"plan" => []}]
  }

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
        children: [search]
      )

    %{test_case() | trace_dict: NestedDict.build(agent)}
  end

  defp measure(test_case, responses, opts \\ []) do
    Mock.script(responses, model: "scripted-judge")
    PlanAdherence.measure(test_case, [adapter: :mock] ++ opts)
  end

  defp prompts(step),
    do: for(%{step: ^step, prompt: prompt} <- Mock.scripted_prompts(), do: prompt)

  describe "metric_name/0, required_params/0 and requires_trace?/0" do
    test "are deepeval's __name__, _required_params and requires_trace" do
      assert PlanAdherence.metric_name() == "Plan Adherence"
      assert PlanAdherence.required_params() == [:input, :actual_output]
      assert PlanAdherence.default_threshold() == 0.5
      assert PlanAdherence.requires_trace?()
    end
  end

  describe "measure/2" do
    test "extracts the task and the plan, then scores the trace's adherence to the plan" do
      test_case = traced_test_case()
      assert {:ok, result} = measure(test_case, @responses)

      assert result.metric == "Plan Adherence"
      assert result.score === 0.5
      assert result.success
      assert result.reason == "Step 2 was never carried out."

      assert result.metadata == %{
               task: "Book a table for two.",
               plan: ["Search for the restaurant", "Book the table"]
             }

      trace_json = NestedDict.to_json(test_case.trace_dict)

      [task] = prompts("task")
      assert task =~ "TRACE DATA:\n\n#{trace_json}\n\n---\n\n### JSON:"

      [plan] = prompts("plan")
      assert plan =~ "TRACE:\n\n#{trace_json}\n\nJSON:"

      [score] = prompts("reason,score")

      assert score =~
               "User Task:\nBook a table for two.\n\n" <>
                 "Agent Plan:\nSearch for the restaurant\nBook the table\n\n" <>
                 "Execution Trace:\n#{trace_json}\n\n---\n\nJSON:"
    end

    test "scores the integer 1 without asking when the trace holds no plan" do
      assert {:ok, result} = measure(traced_test_case(), @no_plan)

      assert result.score === 1

      assert result.reason ==
               "There were no plans to evaluate within the trace of your agent's execution. " <>
                 "Please check if the agent's planning or reasoning or thinking is stored in " <>
                 "any one of the trace attributes."

      assert prompts("reason,score") == []
    end

    test "clamps a score below 1 to the integer 0 in strict mode" do
      assert {:ok, result} = measure(traced_test_case(), @responses, strict_mode: true)

      assert result.score === 0
      assert result.threshold == 1
      refute result.success
    end

    test "writes deepeval's verbose logs: the task, the plan and the score" do
      assert {:ok, result} = measure(traced_test_case(), @no_plan)

      assert result.verbose_logs ==
               "Task: Book a table for two. \n \n \nAgent Plan: \n[] \n \n \nFinal Score: 1 \n"
    end
  end

  describe "prompts" do
    test "always print the multimodal input rules, as deepeval's templates do" do
      assert Prompts.extract_plan_from_trace(trace_json_str: "{}") =~
               "--- MULTIMODAL INPUT RULES ---"

      assert Prompts.evaluate_adherence(
               user_task: "T",
               agent_plan: "P",
               execution_trace_json: "{}"
             ) =~ "--- MULTIMODAL INPUT RULES ---"
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks about the compacted trace when there is one" do
      assert %EvalSpec{
               evaluation_params: [],
               questions: [
                 %Scored.Choice{weight: 2.0},
                 %Scored.Choice{},
                 %Scored.Choice{options: [{"No adherence", +0.0} | _]} = level
               ],
               extra_state: [trace: %Jason.OrderedObject{}]
             } = PlanAdherence.system_one_eval_spec(traced_test_case(), [])

      assert Scored.Choice.not_applicable_options(level) == ["The agent states no plan"]
    end

    test "system_one_eval_spec/2 asks about the test case without a trace" do
      assert %EvalSpec{
               evaluation_params: [:input, :actual_output, :tools_called],
               extra_state: [trace: nil]
             } = PlanAdherence.system_one_eval_spec(test_case(), [])
    end

    test "hybrid scores the adherence with one Score about the task, plan and trace" do
      answers = %Answers{
        scores: %{
          "verdict" => %Answers.Score{
            score: 4,
            probabilities: for(level <- 0..4, do: {level, 0.2}),
            confidence: 0.5
          }
        }
      }

      system_one = SystemOneMock.new(answers: [answers])

      assert {:ok, result} =
               measure(traced_test_case(), @extracted,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 1.0
      assert result.reason =~ ": plan adherence 1.00, confidence 0.50."

      assert [%{state: state}] = SystemOneMock.calls(system_one)

      assert state |> Jason.encode!() |> Jason.decode!() |> Map.keys() ==
               ["plan", "task", "trace"]
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
      assert result.system_one_fallback_reason =~ "ConnectionError: Jev is down"
    end
  end
end
