# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/models/retry_policy.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.LLM.Retry do
  @moduledoc """
  The retry policy of the HTTP adapters, a port of deepeval 4.3.1's
  `models/retry_policy.py`.

  `req_options/1` returns the `Req` `:retry`, `:retry_delay` and
  `:max_retries` options an adapter passes on every request, so OpenAI,
  Anthropic and Ollama calls retry exactly the failures deepeval's Tenacity
  decorators retry, with the same backoff.

  ## Configuration

  Read at call time with `DeepEvalEx.Config.get/1`, from
  `config :deep_eval_ex` or deepeval's environment variables:

  | Key | Environment variable | Default |
  |-----|----------------------|---------|
  | `:retry_max_attempts` | `DEEPEVAL_RETRY_MAX_ATTEMPTS` | `2` |
  | `:retry_initial_seconds` | `DEEPEVAL_RETRY_INITIAL_SECONDS` | `1.0` |
  | `:retry_exp_base` | `DEEPEVAL_RETRY_EXP_BASE` | `2.0` |
  | `:retry_jitter` | `DEEPEVAL_RETRY_JITTER` | `2.0` |
  | `:retry_cap_seconds` | `DEEPEVAL_RETRY_CAP_SECONDS` | `5.0` |

  `:retry_max_attempts` counts the first call, so the default makes one
  retry and `1` disables retries. See `delay/2` for the backoff.

  ## What is retried

  As deepeval's `make_is_transient` with each provider's `ErrorPolicy`
  (see `retryable?/2`):

  - **`:openai`** - transport errors, rate limits (`429`) unless the error
    code is `insufficient_quota`, and `5xx`. Authentication (`401`) and other
    client errors are not retried.
  - **`:anthropic`** - transport errors, rate limits (`429`) and `5xx`,
    including `529` Overloaded. Authentication (`401`) and other client
    errors are not retried.
  - **`:ollama`** - transport errors only; deepeval's Ollama policy retries
    no HTTP status.
  - **`:typesafe`** - transport errors (timeouts included), rate limits
    (`429`) and `5xx`, for `DeepEvalEx.SystemOne.Adapters.TypeSafe`.
    Authentication (`401`), permission (`403`) and other client errors,
    `422` included, are not retried, and neither is a response whose
    `"detail"."error_type"` is `"max_tokens_exceeded"`: deepeval turns it
    into a `SystemOneContextLimitError` inside the retried call, which its
    TypeSafe policy does not retry.

  A request's `:req_options` are merged over these, so `retry: false` still
  turns retries off for one call.

  deepeval's `DEEPEVAL_SDK_RETRY_PROVIDERS` (hand retries to the provider
  SDK) has no counterpart: the adapters call the HTTP APIs directly.
  """

  alias DeepEvalEx.Config

  @type provider :: :openai | :anthropic | :ollama | :typesafe

  # deepeval's OPENAI_MESSAGE_MARKERS: text that identifies a non-retryable
  # code when the response carries no structured one.
  @openai_message_markers %{
    "insufficient_quota" => [
      "insufficient_quota",
      "insufficient quota",
      "exceeded your current quota",
      "requestquotaexceeded"
    ]
  }

  # deepeval's ErrorPolicy per provider, by HTTP status rather than SDK
  # exception class: the OpenAI and Anthropic SDKs raise AuthenticationError
  # for 401, RateLimitError for 429 and an APIStatusError carrying the status
  # otherwise. Ollama's policy lists no auth, rate limit or HTTP status
  # exceptions, so only transport errors are retried. TypeSafe's lists the
  # SDK's authentication and permission errors (401, 403), its rate limit
  # error (429) and its connection, timeout and internal server errors
  # (5xx); its context overflow is never transient.
  @policies %{
    openai: %{
      auth_statuses: [401],
      rate_limit_statuses: [429],
      retry_5xx: true,
      non_retryable_codes: ["insufficient_quota"],
      message_markers: @openai_message_markers
    },
    anthropic: %{
      auth_statuses: [401],
      rate_limit_statuses: [429],
      retry_5xx: true,
      non_retryable_codes: [],
      message_markers: %{}
    },
    ollama: %{
      auth_statuses: [],
      rate_limit_statuses: [],
      retry_5xx: false,
      non_retryable_codes: [],
      message_markers: %{}
    },
    typesafe: %{
      auth_statuses: [401, 403],
      rate_limit_statuses: [429],
      retry_5xx: true,
      non_retryable_codes: [],
      message_markers: %{},
      non_retryable_error_types: ["max_tokens_exceeded"]
    }
  }

  @doc """
  The `Req` retry options for `provider`'s requests: `:retry` classifies a
  response or exception with `retryable?/2`, `:retry_delay` sleeps
  `delay/2` and `:max_retries` is `DEEPEVAL_RETRY_MAX_ATTEMPTS` less the
  first call.

  Retries are logged at `:info`, deepeval's default level for its
  before-sleep retry log.

  Raises `ArgumentError` for a provider without a policy.
  """
  @spec req_options(provider()) :: keyword()
  def req_options(provider) do
    policy!(provider)

    [
      retry: fn _request, response_or_exception -> retryable?(provider, response_or_exception) end,
      retry_delay: &delay/1,
      max_retries: Config.get(:retry_max_attempts) - 1,
      retry_log_level: :info
    ]
  end

  @doc """
  Whether `provider`'s policy retries a response or exception, deepeval's
  `make_is_transient` predicate:

  - a `Req.TransportError` or `Req.HTTPError` (connection failures and
    timeouts) is retried;
  - a response whose `"detail"."error_type"` the policy never retries
    (TypeSafe's `"max_tokens_exceeded"`) is not;
  - an authentication status is not;
  - a rate limit status is, unless the error code in the body (its
    `"error"."code"`, or else a known message) is non-retryable;
  - a `5xx` is when the policy retries `5xx`;
  - anything else is not.

  ## Examples

      iex> DeepEvalEx.LLM.Retry.retryable?(:anthropic, Req.Response.new(status: 529))
      true

      iex> DeepEvalEx.LLM.Retry.retryable?(:openai, Req.Response.new(status: 401))
      false
  """
  @spec retryable?(provider(), Req.Response.t() | Exception.t()) :: boolean()
  def retryable?(provider, response_or_exception) do
    transient?(policy!(provider), response_or_exception)
  end

  @doc """
  The backoff in milliseconds before retry `retry_count` (zero-based, as
  `Req` counts retries), Tenacity's `wait_exponential_jitter` as deepeval
  configures it:

      min(cap, initial * exp_base ** retry_count + uniform(0, jitter))

  with `initial`, `exp_base`, `jitter` and `cap` the
  `DEEPEVAL_RETRY_INITIAL_SECONDS`, `DEEPEVAL_RETRY_EXP_BASE`,
  `DEEPEVAL_RETRY_JITTER` and `DEEPEVAL_RETRY_CAP_SECONDS` settings. A cap of
  `0` means no backoff sleeps or jitter. With the defaults the first retry
  waits 1 to 3 seconds.

  `uniform` returns a float in `[0, 1)` that scales the jitter; it defaults
  to `:rand.uniform/0`.
  """
  @spec delay(non_neg_integer(), (-> float())) :: non_neg_integer()
  def delay(retry_count, uniform \\ &:rand.uniform/0) do
    case Config.get(:retry_cap_seconds) do
      cap when cap == 0 ->
        0

      cap ->
        initial = Config.get(:retry_initial_seconds)
        exp_base = Config.get(:retry_exp_base)
        jitter = Config.get(:retry_jitter) * uniform.()
        round(max(backoff(initial, exp_base, retry_count, jitter, cap), 0) * 1000)
    end
  end

  # Tenacity sleeps the cap when the exponent overflows.
  defp backoff(initial, exp_base, retry_count, jitter, cap) do
    min(initial * :math.pow(exp_base, retry_count) + jitter, cap)
  rescue
    ArithmeticError -> cap
  end

  defp policy!(provider) do
    case Map.fetch(@policies, provider) do
      {:ok, policy} -> policy
      :error -> raise ArgumentError, "unknown retry provider: #{inspect(provider)}"
    end
  end

  defp transient?(_policy, %Req.TransportError{}), do: true
  defp transient?(_policy, %Req.HTTPError{}), do: true

  defp transient?(policy, %Req.Response{status: status, body: body}) do
    cond do
      non_retryable_error_type?(body, policy) ->
        false

      status in policy.auth_statuses ->
        false

      status in policy.rate_limit_statuses ->
        error_code(body, policy) not in policy.non_retryable_codes

      true ->
        policy.retry_5xx and status in 500..599
    end
  end

  defp transient?(_policy, _exception), do: false

  # deepeval's extract_error_code: the body's error.code, else the first
  # code whose message marker appears in the error text, else "".
  defp error_code(body, policy) do
    case get_in_map(body, ["error", "code"]) do
      code when is_binary(code) or is_integer(code) ->
        code |> to_string() |> String.downcase()

      _none ->
        marked_code(body |> error_text() |> String.downcase(), policy.message_markers)
    end
  end

  defp marked_code(text, message_markers) do
    Enum.find_value(message_markers, "", fn {code, needles} ->
      if Enum.any?(needles, &String.contains?(text, &1)), do: code
    end)
  end

  defp non_retryable_error_type?(body, policy) do
    case Map.get(policy, :non_retryable_error_types, []) do
      [] -> false
      types -> detail_error_type(body) in types
    end
  end

  # The body's detail.error_type, TypeSafe's error shape. Retries are
  # classified before Req decodes the body, so a JSON text is decoded here.
  defp detail_error_type(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> detail_error_type(decoded)
      {:error, _} -> nil
    end
  end

  defp detail_error_type(body), do: get_in_map(body, ["detail", "error_type"])

  defp get_in_map(value, []), do: value
  defp get_in_map(%{} = map, [key | rest]), do: get_in_map(Map.get(map, key), rest)
  defp get_in_map(_value, _path), do: nil

  defp error_text(body) when is_binary(body), do: body
  defp error_text(body), do: inspect(body, limit: :infinity, printable_limit: :infinity)
end
