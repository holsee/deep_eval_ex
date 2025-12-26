defmodule DeepEvalEx.LLM.Adapters.OpenAI do
  @moduledoc """
  OpenAI LLM adapter for DeepEvalEx.

  Supports OpenAI's chat completions API with structured outputs.

  ## Configuration

  Set your API key in config:

      config :deep_eval_ex,
        openai_api_key: System.get_env("OPENAI_API_KEY")

  Or pass it directly:

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: :openai,
        api_key: "sk-..."
      )

  ## Supported Models

  - `gpt-4o` - Latest GPT-4 Omni (recommended)
  - `gpt-4o-mini` - Smaller, faster GPT-4
  - `gpt-4-turbo` - GPT-4 Turbo
  - `gpt-3.5-turbo` - GPT-3.5 (faster, cheaper)
  """

  use DeepEvalEx.LLM.Adapter

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"
  @default_temperature 0.0
  @default_max_tokens 4096

  @impl true
  def generate(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    body = %{
      model: model,
      messages: [%{role: "user", content: prompt}],
      temperature: temperature,
      max_tokens: max_tokens
    }

    case make_request("/chat/completions", body, opts) do
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
    model = Keyword.get(opts, :model, @default_model)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    json_schema = schema_to_json_schema(schema)

    body = %{
      model: model,
      messages: [%{role: "user", content: prompt}],
      temperature: temperature,
      max_tokens: max_tokens,
      response_format: %{
        type: "json_schema",
        json_schema: %{
          name: "response",
          strict: true,
          schema: json_schema
        }
      }
    }

    case make_request("/chat/completions", body, opts) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        parse_json_response(content, schema)

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def model_name(opts), do: Keyword.get(opts, :model, @default_model)

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: true

  @impl true
  def supports_multimodal?, do: true

  # Private functions

  defp make_request(path, body, opts) do
    api_key = get_api_key(opts)
    url = "#{@base_url}#{path}"

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
      Application.get_env(:deep_eval_ex, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY") ||
      raise "OpenAI API key not configured. Set OPENAI_API_KEY env var or :openai_api_key config."
  end

  defp retry_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s
    :timer.seconds(round(:math.pow(2, attempt - 1)))
  end

  defp schema_to_json_schema(schema) when is_map(schema), do: schema

  defp schema_to_json_schema(schema) when is_atom(schema) do
    # Convert Ecto schema to JSON schema
    if function_exported?(schema, :__schema__, 1) do
      ecto_schema_to_json_schema(schema)
    else
      # Assume it's already a map module with a schema function
      schema.json_schema()
    end
  end

  defp ecto_schema_to_json_schema(schema) do
    fields = schema.__schema__(:fields)
    types = schema.__schema__(:types)

    properties =
      fields
      |> Enum.map(fn field ->
        type = Map.get(types, field)
        {Atom.to_string(field), ecto_type_to_json_type(type)}
      end)
      |> Map.new()

    required =
      fields
      |> Enum.map(&Atom.to_string/1)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp ecto_type_to_json_type(:string), do: %{"type" => "string"}
  defp ecto_type_to_json_type(:integer), do: %{"type" => "integer"}
  defp ecto_type_to_json_type(:float), do: %{"type" => "number"}
  defp ecto_type_to_json_type(:boolean), do: %{"type" => "boolean"}

  defp ecto_type_to_json_type({:array, inner}),
    do: %{"type" => "array", "items" => ecto_type_to_json_type(inner)}

  defp ecto_type_to_json_type(:map), do: %{"type" => "object"}
  defp ecto_type_to_json_type(_), do: %{"type" => "string"}

  defp parse_json_response(content, _schema) do
    case Jason.decode(content) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, error} ->
        {:error, {:json_parse_error, error, content}}
    end
  end
end
