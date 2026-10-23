defmodule DeepEvalEx.Report.TerminalWidthTest do
  # Sets COLUMNS, which is global: not async, so no other test draws
  # meanwhile.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Report.Terminal

  describe "width/1" do
    setup do
      columns = System.get_env("COLUMNS")

      on_exit(fn ->
        if columns, do: System.put_env("COLUMNS", columns), else: System.delete_env("COLUMNS")
      end)
    end

    test "is the :width option first, then COLUMNS when it is all digits" do
      System.put_env("COLUMNS", "132")
      assert Terminal.width(width: 60) == 60
      assert Terminal.width([]) == 132

      for ignored <- ["", "0", "+90", "90 ", "wide"] do
        System.put_env("COLUMNS", ignored)
        assert Terminal.width([]) == terminal_or_80()
      end
    end

    test "is the terminal's width without COLUMNS, else 80, as Rich's Console" do
      System.delete_env("COLUMNS")
      assert Terminal.width([]) == terminal_or_80()
    end

    defp terminal_or_80 do
      case :io.columns() do
        {:ok, columns} when columns > 0 -> columns
        _no_terminal -> 80
      end
    end
  end
end
