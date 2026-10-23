# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ExUnit.RepeatTest do
  # Not async: --repeat is a VM-wide run override.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Config

  setup do
    on_exit(&Config.clear_run_overrides/0)
  end

  @source """
  use ExUnit.Case, register: false
  use DeepEvalEx.ExUnit

  test "plain" do
    assert true
  end

  describe "block" do
    @tag :rag
    @tag skip: "not ready"
    test "with context", %{test: test} do
      send(self(), test)
    end
  end

  test "not implemented yet"
  """

  defp compile_tests(name) do
    module = Module.concat(__MODULE__, name)
    [{^module, _binary}] = Code.compile_string("defmodule #{inspect(module)} do\n#{@source}\nend")
    module.__ex_unit__().tests
  end

  defp compile_test_names(name), do: name |> compile_tests() |> Enum.map(&Atom.to_string(&1.name))

  test "registers each test once when :repeat is unset" do
    assert compile_test_names(Once) ==
             ["test plain", "test block with context", "test not implemented yet"]
  end

  test "registers each test N times, named as pytest-repeat names them" do
    Config.put_run_overrides(repeat: 3)

    assert compile_test_names(Thrice) == [
             "test plain[1-3]",
             "test plain[2-3]",
             "test plain[3-3]",
             "test block with context[1-3]",
             "test block with context[2-3]",
             "test block with context[3-3]",
             "test not implemented yet[1-3]",
             "test not implemented yet[2-3]",
             "test not implemented yet[3-3]"
           ]
  end

  test "gives every repeat the test's tags" do
    Config.put_run_overrides(repeat: 2)

    {tests, warnings} = ExUnit.CaptureIO.with_io(:stderr, fn -> compile_tests(Tagged) end)
    assert warnings == ""
    tagged = Enum.filter(tests, &(&1.tags.describe == "block"))

    assert length(tagged) == 2
    assert Enum.all?(tagged, &(&1.tags.rag == true and &1.tags.skip == "not ready"))
    refute compile_tests(Untagged) |> hd() |> Map.fetch!(:tags) |> Map.has_key?(:rag)
  end

  test "use DeepEvalEx.ExUnit must come after use ExUnit.Case" do
    assert_raise ArgumentError, ~r/must come after use ExUnit.Case/, fn ->
      Code.compile_string("""
      defmodule #{inspect(Module.concat(__MODULE__, Misordered))} do
        use DeepEvalEx.ExUnit
      end
      """)
    end
  end
end
