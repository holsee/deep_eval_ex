# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ConfigTest do
  # Not async: the tests set environment variables and application config.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Config

  # deepeval 4.3.1's config/settings.py names, per setting.
  @env_vars %{
    results_folder: "DEEPEVAL_RESULTS_FOLDER",
    identifier: "DEEPEVAL_IDENTIFIER",
    ignore_errors: "IGNORE_DEEPEVAL_ERRORS",
    skip_on_missing_params: "SKIP_DEEPEVAL_MISSING_PARAMS",
    verbose_mode: "DEEPEVAL_VERBOSE_MODE",
    use_cache: "ENABLE_DEEPEVAL_CACHE",
    per_task_timeout_seconds_override: "DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE",
    retry_max_attempts: "DEEPEVAL_RETRY_MAX_ATTEMPTS",
    retry_initial_seconds: "DEEPEVAL_RETRY_INITIAL_SECONDS",
    retry_exp_base: "DEEPEVAL_RETRY_EXP_BASE",
    retry_jitter: "DEEPEVAL_RETRY_JITTER",
    retry_cap_seconds: "DEEPEVAL_RETRY_CAP_SECONDS",
    eval_mode: "DEEPEVAL_EVAL_MODE",
    file_system: "DEEPEVAL_FILE_SYSTEM",
    cache_folder: "DEEPEVAL_CACHE_FOLDER",
    typesafe_api_key: "TYPESAFE_API_KEY",
    typesafe_model_name: "TYPESAFE_MODEL_NAME",
    typesafe_cost_per_input_token: "TYPESAFE_COST_PER_INPUT_TOKEN"
  }

  # DeepEvalEx's own settings, without an environment variable.
  @own_settings [:print_results]

  doctest Config

  setup do
    previous_env = Map.new(@env_vars, fn {_key, var} -> {var, System.get_env(var)} end)

    previous_config =
      Map.new(Map.keys(@env_vars) ++ @own_settings, fn key ->
        {key, Application.fetch_env(:deep_eval_ex, key)}
      end)

    Enum.each(@env_vars, fn {key, var} ->
      System.delete_env(var)
      Application.delete_env(:deep_eval_ex, key)
    end)

    Enum.each(@own_settings, &Application.delete_env(:deep_eval_ex, &1))

    on_exit(fn ->
      System.delete_env("DEEP_EVAL_EX_DOC_EXAMPLE")
      Application.delete_env(:deep_eval_ex, :doc_example)

      Enum.each(previous_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      Enum.each(previous_config, fn
        {key, :error} -> Application.delete_env(:deep_eval_ex, key)
        {key, {:ok, value}} -> Application.put_env(:deep_eval_ex, key, value)
      end)
    end)
  end

  describe "keys/0 and env_var/1" do
    test "cover deepeval's settings under their 4.3.1 environment variable names" do
      assert Enum.sort(Config.keys()) == Enum.sort(Map.keys(@env_vars) ++ @own_settings)

      for {key, var} <- @env_vars do
        assert Config.env_var(key) == var
      end
    end

    test "DeepEvalEx's own settings have no environment variable" do
      for key <- @own_settings, do: assert(Config.env_var(key) == nil)
    end

    test "raise on an unknown setting" do
      assert_raise ArgumentError, ~r/unknown DeepEvalEx setting: :nope/, fn ->
        Config.get(:nope)
      end
    end
  end

  describe "get/1 precedence" do
    test "application config wins over the environment variable" do
      System.put_env("DEEPEVAL_RESULTS_FOLDER", "env-out")
      Application.put_env(:deep_eval_ex, :results_folder, "config-out")

      assert Config.get(:results_folder) == "config-out"
    end

    test "a false config value wins over a truthy environment variable" do
      System.put_env("IGNORE_DEEPEVAL_ERRORS", "true")
      Application.put_env(:deep_eval_ex, :ignore_errors, false)

      assert Config.get(:ignore_errors) == false
    end

    test "a blank config value falls through to the environment variable" do
      System.put_env("DEEPEVAL_IDENTIFIER", "env-run")

      for blank <- [nil, "", "  "] do
        Application.put_env(:deep_eval_ex, :identifier, blank)
        assert Config.get(:identifier) == "env-run", "expected env for #{inspect(blank)}"
      end
    end

    test "a blank environment variable is unset" do
      for blank <- ["", "  \n"] do
        System.put_env("DEEPEVAL_RETRY_MAX_ATTEMPTS", blank)
        System.put_env("DEEPEVAL_RESULTS_FOLDER", blank)

        assert Config.get(:retry_max_attempts) == 2
        assert Config.get(:results_folder) == nil
      end
    end
  end

  describe ":print_results" do
    test "defaults to true, as deepeval's DisplayConfig.print_results" do
      assert Config.get(:print_results) == true
    end

    test "is read from application config only" do
      Application.put_env(:deep_eval_ex, :print_results, false)
      assert Config.get(:print_results) == false

      Application.put_env(:deep_eval_ex, :print_results, "no")
      assert Config.get(:print_results) == false
    end
  end

  describe "string settings" do
    test "are nil when unset and trimmed when set" do
      for key <- [:results_folder, :identifier, :typesafe_api_key, :typesafe_model_name] do
        assert Config.get(key) == nil

        System.put_env(Config.env_var(key), "  value \n")
        assert Config.get(key) == "value"
      end
    end
  end

  describe "boolean settings" do
    @booleans [:ignore_errors, :skip_on_missing_params, :verbose_mode, :use_cache]

    test "default to false" do
      for key <- @booleans, do: assert(Config.get(key) == false)
    end

    test "parse the environment variable with deepeval's parse_bool" do
      for key <- @booleans do
        var = Config.env_var(key)

        for value <- ["1", "YES", " 'on' ", "enabled"] do
          System.put_env(var, value)
          assert Config.get(key) == true, "expected #{var}=#{inspect(value)} to be true"
        end

        for value <- ["0", "off", "maybe"] do
          System.put_env(var, value)
          assert Config.get(key) == false, "expected #{var}=#{inspect(value)} to be false"
        end
      end
    end

    test "accept booleans and env-style strings in application config" do
      Application.put_env(:deep_eval_ex, :verbose_mode, true)
      assert Config.get(:verbose_mode) == true

      Application.put_env(:deep_eval_ex, :verbose_mode, "yes")
      assert Config.get(:verbose_mode) == true

      Application.put_env(:deep_eval_ex, :verbose_mode, "no")
      assert Config.get(:verbose_mode) == false
    end
  end

  describe "numeric settings" do
    test "default to deepeval's values" do
      assert Config.get(:retry_max_attempts) == 2
      assert Config.get(:retry_initial_seconds) == 1.0
      assert Config.get(:retry_exp_base) == 2.0
      assert Config.get(:retry_jitter) == 2.0
      assert Config.get(:retry_cap_seconds) == 5.0
      assert Config.get(:per_task_timeout_seconds_override) == nil
      assert Config.get(:typesafe_cost_per_input_token) == nil
    end

    test "parse integers as pydantic does, accepting a zero fraction" do
      for {value, expected} <- [{"3", 3}, {" 3 ", 3}, {"2.0", 2}] do
        System.put_env("DEEPEVAL_RETRY_MAX_ATTEMPTS", value)
        assert Config.get(:retry_max_attempts) === expected
      end
    end

    test "parse floats, returning floats for integer input" do
      for {value, expected} <- [{"0.5", 0.5}, {" 1.5 ", 1.5}, {"1e-1", 0.1}, {"3", 3.0}] do
        System.put_env("DEEPEVAL_RETRY_INITIAL_SECONDS", value)
        assert Config.get(:retry_initial_seconds) === expected
      end

      System.put_env("DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", "0")
      assert Config.get(:per_task_timeout_seconds_override) === 0.0

      # A free Jev, as TypeSafeModel(cost_per_input_token=0) accepts.
      System.put_env("TYPESAFE_COST_PER_INPUT_TOKEN", "0")
      assert Config.get(:typesafe_cost_per_input_token) === 0.0

      Application.put_env(:deep_eval_ex, :retry_cap_seconds, 10)
      assert Config.get(:retry_cap_seconds) === 10.0
    end

    test "raise naming the environment variable on an invalid value, as deepeval's settings do" do
      for {var, value, message} <- [
            {"DEEPEVAL_RETRY_MAX_ATTEMPTS", "0", "an integer greater than or equal to 1"},
            {"DEEPEVAL_RETRY_MAX_ATTEMPTS", "2.5", "an integer greater than or equal to 1"},
            {"DEEPEVAL_RETRY_MAX_ATTEMPTS", "abc", "an integer greater than or equal to 1"},
            {"DEEPEVAL_RETRY_INITIAL_SECONDS", "-1", "a number greater than or equal to 0"},
            {"DEEPEVAL_RETRY_EXP_BASE", "0.5", "a number greater than or equal to 1"},
            {"DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", "none",
             "a number greater than or equal to 0"},
            {"TYPESAFE_COST_PER_INPUT_TOKEN", "-1e-06", "a number greater than or equal to 0"}
          ] do
        System.put_env(var, value)
        key = Enum.find_value(@env_vars, fn {key, v} -> if v == var, do: key end)

        error = assert_raise ArgumentError, fn -> Config.get(key) end
        assert error.message == "#{var} must be #{message}, got: #{inspect(value)}"

        System.delete_env(var)
      end
    end

    test "raise naming the config key on an invalid application config value" do
      Application.put_env(:deep_eval_ex, :retry_max_attempts, 0)

      assert_raise ArgumentError,
                   "config :deep_eval_ex, :retry_max_attempts must be an integer " <>
                     "greater than or equal to 1, got: 0",
                   fn -> Config.get(:retry_max_attempts) end
    end
  end

  describe "per_task_timeout_seconds/0" do
    defmodule NapMetric do
      @moduledoc false

      def metric_name, do: "NapMetric"

      def measure(_test_case, _opts) do
        Process.sleep(1_000)
        {:ok, %DeepEvalEx.Result{metric: metric_name(), score: 1.0, success: true}}
      end
    end

    test "is deepeval's default outer budget of 180 seconds without an override" do
      assert Config.per_task_timeout_seconds() === 180.0

      # deepeval treats an override of 0 as unset.
      System.put_env("DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", "0")
      assert Config.per_task_timeout_seconds() === 180.0
    end

    test "is DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE when set, config first" do
      System.put_env("DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", "2.5")
      assert Config.per_task_timeout_seconds() === 2.5

      Application.put_env(:deep_eval_ex, :per_task_timeout_seconds_override, 30)
      assert Config.per_task_timeout_seconds() === 30.0
    end

    test "is the evaluator's default per-test-case timeout" do
      System.put_env("DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", "0.1")
      test_case = DeepEvalEx.TestCase.new!(input: "a", actual_output: "b")

      assert [[result]] =
               DeepEvalEx.Evaluator.evaluate([test_case], [NapMetric],
                 run_async: false,
                 ignore_errors: true
               )

      assert result.error ==
               "Timed out after 0.10s while evaluating metric. " <>
                 "Increase DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE or set " <>
                 "DEEPEVAL_LOG_STACK_TRACES=1 for full traceback."
    end
  end

  describe "eval_mode" do
    test "is nil when unset" do
      assert Config.get(:eval_mode) == nil
    end

    test "normalises case and whitespace, as deepeval's normalize_eval_mode" do
      for {value, expected} <- [
            {"llm", :llm},
            {" Hybrid ", :hybrid},
            {"SYSTEM_ONE", :system_one}
          ] do
        System.put_env("DEEPEVAL_EVAL_MODE", value)
        assert Config.get(:eval_mode) == expected
      end
    end

    test "treats an unrecognised value as unset" do
      System.put_env("DEEPEVAL_EVAL_MODE", "bogus")
      assert Config.get(:eval_mode) == nil

      System.put_env("DEEPEVAL_EVAL_MODE", "hybrid")
      Application.put_env(:deep_eval_ex, :eval_mode, :bogus)
      assert Config.get(:eval_mode) == :hybrid
    end

    test "accepts atoms in application config" do
      System.put_env("DEEPEVAL_EVAL_MODE", "hybrid")
      Application.put_env(:deep_eval_ex, :eval_mode, :system_one)
      assert Config.get(:eval_mode) == :system_one
    end
  end

  describe "file_system and read_only?/0" do
    test "is nil, not read-only, when unset" do
      assert Config.get(:file_system) == nil
      refute Config.read_only?()
    end

    test "accepts deepeval's READ_ONLY aliases, case-insensitively" do
      for value <- ["READ_ONLY", " read-only ", "ReadOnly", "ro"] do
        System.put_env("DEEPEVAL_FILE_SYSTEM", value)
        assert Config.get(:file_system) == :read_only, "expected :read_only for #{inspect(value)}"
        assert Config.read_only?()
      end
    end

    test "accepts :read_only in application config" do
      Application.put_env(:deep_eval_ex, :file_system, :read_only)
      assert Config.read_only?()
    end

    test "raises like deepeval's settings on any other value" do
      System.put_env("DEEPEVAL_FILE_SYSTEM", "READ_WRITE")

      assert_raise ArgumentError,
                   "DEEPEVAL_FILE_SYSTEM must be READ_ONLY (case-insensitive), got: \"READ_WRITE\"",
                   fn -> Config.read_only?() end
    end
  end

  describe "cache_folder" do
    test "defaults to deepeval's .deepeval" do
      assert Config.get(:cache_folder) == ".deepeval"
    end

    test "reads DEEPEVAL_CACHE_FOLDER" do
      System.put_env("DEEPEVAL_CACHE_FOLDER", "/var/cache/deepeval")
      assert Config.get(:cache_folder) == "/var/cache/deepeval"
    end
  end

  describe "parse_bool/2" do
    test "reads deepeval's truthy and falsy tokens, ignoring case, quotes and whitespace" do
      for value <- ~w(1 true T yes y ON enable Enabled) ++ [~s( "true" )] do
        assert Config.parse_bool(value) == true, "expected #{inspect(value)} to be true"
      end

      for value <- ~w(0 false f no n off disable disabled) do
        assert Config.parse_bool(value, true) == false
      end
    end

    test "returns the default when unset, blank or unrecognised" do
      assert Config.parse_bool(nil) == false
      assert Config.parse_bool("maybe") == false
      assert Config.parse_bool("", true) == true
      assert Config.parse_bool("maybe", true) == true
    end

    test "passes booleans through and reads numbers as non-zero" do
      assert Config.parse_bool(true) == true
      assert Config.parse_bool(false, true) == false
      assert Config.parse_bool(0) == false
      assert Config.parse_bool(2.5) == true
    end
  end

  describe "env/1 and config/1" do
    test "treat blank values as unset and trim set ones" do
      System.put_env("DEEP_EVAL_EX_DOC_EXAMPLE", " \t")
      assert Config.env("DEEP_EVAL_EX_DOC_EXAMPLE") == nil

      Application.put_env(:deep_eval_ex, :doc_example, 0.3)
      assert Config.config(:doc_example) == 0.3
    end
  end
end
