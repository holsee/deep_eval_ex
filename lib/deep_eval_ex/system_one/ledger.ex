defmodule DeepEvalEx.SystemOne.Ledger do
  @moduledoc """
  The per-measure System One bookkeeping of a metric, deepeval 4.3.1's
  `confidence`, `system_one_fallback_reason` and `_system_one_disabled`
  metric attributes.

  - **confidence** - the least decisive System One answer that fed the
    measure, `nil` when no System One call was made (`_record_confidence`)
  - **fallback reasons** - why `:hybrid` decisions were handed back to the
    LLM because their System One call failed, joined with `"; "` as
    `system_one_fallback_reason` (`_note_fallback`)
  - **disabled** - set after a permanent failure (a missing or rejected
    key) so that the rest of the measure stays on the LLM

  ## Scope

  Like `DeepEvalEx.LLM.Usage`, the ledger lives in the process dictionary.
  `c:DeepEvalEx.Metrics.BaseMetric.measure/2` opens a fresh one around every
  measure with `track/1`, deepeval's `reset_system_one_state`, so a metric
  measured again never carries a previous test case's confidence or
  fallback reason, and puts what it holds on the result (`:confidence` and
  `:system_one_fallback_reason`). A metric measured inside another keeps its
  own ledger: nothing is passed on to the enclosing one.

  Tasks started with `DeepEvalEx.LLM.Usage.async/1` see the caller's ledger
  (a disabled flag included), and `DeepEvalEx.LLM.Usage.await/2` folds what
  they recorded back into it: the lower confidence, and the reasons they
  noted after the caller's. Plain `Task`s lose them.

  Every function is a no-op (or returns the empty value) when no ledger is
  open, so System One helpers can always call them.
  """

  alias DeepEvalEx.SystemOne.Answers

  @typedoc """
  A ledger. `:fallback_reasons` are in the order they were noted.
  """
  @type t :: %__MODULE__{
          confidence: number() | nil,
          fallback_reasons: [String.t()],
          disabled?: boolean()
        }

  defstruct confidence: nil, fallback_reasons: [], disabled?: false

  @key {__MODULE__, :scope}

  @doc """
  Runs `fun` with a fresh ledger and returns `{result, ledger}`, what the
  ledger held when `fun` returned.

  An enclosing ledger is set aside while `fun` runs and restored afterwards
  (also when `fun` raises), unchanged.
  """
  @spec track((-> result)) :: {result, t()} when result: term()
  def track(fun) when is_function(fun, 0) do
    outer = Process.put(@key, %__MODULE__{})

    try do
      result = fun.()
      {result, Process.get(@key)}
    after
      if outer, do: Process.put(@key, outer), else: Process.delete(@key)
    end
  end

  @doc """
  The open ledger, or `nil` when none is open.
  """
  @spec current() :: t() | nil
  def current, do: Process.get(@key)

  @doc """
  Folds the least decisive answer of one System One request into the
  measure's confidence (the minimum across the measure), as deepeval's
  `_record_confidence`, and returns the request's own confidence.

  `answers` is a `DeepEvalEx.SystemOne.Answers`, one of its per-type maps
  (`answers.nouls`, ...) or a confidence. A request without answers
  (`nil`) changes nothing.

  ## Examples

      iex> alias DeepEvalEx.SystemOne.{Answers, Ledger}
      iex> {_, ledger} =
      ...>   Ledger.track(fn ->
      ...>     Ledger.record_confidence(%{"q_0" => %Answers.Noul{probability: 0.9}})
      ...>     Ledger.record_confidence(0.95)
      ...>   end)
      iex> ledger.confidence
      0.8
  """
  @spec record_confidence(
          Answers.t()
          | %{optional(String.t()) => Answers.answer()}
          | number()
          | nil
        ) ::
          number() | nil
  def record_confidence(%Answers{} = answers),
    do: answers |> Answers.min_confidence() |> record_confidence()

  def record_confidence(answers) when is_map(answers) do
    answers
    |> Map.values()
    |> Enum.map(&Answers.confidence/1)
    |> Enum.min(fn -> nil end)
    |> record_confidence()
  end

  def record_confidence(nil), do: nil

  def record_confidence(confidence) when is_number(confidence) do
    update(fn ledger -> %{ledger | confidence: lower(ledger.confidence, confidence)} end)
    confidence
  end

  @doc """
  Sets the measure's confidence, replacing the running minimum, as
  deepeval's whole-chain runner sets it to the minimum over its outcomes.
  """
  @spec put_confidence(number() | nil) :: :ok
  def put_confidence(confidence) when is_number(confidence) or is_nil(confidence),
    do: update(&%{&1 | confidence: confidence})

  @doc """
  The measure's confidence so far, or `nil`.
  """
  @spec confidence() :: number() | nil
  def confidence, do: with(%__MODULE__{confidence: confidence} <- current(), do: confidence)

  @doc """
  Records why a `:hybrid` decision fell back to the LLM, deepeval's
  `_note_fallback`.
  """
  @spec note_fallback(String.t()) :: :ok
  def note_fallback(reason) when is_binary(reason),
    do: update(&%{&1 | fallback_reasons: &1.fallback_reasons ++ [reason]})

  @doc """
  The fallback reasons of `ledger` (default: the open one) joined with
  `"; "`, deepeval's `system_one_fallback_reason`, or `nil` when there are
  none.

  ## Examples

      iex> DeepEvalEx.SystemOne.Ledger.fallback_reason(%DeepEvalEx.SystemOne.Ledger{
      ...>   fallback_reasons: ["ConnectionError: Jev is down", "timeout (slow)"]})
      "ConnectionError: Jev is down; timeout (slow)"
  """
  @spec fallback_reason(t() | nil) :: String.t() | nil
  def fallback_reason(ledger \\ current())
  def fallback_reason(%__MODULE__{fallback_reasons: []}), do: nil
  def fallback_reason(%__MODULE__{fallback_reasons: reasons}), do: Enum.join(reasons, "; ")
  def fallback_reason(nil), do: nil

  @doc """
  Keeps the rest of the measure off System One, after a permanent failure.
  """
  @spec disable() :: :ok
  def disable, do: update(&%{&1 | disabled?: true})

  @doc """
  Whether `disable/0` was called in this measure.
  """
  @spec disabled?() :: boolean()
  def disabled?, do: match?(%__MODULE__{disabled?: true}, current())

  @doc false
  # Runs `fun` (in a task) on a copy of `snapshot`, the caller's ledger as
  # `current/0` returned it, and returns `{result, delta}`: what `fun` added,
  # for `join/1`. Without a snapshot no ledger is opened.
  @spec run_forked(t() | nil, (-> result)) :: {result, t() | nil} when result: term()
  def run_forked(nil, fun), do: {fun.(), nil}

  def run_forked(%__MODULE__{} = snapshot, fun) do
    Process.put(@key, snapshot)
    result = fun.()
    ledger = Process.get(@key)
    added = Enum.drop(ledger.fallback_reasons, length(snapshot.fallback_reasons))
    {result, %{ledger | fallback_reasons: added}}
  end

  @doc false
  # Folds a task's delta (`run_forked/2`) into the open ledger.
  @spec join(t() | nil) :: :ok
  def join(nil), do: :ok

  def join(%__MODULE__{} = delta) do
    update(fn ledger ->
      %{
        ledger
        | confidence: lower(ledger.confidence, delta.confidence),
          fallback_reasons: ledger.fallback_reasons ++ delta.fallback_reasons,
          disabled?: ledger.disabled? or delta.disabled?
      }
    end)
  end

  defp update(fun) do
    case current() do
      nil -> :ok
      ledger -> Process.put(@key, fun.(ledger))
    end

    :ok
  end

  # Python's min(current, new): the current value unless the new one is lower.
  defp lower(nil, new), do: new
  defp lower(current, nil), do: current
  defp lower(current, new), do: if(new < current, do: new, else: current)
end
