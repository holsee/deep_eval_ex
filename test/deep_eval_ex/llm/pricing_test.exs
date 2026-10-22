defmodule DeepEvalEx.LLM.PricingTest do
  # Mutates the :model_pricing application env, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Pricing

  doctest Pricing

  setup do
    saved = Application.get_env(:deep_eval_ex, :model_pricing)
    Application.delete_env(:deep_eval_ex, :model_pricing)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:deep_eval_ex, :model_pricing, saved),
        else: Application.delete_env(:deep_eval_ex, :model_pricing)
    end)
  end

  describe "price/1" do
    test "returns deepeval's per-1M-token prices for known OpenAI models" do
      assert Pricing.price("gpt-4o-mini") == %{input: 0.15, output: 0.60}
      assert Pricing.price("gpt-4o") == %{input: 2.50, output: 10.00}
      assert Pricing.price("gpt-4.1") == %{input: 2.00, output: 8.00}
      assert Pricing.price("o3-mini") == %{input: 1.10, output: 4.40}
    end

    test "returns deepeval's per-1M-token prices for known Anthropic models" do
      assert Pricing.price("claude-opus-5") == %{input: 5.00, output: 25.00}
      assert Pricing.price("claude-opus-5-5") == %{input: 4.00, output: 20.00}
      assert Pricing.price("claude-sonnet-5") == %{input: 2.00, output: 10.00}
      assert Pricing.price("claude-haiku-4-5-20251001") == %{input: 1.00, output: 5.00}
      assert Pricing.price("claude-3-haiku-20240307") == %{input: 0.25, output: 1.25}
      assert Pricing.price("claude-3-5-haiku-latest") == %{input: 0.80, output: 4.00}
      assert Pricing.price("claude-fable-5-1") == %{input: 10.00, output: 50.00}
    end

    test "returns nil for unknown models and models deepeval leaves unpriced" do
      assert Pricing.price("my-local-llama") == nil
      assert Pricing.price("o1-mini") == nil
      assert Pricing.price(nil) == nil
    end

    test "prefers :model_pricing config over the built-in table" do
      Application.put_env(:deep_eval_ex, :model_pricing, %{
        "gpt-4o-mini" => %{input: 1.0, output: 2.0},
        "my-local-llama" => %{input: 0.0, output: 0.0}
      })

      assert Pricing.price("gpt-4o-mini") == %{input: 1.0, output: 2.0}
      assert Pricing.price("my-local-llama") == %{input: 0.0, output: 0.0}
      assert Pricing.price("gpt-4o") == %{input: 2.50, output: 10.00}
    end
  end

  describe "cost/3" do
    test "prices input and output tokens per million" do
      assert_in_delta Pricing.cost("gpt-4o-mini", 1_000_000, 1_000_000), 0.75, 1.0e-12
      assert_in_delta Pricing.cost("gpt-4o", 1_000, 500), 0.0075, 1.0e-12
    end

    test "is nil for an unknown model, never a guess" do
      assert Pricing.cost("my-local-llama", 1_000, 500) == nil
    end

    test "is nil when token counts are unknown" do
      assert Pricing.cost("gpt-4o", nil, 500) == nil
      assert Pricing.cost("gpt-4o", 1_000, nil) == nil
    end
  end

  describe ":model_pricing validation" do
    test "rejects an entry missing a price with a clear ArgumentError" do
      Application.put_env(:deep_eval_ex, :model_pricing, %{"my-llm" => %{input: 1.0}})

      assert_raise ArgumentError,
                   ~r/:model_pricing entry for "my-llm".*%\{input: number, output: number\}/s,
                   fn ->
                     Pricing.cost("my-llm", 100, 50)
                   end
    end

    test "rejects non-numeric or negative prices" do
      for price <- [%{input: "1.0", output: 2.0}, %{input: -1, output: 2.0}, {1.0, 2.0}, nil] do
        Application.put_env(:deep_eval_ex, :model_pricing, %{"my-llm" => price})

        assert_raise ArgumentError, ~r/:model_pricing entry for "my-llm"/, fn ->
          Pricing.price("my-llm")
        end
      end
    end

    test "rejects a :model_pricing that is not a map" do
      Application.put_env(:deep_eval_ex, :model_pricing, [{"my-llm", %{input: 1, output: 2}}])

      assert_raise ArgumentError, ~r/:model_pricing must be a map/, fn ->
        Pricing.price("gpt-4o")
      end
    end

    test "only validates the entry that is looked up" do
      Application.put_env(:deep_eval_ex, :model_pricing, %{
        "broken" => :oops,
        "my-llm" => %{input: 1, output: 2}
      })

      assert Pricing.price("my-llm") == %{input: 1, output: 2}
      assert Pricing.price("gpt-4o") == %{input: 2.50, output: 10.00}
    end
  end
end
