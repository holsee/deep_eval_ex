defmodule DeepEvalEx.Tracing.Time do
  @moduledoc """
  Span and trace times: deepeval 4.3.1's `to_zod_compatible_iso`
  (`tracing/utils.py`) and the clock spans read.

  Spans store wall-clock times as integer microseconds since the Unix
  epoch. deepeval exports them as UTC ISO 8601 timestamps ending in `Z`,
  **truncated** (not rounded) to milliseconds for span and trace times and
  to microseconds for an LLM span's `tokenTimes` keys.

  ## Configuration

  The clock can be replaced, for tests, with a `{module, function}` or a
  zero-arity function returning epoch microseconds:

      config :deep_eval_ex, :tracing, clock: {MyApp.FixedClock, :now_us}

  ## Examples

      iex> DeepEvalEx.Tracing.Time.to_zod_iso(1_700_000_000_999_999)
      "2023-11-14T22:13:20.999Z"
      iex> DeepEvalEx.Tracing.Time.to_zod_iso(1_700_000_000_999_999, :microsecond)
      "2023-11-14T22:13:20.999999Z"
  """

  @typedoc "Microseconds since the Unix epoch."
  @type epoch_us :: integer()

  @doc """
  Formats epoch microseconds as deepeval's `to_zod_compatible_iso`:
  `:millisecond` precision (the default) for span and trace times,
  `:microsecond` for `tokenTimes` keys (`microsecond_precision=True`).
  """
  @spec to_zod_iso(epoch_us(), :millisecond | :microsecond) :: String.t()
  def to_zod_iso(epoch_us, precision \\ :millisecond)
      when is_integer(epoch_us) and precision in [:millisecond, :microsecond] do
    epoch_us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(precision)
    |> DateTime.to_iso8601()
  end

  @doc """
  Returns the current wall-clock time in epoch microseconds, from the
  configured `:clock` (see "Configuration") or `System.os_time/1`.
  """
  @spec now_us() :: epoch_us()
  def now_us do
    case Keyword.get(Application.get_env(:deep_eval_ex, :tracing, []), :clock) do
      nil -> System.os_time(:microsecond)
      {module, function} -> apply(module, function, [])
      fun when is_function(fun, 0) -> fun.()
    end
  end
end
