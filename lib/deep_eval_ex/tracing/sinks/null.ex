defmodule DeepEvalEx.Tracing.Sinks.Null do
  @moduledoc """
  The default `DeepEvalEx.Tracing.Sink`: drops every trace, so nothing is
  kept of a trace closed outside a capture but its
  `[:deep_eval_ex, :trace, :stop]` event.
  """

  @behaviour DeepEvalEx.Tracing.Sink

  @impl true
  def export(_trace, _opts), do: :ok
end
