if Code.ensure_loaded?(ReqLLM) do
  defmodule DeepEvalEx.LLM.Adapters.ReqLLM do
    @moduledoc """
    LLM adapter for the providers [ReqLLM](https://hexdocs.pm/req_llm)
    supports: Gemini, Azure, Bedrock, Groq, OpenRouter, xAI and many more,
    beyond the native OpenAI, Anthropic and Ollama adapters.

    ReqLLM is an optional dependency. Add it to your own dependencies to use
    this adapter:

        {:req_llm, "~> 1.29"}

    Without it, the adapter's calls raise an error naming the dependency.

    ## Model Specs

    The `:model` option is a ReqLLM model spec: a `"provider:model"` string
    such as `"google:gemini-2.5-flash"`, `"groq:llama-3.3-70b-versatile"`
    or `"openrouter:anthropic/claude-haiku-4.5"`, or an inline spec such as
    `%{provider: :openai, id: "my-model", base_url: "https://gateway/v1"}`
    for a model ReqLLM's catalog does not list (see ReqLLM's model specs
    guide):

        DeepEvalEx.evaluate([test_case], [metric],
          adapter: {:req_llm, "google:gemini-2.5-flash"}
        )

    `model_name/1`, the result's `evaluation_model`, is the spec string, or
    `"provider:id"` for an inline spec.

    ## Credentials and Endpoints

    ReqLLM finds each provider's API key itself, e.g. in `GOOGLE_API_KEY` or
    `config :req_llm, google_api_key: "..."`; the `:api_key` option
    overrides it. `:base_url` overrides the provider's endpoint.

    An OpenAI-compatible gateway is reachable as the `:openai` provider with
    the gateway's base URL, the key coming from `OPENAI_API_KEY`. ReqLLM
    picks the OpenAI API and parameters by the model id: it sends the
    models it recognises as Responses models (`gpt-4o`, `gpt-4.1`,
    reasoning models, ...) to the Responses API and anything else to Chat
    Completions. A gateway's own model ids (often provider-prefixed) are
    unknown to it, so name the API, `"openai_responses"` or
    `"openai_chat"`, in an inline spec:

        adapter: :req_llm,
        model: %{
          provider: :openai,
          id: "openai/gpt-6-luna",
          base_url: "https://gateway.example.com/v1",
          extra: %{wire: %{protocol: "openai_responses"}}
        }

    The Responses API adapts the request to a reasoning model (no
    `temperature`, `max_output_tokens`), which Chat Completions to an
    unknown model does not. Pass the inline spec as `:model`, not the base
    URL as an option: metrics such as `DeepEvalEx.Metrics.GEval` forward
    only the model to their judge.

    ## Options

    - `:model` - the ReqLLM model spec (required)
    - `:temperature` - sampling temperature, default `0.0` as in deepeval's
      `LiteLLMModel`; ReqLLM drops it for models that reject it
    - `:max_tokens` - response token limit; ReqLLM's per-model default when
      unset
    - `:api_key` - API key, overriding ReqLLM's key lookup
    - `:base_url` - provider base URL
    - `:timeout` - receive timeout in milliseconds (ReqLLM's
      `:receive_timeout`)
    - `:req_options` - extra `Req` options (ReqLLM's `:req_http_options`),
      e.g. `[plug: {Req.Test, MyStub}]` in tests
    - `:req_llm_options` - further ReqLLM options, e.g. `provider_options`
      or `max_retries`, merged last

    ReqLLM's `:on_unsupported` defaults to `:ignore`, so a judge's dropped
    temperature is not logged on every call.

    ## Structured Outputs

    `generate_with_schema/3` asks with ReqLLM's `generate_object/4`, which
    each provider maps to its own structured output (OpenAI's strict JSON
    schema, Anthropic's `output_format`, Gemini's `responseJsonSchema`,
    forced tool calls, ...). The schema is first made strict with
    `DeepEvalEx.LLM.StrictSchema`, as for the OpenAI adapter, so an
    optional field is answered with `null` rather than invented. The object
    comes back as a map with string keys; an answer ReqLLM returns only as
    text is loaded with deepeval's `trimAndLoadJson` by
    `DeepEvalEx.LLM.Adapter.generate_with_schema/3`.

    ## Usage and Cost

    The input and output token counts ReqLLM reports are recorded with
    `DeepEvalEx.LLM.Usage`, under the model spec. The cost is, in order:

    1. `DeepEvalEx.LLM.Pricing`'s price for the spec (`:model_pricing`
       config can price any spec), then for the bare model id, so
       `"openai:gpt-4o"` costs what the OpenAI adapter's `"gpt-4o"` does,
       as deepeval prefers a configured price to a gateway-reported one
    2. ReqLLM's own cost, when its catalog prices the model
    3. otherwise `nil`

    Like deepeval's gateway models (`LiteLLMModel`, `OpenRouterModel`), the
    adapter is native (`native?/0`), so a metric reports its cost.

    ## Retries

    ReqLLM retries failed requests itself (`max_retries`, default `3`):
    transient network errors and, since ReqLLM 1.29, HTTP 408, 429, 500,
    502, 503, 504 and 529 responses, waiting for a response's `Retry-After`
    when it has one and backing off exponentially (about 1s, 2s, 4s)
    otherwise. That includes a `429` for an exhausted quota, which
    DeepEvalEx's own adapters do not retry. Set
    `req_llm_options: [max_retries: 0]` to turn this off. Errors are
    returned as ReqLLM's exceptions, e.g.
    `{:error, %ReqLLM.Error.API.Request{status: 401}}`.
    """

    use DeepEvalEx.LLM.Adapter

    alias DeepEvalEx.LLM.{Pricing, StrictSchema, Usage}

    @default_temperature 0.0

    @impl true
    def generate(prompt, opts \\ []) do
      with {:ok, response} <- call(:generate_text, [prompt], opts) do
        {:ok, ReqLLM.Response.text(response)}
      end
    end

    @impl true
    def generate_with_schema(prompt, schema, opts \\ []) do
      with {:ok, response} <- call(:generate_object, [prompt, json_schema(schema)], opts) do
        case ReqLLM.Response.object(response) do
          object when is_map(object) -> {:ok, object}
          _none -> {:ok, ReqLLM.Response.text(response)}
        end
      end
    end

    @impl true
    def model_name(opts), do: opts |> model() |> spec()

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false

    # A native model, as deepeval's gateway models: its cost is reported.
    @impl true
    def native?, do: true

    # Private functions

    defp call(function, args, opts) do
      model = model(opts)

      with {:ok, response} <- apply(ReqLLM, function, [model | args] ++ [request_opts(opts)]) do
        record_usage(response, model)
        {:ok, response}
      end
    end

    defp model(opts) do
      Keyword.get(opts, :model) ||
        raise ArgumentError,
              "ReqLLM model spec not given. Pass the :model option, e.g. " <>
                ~s(model: "google:gemini-2.5-flash", or adapter: {:req_llm, spec}.)
    end

    defp request_opts(opts) do
      [
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        on_unsupported: :ignore
      ]
      |> put_opt(:max_tokens, opts[:max_tokens])
      |> put_opt(:api_key, opts[:api_key])
      |> put_opt(:base_url, opts[:base_url])
      |> put_opt(:receive_timeout, opts[:timeout])
      |> put_opt(:req_http_options, opts[:req_options])
      |> Keyword.merge(Keyword.get(opts, :req_llm_options, []))
    end

    defp put_opt(req_opts, _key, nil), do: req_opts
    defp put_opt(req_opts, key, value), do: Keyword.put(req_opts, key, value)

    defp json_schema(schema) when is_map(schema), do: StrictSchema.to_strict(schema)

    defp json_schema(schema) when is_atom(schema),
      do: StrictSchema.to_strict(schema.json_schema())

    # The usage of a call the provider answered, whether or not its content
    # can be used: the tokens were spent either way.
    defp record_usage(response, model) do
      usage = ReqLLM.Response.usage(response) || %{}
      input = token_count(usage, :input_tokens, :input)
      output = token_count(usage, :output_tokens, :output)

      Usage.record(%Usage{
        model: spec(model),
        input_tokens: input,
        output_tokens: output,
        cost: cost(model, input, output, usage)
      })
    end

    # ReqLLM counts an unreported side as 0 and says so in `usage_reported`.
    defp token_count(usage, key, side) do
      case usage do
        %{usage_reported: %{^side => false}} -> nil
        %{^key => count} when is_integer(count) -> count
        _usage -> nil
      end
    end

    defp cost(model, input, output, usage) do
      Pricing.cost(spec(model), input, output) ||
        Pricing.cost(model_id(model), input, output) ||
        reported_cost(usage)
    end

    defp reported_cost(%{pricing: %{status: :priced, total: total}}) when is_number(total),
      do: total / 1

    defp reported_cost(_usage), do: nil

    defp spec(model) when is_binary(model), do: model

    defp spec(model) do
      case ReqLLM.model(model) do
        {:ok, resolved} -> LLMDB.Model.spec(resolved)
        {:error, _reason} -> inspect(model)
      end
    end

    defp model_id(model) when is_binary(model) do
      case String.split(model, ":", parts: 2) do
        [_provider, id] -> id
        [id] -> id
      end
    end

    defp model_id(model) do
      case ReqLLM.model(model) do
        {:ok, resolved} -> resolved.id
        {:error, _reason} -> nil
      end
    end
  end
