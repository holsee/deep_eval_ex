# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/cli/test/command.py (run's options and the pytest
# arguments it builds)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.CLI.TestArgs do
  @moduledoc """
  Parses the arguments of `mix deep_eval.test`, deepeval 4.3.1's
  `deepeval test run` options, into run overrides and `mix test` arguments.

  `parse!/1` is pure: it reads no file and sets nothing. It returns a
  `%TestArgs{}` with:

  - `:path` - the test path, verbatim (the run's `testFile`)
  - `:overrides` - the settings the run puts with
    `DeepEvalEx.Config.put_run_overrides/1`, as `command.py`'s
    `set_is_running_deepeval`, `set_should_*`, `set_verbose_mode` and
    `set_identifier`
  - `:mix_test_args` - the arguments for `mix test`, as `command.py` builds
    `pytest_args`
  - `:messages` - lines to print before the run (the `--official` warning)
  - `:color` - `true` or `false` for `--color yes` or `no`, `nil` for
    `auto`

  | `deepeval test run` | `mix deep_eval.test` | Effect |
  |---|---|---|
  | `TEST_FILE_OR_DIRECTORY` | `PATH` | `file::name` runs `file --only test:name`; `file:line` passes through |
  | `--color yes` | `--color yes\\|no\\|auto` | `--color` / `--no-color` |
  | `--durations 10` | `--durations N` | `--slowest N` when given, omitted for `0` |
  | `--pdb` | same | raises: use `iex -S mix deep_eval.test ... -- --breakpoints` |
  | `-x/-X`, `--exit-on-first-failure` | same | `--max-failures 1` |
  | `-w/-W`, `--show-warnings` | same | `:show_warnings` |
  | `-id/--identifier` | same | `:identifier`, when given |
  | `-n/--num-processes` | same | `--max-cases N` |
  | `-r/--repeat` | same | `:repeat`; at least 1; turns `-c` off |
  | `-c/--use-cache` | same | `:use_cache` |
  | `-i/--ignore-errors` | same | `:ignore_errors` |
  | `-s/--skip-on-missing-params` | same | `:skip_on_missing_params` |
  | `-v/--verbose` | same | `:verbose_mode` `true`, else `nil` |
  | `-d/--display` | same, case-insensitive | `:display` |
  | `-m/--mark` | same | `tag`, `not tag` and `a or b` as `--only`/`--exclude` |
  | `-o/--official` | same | the warning in `:messages` |
  | (none) | `--eval-mode` | `:eval_mode` |

  As in `command.py`, the first positional argument is the path, and
  unknown options and further positional arguments, as well as everything
  after `--`, are passed on to `mix test` (typer's `allow_extra_args` and
  `ignore_unknown_options`). Short flags combine (`-ci`) and short options
  take their value attached (`-r3`), as click parses them.

  One difference: `command.py` always passes `--durations=10`, but
  `mix test --slowest` also turns on `--trace`, which runs one test at a
  time, so `--slowest` is passed only when `--durations` is given.

  Invalid arguments raise `ArgumentError`, with click's messages where
  click rejects them.
  """

  alias DeepEvalEx.SystemOne.Mode

  @type t :: %__MODULE__{
          path: String.t(),
          overrides: keyword(),
          mix_test_args: [String.t()],
          messages: [String.t()],
          color: boolean() | nil
        }

  defstruct path: nil, overrides: [], mix_test_args: [], messages: [], color: true

  @official_warning "Warning: --official requires a CONFIDENT_API_KEY environment variable " <>
                      "to be set. Skipping."

  # Long option => {key, kind}; :flag options take no value.
  @long %{
    "--color" => {:color, :string},
    "--durations" => {:durations, :integer},
    "--pdb" => {:pdb, :flag},
    "--exit-on-first-failure" => {:exit_on_first_failure, :flag},
    "--show-warnings" => {:show_warnings, :flag},
    "--identifier" => {:identifier, :string},
    "--num-processes" => {:num_processes, :integer},
    "--repeat" => {:repeat, :integer},
    "--use-cache" => {:use_cache, :flag},
    "--ignore-errors" => {:ignore_errors, :flag},
    "--skip-on-missing-params" => {:skip_on_missing_params, :flag},
    "--verbose" => {:verbose, :flag},
    "--display" => {:display, :string},
    "--mark" => {:mark, :string},
    "--official" => {:official, :flag},
    "--eval-mode" => {:eval_mode, :string}
  }

  # Short option => {key, kind | {:flag, value}}.
  @short %{
    "x" => {:exit_on_first_failure, {:flag, true}},
    "X" => {:exit_on_first_failure, {:flag, false}},
    "w" => {:show_warnings, {:flag, true}},
    "W" => {:show_warnings, {:flag, false}},
    "n" => {:num_processes, :integer},
    "r" => {:repeat, :integer},
    "c" => {:use_cache, {:flag, true}},
    "i" => {:ignore_errors, {:flag, true}},
    "s" => {:skip_on_missing_params, {:flag, true}},
    "v" => {:verbose, {:flag, true}},
    "d" => {:display, :string},
    "m" => {:mark, :string},
    "o" => {:official, {:flag, true}}
  }

  # How click names each option in its messages.
  @names %{
    color: "'--color'",
    durations: "'--durations'",
    identifier: "'--identifier' / '-id'",
    num_processes: "'--num-processes' / '-n'",
    repeat: "'--repeat' / '-r'",
    display: "'--display' / '-d'",
    mark: "'--mark' / '-m'",
    eval_mode: "'--eval-mode'"
  }

  # command.py's defaults.
  @defaults %{
    color: "yes",
    # command.py's default is 10, but mix test's --slowest turns on --trace,
    # which runs one test at a time: it is passed only when asked for.
    durations: nil,
    pdb: false,
    exit_on_first_failure: false,
    show_warnings: false,
    identifier: nil,
    num_processes: nil,
    repeat: nil,
    use_cache: false,
    ignore_errors: false,
    skip_on_missing_params: false,
    verbose: nil,
    display: "all",
    mark: nil,
    official: false,
    eval_mode: nil
  }

  @tag ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc """
  Parses `mix deep_eval.test`'s arguments (see the module documentation).

  ## Examples

      iex> args = DeepEvalEx.CLI.TestArgs.parse!(["test/evals", "-c", "-d", "failing"])
      iex> args.mix_test_args
      ["test/evals", "--color"]
      iex> Keyword.take(args.overrides, [:use_cache, :display])
      [use_cache: true, display: :failing]
  """
  @spec parse!([String.t()]) :: t()
  def parse!(argv) when is_list(argv) do
    {before, after_dashes} = split_dashes(argv)
    {opts, positional, extras} = tokenize(before, @defaults, [], [])

    path =
      case positional do
        [path | _] -> path
        [] -> raise ArgumentError, "Missing argument 'TEST_FILE_OR_DIRECTORY'."
      end

    extras = Enum.drop(positional, 1) |> merge_extras(extras) |> Kernel.++(after_dashes)
    build(path, opts, extras)
  end

  @doc """
  The file or directory part of a test path: without its `::<test name>`
  and its trailing `:<line>`s, as `command.py`'s `check_if_valid_file`
  splits on `::`.

  ## Examples

      iex> DeepEvalEx.CLI.TestArgs.file_part("test/evals/refund_test.exs::test refund")
      "test/evals/refund_test.exs"

      iex> DeepEvalEx.CLI.TestArgs.file_part("test/evals/refund_test.exs:12")
      "test/evals/refund_test.exs"
  """
  @spec file_part(String.t()) :: String.t()
  def file_part(path) do
    [file | _] = String.split(path, "::", parts: 2)
    String.replace(file, ~r/(:\d+)+\z/, "")
  end

  defp split_dashes(argv) do
    case Enum.split_while(argv, &(&1 != "--")) do
      {before, ["--" | rest]} -> {before, rest}
      {before, []} -> {before, []}
    end
  end

  # Extras keep the order they were given in; positional arguments after
  # the path come from the same stream, so both are tagged with their index.
  defp merge_extras(positional, extras) do
    (positional ++ extras)
    |> Enum.sort_by(fn {index, _arg} -> index end)
    |> Enum.map(fn {_index, arg} -> arg end)
  end

  # Returns {opts, positional, extras}; positional and extras as
  # {index, arg} pairs (the first positional unwrapped later).
  defp tokenize(argv, opts, positional, extras) do
    argv
    |> Enum.with_index()
    |> do_tokenize(opts, positional, extras)
  end

  defp do_tokenize([], opts, positional, extras) do
    positional =
      case Enum.reverse(positional) do
        [{_index, path} | rest] -> [path | rest]
        [] -> []
      end

    {opts, positional, Enum.reverse(extras)}
  end

  defp do_tokenize([{"--" <> _ = arg, index} | rest], opts, positional, extras) do
    {name, inline} =
      case String.split(arg, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, nil}
      end

    case Map.fetch(@long, name) do
      {:ok, {key, :flag}} ->
        if inline, do: raise(ArgumentError, "Option '#{name}' does not take a value.")
        do_tokenize(rest, Map.put(opts, key, true), positional, extras)

      {:ok, {key, kind}} ->
        {value, rest} = take_value(name, inline, rest)
        do_tokenize(rest, Map.put(opts, key, cast(key, kind, value)), positional, extras)

      :error ->
        do_tokenize(rest, opts, positional, [{index, arg} | extras])
    end
  end

  defp do_tokenize([{"-id", _index} | rest], opts, positional, extras) do
    {value, rest} = take_value("-id", nil, rest)
    do_tokenize(rest, Map.put(opts, :identifier, value), positional, extras)
  end

  defp do_tokenize([{"-" <> shorts = arg, index} | rest], opts, positional, extras)
       when shorts != "" do
    case shorts(shorts, opts, rest) do
      {:ok, opts, rest} -> do_tokenize(rest, opts, positional, extras)
      :unknown -> do_tokenize(rest, opts, positional, [{index, arg} | extras])
    end
  end

  defp do_tokenize([{arg, index} | rest], opts, positional, extras),
    do: do_tokenize(rest, opts, [{index, arg} | positional], extras)

  # A run of short options, as click reads `-ci` or `-r3`; an unknown letter
  # makes the whole argument unknown.
  defp shorts(<<letter::utf8, more::binary>>, opts, rest) do
    case Map.fetch(@short, <<letter::utf8>>) do
      {:ok, {key, {:flag, value}}} ->
        opts = Map.put(opts, key, value)
        if more == "", do: {:ok, opts, rest}, else: shorts(more, opts, rest)

      {:ok, {key, kind}} ->
        {value, rest} =
          if more == "", do: take_value("-#{<<letter::utf8>>}", nil, rest), else: {more, rest}

        {:ok, Map.put(opts, key, cast(key, kind, value)), rest}

      :error ->
        :unknown
    end
  end

  defp take_value(_name, inline, rest) when is_binary(inline), do: {inline, rest}
  defp take_value(_name, nil, [{value, _index} | rest]), do: {value, rest}

  defp take_value(name, nil, []),
    do: raise(ArgumentError, "Option '#{name}' requires an argument.")

  defp cast(_key, :string, value), do: value

  defp cast(key, :integer, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} ->
        integer

      _ ->
        raise ArgumentError,
              "Invalid value for #{@names[key]}: '#{value}' is not a valid int."
    end
  end

  defp build(path, opts, extras) do
    if opts.pdb do
      raise ArgumentError,
            "--pdb is not supported: ExUnit has no post-mortem debugger. " <>
              "Run `iex -S mix deep_eval.test #{path} -- --breakpoints` instead."
    end

    color = color!(opts.color)

    # command.py raises after building the pytest arguments, before running.
    if opts.repeat != nil and opts.repeat < 1,
      do: raise(ArgumentError, "The repeat argument must be at least 1.")

    %__MODULE__{
      path: path,
      overrides: overrides(path, opts),
      mix_test_args: mix_test_args(path, opts, color, extras),
      messages: if(opts.official, do: [@official_warning], else: []),
      color: color
    }
  end

  defp mix_test_args(path, opts, color, extras) do
    path_args(path, opts.repeat) ++
      if(opts.exit_on_first_failure, do: ["--max-failures", "1"], else: []) ++
      color_args(color) ++
      durations_args(opts.durations) ++
      num_processes_args(opts.num_processes) ++
      mark_args(opts.mark) ++
      extras
  end

  # command.py's set_should_*, set_verbose_mode and set_identifier (only a
  # given identifier), with the run's own settings.
  defp overrides(path, opts) do
    [
      running: true,
      test_file: path,
      use_cache: opts.use_cache and is_nil(opts.repeat),
      ignore_errors: opts.ignore_errors,
      skip_on_missing_params: opts.skip_on_missing_params,
      verbose_mode: if(opts.verbose, do: true),
      repeat: opts.repeat,
      display: display!(opts.display),
      show_warnings: opts.show_warnings
    ] ++ identifier(opts.identifier) ++ eval_mode(eval_mode!(opts.eval_mode))
  end

  defp identifier(identifier) when identifier in [nil, ""], do: []
  defp identifier(identifier), do: [identifier: identifier]

  defp eval_mode(nil), do: []
  defp eval_mode(mode), do: [eval_mode: mode]

  defp num_processes_args(nil), do: []
  defp num_processes_args(count), do: ["--max-cases", to_string(count)]

  # `file::name` selects one test by its full ExUnit name, and every repeat
  # of it, as pytest selects every parametrized repeat of a node id.
  defp path_args(path, repeat) do
    case String.split(path, "::", parts: 2) do
      [file, name] ->
        names =
          if repeat != nil and repeat > 1,
            do: for(i <- 1..repeat, do: "#{name}[#{i}-#{repeat}]"),
            else: [name]

        [file | Enum.flat_map(names, &["--only", "test:" <> &1])]

      [_path] ->
        [path]
    end
  end

  defp color!(value) do
    case String.downcase(value) do
      "yes" -> true
      "no" -> false
      "auto" -> nil
      _ -> invalid_choice(:color, value, ~w(yes no auto))
    end
  end

  defp color_args(true), do: ["--color"]
  defp color_args(false), do: ["--no-color"]
  defp color_args(nil), do: []

  defp durations_args(durations) when is_integer(durations) and durations > 0,
    do: ["--slowest", to_string(durations)]

  defp durations_args(_durations), do: []

  defp display!(value) do
    case String.downcase(value) do
      "all" -> :all
      "failing" -> :failing
      "passing" -> :passing
      _ -> invalid_choice(:display, value, ~w(all failing passing))
    end
  end

  defp eval_mode!(nil), do: nil

  defp eval_mode!(value) do
    Mode.normalize(value) ||
      invalid_choice(:eval_mode, value, Enum.map(Mode.modes(), &Atom.to_string/1))
  end

  defp invalid_choice(key, value, choices) do
    choices = Enum.map_join(choices, ", ", &"'#{&1}'")
    raise ArgumentError, "Invalid value for #{@names[key]}: '#{value}' is not one of #{choices}."
  end

  # pytest's -m, as far as ExUnit's --only and --exclude filters reach.
  defp mark_args(nil), do: []

  defp mark_args(expression) do
    expression = String.trim(expression)
    alternatives = String.split(expression, ~r/\s+or\s+/)

    case String.split(expression, ~r/\s+/) do
      ["not", tag] ->
        if tag?(tag), do: ["--exclude", tag], else: unsupported_mark!(expression)

      _words ->
        if Enum.all?(alternatives, &tag?/1),
          do: Enum.flat_map(alternatives, &["--only", &1]),
          else: unsupported_mark!(expression)
    end
  end

  # pytest's mark expression keywords are not marks.
  defp tag?(word), do: Regex.match?(@tag, word) and word not in ~w(not and or)

  defp unsupported_mark!(expression) do
    raise ArgumentError,
          "Unsupported --mark expression #{inspect(expression)}: mix deep_eval.test " <>
            "supports `tag`, `not tag` and `tag or tag`, which ExUnit's --only and " <>
            "--exclude filters can express."
  end
end
