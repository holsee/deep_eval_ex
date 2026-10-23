defmodule DeepEvalEx.LLM.Adapter do
  @moduledoc """
  Behaviour for LLM adapters.

  Implement this behaviour to add support for a new LLM provider.
  DeepEvalEx uses adapters to abstract away the differences between
  LLM providers (OpenAI, Anthropic, Ollama, etc.).

  ## Implementing a Custom Adapter

      defmodule MyApp.CustomLLMAdapter do
        @behaviour DeepEvalEx.LLM.Adapter

        @impl true
        def generate(prompt, opts) do
          # Call your LLM API
          {:ok, "response text"}
        end

        @impl true
        def generate_with_schema(prompt, schema, opts) do
          # Call your LLM API with structured output
          {:ok, %{key: "value"}}
        end

        @impl true
        def model_name(opts), do: Keyword.get(opts, :model, "custom-model")

        @impl true
        def supports_structured_outputs?, do: true

        @impl true
        def supports_log_probs?, do: false
      end

  ## Judges Without Structured Outputs

  As in deepeval, a judge need not enforce the schema. `generate_with_schema/3`
  loads the text such a judge answers with deepeval's `trimAndLoadJson` (see
  `DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json/1`), and fails with
  `DeepEvalEx.LLM.InvalidJSONError` when it holds no valid JSON:

  - an adapter whose `supports_structured_outputs?/0` is `false` is asked with
    `generate/2`, and its text loaded, as deepeval's `DeepEvalBaseLLM` falls
    back to `generate` for a model that takes no schema
  - an adapter whose `generate_with_schema/3` returns a string, for instance
    from a JSON mode (`supports_json_mode?/0`), has the string loaded, as
    deepeval's `generate_with_schema_and_extract` loads any answer that is not
    a schema instance

  ## Log Probabilities

  GEval weights its score by the judge's log probabilities, as deepeval
  does, when the judge offers them: an adapter implementing
  `c:generate_raw_response/2` whose `c:supports_log_probs?/1` (or, without
  it, `c:supports_log_probs?/0`) is `true` for the model. See
  `supports_log_probs?/1`. Any other judge is asked with
  `generate_with_schema/3` and its score kept, as deepeval falls back for a
  model without `generate_raw_response`.

  ## Reporting Token Usage

  Adapters report the token usage of each call with
  `DeepEvalEx.LLM.Usage.record/1`; results then carry the tokens and cost.
  Adapters that report nothing still get their `model_name/1` recorded as the
  result's `:evaluation_model`. See `DeepEvalEx.LLM.Usage`.

  ## Native Adapters and Cost

  As in deepeval, a metric's cost is only reported for a *native* judge:
  the OpenAI, Anthropic and Ollama adapters, whose `c:native?/0` is `true`.
  A measure with a native judge starts from zero cost and token counts;
  one with a custom judge (any adapter whose `c:native?/0` is `false`, the
  default, `DeepEvalEx.LLM.Adapters.Mock` included) starts from `nil`, so
  its cost is `nil` whatever its calls report, while their token counts
  are kept. See `DeepEvalEx.LLM.Usage.seed/1`.

  ## Tracing

  Inside a trace, each call of `generate/2`, `generate_with_schema/3` and
  `generate_raw_response/2` is an `:llm` span (see `DeepEvalEx.Tracing`),
  as deepeval 4.3.1's `deepeval.openai` and `deepeval.anthropic` patchers
  record a client call. The wrapping happens once, here, so every adapter
  (a custom one or `DeepEvalEx.LLM.Adapters.Mock` included) is traced:

  - the span is named after the function, with the adapter's
    `model_name/1` as its model, the prompt as its input and the answer
    (a raw response's message text) as its output;
  - its token counts are those of the usage the adapter recorded;
  - the OpenAI and Anthropic adapters set its `integration` and
    `provider` to `"OpenAI"` or `"Anthropic"`; other adapters set none,
    so the span takes its parent's integration;
  - an `{:error, reason}` answer makes it `:errored`, with the
    exception's message or the inspected reason, as the Python clients
    raise;
  - the trace takes the prompt as its input and the answer as its output
    when it has none yet, and `DeepEvalEx.Tracing.trace/2`'s
    `:llm_span_context` gives the span its metrics, metric collection,
    prompt and test-case fields, as in deepeval.

  A call outside any span records nothing (deepeval's `_drop_if_root`),
  and neither does a metric's judge: metrics and classifiers run inside
  `DeepEvalEx.Tracing.suppress/1`. For an app's own Req-based client, see
  `DeepEvalEx.Tracing.ReqStep`.

  ## Using a Custom Adapter

      DeepEvalEx.evaluate([test_case], [metric],
        adapter: MyApp.CustomLLMAdapter,
        model: "custom-model-v2"
      )
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.Utils.Generation
  alias DeepEvalEx.Tracing.LLMSpan

  # The integration and provider of an adapter's LLM spans, deepeval's
  # `Integration` and `Provider` values.
  @providers %{
    DeepEvalEx.LLM.Adapters.OpenAI => [integration: "OpenAI", provider: "OpenAI"],
    DeepEvalEx.LLM.Adapters.Anthropic => [integration: "Anthropic", provider: "Anthropic"]
  }

  @type prompt :: String.t()
  @type schema :: module() | map()
  @type opts :: keyword()
  @type error :: {:error, term()}

  @doc """
  Generates a response from the LLM.

  ## Parameters

  - `prompt` - The prompt to send to the LLM
  - `opts` - Options including:
    - `:model` - Model name/identifier
    - `:temperature` - Sampling temperature (0.0 - 2.0)
    - `:max_tokens` - Maximum tokens in response
    - `:api_key` - API key (if not configured globally)

  ## Returns

  - `{:ok, response}` - The generated text response
  - `{:error, reason}` - Error tuple
  """
  @callback generate(prompt(), opts()) :: {:ok, String.t()} | error()

  @doc """
  Generates a structured response matching the given schema.

  Uses the LLM's native structured output capability (JSON mode,
  function calling, or tool use) to ensure the response matches
  the expected schema.

  ## Parameters

  - `prompt` - The prompt to send to the LLM
  - `schema` - A schema module (exporting json_schema/0) or JSON schema map
  - `opts` - Same options as `generate/2`

  ## Returns

  - `{:ok, struct}` - Parsed response matching the schema
  - `{:error, reason}` - Error tuple
  """
  @callback generate_with_schema(prompt(), schema(), opts()) ::
              {:ok, struct() | map()} | error()

  @doc """
  Returns the model name/identifier.
  """
  @callback model_name(opts()) :: String.t()

  @doc """
  Returns whether this adapter supports structured outputs.

  When true, `generate_with_schema/3` uses native structured output
  features. When false, `DeepEvalEx.LLM.Adapter.generate_with_schema/3`
  calls `generate/2` instead and loads the JSON from its text.
  """
  @callback supports_structured_outputs?() :: boolean()

  @doc """
  Returns whether this adapter supports log probabilities.

  Log probs can be used for more accurate scoring in some metrics. An
  adapter whose support depends on the model implements
  `c:supports_log_probs?/1` too, which takes precedence; see "Log
  Probabilities" above.
  """
  @callback supports_log_probs?() :: boolean()

  @doc """
  Returns whether the model `opts` name returns log probabilities,
  deepeval's per-model `supports_log_probs`. Takes precedence over
  `c:supports_log_probs?/0` when implemented.
  """
  @callback supports_log_probs?(opts()) :: boolean()

  @doc """
  Generates a response with the log probabilities of its tokens, deepeval's
  `generate_raw_response`: the provider's whole chat completion, decoded
  from its JSON, in OpenAI's shape:

      %{"choices" => [%{"message" => %{"content" => "..."},
                        "logprobs" => %{"content" => [%{"token" => "7",
                                                        "logprob" => -0.1,
                                                        "top_logprobs" => [...]}]}}]}

  Takes the options of `generate/2`, and `:top_logprobs`, the number of
  most likely tokens to return at each position.
  """
  @callback generate_raw_response(prompt(), opts()) :: {:ok, map()} | error()

  @doc """
  Returns whether this adapter supports multimodal inputs (images).
  """
  @callback supports_multimodal?() :: boolean()

  @doc """
  Returns whether the model `opts` name accepts a sampling temperature,
  deepeval's `supports_temperature()`. Adapters leave `:temperature` out of
  requests to models that reject it.

  Defaults to `true`, as deepeval's model data does.
  """
  @callback supports_temperature?(opts()) :: boolean()

  @doc """
  Returns whether the provider can constrain an answer to JSON without
  enforcing a schema, deepeval's `supports_json_mode()`.

  Defaults to `false`.
  """
  @callback supports_json_mode?() :: boolean()

  @doc """
  Returns whether the adapter is one of deepeval's *native* models, whose
  cost a metric reports: deepeval's `using_native_model`.

  A metric with a native judge seeds its cost and token counts with zero,
  one with a custom judge with `nil`, which voids its cost (see
  `DeepEvalEx.LLM.Usage.seed/1`). Defaults to `false`; the OpenAI,
  Anthropic and Ollama adapters return `true`. A custom adapter that
  prices its calls with `DeepEvalEx.LLM.Usage.new/3` returns `true` to
  have their cost reported.
  """
  @callback native?() :: boolean()

  @optional_callbacks [
    native?: 0,
    supports_multimodal?: 0,
    supports_temperature?: 1,
    supports_json_mode?: 0,
    supports_log_probs?: 1,
    generate_raw_response: 2
  ]

  # Defaults for the optional capabilities
  defmacro __using__(_opts) do
    quote do
      @behaviour DeepEvalEx.LLM.Adapter

      @impl true
      def native?, do: false

      @impl true
      def supports_multimodal?, do: false

      @impl true
      def supports_temperature?(_opts), do: true

      @impl true
      def supports_json_mode?, do: false

      defoverridable native?: 0,
                     supports_multimodal?: 0,
                     supports_temperature?: 1,
                     supports_json_mode?: 0
    end
  end

  @doc """
  Whether `adapter` (a module or provider atom) accepts a temperature for the
  model `opts` name: its `c:supports_temperature?/1`, or `true` when it does
  not implement it.
  """
  @spec supports_temperature?(module(), opts()) :: boolean()
  def supports_temperature?(adapter, opts \\ []) do
    capability(get_adapter(adapter), :supports_temperature?, [opts], true)
  end

  @doc """
  Whether `adapter` (a module or provider atom) has a JSON mode: its
  `c:supports_json_mode?/0`, or `false` when it does not implement it.
  """
  @spec supports_json_mode?(module()) :: boolean()
  def supports_json_mode?(adapter) do
    capability(get_adapter(adapter), :supports_json_mode?, [], false)
  end

  @doc """
  Whether the judge `opts` resolve to (`:adapter`, else the configured
  default) is native: its `c:native?/0`, or `false` when it does not
  implement it.

  ## Examples

      DeepEvalEx.LLM.Adapter.native?(adapter: :openai)
      #=> true

      DeepEvalEx.LLM.Adapter.native?(adapter: :mock)
      #=> false
  """
  @spec native?(opts()) :: boolean()
  def native?(opts) when is_list(opts) do
    {adapter, _model} = resolve_adapter(opts)
    capability(adapter, :native?, [], false)
  end

  defp capability(adapter, name, args, default) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, name, length(args)),
      do: apply(adapter, name, args),
      else: default
  end

  @doc """
  Reads an environment variable for adapter configuration, treating a blank
  value as unset and trimming surrounding whitespace from a set one. Same as
  `DeepEvalEx.Config.env/1`.

  Tooling such as dev containers often forwards unset host variables as empty
  strings; an empty `OPENAI_BASE_URL` must fall back to the default rather
  than produce an empty URL.

  ## Examples

      iex> System.put_env("DEEP_EVAL_EX_DOC_EXAMPLE", "")
      iex> DeepEvalEx.LLM.Adapter.env("DEEP_EVAL_EX_DOC_EXAMPLE")
      nil

      iex> System.put_env("DEEP_EVAL_EX_DOC_EXAMPLE", "  sk-test  ")
      iex> DeepEvalEx.LLM.Adapter.env("DEEP_EVAL_EX_DOC_EXAMPLE")
      "sk-test"
  """
  @spec env(String.t()) :: String.t() | nil
  defdelegate env(name), to: DeepEvalEx.Config

  @doc """
  Reads a `:deep_eval_ex` application config value for adapter configuration,
  treating a blank string as unset and trimming surrounding whitespace from a
  set one. Non-string values are returned unchanged. Same as
  `DeepEvalEx.Config.config/1`.

  Config such as `openai_api_key: System.get_env("OPENAI_API_KEY")` stores an
  empty string when the variable is set but empty; that must fall through to
  the next source rather than be sent as the key.

  ## Examples

      iex> Application.put_env(:deep_eval_ex, :doc_example, "  ")
      iex> DeepEvalEx.LLM.Adapter.config(:doc_example)
      nil

      iex> Application.put_env(:deep_eval_ex, :doc_example, " https://example.com/v1 ")
      iex> DeepEvalEx.LLM.Adapter.config(:doc_example)
      "https://example.com/v1"
  """
  @spec config(atom()) :: term()
  defdelegate config(key), to: DeepEvalEx.Config

  @doc """
  Gets the configured adapter module for a provider.

  ## Examples

      DeepEvalEx.LLM.Adapter.get_adapter(:openai)
      #=> DeepEvalEx.LLM.Adapters.OpenAI

      DeepEvalEx.LLM.Adapter.get_adapter(:anthropic)
      #=> DeepEvalEx.LLM.Adapters.Anthropic
  """
  @spec get_adapter(atom()) :: module()
  def get_adapter(:openai), do: DeepEvalEx.LLM.Adapters.OpenAI
  def get_adapter(:anthropic), do: DeepEvalEx.LLM.Adapters.Anthropic
  def get_adapter(:ollama), do: DeepEvalEx.LLM.Adapters.Ollama
  def get_adapter(:mock), do: DeepEvalEx.LLM.Adapters.Mock
  def get_adapter(module) when is_atom(module), do: module

  @doc """
  Gets the default adapter based on configuration.
  """
  @spec default_adapter() :: {module(), String.t()}
  def default_adapter do
    case Application.get_env(:deep_eval_ex, :default_model, {:openai, "gpt-4o-mini"}) do
      {provider, model} -> {get_adapter(provider), model}
      model when is_binary(model) -> {get_adapter(:openai), model}
    end
  end

  @doc """
  Generates a response using the default or specified adapter.

  This is a convenience function that resolves the adapter and calls generate.
  The call's `DeepEvalEx.LLM.Usage` is recorded in the caller's usage scope.

  ## Options

  - `:adapter` - Adapter module or provider atom
  - `:model` - Model name
  - All other options are passed to the adapter
  """
  @spec generate(prompt(), opts()) :: {:ok, String.t()} | error()
  def generate(prompt, opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)
    traced("generate", adapter, prompt, opts, fn -> adapter.generate(prompt, opts) end)
  end

  @doc """
  Generates a structured response using the default or specified adapter.

  A judge without structured outputs answers with text, which is loaded
  with deepeval's `trimAndLoadJson`; text holding no valid JSON is
  `{:error, %DeepEvalEx.LLM.InvalidJSONError{}}` (see "Judges Without
  Structured Outputs" above).

  Records usage like `generate/2`.
  """
  @spec generate_with_schema(prompt(), schema(), opts()) :: {:ok, map()} | error()
  def generate_with_schema(prompt, schema, opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)

    traced("generate_with_schema", adapter, prompt, opts, fn ->
      with {:ok, answer} <- ask_for_schema(adapter, prompt, schema, opts) do
        load_json(answer)
      end
    end)
  end

  defp ask_for_schema(adapter, prompt, schema, opts) do
    if adapter.supports_structured_outputs?(),
      do: adapter.generate_with_schema(prompt, schema, opts),
      else: adapter.generate(prompt, opts)
  end

  # Only text is loaded: a map was decoded by the adapter already.
  defp load_json(answer) when is_binary(answer) or is_nil(answer),
    do: Generation.trim_and_load_json(answer)

  defp load_json(answer), do: {:ok, answer}

  @doc """
  Whether the judge `opts` resolve to returns log probabilities: its adapter
  implements `c:generate_raw_response/2` and its `c:supports_log_probs?/1`
  for the model (or, without it, `c:supports_log_probs?/0`) is `true`.

  deepeval's GEval asks such a judge with `generate_raw_response` and
  weights the score by the logprobs; any other judge gets the schema call.

  ## Examples

      DeepEvalEx.LLM.Adapter.supports_log_probs?(adapter: :openai, model: "gpt-4o")
      #=> true

      DeepEvalEx.LLM.Adapter.supports_log_probs?(adapter: :anthropic)
      #=> false
  """
  @spec supports_log_probs?(opts()) :: boolean()
  def supports_log_probs?(opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)

    raw_response?(adapter) and
      capability(
        adapter,
        :supports_log_probs?,
        [opts],
        capability(adapter, :supports_log_probs?, [], false)
      )
  end

  @doc """
  Generates a response with the log probabilities of its tokens using the
  default or specified adapter (see `c:generate_raw_response/2`).

  Records usage like `generate/2`. An adapter without
  `c:generate_raw_response/2` is `{:error, {:log_probs_unsupported, model}}`.
  """
  @spec generate_raw_response(prompt(), opts()) :: {:ok, map()} | error()
  def generate_raw_response(prompt, opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)

    if raw_response?(adapter),
      do:
        traced("generate_raw_response", adapter, prompt, opts, fn ->
          adapter.generate_raw_response(prompt, opts)
        end),
      else: {:error, {:log_probs_unsupported, adapter.model_name(opts)}}
  end

  defp raw_response?(adapter),
    do: Code.ensure_loaded?(adapter) and function_exported?(adapter, :generate_raw_response, 2)

  @doc """
  Returns the name of the judge model that `generate/2` and
  `generate_with_schema/3` would call with `opts`, or `nil` when the adapter
  cannot be loaded.

  Mirrors deepeval, where an LLM metric's `evaluation_model` is its model's
  `get_model_name()`, known from initialisation whether or not a call is made.

  ## Examples

      DeepEvalEx.LLM.Adapter.model_name(adapter: :openai, model: "gpt-4o")
      #=> "gpt-4o"
  """
  @spec model_name(opts()) :: String.t() | nil
  def model_name(opts \\ []) do
    {adapter, model} = resolve_adapter(opts)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :model_name, 1) do
      adapter.model_name(Keyword.put_new(opts, :model, model))
    end
  end

  # Runs one call of `adapter` as an LLM span (see "Tracing" above) and
  # passes on the usage it recorded.
  defp traced(name, adapter, prompt, opts, fun) do
    model = adapter.model_name(opts)

    span_opts =
      [name: name, model: model, input: prompt] ++ Map.get(@providers, adapter, [])

    LLMSpan.run(span_opts, fn ->
      {result, usages} = with_usage(model, fun)
      {result, outcome(name, result, usages, prompt)}
    end)
  end

  # A successful call that reported no usage still records the adapter's
  # model, so the judge model is known even when its tokens and cost are
  # not.
  defp with_usage(model, fun) do
    {result, usages} = Usage.track(fun)

    case {result, usages} do
      {{:ok, _}, []} -> Usage.record(%Usage{model: model})
      _ -> Usage.record_all(usages)
    end

    {result, usages}
  end

  defp outcome(name, result, usages, prompt) do
    tokens = [
      input_token_count: token_sum(usages, :input_tokens),
      output_token_count: token_sum(usages, :output_tokens)
    ]

    case result do
      {:ok, answer} -> [output: span_output(name, answer), trace_input: prompt] ++ tokens
      {:error, reason} -> [error: error_text(reason)] ++ tokens
      _other -> tokens
    end
  end

  defp token_sum(usages, field) do
    case usages |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end

  # A raw response's output is its text, as the patchers' `message.content`.
  defp span_output("generate_raw_response", %{"choices" => [%{"message" => message} | _]}),
    do: Map.get(message, "content")

  defp span_output(_name, answer), do: answer

  defp error_text(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_text(reason), do: inspect(reason)

  defp resolve_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil ->
        default_adapter()

      {provider, model} when is_atom(provider) ->
        {get_adapter(provider), model}

      adapter when is_atom(adapter) ->
        model = Keyword.get(opts, :model, "default")
        {get_adapter(adapter), model}
    end
  end
end
