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

  ## Reporting Token Usage

  Adapters report the token usage of each call with
  `DeepEvalEx.LLM.Usage.record/1`; results then carry the tokens and cost.
  Adapters that report nothing still get their `model_name/1` recorded as the
  result's `:evaluation_model`. See `DeepEvalEx.LLM.Usage`.

  ## Using a Custom Adapter

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: MyApp.CustomLLMAdapter,
        model: "custom-model-v2"
      )
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.Utils.Generation

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

  Log probs can be used for more accurate scoring in some metrics.
  """
  @callback supports_log_probs?() :: boolean()

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

  @optional_callbacks [supports_multimodal?: 0, supports_temperature?: 1, supports_json_mode?: 0]

  # Defaults for the optional capabilities
  defmacro __using__(_opts) do
    quote do
      @behaviour DeepEvalEx.LLM.Adapter

      @impl true
      def supports_multimodal?, do: false

      @impl true
      def supports_temperature?(_opts), do: true

      @impl true
      def supports_json_mode?, do: false

      defoverridable supports_multimodal?: 0, supports_temperature?: 1, supports_json_mode?: 0
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

  defp capability(adapter, name, args, default) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, name, length(args)),
      do: apply(adapter, name, args),
      else: default
  end

  @doc """
  Reads an environment variable for adapter configuration, treating a blank
  value as unset and trimming surrounding whitespace from a set one.

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
  def env(name), do: name |> System.get_env() |> present()

  @doc """
  Reads a `:deep_eval_ex` application config value for adapter configuration,
  treating a blank string as unset and trimming surrounding whitespace from a
  set one. Non-string values are returned unchanged.

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
  def config(key), do: :deep_eval_ex |> Application.get_env(key) |> present()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value), do: value

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
    with_usage(adapter, opts, fn -> adapter.generate(prompt, opts) end)
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

    with_usage(adapter, opts, fn ->
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

  # Passes on the usage the adapter recorded. A successful call that reported
  # none still records the adapter's model, so the judge model is known even
  # when its tokens and cost are not.
  defp with_usage(adapter, opts, fun) do
    {result, usages} = Usage.track(fun)

    case {result, usages} do
      {{:ok, _}, []} -> Usage.record(%Usage{model: adapter.model_name(opts)})
      _ -> Usage.record_all(usages)
    end

    result
  end

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
