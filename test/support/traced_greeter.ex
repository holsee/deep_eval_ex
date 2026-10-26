defmodule DeepEvalEx.Test.TracedGreeter do
  @moduledoc """
  A `deftraced` function with a `@doc` and a `@spec`, compiled to a beam
  file so that tests can read them back.
  """

  use DeepEvalEx.Tracing

  @doc "Greets someone."
  @spec greet(String.t()) :: String.t()
  deftraced greet(name), type: :agent do
    "Hello, #{name}"
  end
end
