defmodule DeepEvalEx.TracingScenariosTest do
  @moduledoc """
  Checks `DeepEvalEx.Test.TracingScenarios.compile/2`, which the parity
  tests of the traced fixtures share and which async tests call at once.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.TracingScenarios

  @moduletag :parity

  test "compile/2 defines a scenario's module once when tests ask for it at the same time" do
    namespace = Module.concat(__MODULE__, "Run#{System.unique_integer([:positive])}")

    modules =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> TracingScenarios.compile("nested_spans", namespace) end)
      end)
      |> Task.await_many(30_000)

    assert modules == List.duplicate(Module.concat(namespace, NestedSpans), 8)
    assert function_exported?(hd(modules), :__functions__, 0)
  end
end
