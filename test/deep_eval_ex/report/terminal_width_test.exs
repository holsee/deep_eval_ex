defmodule DeepEvalEx.Report.TerminalWidthTest do
  # Sets COLUMNS, LINES, TERM and the colour variables, which are global:
  # not async, so no other test draws meanwhile.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Report.Terminal

  @vars ~w(COLUMNS LINES TERM NO_COLOR FORCE_COLOR TTY_COMPATIBLE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)
  end

  describe "width/1" do
    test "is the :width option first, then COLUMNS when it is all digits" do
      System.put_env("COLUMNS", "132")
      assert Terminal.width(width: 60) == 60
      assert Terminal.width([]) == 132

      for ignored <- ["", "+90", "90 ", "wide"] do
        System.put_env("COLUMNS", ignored)
        assert Terminal.width([]) == terminal_or_80()
      end
    end

    test "is 80, not the terminal's width, for COLUMNS=0" do
      System.put_env("COLUMNS", "0")
      assert Terminal.width([]) == 80
    end

    test "is the terminal's width without COLUMNS, else 80, as Rich's Console" do
      assert Terminal.width([]) == terminal_or_80()
    end

    test "is 80 on a dumb terminal, even with COLUMNS, as Rich's Console" do
      System.put_env("FORCE_COLOR", "1")
      System.put_env("COLUMNS", "132")

      for term <- ["dumb", "unknown", "DUMB"] do
        System.put_env("TERM", term)
        assert Terminal.width([]) == 80
      end

      # Not a terminal, so not a dumb one.
      System.put_env("FORCE_COLOR", "")
      assert Terminal.width([]) == 132
    end

    test "is COLUMNS on a dumb terminal when LINES is set too, as Rich's Console" do
      System.put_env("FORCE_COLOR", "1")
      System.put_env("TERM", "dumb")
      System.put_env("COLUMNS", "132")
      System.put_env("LINES", "40")
      assert Terminal.width([]) == 132
    end

    defp terminal_or_80 do
      case :io.columns() do
        {:ok, columns} when columns > 0 -> columns
        _no_terminal -> 80
      end
    end
  end

  describe "colour" do
    @styled {:style, "red bold", "x"}
    @full "\e[31m\e[1mx\e[0m"

    test "is off when not a terminal: TTY_COMPATIBLE=0 or an empty FORCE_COLOR" do
      System.put_env("TTY_COMPATIBLE", "0")
      System.put_env("FORCE_COLOR", "1")
      assert render() == "x"

      System.delete_env("TTY_COMPATIBLE")
      System.put_env("FORCE_COLOR", "")
      assert render() == "x"
    end

    test "is on when FORCE_COLOR or TTY_COMPATIBLE=1 says it is a terminal" do
      System.put_env("FORCE_COLOR", "1")
      assert render() == @full

      System.put_env("FORCE_COLOR", "")
      System.put_env("TTY_COMPATIBLE", "1")
      assert render() == @full
    end

    test "is off on a dumb terminal" do
      System.put_env("FORCE_COLOR", "1")

      for term <- ["dumb", "unknown"] do
        System.put_env("TERM", term)
        assert render() == "x"
      end

      System.put_env("TERM", "xterm-256color")
      assert render() == @full
    end

    test "NO_COLOR drops colours and keeps bold, dim and italic, as Rich's no_color" do
      System.put_env("FORCE_COLOR", "1")
      System.put_env("NO_COLOR", "1")
      assert render() == "\e[1mx\e[0m"
      assert render({:style, "rgb(5,245,141)", "x"}) == "x"
      assert render({:style, "dim italic", "x"}) == "\e[2m\e[3mx\e[0m"

      System.put_env("NO_COLOR", "")
      assert render() == @full
    end

    test "the :color option wins over the environment" do
      System.put_env("TTY_COMPATIBLE", "0")
      assert render(@styled, color: true) == @full

      System.put_env("TTY_COMPATIBLE", "1")
      System.put_env("NO_COLOR", "1")
      assert render(@styled, color: false) == "x"
      assert render(@styled, color: true) == @full
    end

    test "render/2 decides it the same way" do
      System.put_env("FORCE_COLOR", "")
      refute IO.iodata_to_binary(Terminal.render(@styled, width: 10)) =~ "\e["

      System.put_env("FORCE_COLOR", "1")
      assert IO.iodata_to_binary(Terminal.render(@styled, width: 10)) =~ @full
    end

    defp render(text \\ @styled, opts \\ []),
      do: text |> Terminal.render_text(opts) |> IO.iodata_to_binary()
  end
end
