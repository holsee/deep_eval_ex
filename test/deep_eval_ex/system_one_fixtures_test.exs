defmodule DeepEvalEx.SystemOneFixturesTest do
  @moduledoc """
  Checks the structure of the System One fixtures of
  `test/fixtures/deepeval/system_one/` (see the fixtures' README), which
  record what deepeval 4.3.1 asks Jev and does with its answers under the
  `system_one` and `hybrid` eval modes.

  DeepEvalEx has no System One support yet, so nothing is compared with
  DeepEvalEx here: these tests keep the fixtures loadable and consistent
  (every `decide()` call well formed, every question answered with its own
  type, measure and export agreeing) until the eval-mode units consume them.
  """

  use ExUnit.Case, async: true

  @moduletag :parity

  @fixtures Path.expand("../fixtures/deepeval/system_one", __DIR__)

  @scenarios @fixtures
             |> File.ls!()
             |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
             |> Enum.sort()

  for scenario <- @scenarios,
      file <- ~w(input.json decide.json measure.json prompts.json test_run.json
                 classifications.json) do
    @external_resource Path.join([@fixtures, scenario, file])
  end

  # The scenarios of scripts/parity/generate_system_one_fixtures.py.
  @expected ~w(
    answer_relevancy_hybrid answer_relevancy_hybrid_fallback answer_relevancy_system_one
    argument_correctness_hybrid argument_correctness_hybrid_fallback
    argument_correctness_system_one
    batch_system_one batch_system_one_agent batch_system_one_conversational batch_system_one_down
    batch_system_one_goal_tool batch_system_one_json batch_system_one_retention_role
    batch_system_one_pii_alignment batch_system_one_retrieval batch_system_one_safety
    batch_system_one_summarization batch_system_one_turn_rag
    bias_hybrid bias_hybrid_fallback bias_system_one
    contextual_precision_hybrid contextual_precision_hybrid_fallback
    contextual_precision_system_one
    contextual_recall_hybrid contextual_recall_hybrid_fallback contextual_recall_system_one
    contextual_relevancy_hybrid contextual_relevancy_hybrid_fallback
    contextual_relevancy_system_one
    conversation_completeness_hybrid conversation_completeness_hybrid_fallback
    conversation_completeness_system_one
    conversational_jev_eval conversational_jev_eval_strict_not_applicable
    conversational_jev_eval_down
    dag_hybrid dag_hybrid_fallback dag_system_one
    faithfulness_hybrid faithfulness_hybrid_fallback faithfulness_system_one
    faithfulness_system_one_strict
    goal_accuracy_hybrid goal_accuracy_hybrid_fallback goal_accuracy_system_one
    goal_accuracy_system_one_strict
    hallucination_hybrid hallucination_hybrid_fallback hallucination_system_one
    knowledge_retention_hybrid knowledge_retention_hybrid_fallback knowledge_retention_system_one
    jev_eval jev_eval_strict_not_applicable jev_eval_trace
    json_correctness_hybrid json_correctness_system_one
    pii_leakage_hybrid pii_leakage_hybrid_fallback pii_leakage_system_one
    plan_adherence_hybrid plan_adherence_hybrid_fallback plan_adherence_hybrid_no_trace
    plan_adherence_system_one plan_adherence_system_one_no_trace
    plan_quality_hybrid plan_quality_hybrid_fallback plan_quality_system_one
    plan_quality_system_one_no_plan
    prompt_alignment_hybrid prompt_alignment_hybrid_fallback prompt_alignment_system_one
    refusal_classifier_system_one
    role_adherence_hybrid role_adherence_hybrid_fallback role_adherence_system_one
    step_efficiency_hybrid step_efficiency_hybrid_fallback step_efficiency_hybrid_no_trace
    step_efficiency_system_one
    summarization_hybrid summarization_hybrid_fallback summarization_system_one
    task_completion_hybrid task_completion_hybrid_fallback task_completion_system_one
    task_completion_system_one_task
    tool_correctness_hybrid tool_correctness_hybrid_fallback tool_correctness_system_one
    tool_use_hybrid tool_use_hybrid_fallback tool_use_system_one
    toxicity_hybrid toxicity_hybrid_fallback toxicity_system_one
    turn_relevancy_hybrid turn_relevancy_hybrid_fallback turn_relevancy_system_one
    turn_relevancy_system_one_strict
    turn_contextual_precision_hybrid turn_contextual_precision_hybrid_fallback
    turn_contextual_precision_system_one
    turn_contextual_recall_hybrid turn_contextual_recall_hybrid_fallback
    turn_contextual_recall_system_one
    turn_contextual_relevancy_hybrid turn_contextual_relevancy_hybrid_fallback
    turn_contextual_relevancy_system_one
    turn_faithfulness_hybrid turn_faithfulness_hybrid_fallback turn_faithfulness_system_one
    turn_faithfulness_system_one_strict
  )

  @answer_kinds %{"noul" => "nouls", "score" => "scores", "choice" => "choices"}

  # Metrics that ask System One nothing in any mode: JsonCorrectness decides
  # in code. They have no hybrid_fallback scenario, as nothing can fail.
  @asks_nothing ~w(json_correctness)

  defp asks?(spec), do: spec["kind"] not in @asks_nothing

  # Scenarios whose test case gives the metric nothing to ask: StepEfficiency
  # and PlanAdherence have no hybrid Score without a trace.
  @asks_nothing_of_test_case ~w(step_efficiency_hybrid_no_trace plan_adherence_hybrid_no_trace)

  defp asks?(scenario, spec), do: scenario not in @asks_nothing_of_test_case and asks?(spec)

  # A JevEval has no eval mode: it is always decided by System One.
  defp decided_by_system_one?(spec),
    do: spec["eval_mode"] == "system_one" or spec["kind"] in ~w(jev_eval conversational_jev_eval)

  defp load(scenario, file) do
    [@fixtures, scenario, file] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  test "covers every scenario of the fixture script" do
    assert @scenarios == Enum.sort(@expected)
  end

  test "covers every eval-mode metric in system_one, hybrid and, when it asks, hybrid fallback" do
    for kind <-
          ~w(faithfulness hallucination answer_relevancy contextual_precision contextual_recall
             contextual_relevancy bias toxicity pii_leakage prompt_alignment summarization
             argument_correctness tool_correctness turn_relevancy conversation_completeness
             knowledge_retention role_adherence turn_faithfulness turn_contextual_precision
             turn_contextual_recall turn_contextual_relevancy goal_accuracy tool_use
             task_completion step_efficiency plan_quality plan_adherence dag),
        suffix <- ~w(system_one hybrid hybrid_fallback) do
      assert "#{kind}_#{suffix}" in @scenarios
    end

    for kind <- @asks_nothing, suffix <- ~w(system_one hybrid) do
      assert "#{kind}_#{suffix}" in @scenarios
    end
  end

  for scenario <- @scenarios do
    describe scenario do
      setup do
        input = load(unquote(scenario), "input.json")
        decide = load(unquote(scenario), "decide.json")
        measure = load(unquote(scenario), "measure.json")
        %{input: input, decide: decide, measure: measure}
      end

      test "has its files", %{input: input} do
        dir = Path.join(@fixtures, unquote(scenario))
        assert File.regular?(Path.join(dir, "prompts.json")) == Map.has_key?(input, "responses")
        # A classifiers-only evaluate() writes no test run file.
        assert File.regular?(Path.join(dir, "test_run.json")) == Map.has_key?(input, "metrics")

        assert File.regular?(Path.join(dir, "classifications.json")) ==
                 Map.has_key?(input, "classifier")
      end

      test "describes one test case and its System One model", %{input: input} do
        assert is_binary(input["description"])
        assert is_map(input["test_case"])
        assert is_binary(input["system_one"]["model"])

        assert Map.has_key?(input["system_one"], "answers") !=
                 Map.has_key?(input["system_one"], "raises")

        assert Map.has_key?(input, "metrics") != Map.has_key?(input, "classifier")
      end

      test "records one measure per metric", %{input: input, decide: decide, measure: measure} do
        count = length(input["metrics"] || [input["classifier"]])
        assert length(decide["measure"]) == count
        assert length(measure) == count
      end

      test "records well-formed decide() calls", %{input: input, decide: decide} do
        calls = decide["evaluate"] ++ List.flatten(decide["measure"])
        specs = input["metrics"] || [input["classifier"]]
        assert calls != [] or not Enum.any?(specs, &asks?(unquote(scenario), &1))
        Enum.each(calls, &assert_call/1)

        for {spec, measured} <- Enum.zip(specs, decide["measure"]),
            not asks?(unquote(scenario), spec) do
          assert measured == []
        end
      end

      test "batches evaluate() only when the scenario says so", %{input: input, decide: decide} do
        if input["batched"] do
          assert [%{"questions" => questions}] = decide["evaluate"]

          prefixes =
            questions |> Map.keys() |> Enum.map(&hd(String.split(&1, "."))) |> Enum.uniq()

          # Only the metrics that ask anything are in the request.
          asking = Enum.count(input["metrics"], &asks?/1)
          assert Enum.sort(prefixes) == Enum.map(0..(asking - 1), &"m#{&1}")
        else
          assert decide["evaluate"] == List.flatten(decide["measure"])
        end
      end

      test "records fallbacks exactly when Jev failed in hybrid mode", ctx do
        %{input: input, decide: decide, measure: measure} = ctx
        failed? = Map.has_key?(input["system_one"], "raises")

        for {spec, state, calls} <-
              Enum.zip([input["metrics"] || [input["classifier"]], measure, decide["measure"]]) do
          assert Enum.all?(calls, &(Map.has_key?(&1, "error") == failed?))

          if failed? and spec["eval_mode"] == "hybrid" do
            assert state["system_one_fallback_reason"] =~ input["system_one"]["raises"]["type"]
            assert state["error"] == nil
          else
            assert state["system_one_fallback_reason"] == nil
          end

          # Under system_one nothing falls back: measure() raises, as a
          # JevEval's always does.
          if failed? and decided_by_system_one?(spec) do
            assert state["raised"]["type"] == input["system_one"]["raises"]["type"]
          else
            assert state["raised"] == nil
          end

          # Confidence comes from Jev's answers only.
          assert is_number(state["confidence"]) ==
                   (asks?(unquote(scenario), spec) and not failed?)
        end
      end

      test "exports what measure() reported", %{input: input, measure: measure} do
        exported =
          if input["classifier"] do
            load(unquote(scenario), "classifications.json")
          else
            # A conversational test case is exported apart.
            test_run = load(unquote(scenario), "test_run.json")
            [test_case] = test_run["testCases"] ++ (test_run["conversationalTestCases"] || [])
            test_case["metricsData"]
          end

        assert length(exported) == length(measure)

        for {data, state} <- Enum.zip(exported, measure) do
          assert data["evaluationModel"] == state["evaluation_model"]

          if is_nil(input["batched"]) and is_nil(state["error"]),
            do: assert(data["reason"] == state["reason"])
        end
      end
    end
  end

  defp assert_call(%{"state" => state, "questions" => questions} = call) do
    assert is_map(state) and map_size(state) > 0
    assert is_map(questions) and map_size(questions) > 0
    Enum.each(questions, fn {_key, question} -> assert_question(question) end)

    case call do
      %{"error" => %{"type" => type, "message" => message}} ->
        assert is_binary(type) and is_binary(message)
        refute Map.has_key?(call, "answers")

      %{"answers" => answers} ->
        assert_answers(questions, answers)
        assert_cost(call["cost"])
    end
  end

  defp assert_question(%{"type" => "noul", "instructions" => instructions} = question) do
    assert instructions != nil

    case question do
      %{"criteria" => criteria} -> assert Map.keys(criteria) |> Enum.sort() == ~w(false true)
      _ -> :ok
    end
  end

  defp assert_question(%{"type" => "choice", "instructions" => _, "criteria" => criteria}) do
    assert is_map(criteria) and map_size(criteria) >= 2
  end

  defp assert_question(%{"type" => "score", "instructions" => _, "criteria" => levels}) do
    assert is_list(levels) and length(levels) >= 2
  end

  # Every question is answered under its own type, and nothing else is.
  defp assert_answers(questions, answers) do
    assert Map.keys(answers) |> Enum.sort() == ~w(choices nouls scores)

    expected =
      Enum.group_by(questions, fn {_key, q} -> @answer_kinds[q["type"]] end, &elem(&1, 0))

    for kind <- Map.values(@answer_kinds) do
      assert answers[kind] |> Map.keys() |> Enum.sort() == Enum.sort(Map.get(expected, kind, []))
    end

    for {key, answer} <- answers["nouls"], do: assert_probability(answer["probability"], key)

    for {key, answer} <- answers["scores"] do
      levels = length(questions[key]["criteria"])
      assert is_number(answer["score"]) and answer["score"] >= 0 and answer["score"] < levels

      assert Enum.all?(
               Map.keys(answer["probabilities"]),
               &(String.to_integer(&1) in 0..(levels - 1))
             )

      assert_probability(answer["confidence"], key)
    end

    for {key, answer} <- answers["choices"] do
      options = Map.keys(questions[key]["criteria"])
      assert answer["choice"] in options
      assert Map.keys(answer["probabilities"]) -- options == []
      assert_probability(answer["confidence"], key)
    end
  end

  defp assert_probability(p, key) do
    assert is_number(p) and p >= 0 and p <= 1, "#{key}: #{inspect(p)} is not a probability"
  end

  defp assert_cost(nil), do: :ok
  defp assert_cost(cost) when is_number(cost), do: assert(cost >= 0)

  defp assert_cost(%{"value" => value, "input_tokens" => input, "output_tokens" => output}) do
    assert is_number(value) and is_integer(input) and is_integer(output)
  end
end
