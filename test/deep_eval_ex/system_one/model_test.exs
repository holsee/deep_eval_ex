defmodule DeepEvalEx.SystemOne.ModelTest do
  # Reads and writes the :system_one_model application env.
  use ExUnit.Case, async: false

  alias DeepEvalEx.SystemOne.{Error, Model}
  alias DeepEvalEx.Test.{SystemOneBare, SystemOneStub}

  doctest DeepEvalEx.SystemOne.Model

  setup do
    saved = Application.fetch_env(:deep_eval_ex, :system_one_model)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:deep_eval_ex, :system_one_model, value)
        :error -> Application.delete_env(:deep_eval_ex, :system_one_model)
      end
    end)
  end

  describe "resolve/1" do
    test "takes a module or {module, opts}, named by its model_name/1" do
      assert Model.resolve(SystemOneStub) == %Model{
               adapter: SystemOneStub,
               opts: [],
               name: "stub-jev"
             }

      assert Model.resolve({SystemOneStub, name: "jev-x"}) ==
               %Model{adapter: SystemOneStub, opts: [name: "jev-x"], name: "jev-x"}
    end

    test "passes a resolved model through" do
      model = Model.resolve(SystemOneBare)
      assert Model.resolve(model) == model
    end

    test "nil is the configured :system_one_model" do
      Application.put_env(:deep_eval_ex, :system_one_model, {SystemOneStub, name: "configured"})
      assert %Model{adapter: SystemOneStub, name: "configured"} = Model.resolve(nil)
    end

    test "aliases name the built-in adapters, a string a TypeSafe model" do
      assert Model.adapter(:typesafe) == DeepEvalEx.SystemOne.Adapters.TypeSafe
      assert Model.adapter(:jev) == DeepEvalEx.SystemOne.Adapters.TypeSafe
      assert Model.adapter(:mock) == DeepEvalEx.SystemOne.Adapters.Mock
      assert Model.adapter(SystemOneStub) == SystemOneStub

      assert Model.spec("jev-preview") ==
               {DeepEvalEx.SystemOne.Adapters.TypeSafe, model: "jev-preview"}

      assert Model.spec(nil) == {DeepEvalEx.SystemOne.Adapters.TypeSafe, []}
      assert Model.spec({:mock, model: "m"}) == {DeepEvalEx.SystemOne.Adapters.Mock, model: "m"}
    end

    test "an adapter that is not a System One adapter raises ArgumentError" do
      assert_raise ArgumentError, ~r/not a System One adapter/, fn -> Model.resolve(Enum) end

      assert_raise ArgumentError, ~r/not a System One adapter/, fn ->
        Model.resolve(NoSuchAdapter)
      end

      assert_raise ArgumentError, ~r/invalid System One model/, fn -> Model.resolve(42) end
    end
  end

  describe "init/1" do
    test "runs the adapter's init/1, keeping the options it returns" do
      model = Model.resolve({SystemOneStub, init: {:ok, [name: "after-init"]}})
      assert {:ok, %Model{opts: [name: "after-init"], name: "after-init"}} = Model.init(model)

      error = %Error{reason: :auth, type: "DeepEvalError", message: "no key", permanent?: true}
      model = Model.resolve({SystemOneStub, init: {:error, error}})
      assert Model.init(model) == {:error, error}
    end

    test "is a passthrough for an adapter without init/1" do
      model = Model.resolve(SystemOneBare)
      assert Model.init(model) == {:ok, model}
    end
  end

  describe "context_budget/1" do
    test "is the adapter's, else Jev's 32k state and 64k request limits" do
      assert Model.context_budget(Model.resolve(SystemOneBare)) == {32_000, 64_000}
      assert Model.context_budget(Model.resolve(SystemOneStub)) == {32_000, 64_000}

      assert Model.context_budget(Model.resolve({SystemOneStub, budget: :unbounded})) ==
               :unbounded
    end
  end
end
