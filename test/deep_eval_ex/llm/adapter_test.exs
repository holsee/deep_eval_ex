defmodule DeepEvalEx.LLM.AdapterTest do
  # Mutates application and OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapter

  @var "DEEP_EVAL_EX_ADAPTER_TEST"
  @key :adapter_test_value

  setup do
    on_exit(fn ->
      System.delete_env(@var)
      System.delete_env("DEEP_EVAL_EX_DOC_EXAMPLE")
      Application.delete_env(:deep_eval_ex, @key)
      Application.delete_env(:deep_eval_ex, :doc_example)
    end)
  end

  doctest Adapter, only: [env: 1, config: 1]

  describe "env/1" do
    test "returns nil for an unset variable" do
      System.delete_env(@var)
      assert Adapter.env(@var) == nil
    end

    test "treats blank values as unset" do
      for blank <- ["", "  ", "\n\t"] do
        System.put_env(@var, blank)
        assert Adapter.env(@var) == nil, "expected nil for #{inspect(blank)}"
      end
    end

    test "trims surrounding whitespace from a set value" do
      System.put_env(@var, "  sk-test\n")
      assert Adapter.env(@var) == "sk-test"
    end
  end

  describe "config/1" do
    test "returns nil for an unset key" do
      assert Adapter.config(@key) == nil
    end

    test "treats blank strings as unset" do
      for blank <- ["", "  ", "\n"] do
        Application.put_env(:deep_eval_ex, @key, blank)
        assert Adapter.config(@key) == nil, "expected nil for #{inspect(blank)}"
      end
    end

    test "trims surrounding whitespace from a string value" do
      Application.put_env(:deep_eval_ex, @key, " https://example.com/v1 ")
      assert Adapter.config(@key) == "https://example.com/v1"
    end

    test "passes non-string values through" do
      Application.put_env(:deep_eval_ex, @key, 0.3)
      assert Adapter.config(@key) == 0.3
    end
  end
end
