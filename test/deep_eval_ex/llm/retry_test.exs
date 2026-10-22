# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.LLM.RetryTest do
  # Not async: the tests set the retry settings in application config and
  # the environment.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Retry

  @keys ~w(retry_max_attempts retry_initial_seconds retry_exp_base retry_jitter retry_cap_seconds)a
  @vars ~w(DEEPEVAL_RETRY_MAX_ATTEMPTS DEEPEVAL_RETRY_INITIAL_SECONDS DEEPEVAL_RETRY_EXP_BASE
           DEEPEVAL_RETRY_JITTER DEEPEVAL_RETRY_CAP_SECONDS)

  setup do
    saved_config = Map.new(@keys, &{&1, Application.get_env(:deep_eval_ex, &1)})
    saved_env = Map.new(@vars, &{&1, System.get_env(&1)})

    Enum.each(@keys, &Application.delete_env(:deep_eval_ex, &1))
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved_config, fn
        {key, nil} -> Application.delete_env(:deep_eval_ex, key)
        {key, value} -> Application.put_env(:deep_eval_ex, key, value)
      end)

      Enum.each(saved_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  defp response(status, body \\ %{}), do: Req.Response.new(status: status, body: body)

  defp no_jitter, do: 0.0
  defp max_jitter, do: 1.0

  describe "delay/2" do
    test "backs off exponentially from deepeval's defaults, capped at 5s" do
      Application.put_env(:deep_eval_ex, :retry_jitter, 0)

      assert Enum.map(0..4, &Retry.delay(&1, fn -> no_jitter() end)) ==
               [1_000, 2_000, 4_000, 5_000, 5_000]
    end

    test "adds uniform jitter of up to DEEPEVAL_RETRY_JITTER seconds" do
      assert Retry.delay(0, fn -> 0.5 end) == 2_000
      assert Retry.delay(1, fn -> 0.25 end) == 2_500
    end

    test "caps the sleep including its jitter" do
      assert Retry.delay(2, fn -> max_jitter() end) == 5_000
    end

    test "reads the initial, base, jitter and cap settings at call time" do
      System.put_env("DEEPEVAL_RETRY_INITIAL_SECONDS", "0.5")
      System.put_env("DEEPEVAL_RETRY_EXP_BASE", "3")
      Application.put_env(:deep_eval_ex, :retry_jitter, 0.0)
      Application.put_env(:deep_eval_ex, :retry_cap_seconds, 100)

      assert Enum.map(0..2, &Retry.delay(&1, fn -> no_jitter() end)) == [500, 1_500, 4_500]
    end

    test "a cap of 0 means no backoff sleep and no jitter" do
      Application.put_env(:deep_eval_ex, :retry_cap_seconds, 0)

      assert Retry.delay(0, fn -> max_jitter() end) == 0
      assert Retry.delay(5, fn -> max_jitter() end) == 0
    end

    test "an overflowing exponent sleeps the cap" do
      Application.put_env(:deep_eval_ex, :retry_jitter, 0)

      assert Retry.delay(5_000, fn -> no_jitter() end) == 5_000
    end
  end

  describe "retryable?/2 for :openai" do
    test "retries rate limits and 5xx" do
      assert Retry.retryable?(:openai, response(429))
      assert Retry.retryable?(:openai, response(500))
      assert Retry.retryable?(:openai, response(503))
    end

    test "does not retry an exhausted quota, by error code or message" do
      quota = %{"error" => %{"code" => "insufficient_quota", "type" => "insufficient_quota"}}
      refute Retry.retryable?(:openai, response(429, quota))

      refute Retry.retryable?(
               :openai,
               response(429, %{"error" => %{"code" => "INSUFFICIENT_QUOTA"}})
             )

      message = %{"error" => %{"message" => "You exceeded your current quota, please check."}}
      refute Retry.retryable?(:openai, response(429, message))

      refute Retry.retryable?(:openai, response(429, ~s({"error": "RequestQuotaExceeded"})))
    end

    test "does not retry authentication or other client errors" do
      for status <- [400, 401, 403, 404, 408, 409, 422] do
        refute Retry.retryable?(:openai, response(status)), "retried #{status}"
      end
    end

    test "retries transport and protocol errors" do
      assert Retry.retryable?(:openai, %Req.TransportError{reason: :econnrefused})
      assert Retry.retryable?(:openai, %Req.TransportError{reason: :timeout})
      assert Retry.retryable?(:openai, %Req.TransportError{reason: :nxdomain})
      assert Retry.retryable?(:openai, %Req.HTTPError{protocol: :http2, reason: :unprocessed})
    end

    test "does not retry other exceptions" do
      refute Retry.retryable?(:openai, %ArgumentError{message: "boom"})
    end
  end

  describe "retryable?/2 for :anthropic" do
    test "retries rate limits, 5xx and 529 Overloaded" do
      assert Retry.retryable?(:anthropic, response(429))
      assert Retry.retryable?(:anthropic, response(500))

      overloaded = %{"type" => "error", "error" => %{"type" => "overloaded_error"}}
      assert Retry.retryable?(:anthropic, response(529, overloaded))
    end

    test "has no non-retryable rate limit codes" do
      quota = %{"error" => %{"code" => "insufficient_quota"}}
      assert Retry.retryable?(:anthropic, response(429, quota))
    end

    test "does not retry authentication or other client errors" do
      for status <- [400, 401, 403, 404, 413] do
        refute Retry.retryable?(:anthropic, response(status)), "retried #{status}"
      end
    end

    test "retries transport errors" do
      assert Retry.retryable?(:anthropic, %Req.TransportError{reason: :closed})
    end
  end

  describe "retryable?/2 for :ollama" do
    test "retries transport errors only, never an HTTP status" do
      assert Retry.retryable?(:ollama, %Req.TransportError{reason: :econnrefused})

      for status <- [429, 500, 503, 529] do
        refute Retry.retryable?(:ollama, response(status)), "retried #{status}"
      end
    end
  end

  describe "req_options/1" do
    test "makes DEEPEVAL_RETRY_MAX_ATTEMPTS attempts, the first call included" do
      assert Keyword.fetch!(Retry.req_options(:openai), :max_retries) == 1

      System.put_env("DEEPEVAL_RETRY_MAX_ATTEMPTS", "4")
      assert Keyword.fetch!(Retry.req_options(:openai), :max_retries) == 3

      Application.put_env(:deep_eval_ex, :retry_max_attempts, 1)
      assert Keyword.fetch!(Retry.req_options(:anthropic), :max_retries) == 0
    end

    test "wires the provider's classification and the backoff into Req" do
      opts = Retry.req_options(:anthropic)
      retry = Keyword.fetch!(opts, :retry)
      retry_delay = Keyword.fetch!(opts, :retry_delay)

      assert retry.(Req.new(), response(529))
      refute retry.(Req.new(), response(401))

      Application.put_env(:deep_eval_ex, :retry_cap_seconds, 0)
      assert retry_delay.(0) == 0
    end

    test "rejects an unknown provider" do
      assert_raise ArgumentError, ~r/unknown retry provider: :bedrock/, fn ->
        Retry.req_options(:bedrock)
      end
    end
  end
end