else
  defmodule DeepEvalEx.LLM.Adapters.ReqLLM do
    @moduledoc """
    LLM adapter for the providers [ReqLLM](https://hexdocs.pm/req_llm)
    supports.

    ReqLLM is an optional dependency and is not installed: add
    `{:req_llm, "~> 1.29"}` to your dependencies to use this adapter.
    """

    use DeepEvalEx.LLM.Adapter

    # Every call raises, by design.
    @dialyzer {:nowarn_function,
               generate: 1, generate: 2, generate_with_schema: 2, generate_with_schema: 3}

    @impl true
    def generate(_prompt, _opts \\ []), do: missing_dependency!()

    @impl true
    def generate_with_schema(_prompt, _schema, _opts \\ []), do: missing_dependency!()

    @impl true
    def model_name(opts) do
      case Keyword.get(opts, :model) do
        model when is_binary(model) -> model
        _other -> missing_dependency!()
      end
    end

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false

    @impl true
    def native?, do: true

    @spec missing_dependency!() :: no_return()
    defp missing_dependency! do
      raise RuntimeError,
            "DeepEvalEx.LLM.Adapters.ReqLLM requires the optional :req_llm dependency. " <>
              ~s(Add {:req_llm, "~> 1.29"} to your mix.exs deps and run mix deps.get.)
    end
  end
end
