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

  # A judge without structured outputs: generate_with_schema/3 must not be
  # called, and generate/2 answers with text around the JSON.
  defmodule TextJudge do
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, opts), do: {:ok, Keyword.fetch!(opts, :reply)}

    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: raise("not called")

    @impl true
    def model_name(_opts), do: "text-judge"

    @impl true
    def supports_structured_outputs?, do: false

    @impl true
    def supports_log_probs?, do: false
  end

  # A judge whose generate_with_schema/3 returns its raw text, as deepeval's
  # custom models may.
  defmodule RawJudge do
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: raise("not called")

    @impl true
    def generate_with_schema(_prompt, _schema, opts), do: Keyword.fetch!(opts, :reply)

    @impl true
    def model_name(_opts), do: "raw-judge"

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false
  end

  @schema %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}}
  @invalid "Evaluation LLM outputted an invalid JSON. Please use a better evaluation model."

  describe "generate_with_schema/3 JSON fallback" do
    test "parses the text of a judge without structured outputs with trimAndLoadJson" do
      reply = ~s(Here you go:\n```json\n{"reason": "Fine.",}\n```)

      assert Adapter.generate_with_schema("Why?", @schema, adapter: TextJudge, reply: reply) ==
               {:ok, %{"reason" => "Fine."}}
    end

    test "parses a binary a structured judge returns" do
      reply = {:ok, ~s({"reason": "Fine.")}

      assert Adapter.generate_with_schema("Why?", @schema, adapter: RawJudge, reply: reply) ==
               {:ok, %{"reason" => "Fine."}}
    end

    test "passes a decoded map through unchanged" do
      reply = {:ok, %{"reason" => "Fine.,}"}}

      assert Adapter.generate_with_schema("Why?", @schema, adapter: RawJudge, reply: reply) ==
               reply
    end

    test "returns deepeval's error for text holding no valid JSON" do
      for reply <- [{:ok, "I cannot help with that."}, {:ok, nil}] do
        assert {:error, %DeepEvalEx.LLM.InvalidJSONError{} = error} =
                 Adapter.generate_with_schema("Why?", @schema, adapter: RawJudge, reply: reply)

        assert Exception.message(error) == @invalid
      end

      assert {:error, error} =
               Adapter.generate_with_schema("Why?", @schema, adapter: TextJudge, reply: "No.")

      assert Exception.message(error) == @invalid
    end

    test "passes adapter errors through" do
      reply = {:error, :timeout}

      assert Adapter.generate_with_schema("Why?", @schema, adapter: RawJudge, reply: reply) ==
               reply
    end
  end

  describe "capabilities" do
    test "default to temperature support and no JSON mode" do
      assert TextJudge.supports_temperature?([])
      refute TextJudge.supports_json_mode?()
      refute TextJudge.supports_multimodal?()
    end

    test "are reported for an adapter, falling back to the defaults" do
      assert Adapter.supports_temperature?(TextJudge, [])
      refute Adapter.supports_json_mode?(TextJudge)

      refute Adapter.supports_temperature?(DeepEvalEx.LLM.Adapters.OpenAI, model: "o3-mini")
      assert Adapter.supports_json_mode?(DeepEvalEx.LLM.Adapters.OpenAI)
    end
  end
end
