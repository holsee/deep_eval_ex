defmodule DeepEvalEx.Tracing.Sinks.Test do
  @moduledoc """
  A `DeepEvalEx.Tracing.Sink` for tests: sends each trace to a process as
  `{:trace, %DeepEvalEx.Tracing.Trace{}}`.

  ## Options

  - `:pid` (required) - The process to send traces to

  ## Examples

      # The sink is application config, so the test cannot be async; other
      # tests' traces may arrive too, so match on yours.
      Application.put_env(:deep_eval_ex, :tracing,
        sink: {DeepEvalEx.Tracing.Sinks.Test, pid: self()}
      )

      MyApp.Support.answer("hi")

      assert_receive {:trace, %DeepEvalEx.Tracing.Trace{root_spans: [%{name: "answer"}]}}
  """

  @behaviour DeepEvalEx.Tracing.Sink

  @impl true
  def export(trace, opts) do
    send(Keyword.fetch!(opts, :pid), {:trace, trace})
    :ok
  end
end
