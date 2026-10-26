defmodule DeepEvalEx.Scope do
  @moduledoc false
  # The process-scoped state a task carries across from its caller, in one
  # fork/join (ADR-0009 decision 11, ADR-0011 decision 3):
  #
  # - the caller's `DeepEvalEx.Tracing.Ctx`, a snapshot taken when the task
  #   starts, so its spans nest under the caller's current span;
  # - a fresh `DeepEvalEx.LLM.Usage` scope, whose usages `await/2` records
  #   in the caller's;
  # - a copy of the caller's `DeepEvalEx.SystemOne.Ledger`, whose additions
  #   `await/2` folds back into the caller's.
  #
  # `DeepEvalEx.LLM.Usage.async/1` and `DeepEvalEx.Tracing.async/1` (and
  # their `await/2`) are this function under the name their callers know.

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.Ledger
  alias DeepEvalEx.Tracing.Ctx

  @spec async((-> term())) :: Task.t()
  def async(fun) when is_function(fun, 0) do
    ledger = Ledger.current()
    ctx = Ctx.current()

    Task.async(fn -> Ctx.with(ctx, fn -> run(ledger, fun) end) end)
  end

  @spec await(Task.t(), timeout()) :: term()
  def await(task, timeout \\ 5_000) do
    {result, usages, ledger} = Task.await(task, timeout)
    Usage.record_all(usages)
    Ledger.join(ledger)
    result
  end

  defp run(ledger, fun) do
    {{result, usages}, ledger} = Ledger.run_forked(ledger, fn -> Usage.track(fun) end)
    {result, usages, ledger}
  end
end
