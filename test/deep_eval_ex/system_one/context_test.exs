defmodule DeepEvalEx.SystemOne.ContextTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Context, Model}
  alias DeepEvalEx.Test.SystemOneToy

  doctest Context

  defmodule WholeChainMetric do
    @moduledoc false
    def system_one_eval_spec(_test_case, _opts), do: nil
  end

  defmodule DecisionsOnlyMetric do
    @moduledoc false
    def measure(_test_case, _opts), do: :ok
  end

  describe "resolve!/2 under :llm" do
    test "builds no System One model, whatever :system_one_model says" do
      assert Context.resolve!(WholeChainMetric, eval_mode: :llm, system_one_model: 42) ==
               %Context{mode: :llm, model: nil, llm?: true}
    end
  end

  describe "resolve!/2 under :hybrid" do
    test "resolves and initialises the model and keeps the LLM" do
      mock = Mock.new(model: "fake-jev")

      assert %Context{mode: :hybrid, llm?: true, model: %Model{adapter: Mock, name: "fake-jev"}} =
               Context.resolve!(DecisionsOnlyMetric, eval_mode: "hybrid", system_one_model: mock)
    end

    test "keeps the options init/1 returns" do
      assert %Context{model: %Model{adapter: SystemOneToy, opts: [api_key: "k"], name: "toy-v1"}} =
               Context.resolve!(DecisionsOnlyMetric,
                 eval_mode: :hybrid,
                 system_one_model: {SystemOneToy, api_key: "k"}
               )
    end
  end

  describe "resolve!/2 under :system_one" do
    test "has no LLM for a metric with a whole-chain form" do
      context =
        Context.resolve!(WholeChainMetric,
          eval_mode: :system_one,
          system_one_model: Mock.new(),
          # Not resolved: no LLM is built under system_one.
          adapter: :no_such_adapter
        )

      assert %Context{mode: :system_one, llm?: false, model: %Model{adapter: Mock}} = context
    end

    test "runs a metric without system_one_eval_spec/2 as :hybrid, with its LLM" do
      assert %Context{mode: :hybrid, llm?: true, model: %Model{adapter: Mock}} =
               Context.resolve!(DecisionsOnlyMetric,
                 eval_mode: :system_one,
                 system_one_model: Mock.new()
               )
    end
  end

  test "an init/1 failure raises DeepEvalError with deepeval's text" do
    error =
      assert_raise DeepEvalError, fn ->
        Context.resolve!(WholeChainMetric, eval_mode: :system_one, system_one_model: SystemOneToy)
      end

    assert error.message ==
             "DEEPEVAL_EVAL_MODE=system_one routes metric decisions to toy-v1, but it is not " <>
               "usable: SystemOneToy needs :api_key Fix its options or switch back with " <>
               "`deepeval set-eval-mode llm`."
  end

  test "an unrecognised :eval_mode or :system_one_model raises ArgumentError" do
    assert_raise ArgumentError, ~r/Unsupported eval_mode 'fast'/, fn ->
      Context.resolve!(WholeChainMetric, eval_mode: "fast")
    end

    assert_raise ArgumentError, ~r/invalid System One model/, fn ->
      Context.resolve!(WholeChainMetric, eval_mode: :hybrid, system_one_model: 42)
    end
  end

  test "an already resolved context in :system_one is returned as it is" do
    context = %Context{mode: :hybrid, model: Model.resolve(Mock.new()), llm?: true}

    assert Context.resolve!(WholeChainMetric, eval_mode: :llm, system_one: context) == context
  end
end
