defmodule DeepEvalEx.LLM.Adapters.Ollama do
  @moduledoc """
  Ollama LLM adapter for DeepEvalEx, for judging with local models.

  Calls Ollama's native `/api/chat` endpoint without streaming, mirroring
  deepeval's `OllamaModel`, and returns structured outputs through Ollama's
  structured outputs (`format` set to a JSON schema). No API key is needed.

  ## Configuration

      config :deep_eval_ex,
        default_model: {:ollama, "llama3.2"}

  Or per evaluation:

      DeepEvalEx.evaluate([test_case], [metric],
        adapter: :ollama,
        model: "qwen3:8b"
      )

  The model must be pulled on the Ollama server (`ollama pull llama3.2`).

  ## Base URL

  The server URL is resolved in this order (a trailing slash is stripped,
  and requests go to `{base_url}/api/chat`):

  1. the `:base_url` option
  2. `config :deep_eval_ex, ollama_base_url: "..."`
  3. the `OLLAMA_HOST` environment variable
  4. `"http://localhost:11434"`

  As in the Ollama clients, a URL without a scheme (`"gpu-box:11434"`, the
  usual form of `OLLAMA_HOST`) is read as `http`, on port `11434` when it
  names none.

  ## Options

  - `:model` - model name; falls back to the `:ollama_model` config. There is
    no default model, as in deepeval, so one of them is required.
  - `:temperature` - sampling temperature; falls back to the
    `:ollama_temperature` config, then to `0.0`, as deepeval's `OllamaModel`
    does. Always sent in the request's `options`.
  - `:options` - map of further Ollama model options (e.g. `%{num_ctx:
    8192}`), deepeval's `generation_kwargs`. A `temperature` in it is ignored
    in favour of `:temperature`, as in deepeval.
  - `:base_url` - server URL, see above
  - `:timeout` - receive timeout in milliseconds (default `120_000`, as local
    models can be slow)
  - `:req_options` - extra `Req` options merged into the request, e.g.
    `[plug: {Req.Test, DeepEvalEx.LLM.Adapters.Ollama}]` in tests

  ## Structured Outputs

  `generate_with_schema/3` sends the JSON schema as the request's `format`,
  which constrains the model's output to it, and decodes the message content
  into a map with string keys, the same shape the other adapters return.

  ## Usage and Cost

  The `prompt_eval_count` and `eval_count` of every response are recorded as
  input and output tokens with `DeepEvalEx.LLM.Usage`. Local models cost
  nothing: deepeval's `OllamaModel` reports a cost of `0` for every call, so
  each call is recorded with a cost of `0.0` and the result's
  `:evaluation_cost` is `0.0` rather than `nil`.
  """

  use DeepEvalEx.LLM.Adapter

  alias DeepEvalEx.LLM.{Adapter, Usage}

  @default_base_url "http://localhost:11434"
  @default_port 11_434
  @default_temperature 0.0

  @impl true
  def generate(prompt, opts \\ []) do
    with {:ok, response} <- chat(base_body(prompt, opts), opts) do
      case content(response) do
        nil -> {:error, {:unexpected_response, response}}
        content -> {:ok, content}
      end
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts \\ []) do
    body =
      prompt
      |> base_body(opts)
      |> Map.put(:format, schema_to_json_schema(schema))

    with {:ok, response} <- chat(body, opts) do
      case content(response) do
        nil -> {:error, {:unexpected_response, response}}
        content -> parse_json_response(content)
      end
    end
  end

  @impl true
  def model_name(opts) do
    Keyword.get_lazy(opts, :model, fn -> Application.get_env(:deep_eval_ex, :ollama_model) end) ||
      raise ArgumentError,
            "Ollama model not configured. Pass the :model option or set :ollama_model config."
  end

  @impl true
  def supports_structured_outputs?, do: true

  # Ollama's `format: "json"`; nearly every entry of deepeval's
  # OLLAMA_MODELS_DATA has `supports_json=True`.
  @impl true
  def supports_json_mode?, do: true

  @impl true
  def supports_log_probs?, do: false

  # Private functions

  defp base_body(prompt, opts) do
    %{
      model: model_name(opts),
      messages: [%{role: "user", content: prompt}],
      stream: false,
      options: model_options(opts)
    }
  end

  # deepeval sends `{"temperature": temperature, **generation_kwargs}` after
  # dropping any temperature from the kwargs, so the temperature always wins.
  defp model_options(opts) do
    temperature =
      Keyword.get_lazy(opts, :temperature, fn ->
        Application.get_env(:deep_eval_ex, :ollama_temperature, @default_temperature)
      end)

    opts
    |> Keyword.get(:options, %{})
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("temperature", temperature)
  end

  defp content(%{"message" => %{"content" => content}}) when is_binary(content), do: content
  defp content(_response), do: nil

  defp base_url(opts) do
    (Keyword.get(opts, :base_url) ||
       Adapter.config(:ollama_base_url) ||
       Adapter.env("OLLAMA_HOST") ||
       @default_base_url)
    |> String.trim_trailing("/")
    |> normalize_host()
  end

  # A bare `host` or `host:port` (how OLLAMA_HOST is usually set) is read as
  # http on Ollama's port, as the Ollama clients read it.
  defp normalize_host(url) do
    cond do
      url =~ ~r{^[a-z][a-z0-9+.-]*://}i -> url
      url =~ ~r{:\d+(/|$)} -> "http://" <> url
      true -> "http://" <> Regex.replace(~r{^[^/]*}, url, "\\0:#{@default_port}", global: false)
    end
  end

  # Posts a chat request and records its usage, whether or not its content
  # can be used.
  defp chat(body, opts) do
    with {:ok, response} <- make_request("/api/chat", body, opts) do
      record_usage(response, body.model)
      {:ok, response}
    end
  end

  # deepeval prices every Ollama call at 0, so the cost is 0.0 even when the
  # response carries no token counts.
  defp record_usage(response, model) when is_map(response) do
    Usage.record(%Usage{
      model: model,
      input_tokens: token_count(response, "prompt_eval_count"),
      output_tokens: token_count(response, "eval_count"),
      cost: 0.0
    })
  end

  defp record_usage(_response, _model), do: :ok

  defp token_count(response, key) do
    case Map.get(response, key) do
      count when is_integer(count) -> count
      _ -> nil
    end
  end

  defp make_request(path, body, opts) do
    url = base_url(opts) <> path

    req_opts = [
      json: body,
      receive_timeout: Keyword.get(opts, :timeout, 120_000),
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

  # Req passes the retry count starting at 0. Exponential backoff: 1s, 2s, 4s
  defp retry_delay(retry_count) do
    :timer.seconds(Integer.pow(2, retry_count))
  end

  defp schema_to_json_schema(schema) when is_map(schema), do: schema

  defp schema_to_json_schema(schema) when is_atom(schema) do
    schema.json_schema()
  end

  defp parse_json_response(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, error} -> {:error, {:json_parse_error, error, content}}
    end
  end
end
