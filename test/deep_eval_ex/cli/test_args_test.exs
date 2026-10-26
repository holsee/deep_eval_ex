# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.CLI.TestArgsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.CLI.TestArgs

  doctest TestArgs

  # deepeval 4.3.1's `deepeval test run`, with pytest.main patched: the
  # pytest arguments, settings, output or error of each argv.
  @cases "test/fixtures/deepeval/cli/args/cases.json" |> File.read!() |> Jason.decode!()

  @default_mix_args ["--color"]

  describe "parse!/1 against deepeval's command.py" do
    for %{"argv" => argv, "error" => nil} = deepeval <- @cases,
        argv != ["test_example.py", "-o"] do
      @deepeval deepeval
      test "#{Enum.join(argv, " ")} gives deepeval's pytest arguments and settings" do
        args = TestArgs.parse!(@deepeval["argv"])

        {expected_args, expected_overrides} =
          from_pytest_args(@deepeval["pytest_args"], @deepeval["argv"])

        assert args.mix_test_args == expected_args
        assert args.path == hd(@deepeval["argv"])
        assert args.messages == []

        for {key, value} <- expected_overrides,
            do: assert({key, Keyword.fetch(args.overrides, key)} == {key, {:ok, value}})

        settings = @deepeval["settings"]
        assert args.overrides[:running] == true
        assert args.overrides[:test_file] == hd(@deepeval["argv"])
        assert args.overrides[:use_cache] == settings["use_cache"]
        assert args.overrides[:ignore_errors] == settings["ignore_errors"]
        assert args.overrides[:skip_on_missing_params] == settings["skip_on_missing_params"]
        assert Keyword.fetch!(args.overrides, :verbose_mode) == settings["verbose_mode"]
        assert Keyword.get(args.overrides, :identifier) == settings["identifier"]
        assert Keyword.has_key?(args.overrides, :identifier) == (settings["identifier"] != nil)
      end
    end

    for %{"argv" => argv, "error" => error} = deepeval <- @cases,
        error != nil,
        error != "Provided path is neither a valid file nor a directory." do
      @deepeval deepeval
      test "#{Enum.join(argv, " ")} raises deepeval's error" do
        assert_raise ArgumentError, @deepeval["error"], fn ->
          TestArgs.parse!(@deepeval["argv"])
        end
      end
    end

    test "-o prints deepeval's --official warning, as DeepEvalEx has no Confident AI key" do
      %{"stdout" => stdout} = Enum.find(@cases, &(&1["argv"] == ["test_example.py", "-o"]))

      assert TestArgs.parse!(["test_example.py", "-o"]).messages == [String.trim_trailing(stdout)]
    end
  end

  describe "parse!/1" do
    test "defaults to command.py's: colour on, display all" do
      args = TestArgs.parse!(["test/evals"])

      assert args.mix_test_args == ["test/evals" | @default_mix_args]
      assert args.color == true
      assert args.report_color == nil

      assert args.overrides == [
               running: true,
               test_file: "test/evals",
               use_cache: false,
               ignore_errors: false,
               skip_on_missing_params: false,
               verbose_mode: nil,
               repeat: nil,
               display: :all,
               show_warnings: false
             ]
    end

    test "requires a path" do
      assert_raise ArgumentError, "Missing argument 'TEST_FILE_OR_DIRECTORY'.", fn ->
        TestArgs.parse!(["-c"])
      end
    end

    test "passes everything after -- and unknown options on to mix test, in order" do
      args = TestArgs.parse!(["test/evals", "--seed", "0", "-c", "--", "--trace", "-c"])

      assert args.mix_test_args ==
               ["test/evals" | @default_mix_args] ++ ["--seed", "0", "--trace", "-c"]

      assert args.overrides[:use_cache] == true
    end

    test "reads --opt=value and attached short values, as click" do
      args = TestArgs.parse!(["test/evals", "--repeat=2", "-dPASSING", "-n4"])

      assert args.overrides[:repeat] == 2
      assert args.overrides[:display] == :passing
      assert "--max-cases" in args.mix_test_args
    end

    test "-x/-X and -w/-W: the last one wins" do
      assert TestArgs.parse!(["t", "-X", "-x"]).mix_test_args ==
               ["t", "--max-failures", "1"] ++ @default_mix_args

      assert TestArgs.parse!(["t", "-W", "-w"]).overrides[:show_warnings] == true
      assert TestArgs.parse!(["t", "--show-warnings", "-W"]).overrides[:show_warnings] == false
    end

    test "--repeat turns the cache off" do
      assert TestArgs.parse!(["t", "-c", "-r", "1"]).overrides[:use_cache] == false
      assert TestArgs.parse!(["t", "-c", "-r", "1"]).overrides[:repeat] == 1
    end

    test "file::name selects the test, and each of its repeats" do
      assert TestArgs.parse!(["t.exs::test refund"]).mix_test_args ==
               ["t.exs", "--only", "test:test refund"] ++ @default_mix_args

      assert TestArgs.parse!(["t.exs::test refund", "-r", "2"]).mix_test_args ==
               ["t.exs", "--only", "test:test refund[1-2]", "--only", "test:test refund[2-2]"] ++
                 @default_mix_args

      assert TestArgs.parse!(["t.exs::test refund"]).overrides[:test_file] == "t.exs::test refund"
    end

    test "file:line passes through" do
      assert hd(TestArgs.parse!(["t.exs:12"]).mix_test_args) == "t.exs:12"
    end

    test "--color yes, no and auto" do
      assert TestArgs.parse!(["t", "--color", "no"]).color == false
      assert TestArgs.parse!(["t", "--color", "no"]).report_color == false
      assert TestArgs.parse!(["t", "--color", "yes"]).report_color == true
      assert TestArgs.parse!(["t", "--color=YES"]).report_color == true
      assert TestArgs.parse!(["t", "--color", "auto"]).report_color == nil
      assert "--no-color" in TestArgs.parse!(["t", "--color", "no"]).mix_test_args
      assert TestArgs.parse!(["t", "--color", "auto"]).color == nil
      assert TestArgs.parse!(["t", "--color", "auto"]).mix_test_args == ["t"]

      assert_raise ArgumentError, ~r/'--color': 'blue' is not one of 'yes', 'no', 'auto'/, fn ->
        TestArgs.parse!(["t", "--color", "blue"])
      end
    end

    test "--durations N gives --slowest N only when asked for, as --slowest turns on --trace" do
      assert TestArgs.parse!(["t"]).mix_test_args == ["t", "--color"]
      assert TestArgs.parse!(["t", "--durations", "0"]).mix_test_args == ["t", "--color"]

      assert TestArgs.parse!(["t", "--durations", "3"]).mix_test_args == [
               "t",
               "--color",
               "--slowest",
               "3"
             ]
    end

    test "--pdb raises with the iex hint" do
      assert_raise ArgumentError, ~r/iex -S mix deep_eval.test t -- --breakpoints/, fn ->
        TestArgs.parse!(["t", "--pdb"])
      end
    end

    test "-m translates tag, not tag and or; anything else raises" do
      assert mark("rag") == ["--only", "rag"]
      assert mark("not slow") == ["--exclude", "slow"]

      assert mark("rag or slow or nightly") == [
               "--only",
               "rag",
               "--only",
               "slow",
               "--only",
               "nightly"
             ]

      for expression <- ["rag and slow", "not rag or slow", "rag(x)", "not"] do
        assert_raise ArgumentError, ~r/Unsupported --mark expression/, fn -> mark(expression) end
      end
    end

    test "--eval-mode sets the run's eval mode" do
      assert TestArgs.parse!(["t", "--eval-mode", "SYSTEM_ONE"]).overrides[:eval_mode] ==
               :system_one

      refute Keyword.has_key?(TestArgs.parse!(["t"]).overrides, :eval_mode)

      assert_raise ArgumentError,
                   ~r/'--eval-mode': 'fast' is not one of 'llm', 'hybrid', 'system_one'/,
                   fn ->
                     TestArgs.parse!(["t", "--eval-mode", "fast"])
                   end
    end

    test "an option without its value raises as click" do
      assert_raise ArgumentError, "Option '--repeat' requires an argument.", fn ->
        TestArgs.parse!(["t", "--repeat"])
      end

      assert_raise ArgumentError, "Option '-id' requires an argument.", fn ->
        TestArgs.parse!(["t", "-id"])
      end
    end
  end

  test "file_part/1 strips the test name and line numbers" do
    assert TestArgs.file_part("test/evals") == "test/evals"
    assert TestArgs.file_part("a_test.exs:3:9") == "a_test.exs"
    assert TestArgs.file_part("a_test.exs::test x:1") == "a_test.exs"
  end

  defp mark(expression) do
    ["t", "--mark", expression]
    |> TestArgs.parse!()
    |> Map.fetch!(:mix_test_args)
    |> Enum.drop(2)
  end

  # What command.py's pytest arguments mean for `mix test`, and for the run's
  # settings that only show in them (--count, --disable-warnings). Its
  # default --durations=10 is not passed on (see TestArgs).
  defp from_pytest_args(pytest_args, argv) do
    durations? = "--durations" in argv

    {before, extras} = Enum.split_while(pytest_args, &(&1 != "-p"))
    extras = Enum.drop(extras, 2)
    show_warnings = "--disable-warnings" not in before

    {args, path, overrides} =
      before
      |> chunk([])
      |> Enum.reduce({[], nil, [show_warnings: show_warnings, repeat: nil]}, fn
        ["-x"], {args, path, o} ->
          {args ++ ["--max-failures", "1"], path, o}

        ["--color=yes"], {args, path, o} ->
          {args ++ ["--color"], path, o}

        ["--color=no"], {args, path, o} ->
          {args ++ ["--no-color"], path, o}

        ["--durations=0"], acc ->
          acc

        ["--durations=" <> _n], acc when not durations? ->
          acc

        ["--durations=" <> n], {args, path, o} ->
          {args ++ ["--slowest", n], path, o}

        ["-n", n], {args, path, o} ->
          {args ++ ["--max-cases", n], path, o}

        ["--count", n], {args, path, o} ->
          {args, path, Keyword.put(o, :repeat, String.to_integer(n))}

        ["-m", expression], {args, path, o} ->
          {args ++ mark_oracle(expression), path, o}

        ["--identifier", _id], acc ->
          acc

        [flag], acc when flag in ["--quiet", "--verbose", "-s", "--disable-warnings"] ->
          acc

        [path], {args, nil, o} ->
          {args, path, o}
      end)

    path_args =
      case String.split(path, "::") do
        [file, name] -> [file, "--only", "test:" <> name]
        [path] -> [path]
      end

    {path_args ++ args ++ extras, overrides}
  end

  defp chunk([], acc), do: Enum.reverse(acc)

  defp chunk([option, value | rest], acc) when option in ["-n", "--count", "-m", "--identifier"],
    do: chunk(rest, [[option, value] | acc])

  defp chunk([arg | rest], acc), do: chunk(rest, [[arg] | acc])

  defp mark_oracle("not " <> tag), do: ["--exclude", tag]

  defp mark_oracle(expression),
    do: expression |> String.split(" or ") |> Enum.flat_map(&["--only", &1])
end
