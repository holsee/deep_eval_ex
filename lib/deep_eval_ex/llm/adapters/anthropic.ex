defmodule DeepEvalEx.LLM.Adapters.Anthropic do
  @moduledoc """
  Anthropic LLM adapter for DeepEvalEx.

  Calls Anthropic's Messages API, mirroring deepeval's `AnthropicModel`
  defaults, and returns structured outputs through a forced tool call.

  ## Configuration

  Set your API key in config:

      config :deep_eval_ex,
        anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")

  Or pass it directly:

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: :anthropic,
        api_key: "sk-ant-..."
      )

  The API key is resolved from the `:api_key` option, then the
  `:anthropic_api_key` config, then the `ANTHROPIC_API_KEY` environment
  variable.

  ## Base URL

  The API base URL is resolved in this order (a trailing slash is stripped,
  and requests go to `{base_url}/v1/messages`; a base URL that already ends
  in `/v1`, as some gateways publish it, is used as is):

  1. the `:base_url` option
  2. `config :deep_eval_ex, anthropic_base_url: "..."`
  3. the `ANTHROPIC_BASE_URL` environment variable
  4. `"https://api.anthropic.com"`

  ## Options

  - `:model` - model name (default `"claude-opus-5"`, deepeval's default)
  - `:max_tokens` - response token limit; defaults to `8192`, or `4096` for
    Claude 3 models (`claude-3-opus`, `claude-3-sonnet`, `claude-3-haiku`),
    which reject anything higher, as in deepeval
  - `:temperature` - sampling temperature; falls back to the
    `:anthropic_temperature` config and is omitted when neither is set, as
    deepeval's `AnthropicModel` does. Models that reject `temperature`
    (`claude-opus-4-7` and later, `claude-sonnet-5`, `claude-fable-5`, ...)
    never get it, whatever is configured.
  - `:base_url` - API base URL, see above
  - `:api_key` - API key (overrides config and `ANTHROPIC_API_KEY`)
  - `:timeout` - receive timeout in milliseconds (default `60_000`)
  - `:req_options` - extra `Req` options merged into the request, e.g.
    `[plug: {Req.Test, DeepEvalEx.LLM.Adapters.Anthropic}]` in tests

  Models that support extended thinking are sent `thinking: %{type:
  "disabled"}`, as deepeval does when thinking is not switched on; forcing a
  tool, as `generate_with_schema/3` does, is not allowed with thinking.

  ## Structured Outputs

  `generate_with_schema/3` offers the model a single `"response"` tool whose
  `input_schema` is the JSON schema and forces it with `tool_choice`. The
  `tool_use` block's `input` is returned as a map with string keys.

  ## Usage and Cost

  The `usage.input_tokens` and `usage.output_tokens` of every response are
  recorded with `DeepEvalEx.LLM.Usage`, priced for the requested model by
  `DeepEvalEx.LLM.Pricing`.
  """

  use DeepEvalEx.LLM.Adapter

  alias DeepEvalEx.LLM.{Adapter, Usage}

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @default_model "claude-opus-5"
  @default_max_tokens 8192
  @tool_name "response"

  # Claude 3 models cap output at 4096 tokens and reject anything higher.
  @legacy_max_tokens 4096
  @legacy_max_tokens_prefixes ["claude-3-opus", "claude-3-sonnet", "claude-3-haiku"]

  # The `supports_temperature=False` entries of deepeval's
  # ANTHROPIC_MODELS_DATA, looked up by exact name as deepeval does.
  @temperature_rejecting_models MapSet.new(~w(
    claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-opus-5-5
    claude-sonnet-5 claude-fable-5 claude-fable-5-1
  ))

  # The `supports_thinking=True` entries of deepeval's ANTHROPIC_MODELS_DATA.
  @thinking_models MapSet.new(~w(
    claude-3-7-sonnet-20250219 claude-3-7-sonnet-latest
    claude-opus-4-20250514 claude-opus-4 claude-opus-4-1-20250805
    claude-sonnet-4-20250514 claude-sonnet-4
    claude-sonnet-4-5-20250929 claude-sonnet-4-5
    claude-haiku-4-5-20251001 claude-haiku-4-5
    claude-opus-4-5-20251124 claude-opus-4-5
    claude-opus-4-6-20250610 claude-opus-4-6
    claude-sonnet-4-6-20250514 claude-sonnet-4-6
    claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-sonnet-5
  ))

  @impl true
  def generate(prompt, opts \\ []) do
    with {:ok, response} <- create_message(base_body(prompt, opts), opts) do
      case text(response) do
        nil -> {:error, {:unexpected_response, response}}
        text -> {:ok, text}
      end
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts \\ []) do
    body =
      prompt
      |> base_body(opts)
      |> Map.merge(%{
        tools: [
          %{
            name: @tool_name,
            description: "Respond with output matching this schema.",
            input_schema: schema_to_json_schema(schema)
          }
        ],
        tool_choice: %{type: "tool", name: @tool_name}
      })

    with {:ok, response} <- create_message(body, opts) do
      case tool_input(response) do
        nil -> {:error, {:unexpected_response, response}}
        input -> {:ok, input}
      end
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, @default_model)

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: false

  # Private functions

  defp base_body(prompt, opts) do
    model = model_name(opts)

    %{
      model: model,
      messages: [%{role: "user", content: prompt}],
      max_tokens: Keyword.get_lazy(opts, :max_tokens, fn -> default_max_tokens(model) end)
    }
    |> put_temperature(model, opts)
    |> put_thinking(model)
  end

  defp default_max_tokens(model) do
    if String.starts_with?(model, @legacy_max_tokens_prefixes),
      do: @legacy_max_tokens,
      else: @default_max_tokens
  end

  # Only sent when configured, as in deepeval's AnthropicModel, and never to
  # models that reject it.
  defp put_temperature(body, model, opts) do
    temperature =
      Keyword.get_lazy(opts, :temperature, fn ->
        Application.get_env(:deep_eval_ex, :anthropic_temperature)
      end)

    if is_nil(temperature) or MapSet.member?(@temperature_rejecting_models, model),
      do: body,
      else: Map.put(body, :temperature, temperature)
  end

  defp put_thinking(body, model) do
    if MapSet.member?(@thinking_models, model),
      do: Map.put(body, :thinking, %{type: "disabled"}),
      else: body
  end

  # The text blocks joined, skipping thinking and other blocks; nil when there
  # are none.
  defp text(%{"content" => content}) when is_list(content) do
    case for(%{"type" => "text", "text" => text} <- content, do: text) do
      [] -> nil
      texts -> Enum.join(texts)
    end
  end

  defp text(_response), do: nil

  defp tool_input(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "tool_use", "name" => @tool_name, "input" => input} when is_map(input) -> input
      _block -> nil
    end)
  end

  defp tool_input(_response), do: nil

  defp base_url(opts) do
    url =
      Keyword.get(opts, :base_url) ||
        Adapter.config(:anthropic_base_url) ||
        Adapter.env("ANTHROPIC_BASE_URL") ||
        @default_base_url

    url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1", "")
  end

  # Posts a message and records the token usage it reports, whether or not
  # its content can be used: the tokens were spent either way.
  defp create_message(body, opts) do
    with {:ok, response} <- make_request("/v1/messages", body, opts) do
      record_usage(response, opts)
      {:ok, response}
    end
  end

  defp record_usage(
         %{"usage" => %{"input_tokens" => input, "output_tokens" => output}},
         opts
       )
       when is_integer(input) and is_integer(output) do
    Usage.record(Usage.new(model_name(opts), input, output))
  end

  defp record_usage(_response, _opts), do: :ok

  defp make_request(path, body, opts) do
    url = base_url(opts) <> path

    headers = [
      {"x-api-key", get_api_key(opts)},
      {"anthropic-version", @api_version},
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
      Adapter.config(:anthropic_api_key) ||
      Adapter.env("ANTHROPIC_API_KEY") ||
      raise "Anthropic API key not configured. " <>
              "Set ANTHROPIC_API_KEY env var or :anthropic_api_key config."
  end

  # Req passes the retry count starting at 0. Exponential backoff: 1s, 2s, 4s
  defp retry_delay(retry_count) do
    :timer.seconds(Integer.pow(2, retry_count))
  end

  defp schema_to_json_schema(schema) when is_map(schema), do: schema

  defp schema_to_json_schema(schema) when is_atom(schema) do
    schema.json_schema()
  end
end
