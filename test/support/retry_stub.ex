defmodule DeepEvalEx.Test.RetryStub do
  @moduledoc """
  Helpers for testing an adapter's retries against a `Req.Test` stub.

  `no_backoff/1` sets `DEEPEVAL_RETRY_CAP_SECONDS`' `:retry_cap_seconds`
  config to `0`, deepeval's "no backoff sleeps", so retries run without
  sleeping; `stub_replies/2` makes the stub answer each attempt in turn and
  counts the attempts.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  An ExUnit `setup` callback that disables the retry backoff for the test
  and restores the `:retry_cap_seconds` config afterwards.
  """
  @spec no_backoff(map()) :: :ok
  def no_backoff(_context) do
    saved = Application.get_env(:deep_eval_ex, :retry_cap_seconds)
    Application.put_env(:deep_eval_ex, :retry_cap_seconds, 0)

    on_exit(fn ->
      if saved == nil,
        do: Application.delete_env(:deep_eval_ex, :retry_cap_seconds),
        else: Application.put_env(:deep_eval_ex, :retry_cap_seconds, saved)
    end)

    :ok
  end

  @doc """
  Stubs `stub` to answer the nth attempt with the nth of `replies`, the last
  one answering every later attempt. A reply is `{status, json_body}` or
  `{:transport_error, reason}`.

  Returns a counter for `attempts/1`.
  """
  @spec stub_replies(module(), [{pos_integer(), term()} | {:transport_error, atom()}]) ::
          :counters.counters_ref()
  def stub_replies(stub, [_ | _] = replies) do
    counter = :counters.new(1, [])

    Req.Test.stub(stub, fn conn ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)

      case Enum.at(replies, attempt - 1, List.last(replies)) do
        {:transport_error, reason} ->
          Req.Test.transport_error(conn, reason)

        {status, body} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)

    counter
  end

  @doc """
  The number of attempts the stub of `stub_replies/2` has answered.
  """
  @spec attempts(:counters.counters_ref()) :: non_neg_integer()
  def attempts(counter), do: :counters.get(counter, 1)
end
