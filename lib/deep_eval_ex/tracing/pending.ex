defmodule DeepEvalEx.Tracing.Pending do
  @moduledoc """
  The slots `DeepEvalEx.Tracing.next_span/2` and its typed variants stage
  for the next span of a type: deepeval 4.3.1's `_PendingSlot`,
  `pop_pending_for` and `apply_pending_to_span` (`tracing/context.py`).

  A slot is one row in `DeepEvalEx.Tracing.Store`, named in the context's
  `:pending` map (see `DeepEvalEx.Tracing.Ctx`) for as long as the staging
  function runs. Taking it removes the row, so a slot is consumed once,
  by the first matching span, in whichever process opens it: a task that
  joins through `$callers` or `DeepEvalEx.Tracing.async/1` takes its
  caller's slot, as deepeval's slot wrapper is shared with the asyncio
  tasks it creates.

  `DeepEvalEx.Tracing.open_span/2` (and so `span/3`, `record_span/2` and
  `deftraced`) applies the slots when it builds a span, before the span is
  current, so `update_current_span/1` sees them as the baseline. An
  integration that builds spans some other way calls `pop/2` and
  `apply_to_span/2` itself, as deepeval's do.
  """

  alias DeepEvalEx.Tracing.{Ctx, Span, Store, Update}

  @typedoc "A staged payload: the fields given to `next_*`, without `nil` values."
  @type payload :: keyword()

  @doc """
  Runs `fun` with a slot holding `opts` staged for the next span of
  `type` (`:base` for any type), and returns its result. The slot is
  removed when `fun` returns or raises, consumed or not, and the slot it
  replaced, if any, is current again.

  `nil` values are left out, deepeval's `_drop_none`. Raises
  `ArgumentError` on an option `next_*` of `type` does not take.
  """
  @spec stage(Span.type(), keyword(), (-> result)) :: result when result: term()
  def stage(type, opts, fun) when is_function(fun, 0) do
    payload = Update.validate_pending!(type, opts)
    ctx = Ctx.current() || %Ctx{}
    ref = make_ref()
    Store.put_pending(ref, payload)

    try do
      Ctx.with(%{ctx | pending: Map.put(ctx.pending, type, ref)}, fun)
    after
      Store.delete_pending(ref)
    end
  end

  @doc """
  Takes the slots staged for a span of `type` in `ctx`: the base slot's
  fields, with the typed slot's over them ("more specific wins"). Each
  slot taken is gone for every process. A `:base` span takes only the
  base slot.
  """
  @spec pop(Ctx.t() | nil, Span.type()) :: payload()
  def pop(nil, _type), do: []

  def pop(%Ctx{pending: pending}, type) do
    base = take(pending, :base)
    if type == :base, do: base, else: Keyword.merge(base, take(pending, type))
  end

  defp take(pending, type) do
    case Map.fetch(pending, type) do
      {:ok, ref} -> Store.take_pending(ref) || []
      :error -> []
    end
  end

  @doc """
  Sets a popped payload on `span`, `apply_pending_to_span`: a staged
  `:test_case` is unpacked first (as `update_current_span/1` does), then
  every other field is set over it. Tool calls become
  `DeepEvalEx.Schemas.ToolCall` structs, and integer token counts and
  costs floats.
  """
  @spec apply_to_span(Span.t(), payload()) :: Span.t()
  def apply_to_span(%Span{} = span, payload), do: Update.apply_pending(span, payload)
end
