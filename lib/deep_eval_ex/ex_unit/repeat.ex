# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ports pytest-repeat's --count, which `deepeval test run --repeat` uses
# Original: https://github.com/pytest-dev/pytest-repeat

defmodule DeepEvalEx.ExUnit.Repeat do
  @moduledoc """
  `test` macros that register each test as many times as
  `mix deep_eval.test --repeat N` asks, as pytest-repeat's `--count`
  repeats each test under `deepeval test run --repeat`.

  `use DeepEvalEx.ExUnit` imports them in place of `ExUnit.Case`'s. They
  read the `:repeat` setting (see `DeepEvalEx.Config`) when the test module
  is compiled, which `mix test` does after `mix deep_eval.test` has set it:

  - unset or `1`: one `ExUnit.Case.test/3`, unchanged;
  - `N > 1`: `N` tests named as pytest-repeat names them,
    `"<name>[1-N]"` to `"<name>[N-N]"`, each with the test's `@tag`s. Each
    runs the whole test body, the application call that produces the
    output under evaluation included.

  Repeated tests of an `async: true` module run concurrently.
  """

  alias DeepEvalEx.Config

  @doc """
  A test not implemented yet, as `ExUnit.Case.test/1`, repeated.
  """
  defmacro test(message) do
    message
    |> names()
    |> Enum.map(&quote(do: ExUnit.Case.test(unquote(&1))))
    |> repeated()
  end

  @doc """
  A test, as `ExUnit.Case.test/3`, repeated (see the module documentation).
  """
  defmacro test(message, var \\ quote(do: _), contents) do
    message
    |> names()
    |> Enum.map(&quote(do: ExUnit.Case.test(unquote(&1), unquote(var), unquote(contents))))
    |> repeated()
  end

  defp names(message) do
    case Config.get(:repeat) do
      count when is_integer(count) and count > 1 ->
        for i <- 1..count, do: quote(do: unquote(message) <> unquote("[#{i}-#{count}]"))

      _once ->
        [message]
    end
  end

  defp repeated([test]), do: test

  # Registering a test consumes its @tag attributes: each repeat gets them
  # back, so `@tag skip: ...` or `@tag :rag` applies to every repeat.
  defp repeated([first | rest]) do
    quote do
      repeated_tags = Module.get_attribute(__MODULE__, :tag)
      unquote(first)

      unquote_splicing(
        Enum.map(rest, fn test ->
          quote do
            Enum.each(Enum.reverse(repeated_tags), &Module.put_attribute(__MODULE__, :tag, &1))
            unquote(test)
          end
        end)
      )
    end
  end
end
