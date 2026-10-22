defmodule DeepEvalEx.SystemOne.ModeTest do
  # Reads and writes DEEPEVAL_EVAL_MODE and the :eval_mode application env.
  use ExUnit.Case, async: false

  alias DeepEvalEx.SystemOne.Mode

  doctest Mode

  defmodule WholeChainMetric do
    @moduledoc false
    def system_one_eval_spec(_test_case, _opts), do: :spec
  end

  defmodule NilSpecMetric do
    @moduledoc false
    # Exports the callback but has no whole-chain spec, as ToolCorrectness.
    def system_one_eval_spec(_test_case, _opts), do: nil
  end

  defmodule NoSpecMetric do
    @moduledoc false
    def measure(_test_case, _opts), do: :ok
  end

  setup do
    saved_env = System.get_env("DEEPEVAL_EVAL_MODE")
    saved_config = Application.fetch_env(:deep_eval_ex, :eval_mode)
    System.delete_env("DEEPEVAL_EVAL_MODE")
    Application.delete_env(:deep_eval_ex, :eval_mode)

    on_exit(fn ->
      if saved_env,
        do: System.put_env("DEEPEVAL_EVAL_MODE", saved_env),
        else: System.delete_env("DEEPEVAL_EVAL_MODE")

      case saved_config do
        {:ok, value} -> Application.put_env(:deep_eval_ex, :eval_mode, value)
        :error -> Application.delete_env(:deep_eval_ex, :eval_mode)
      end
    end)
  end

  describe "resolve/1" do
    test "defaults to :llm when nothing is set" do
      assert Mode.resolve([]) == :llm
      assert Mode.resolve(eval_mode: nil) == :llm
      assert Mode.resolve(nil) == :llm
    end

    test "the metric's :eval_mode wins over app config and the environment" do
      System.put_env("DEEPEVAL_EVAL_MODE", "hybrid")
      Application.put_env(:deep_eval_ex, :eval_mode, :hybrid)

      assert Mode.resolve(eval_mode: :system_one) == :system_one
      assert Mode.resolve(eval_mode: :llm) == :llm
      assert Mode.resolve(:system_one) == :system_one
    end

    test "normalises the metric option's case and whitespace, as normalize_eval_mode" do
      assert Mode.resolve(eval_mode: " Hybrid ") == :hybrid
      assert Mode.resolve(eval_mode: "SYSTEM_ONE") == :system_one
      assert Mode.resolve(eval_mode: :LLM) == :llm
    end

    test "an invalid metric option raises with deepeval's message" do
      for {value, shown} <- [{"bogus", "'bogus'"}, {:bogus, "'bogus'"}, {"", "''"}, {1, "1"}] do
        assert_raise ArgumentError,
                     "Unsupported eval_mode #{shown}. Valid values: llm, hybrid, system_one.",
                     fn -> Mode.resolve(eval_mode: value) end
      end
    end

    test "falls back to app config, then DEEPEVAL_EVAL_MODE" do
      System.put_env("DEEPEVAL_EVAL_MODE", " SYSTEM_ONE ")
      assert Mode.resolve([]) == :system_one

      Application.put_env(:deep_eval_ex, :eval_mode, :hybrid)
      assert Mode.resolve([]) == :hybrid
    end

    test "an invalid setting is ignored" do
      System.put_env("DEEPEVAL_EVAL_MODE", "bogus")
      assert Mode.resolve([]) == :llm

      Application.put_env(:deep_eval_ex, :eval_mode, :bogus)
      System.put_env("DEEPEVAL_EVAL_MODE", "hybrid")
      assert Mode.resolve([]) == :hybrid
    end
  end

  describe "for_classifier/1" do
    test "runs :hybrid as :llm, from the option or the setting" do
      assert Mode.for_classifier(eval_mode: :hybrid) == :llm

      System.put_env("DEEPEVAL_EVAL_MODE", "hybrid")
      assert Mode.for_classifier([]) == :llm
    end

    test "keeps :llm and :system_one" do
      assert Mode.for_classifier(eval_mode: :system_one) == :system_one
      assert Mode.for_classifier(eval_mode: :llm) == :llm
      assert Mode.for_classifier([]) == :llm
    end

    test "raises on an invalid option" do
      assert_raise ArgumentError, ~r/Unsupported eval_mode 'x'/, fn ->
        Mode.for_classifier(eval_mode: "x")
      end
    end
  end

  describe "uses_system_one?/1" do
    test "is true for every mode but :llm" do
      refute Mode.uses_system_one?(:llm)
      assert Mode.uses_system_one?(:hybrid)
      assert Mode.uses_system_one?(:system_one)
    end
  end

  describe "effective/2" do
    test "keeps :system_one for a metric that exports system_one_eval_spec/2" do
      assert Mode.effective(WholeChainMetric, eval_mode: :system_one) == :system_one
    end

    test "exporting the callback counts even when it returns nil" do
      assert Mode.effective(NilSpecMetric, eval_mode: :system_one) == :system_one
    end

    test "runs :system_one as :hybrid for a metric with no whole-metric form" do
      assert Mode.effective(NoSpecMetric, eval_mode: :system_one) == :hybrid

      System.put_env("DEEPEVAL_EVAL_MODE", "system_one")
      assert Mode.effective(NoSpecMetric, []) == :hybrid
    end

    test "leaves :llm and :hybrid alone" do
      for metric <- [WholeChainMetric, NoSpecMetric] do
        assert Mode.effective(metric, eval_mode: :llm) == :llm
        assert Mode.effective(metric, eval_mode: :hybrid) == :hybrid
        assert Mode.effective(metric, []) == :llm
      end
    end

    test "takes an already-resolved mode" do
      assert Mode.effective(NoSpecMetric, :system_one) == :hybrid
      assert Mode.effective(WholeChainMetric, :system_one) == :system_one
    end

    test "raises on an invalid option" do
      assert_raise ArgumentError, ~r/Unsupported eval_mode/, fn ->
        Mode.effective(WholeChainMetric, eval_mode: "nope")
      end
    end
  end

  describe "normalize/1" do
    test "is case-insensitive and ignores whitespace; anything else is nil" do
      assert Mode.normalize(" Hybrid\n") == :hybrid
      assert Mode.normalize(:system_one) == :system_one
      assert Mode.normalize("llm") == :llm
      assert Mode.normalize("system-one") == nil
      assert Mode.normalize("") == nil
      assert Mode.normalize(nil) == nil
      assert Mode.normalize(1) == nil
    end
  end
end
