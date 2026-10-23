# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/config/settings.py, deepeval/config/utils.py
# (parse_bool), deepeval/config/eval_mode.py (normalize_eval_mode) and
# deepeval/utils.py (is_read_only_env)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Config do
  @moduledoc """
  Resolves DeepEvalEx's deepeval settings from application config and the
  environment variables deepeval 4.3.1 reads.

  Each setting has a key in `config :deep_eval_ex` and the environment
  variable deepeval's `config/settings.py` names it, so a `.env` shared with
  a Python deepeval project configures both. `get/1` reads the application
  config first and falls back to the environment variable, then to
  deepeval's default:

      config :deep_eval_ex,
        results_folder: "eval_results",
        verbose_mode: true,
        retry_max_attempts: 3

  | Key | Environment variable | Type | Default |
  |-----|----------------------|------|---------|
  | `:results_folder` | `DEEPEVAL_RESULTS_FOLDER` | string | `nil` |
  | `:identifier` | `DEEPEVAL_IDENTIFIER` | string | `nil` |
  | `:ignore_errors` | `IGNORE_DEEPEVAL_ERRORS` | boolean | `false` |
  | `:skip_on_missing_params` | `SKIP_DEEPEVAL_MISSING_PARAMS` | boolean | `false` |
  | `:verbose_mode` | `DEEPEVAL_VERBOSE_MODE` | boolean | `false` |
  | `:use_cache` | `ENABLE_DEEPEVAL_CACHE` | boolean | `false` |
  | `:per_task_timeout_seconds_override` | `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE` | float >= 0 | `nil` |
  | `:retry_max_attempts` | `DEEPEVAL_RETRY_MAX_ATTEMPTS` | integer >= 1 | `2` |
  | `:retry_initial_seconds` | `DEEPEVAL_RETRY_INITIAL_SECONDS` | float >= 0 | `1.0` |
  | `:retry_exp_base` | `DEEPEVAL_RETRY_EXP_BASE` | float >= 1 | `2.0` |
  | `:retry_jitter` | `DEEPEVAL_RETRY_JITTER` | float >= 0 | `2.0` |
  | `:retry_cap_seconds` | `DEEPEVAL_RETRY_CAP_SECONDS` | float >= 0 | `5.0` |
  | `:eval_mode` | `DEEPEVAL_EVAL_MODE` | `:llm`, `:hybrid` or `:system_one` | `nil` |
  | `:file_system` | `DEEPEVAL_FILE_SYSTEM` | `:read_only` | `nil` |
  | `:cache_folder` | `DEEPEVAL_CACHE_FOLDER` | string | `".deepeval"` |
  | `:typesafe_api_key` | `TYPESAFE_API_KEY` | string | `nil` |
  | `:typesafe_model_name` | `TYPESAFE_MODEL_NAME` | string | `nil` |
  | `:typesafe_cost_per_input_token` | `TYPESAFE_COST_PER_INPUT_TOKEN` | float >= 0 | `nil` |
  | `:print_results` | none | boolean | `true` |
  | `:running` | `DEEPEVAL` | boolean | `false` |
  | `:repeat` | none | integer >= 1 | `nil` |
  | `:display` | none | `:all`, `:failing` or `:passing` | `:all` |
  | `:test_file` | none | string | `nil` |
  | `:show_warnings` | none | boolean | `false` |

  `:print_results` is DeepEvalEx's own: whether `DeepEvalEx.evaluate_run/3`
  prints the evaluation report and summary (deepeval's
  `DisplayConfig.print_results`); set it to `false` to silence every run,
  in tests for instance. It has no environment variable.

  `:running`, `:repeat`, `:display`, `:test_file` and `:show_warnings` are
  the settings of a `mix deep_eval.test` run, which sets them as run
  overrides (see below): `:running` is deepeval's `get_is_running_deepeval()`
  (the `DEEPEVAL` variable, which `deepeval test run` sets to `YES`), and
  the others are the task's `--repeat`, `--display`, test path and
  `--show-warnings`.

  ## Run overrides

  `put_run_overrides/1` sets values that win over application config and
  the environment until `clear_run_overrides/0`, as deepeval's
  `set_should_use_cache`, `set_should_ignore_errors`, `set_identifier` and
  the other in-process setters win over `.env`. `mix deep_eval.test` puts
  its flags there (see `Mix.Tasks.DeepEval.Test`). An override of `nil` is
  a value, not a fall-through: `verbose_mode: nil` reads as `nil` whatever
  the config says, as `set_verbose_mode(None)` does. Overrides are kept in
  `:persistent_term`, so they are seen by every process of the VM.

  ## Parsing

  Values are parsed as deepeval's settings parse them:

  - Booleans with `parse_bool/2`: `1`, `true`, `yes`, `on`, ... are `true`
    and anything else is `false`.
  - Numbers as pydantic does: surrounding whitespace is ignored, an integer
    setting accepts a zero fraction (`"2.0"`), and a value that is not a
    number or breaks the setting's bound raises an `ArgumentError` naming
    the variable, where deepeval fails to load its settings.
  - `:eval_mode` with `DeepEvalEx.SystemOne.Mode.normalize/1`, as
    `normalize_eval_mode`: case-insensitively, and an unrecognised value
    counts as unset.
  - `:file_system` case-insensitively: `READ_ONLY`, `READ-ONLY`, `READONLY`
    and `RO` are `:read_only`, and any other value raises an
    `ArgumentError`, as deepeval's settings validator rejects it.

  Application config may hold the native value (`true`, `3`, `:hybrid`) or
  the same strings as the environment variable.

  A blank value, in application config or the environment, is unset and
  falls through to the next source (see `env/1` and `config/1`). Unlike
  deepeval, which rejects an empty numeric variable, a blank numeric
  variable therefore reads as its default.
  """

  alias DeepEvalEx.SystemOne.Mode

  # deepeval's outer per-task budget when neither its per-task nor its
  # per-attempt timeout override is set (`_calc_auto_outer_timeout`).
  @default_per_task_timeout_seconds 180.0

  @settings [
    results_folder: {"DEEPEVAL_RESULTS_FOLDER", :string, nil},
    identifier: {"DEEPEVAL_IDENTIFIER", :string, nil},
    ignore_errors: {"IGNORE_DEEPEVAL_ERRORS", :boolean, false},
    skip_on_missing_params: {"SKIP_DEEPEVAL_MISSING_PARAMS", :boolean, false},
    verbose_mode: {"DEEPEVAL_VERBOSE_MODE", :boolean, false},
    use_cache: {"ENABLE_DEEPEVAL_CACHE", :boolean, false},
    per_task_timeout_seconds_override:
      {"DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", {:float, :>=, 0}, nil},
    retry_max_attempts: {"DEEPEVAL_RETRY_MAX_ATTEMPTS", {:integer, :>=, 1}, 2},
    retry_initial_seconds: {"DEEPEVAL_RETRY_INITIAL_SECONDS", {:float, :>=, 0}, 1.0},
    retry_exp_base: {"DEEPEVAL_RETRY_EXP_BASE", {:float, :>=, 1}, 2.0},
    retry_jitter: {"DEEPEVAL_RETRY_JITTER", {:float, :>=, 0}, 2.0},
    retry_cap_seconds: {"DEEPEVAL_RETRY_CAP_SECONDS", {:float, :>=, 0}, 5.0},
    eval_mode: {"DEEPEVAL_EVAL_MODE", :eval_mode, nil},
    file_system: {"DEEPEVAL_FILE_SYSTEM", :file_system, nil},
    cache_folder: {"DEEPEVAL_CACHE_FOLDER", :string, ".deepeval"},
    typesafe_api_key: {"TYPESAFE_API_KEY", :string, nil},
    typesafe_model_name: {"TYPESAFE_MODEL_NAME", :string, nil},
    # deepeval's setting is a PositiveFloat, but its TypeSafeModel accepts a
    # price of 0 (a free Jev); only a negative price is an error there.
    typesafe_cost_per_input_token: {"TYPESAFE_COST_PER_INPUT_TOKEN", {:float, :>=, 0}, nil},
    print_results: {nil, :boolean, true},
    running: {"DEEPEVAL", :boolean, false},
    repeat: {nil, {:integer, :>=, 1}, nil},
    display: {nil, :display, :all},
    test_file: {nil, :string, nil},
    show_warnings: {nil, :boolean, false}
  ]

  # Where put_run_overrides/1 keeps its overrides.
  @overrides_key {__MODULE__, :run_overrides}

  # deepeval's TestRunResultDisplay values.
  @displays [:all, :failing, :passing]

  # deepeval's Settings._normalize_fs aliases.
  @read_only_aliases ~w(READ_ONLY READ-ONLY READONLY RO)

  # deepeval's config/utils.py tokens.
  @truthy ~w(1 true t yes y on enable enabled)
  @falsy ~w(0 false f no n off disable disabled)

  @type key ::
          :results_folder
          | :identifier
          | :ignore_errors
          | :skip_on_missing_params
          | :verbose_mode
          | :use_cache
          | :per_task_timeout_seconds_override
          | :retry_max_attempts
          | :retry_initial_seconds
          | :retry_exp_base
          | :retry_jitter
          | :retry_cap_seconds
          | :eval_mode
          | :file_system
          | :cache_folder
          | :typesafe_api_key
          | :typesafe_model_name
          | :typesafe_cost_per_input_token
          | :print_results
          | :running
          | :repeat
          | :display
          | :test_file
          | :show_warnings

  @doc """
  Every setting `get/1` resolves.
  """
  @spec keys() :: [key()]
  def keys, do: Keyword.keys(@settings)

  @doc """
  The environment variable a setting is read from, or `nil` for a setting
  without one.

  ## Examples

      iex> DeepEvalEx.Config.env_var(:ignore_errors)
      "IGNORE_DEEPEVAL_ERRORS"
  """
  @spec env_var(key()) :: String.t() | nil
  def env_var(key) do
    {var, _type, _default} = setting!(key)
    var
  end

  @doc """
  Resolves a setting: its run override when one is set (see "Run
  overrides"), else `config :deep_eval_ex, key` when set, else its
  environment variable, else deepeval's default (see the table above).

  Raises `ArgumentError` for an unknown key or a numeric value that is not
  a number or is out of the setting's bounds.

  ## Examples

      iex> DeepEvalEx.Config.get(:retry_max_attempts)
      2
  """
  @spec get(key()) :: term()
  def get(key) do
    {var, type, default} = setting!(key)

    case fetch_run_override(key) do
      {:ok, value} ->
        value

      :error ->
        with nil <- parse(config(key), type, "config :deep_eval_ex, #{inspect(key)}"),
             nil <- parse(var && env(var), type, var) do
          default
        end
    end
  end

  @doc """
  Sets run overrides: each value wins over application config and the
  environment in `get/1` until `clear_run_overrides/0` (see "Run
  overrides"). Values are parsed as application config is, and merged
  into the overrides already set.

  Raises `ArgumentError` for an unknown key or an invalid value.

  ## Examples

      DeepEvalEx.Config.put_run_overrides(ignore_errors: true, identifier: "nightly")
      DeepEvalEx.Config.get(:ignore_errors)
      #=> true
  """
  @spec put_run_overrides(keyword()) :: :ok
  def put_run_overrides(overrides) when is_list(overrides) do
    parsed =
      Map.new(overrides, fn {key, value} ->
        {_var, type, _default} = setting!(key)
        {key, parse(value, type, "run override #{inspect(key)}")}
      end)

    :persistent_term.put(@overrides_key, Map.merge(run_overrides(), parsed))
  end

  @doc """
  Clears every run override set by `put_run_overrides/1`.
  """
  @spec clear_run_overrides() :: :ok
  def clear_run_overrides do
    :persistent_term.erase(@overrides_key)
    :ok
  end

  @doc """
  The run overrides currently set, as a map.
  """
  @spec run_overrides() :: %{optional(key()) => term()}
  def run_overrides, do: :persistent_term.get(@overrides_key, %{})

  defp fetch_run_override(key), do: Map.fetch(run_overrides(), key)

  @doc """
  The time budget in seconds for evaluating one test case, deepeval's
  computed `DEEPEVAL_PER_TASK_TIMEOUT_SECONDS`: the
  `:per_task_timeout_seconds_override` setting
  (`DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE`) when set and not `0`, else
  deepeval's default outer budget of `180.0`.

  `DeepEvalEx.Evaluator` uses it as the default `:timeout`.

  ## Examples

      iex> DeepEvalEx.Config.per_task_timeout_seconds()
      180.0
  """
  @spec per_task_timeout_seconds() :: float()
  def per_task_timeout_seconds do
    case get(:per_task_timeout_seconds_override) do
      override when is_float(override) and override > 0 -> override
      _unset -> @default_per_task_timeout_seconds
    end
  end

  @doc """
  Whether DeepEvalEx must not write to disk, deepeval's `is_read_only_env`:
  the `:file_system` setting (`DEEPEVAL_FILE_SYSTEM`) is `READ_ONLY`.

  `DeepEvalEx.TestRun.LocalStore` then skips the `.deepeval` snapshots.

  ## Examples

      iex> DeepEvalEx.Config.read_only?()
      false
  """
  @spec read_only?() :: boolean()
  def read_only?, do: get(:file_system) == :read_only

  defp setting!(key) do
    case Keyword.fetch(@settings, key) do
      {:ok, setting} -> setting
      :error -> raise ArgumentError, "unknown DeepEvalEx setting: #{inspect(key)}"
    end
  end

  defp parse(nil, _type, _source), do: nil

  defp parse(value, :string, _source) when is_binary(value), do: value

  defp parse(value, :string, source) do
    raise ArgumentError, "#{source} must be a string, got: #{inspect(value)}"
  end

  defp parse(value, :boolean, _source), do: parse_bool(value)
  defp parse(value, :eval_mode, _source), do: Mode.normalize(value)
  defp parse(value, :display, _source) when value in @displays, do: value

  defp parse(value, :display, source) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      display when display in ~w(all failing passing) -> String.to_existing_atom(display)
      _other -> raise_display(value, source)
    end
  end

  defp parse(value, :display, source), do: raise_display(value, source)
  defp parse(:read_only, :file_system, _source), do: :read_only

  defp parse(value, :file_system, source) when is_binary(value) do
    if String.upcase(String.trim(value)) in @read_only_aliases,
      do: :read_only,
      else: raise_file_system(value, source)
  end

  defp parse(value, :file_system, source), do: raise_file_system(value, source)

  defp parse(value, {kind, op, bound} = type, source) do
    number = to_number(value, kind)

    if number != nil and compare(number, op, bound),
      do: number,
      else: raise(ArgumentError, "#{source} must be #{describe(type)}, got: #{inspect(value)}")
  end

  defp raise_display(value, source) do
    raise ArgumentError,
          "#{source} must be one of :all, :failing or :passing, got: #{inspect(value)}"
  end

  defp raise_file_system(value, source) do
    raise ArgumentError,
          "#{source} must be READ_ONLY (case-insensitive), got: #{inspect(value)}"
  end

  defp to_number(value, :float) when is_number(value), do: value / 1
  defp to_number(value, :integer) when is_integer(value), do: value

  defp to_number(value, :integer) when is_float(value),
    do: if(value == Float.round(value), do: trunc(value))

  # pydantic's int parsing accepts a zero fraction but no exponent.
  defp to_number(value, :integer) when is_binary(value) do
    case Regex.run(~r/\A([+-]?\d+)(?:\.0*)?\z/, value) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp to_number(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_number(_value, _kind), do: nil

  defp compare(number, :>=, bound), do: number >= bound

  defp describe({:integer, op, bound}), do: "an integer #{describe_op(op)} #{bound}"
  defp describe({:float, op, bound}), do: "a number #{describe_op(op)} #{bound}"

  defp describe_op(:>=), do: "greater than or equal to"

  @doc """
  Reads a value as a boolean, as deepeval's `parse_bool`.

  Booleans are returned as they are and numbers are `true` unless zero.
  Other values are read as text, ignoring surrounding whitespace and quotes
  and case: `1`, `true`, `t`, `yes`, `y`, `on`, `enable` and `enabled` are
  `true`; `0`, `false`, `f`, `no`, `n`, `off`, `disable` and `disabled` are
  `false`. `nil`, blank text and any other value return `default`.

  ## Examples

      iex> DeepEvalEx.Config.parse_bool("YES")
      true

      iex> DeepEvalEx.Config.parse_bool(nil)
      false

      iex> DeepEvalEx.Config.parse_bool("maybe", true)
      true
  """
  @spec parse_bool(term(), boolean()) :: boolean()
  def parse_bool(value, default \\ false)
  def parse_bool(value, _default) when is_boolean(value), do: value
  def parse_bool(nil, default), do: default
  def parse_bool(value, _default) when is_number(value), do: value != 0

  def parse_bool(value, default) when is_binary(value) or is_atom(value) do
    token =
      value
      |> to_string()
      |> String.trim()
      |> String.trim("\"")
      |> String.trim("'")
      |> String.downcase()

    cond do
      token in @truthy -> true
      token in @falsy -> false
      true -> default
    end
  end

  def parse_bool(_value, default), do: default

  @doc """
  Reads an environment variable, treating a blank value as unset and
  trimming surrounding whitespace from a set one.

  Tooling such as dev containers often forwards unset host variables as empty
  strings; an empty `OPENAI_BASE_URL` must fall back to the default rather
  than produce an empty URL.

  ## Examples

      iex> System.put_env("DEEP_EVAL_EX_DOC_EXAMPLE", "")
      iex> DeepEvalEx.Config.env("DEEP_EVAL_EX_DOC_EXAMPLE")
      nil

      iex> System.put_env("DEEP_EVAL_EX_DOC_EXAMPLE", "  sk-test  ")
      iex> DeepEvalEx.Config.env("DEEP_EVAL_EX_DOC_EXAMPLE")
      "sk-test"
  """
  @spec env(String.t()) :: String.t() | nil
  def env(name), do: name |> System.get_env() |> present()

  @doc """
  Reads a `:deep_eval_ex` application config value, treating a blank string
  as unset and trimming surrounding whitespace from a set one. Non-string
  values are returned unchanged.

  Config such as `openai_api_key: System.get_env("OPENAI_API_KEY")` stores an
  empty string when the variable is set but empty; that must fall through to
  the next source rather than be used as the value.

  ## Examples

      iex> Application.put_env(:deep_eval_ex, :doc_example, "  ")
      iex> DeepEvalEx.Config.config(:doc_example)
      nil

      iex> Application.put_env(:deep_eval_ex, :doc_example, " https://example.com/v1 ")
      iex> DeepEvalEx.Config.config(:doc_example)
      "https://example.com/v1"
  """
  @spec config(atom()) :: term()
  def config(key), do: :deep_eval_ex |> Application.get_env(key) |> present()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value), do: value
end
