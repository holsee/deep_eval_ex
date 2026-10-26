defmodule DeepEvalEx.Metrics.LLMOnlyEvalModeTest do
  # Regression tests for the metrics that take no part in System One, as in
  # deepeval 4.3.1: GEval builds its LLM with `initialize_model(model)` and
  # no eval mode, and ExactMatch builds no model at all, so neither builds a
  # System One model nor makes a System One call, whatever
  # DEEPEVAL_EVAL_MODE says.
  #
  # Reads and writes DEEPEVAL_EVAL_MODE, TYPESAFE_API_KEY and their
  # application env.
  use ExUnit.Case, async: false

  alias DeepEvalEx.{Evaluator, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.{ExactMatch, GEval}
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.Context

  @env %{
    "DEEPEVAL_EVAL_MODE" => :eval_mode,
    "TYPESAFE_API_KEY" => :typesafe_api_key,
    "TYPESAFE_MODEL_NAME" => :typesafe_model_name
  }

  setup do
    saved =
      for {var, key} <- @env do
        saved = {var, System.get_env(var), key, Application.fetch_env(:deep_eval_ex, key)}
        System.delete_env(var)
        Application.delete_env(:deep_eval_ex, key)
        saved
      end

    saved_model = Application.fetch_env(:deep_eval_ex, :system_one_model)
    Application.delete_env(:deep_eval_ex, :system_one_model)
    # No TypeSafe key: building Jev would fail, as deepeval's TypeSafeModel().
    System.put_env("DEEPEVAL_EVAL_MODE", "system_one")
    Mock.clear_responses()

    on_exit(fn ->
      for {var, env, key, config} <- saved do
        if env, do: System.put_env(var, env), else: System.delete_env(var)
        restore(key, config)
      end

      restore(:system_one_model, saved_model)
    end)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:deep_eval_ex, key, value)
  defp restore(key, :error), do: Application.delete_env(:deep_eval_ex, key)

  defp g_eval do
    GEval.new(
      name: "Helpfulness",
      evaluation_params: [:input, :actual_output],
      evaluation_steps: ["Check the answer"]
    )
  end

  describe "GEval under DEEPEVAL_EVAL_MODE=system_one" do
    test "resolves an LLM-only context, building no System One model" do
      assert Context.resolve!(GEval, []) == %Context{mode: :llm, model: nil, llm?: true}
    end

    test "is judged by its LLM, with no TypeSafe key configured" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 8, "reason" => "Helpful."})
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      result = Evaluator.evaluate_metric(test_case, g_eval(), adapter: :mock)

      assert %{score: 0.8, reason: "Helpful.", error: nil, success: true} = result
      assert result.evaluation_model == "mock-model"
      assert result.confidence == nil
      assert result.system_one_fallback_reason == nil
    end

    test "makes no System One call, even with a System One model configured" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 6, "reason" => "Fine."})
      system_one = SystemOneMock.new(model: "fake-jev")
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      result =
        Evaluator.evaluate_metric(test_case, g_eval(),
          adapter: :mock,
          system_one_model: system_one
        )

      assert %{score: 0.6, error: nil} = result
      assert result.evaluation_model == "mock-model"
      assert SystemOneMock.calls(system_one) == []
    end

    test "stays LLM-only when measured with its options" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 8, "reason" => "Good."})
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, %{score: 0.8, evaluation_model: "mock-model"}} =
               GEval.measure(test_case,
                 name: "Inline",
                 evaluation_params: [:input, :actual_output],
                 evaluation_steps: ["Check"],
                 adapter: :mock
               )
    end
  end

  describe "ExactMatch under DEEPEVAL_EVAL_MODE=system_one" do
    test "resolves an LLM-only context, building no System One model" do
      assert Context.resolve!(ExactMatch, []) == %Context{mode: :llm, model: nil, llm?: true}
    end

    test "ignores the mode: same result as under :llm, with no model and no cost" do
      test_case = TestCase.new!(input: "Q", actual_output: " 4 ", expected_output: "4")
      system_one = SystemOneMock.new(model: "fake-jev")

      assert {:ok, result} = ExactMatch.measure(test_case, system_one_model: system_one)
      assert {:ok, llm_result} = ExactMatch.measure(test_case, eval_mode: :llm)

      assert %{score: 1.0, success: true, evaluation_model: nil, evaluation_cost: nil} = result
      assert result.reason == "The actual and expected outputs are exact matches."
      assert result.confidence == nil
      assert Map.drop(result, [:latency_ms]) == Map.drop(llm_result, [:latency_ms])
      assert SystemOneMock.calls(system_one) == []
    end

    test "is measured by the evaluator with no TypeSafe key configured" do
      test_case = TestCase.new!(input: "Q", actual_output: "5", expected_output: "4")

      assert %{score: +0.0, success: false, error: nil, evaluation_model: nil} =
               Evaluator.evaluate_metric(test_case, ExactMatch, [])
    end
  end
end
