# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.DeepEval.TestTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DeepEval.Test, as: Task

  describe "with_formatter/1" do
    test "keeps ExUnit's formatter and adds DeepEvalEx's" do
      assert Task.with_formatter(["test/evals"]) == [
               "test/evals",
               "--formatter",
               "ExUnit.CLIFormatter",
               "--formatter",
               "DeepEvalEx.ExUnit.Formatter"
             ]
    end

    test "adds DeepEvalEx's after the formatters given" do
      assert Task.with_formatter(["t", "--formatter", "JUnitFormatter"]) ==
               [
                 "t",
                 "--formatter",
                 "JUnitFormatter",
                 "--formatter",
                 "DeepEvalEx.ExUnit.Formatter"
               ]
    end
  end

  describe "check_if_valid_file!/1 (command.py's check_if_valid_file)" do
    test "accepts files and folders, with a test name or line" do
      assert Task.check_if_valid_file!("test") == :ok
      assert Task.check_if_valid_file!("mix.exs") == :ok
      assert Task.check_if_valid_file!("mix.exs::test anything") == :ok
      assert Task.check_if_valid_file!("mix.exs:3") == :ok
    end

    test "raises deepeval's message for anything else" do
      assert_raise Mix.Error, "Provided path is neither a valid file nor a directory.", fn ->
        Task.check_if_valid_file!("test/missing_test.exs")
      end
    end
  end
end
