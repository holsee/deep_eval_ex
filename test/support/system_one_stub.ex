defmodule DeepEvalEx.Test.SystemOneStub do
  @moduledoc """
  A `DeepEvalEx.SystemOne.Adapter` for the facade's tests, answering with
  the function in its `:decide` option.

  `:decide` takes `(state, questions, opts)` and returns what the adapter's
  `decide/3` returns (or raises). `:name` is its `model_name/1` (default
  `"stub-jev"`), `:budget` its `context_budget/1` and `:init` the result of
  its `init/1` (both default to the `use` defaults).
  """

  use DeepEvalEx.SystemOne.Adapter

  @impl true
  def model_name(opts), do: Keyword.get(opts, :name, "stub-jev")

  @impl true
  def decide(state, questions, opts), do: Keyword.fetch!(opts, :decide).(state, questions, opts)

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :init) do
      {:ok, result} -> result
      :error -> super(opts)
    end
  end

  @impl true
  def context_budget(opts) do
    case Keyword.fetch(opts, :budget) do
      {:ok, budget} -> budget
      :error -> super(opts)
    end
  end
end

defmodule DeepEvalEx.Test.SystemOneBare do
  @moduledoc """
  A `DeepEvalEx.SystemOne.Adapter` implementing only the two required
  callbacks, with `@behaviour` rather than `use`.
  """

  @behaviour DeepEvalEx.SystemOne.Adapter

  @impl true
  def model_name(_opts), do: "bare-jev"

  @impl true
  def decide(_state, _questions, _opts), do: {:ok, %DeepEvalEx.SystemOne.Answers{}, nil}
end
