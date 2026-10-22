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
    batch_system_one batch_system_one_down batch_system_one_retrieval batch_system_one_safety
    bias_hybrid bias_hybrid_fallback bias_system_one
    contextual_precision_hybrid contextual_precision_hybrid_fallback
    contextual_precision_system_one
    contextual_recall_hybrid contextual_recall_hybrid_fallback contextual_recall_system_one
    contextual_relevancy_hybrid contextual_relevancy_hybrid_fallback
    contextual_relevancy_system_one
    faithfulness_hybrid faithfulness_hybrid_fallback faithfulness_system_one
    faithfulness_system_one_strict
    hallucination_hybrid hallucination_hybrid_fallback hallucination_system_one
    jev_eval jev_eval_strict_not_applicable
    refusal_classifier_system_one
    tool_correctness_hybrid tool_correctness_hybrid_fallback tool_correctness_system_one
    toxicity_hybrid toxicity_hybrid_fallback toxicity_system_one
  )

  @answer_kinds %{"noul" => "nouls", "score" => "scores", "choice" => "choices"}

  defp load(scenario, file) do
    [@fixtures, scenario, file] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  test "covers every scenario of the fixture script" do
    assert @scenarios == Enum.sort(@expected)
  end

  test "covers every eval-mode metric in system_one, hybrid and hybrid fallback" do
    for kind <-
          ~w(faithfulness hallucination answer_relevancy contextual_precision contextual_recall
             contextual_relevancy bias toxicity tool_correctness),
        suffix <- ~w(system_one hybrid hybrid_fallback) do
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

      test "records well-formed decide() calls", %{decide: decide} do
        calls = decide["evaluate"] ++ List.flatten(decide["measure"])
        assert calls != []
        Enum.each(calls, &assert_call/1)
      end

      test "batches evaluate() only when the scenario says so", %{input: input, decide: decide} do
        if input["batched"] do
          assert [%{"questions" => questions}] = decide["evaluate"]

          prefixes =
            questions |> Map.keys() |> Enum.map(&hd(String.split(&1, "."))) |> Enum.uniq()

          assert Enum.sort(prefixes) == Enum.map(0..(length(input["metrics"]) - 1), &"m#{&1}")
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

          # Under system_one nothing falls back: measure() raises.
          if failed? and spec["eval_mode"] == "system_one" do
            assert state["raised"]["type"] == input["system_one"]["raises"]["type"]
          else
            assert state["raised"] == nil
          end

          # Confidence comes from Jev's answers only.
          assert is_number(state["confidence"]) != failed?
        end
      end

      test "exports what measure() reported", %{input: input, measure: measure} do
        exported =
          if input["classifier"] do
            load(unquote(scenario), "classifications.json")
          else
            [test_case] = load(unquote(scenario), "test_run.json")["testCases"]
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
