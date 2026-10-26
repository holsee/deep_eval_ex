defmodule DeepEvalEx.Tracing.ConfigTest do
  # Changes the :tracing application config, which every capture reads.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Span, Trace}

  setup do
    previous = Application.get_env(:deep_eval_ex, :tracing)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:deep_eval_ex, :tracing, previous),
        else: Application.delete_env(:deep_eval_ex, :tracing)
    end)
  end

  test "masks default inputs and outputs, of the span and the trace" do
    Application.put_env(:deep_eval_ex, :tracing, mask: fn _data -> "[masked]" end)

    {_, [trace]} =
      Tracing.capture([], fn ->
        Tracing.span(:base, [name: "secret", input: "card 4242"], fn -> "token" end)
      end)

    assert [%Span{input: "[masked]", output: "[masked]"}] = trace.root_spans
    assert {trace.input, trace.output} == {"[masked]", "[masked]"}
  end

  test "takes uuids and times from the configured generators" do
    {:ok, ids} = Agent.start_link(fn -> 0 end)
    next_id = fn -> "id-#{Agent.get_and_update(ids, &{&1 + 1, &1 + 1})}" end
    Application.put_env(:deep_eval_ex, :tracing, uuid: next_id, clock: fn -> 1_000 end)

    {_, [trace]} =
      Tracing.capture([], fn -> Tracing.span(:base, [name: "s"], fn -> :ok end) end)

    assert %Trace{start_us: 1_000, end_us: 1_000, root_spans: [span]} = trace
    assert {span.uuid, trace.uuid} == {"id-1", "id-2"}
    assert {span.start_us, span.end_us} == {1_000, 1_000}
  end
end
