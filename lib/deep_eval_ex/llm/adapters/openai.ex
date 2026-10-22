defmodule DeepEvalEx.LLM.Adapters.OpenAI do
  @moduledoc """
  OpenAI LLM adapter for DeepEvalEx.

  Supports OpenAI's chat completions API with structured outputs, and any
  OpenAI-compatible gateway reachable at a different base URL.

  ## Configuration

  Set your API key in config:

      config :deep_eval_ex,
        openai_api_key: System.get_env("OPENAI_API_KEY")

  Or pass it directly:

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: :openai,
        api_key: "sk-..."
      )

  ## Base URL

  The API base URL is resolved in this order (a trailing slash is stripped):

  1. the `:base_url` option
  2. `config :deep_eval_ex, openai_base_url: "..."`
  3. the `OPENAI_BASE_URL` environment variable
  4. `"https://api.openai.com/v1"`

  ## Options

  - `:model` - model name (default `"gpt-4o-mini"`)
  - `:max_completion_tokens` - completion token limit (default `4096`);
    `:max_tokens` is accepted as an alias
  - `:temperature` - sampling temperature; falls back to the
    `:openai_temperature` config, then to `0.0`, as deepeval's `GPTModel`
    does, so judges are deterministic rather than running at OpenAI's default
    of `1.0`. Reasoning models (`o1`, `o3`, `o4`, `gpt-5`, ...) reject
    `temperature`, so it is never sent for them, as in deepeval.
  - `:base_url` - API base URL, see above
  - `:api_key` - API key (overrides config and `OPENAI_API_KEY`)
  - `:timeout` - receive timeout in milliseconds (default `60_000`)
  - `:top_logprobs` - for `generate_raw_response/2`, the number of most
    likely tokens returned at each position (default `5`)
  - `:req_options` - extra `Req` options merged into the request, e.g.
    `[plug: {Req.Test, DeepEvalEx.LLM.Adapters.OpenAI}]` in tests

  ## Supported Models

  - `gpt-4o` - Latest GPT-4 Omni (recommended)
  - `gpt-4o-mini` - Smaller, faster GPT-4
  - `gpt-4-turbo` - GPT-4 Turbo
  - `gpt-3.5-turbo` - GPT-3.5 (faster, cheaper)

  ## Usage and Cost

  The `usage.prompt_tokens` and `usage.completion_tokens` of every response
  are recorded with `DeepEvalEx.LLM.Usage`, priced for the requested model
  by `DeepEvalEx.LLM.Pricing`.
  """

  use DeepEvalEx.LLM.Adapter

  alias DeepEvalEx.LLM.{Adapter, StrictSchema, Usage}

  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"
  @default_max_completion_tokens 4096
  @default_temperature 0.0

  # Models that reject a `temperature` parameter, mirroring the
  # `supports_temperature=False` entries in deepeval's OpenAI model registry.
  @reasoning_model_pattern ~r/^(o\d|gpt-[5-9])/

  # The `supports_log_probs=True` entries of deepeval 4.3.1's OpenAI model
  # registry (OPENAI_MODELS_DATA); any other model, known or not, has none.
  @log_prob_models ~w(
    gpt-3.5-turbo gpt-3.5-turbo-0125 gpt-3.5-turbo-1106
    gpt-4-0125-preview gpt-4-1106-preview gpt-4-turbo gpt-4-turbo-2024-04-09
    gpt-4-turbo-preview gpt-4o gpt-4 gpt-4o-2024-05-13 gpt-4o-2024-08-06
    gpt-4o-2024-11-20 gpt-4o-mini gpt-4o-mini-2024-07-18 gpt-4-32k gpt-4-32k-0613
    gpt-4.1 gpt-4.1-mini gpt-4.1-nano gpt-5.4 gpt-5.4-2026-03-05
  )

  # Their `max_log_probs`, where the registry caps `top_logprobs`.
  @max_log_probs %{"gpt-5.4" => 5, "gpt-5.4-2026-03-05" => 5}

  # deepeval's generate_raw_response default.
  @default_top_logprobs 5

  @impl true
  def generate(prompt, opts \\ []) do
    body = base_body(prompt, opts)

    case chat_completion(body, opts) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, content}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts \\ []) do
    json_schema = schema_to_json_schema(schema)

    body =
      prompt
      |> base_body(opts)
      |> Map.put(:response_format, %{
        type: "json_schema",
        json_schema: %{
          name: "response",
          strict: true,
          schema: json_schema
        }
      })

    case chat_completion(body, opts) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        parse_json_response(content, schema)

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Generates a chat completion with logprobs, deepeval's
  `GPTModel.generate_raw_response`: the request of `generate/2` with
  `logprobs: true` and `top_logprobs` (the `:top_logprobs` option, default
  `5`, capped at the model's maximum as deepeval caps it), returning the
  whole decoded completion.

  Models without logprobs (see `supports_log_probs?/1`) are
  `{:error, {:log_probs_unsupported, model}}`, where deepeval raises.
  """
  @impl true
  def generate_raw_response(prompt, opts \\ []) do
    model = model_name(opts)

    if supports_log_probs?(opts) do
      body =
        prompt
        |> base_body(opts)
        |> Map.merge(%{
          logprobs: true,
          top_logprobs:
            cap_top_logprobs(model, Keyword.get(opts, :top_logprobs, @default_top_logprobs))
        })

      case chat_completion(body, opts) do
        {:ok, %{"choices" => [_ | _]} = completion} -> {:ok, completion}
        {:ok, response} -> {:error, {:unexpected_response, response}}
        {:error, _} = error -> error
      end
    else
      {:error, {:log_probs_unsupported, model}}
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, @default_model)

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: true

  # The `supports_log_probs` entries of deepeval's OpenAI model registry:
  # only the models it lists with logprobs, so not reasoning models.
  @impl true
  def supports_log_probs?(opts), do: base_model(model_name(opts)) in @log_prob_models

  @impl true
  def supports_multimodal?, do: true

  # The `supports_temperature=False` entries of deepeval's OpenAI model
  # registry: reasoning models reject a `temperature`.
  @impl true
  def supports_temperature?(opts) do
    not Regex.match?(@reasoning_model_pattern, base_model(model_name(opts)))
  end

  @impl true
  def supports_json_mode?, do: true

  # Private functions

  defp base_body(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)

    max_completion_tokens =
      Keyword.get_lazy(opts, :max_completion_tokens, fn ->
        Keyword.get(opts, :max_tokens, @default_max_completion_tokens)
      end)

    body = %{
      model: model,
      messages: [%{role: "user", content: prompt}],
      max_completion_tokens: max_completion_tokens
    }

    case temperature(model, opts) do
      nil -> body
      temperature -> Map.put(body, :temperature, temperature)
    end
  end

  # Defaults to 0.0 like deepeval's GPTModel; reasoning models reject it
  # outright, so it is dropped for them whatever was configured.
  defp temperature(model, opts) do
    if supports_temperature?(model: model) do
      Keyword.get_lazy(opts, :temperature, fn ->
        Application.get_env(:deep_eval_ex, :openai_temperature, @default_temperature)
      end)
    end
  end

  defp cap_top_logprobs(model, top_logprobs) do
    case Map.fetch(@max_log_probs, base_model(model)) do
      {:ok, max} -> min(top_logprobs, max)
      :error -> top_logprobs
    end
  end

  # Gateways name models with a provider path and a region suffix, e.g.
  # "aws-bedrock-runtime/openai/gpt-6.1-sol@global"; capabilities follow
  # the underlying model, "gpt-6.1-sol".
  defp base_model(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.split("@")
    |> hd()
  end

  defp base_url(opts) do
    url =
      Keyword.get(opts, :base_url) ||
        Adapter.config(:openai_base_url) ||
        Adapter.env("OPENAI_BASE_URL") ||
        @default_base_url

    String.trim_trailing(url, "/")
  end

  # Posts a chat completion and records the token usage it reports, whether
  # or not its content can be used: the tokens were spent either way.
  defp chat_completion(body, opts) do
    with {:ok, response} <- make_request("/chat/completions", body, opts) do
      record_usage(response, opts)
      {:ok, response}
    end
  end

  defp record_usage(
         %{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}},
         opts
       )
       when is_integer(input) and is_integer(output) do
    Usage.record(Usage.new(model_name(opts), input, output))
  end

  defp record_usage(_response, _opts), do: :ok

  defp make_request(path, body, opts) do
    api_key = get_api_key(opts)
    url = base_url(opts) <> path

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    req_opts = [
      json: body,
      headers: headers,
      receive_timeout: Keyword.get(opts, :timeout, 60_000),
      retry: :transient,
      retry_delay: &retry_delay/1,
      max_retries: 3
    ]

    req_opts = Keyword.merge(req_opts, Keyword.get(opts, :req_options, []))

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp get_api_key(opts) do
    Keyword.get(opts, :api_key) ||
      Adapter.config(:openai_api_key) ||
      Adapter.env("OPENAI_API_KEY") ||
      raise "OpenAI API key not configured. Set OPENAI_API_KEY env var or :openai_api_key config."
  end

  # Req passes the retry count starting at 0. Exponential backoff: 1s, 2s, 4s
  defp retry_delay(retry_count) do
    :timer.seconds(Integer.pow(2, retry_count))
  end

  # strict: true requires closed objects with every property required.
  defp schema_to_json_schema(schema) when is_map(schema), do: StrictSchema.to_strict(schema)

  defp schema_to_json_schema(schema) when is_atom(schema) do
    StrictSchema.to_strict(schema.json_schema())
  end

  defp parse_json_response(content, _schema) do
    case Jason.decode(content) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, error} ->
        {:error, {:json_parse_error, error, content}}
    end
  end
end
