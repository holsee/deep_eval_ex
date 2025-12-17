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

  ## Using a Custom Adapter

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: MyApp.CustomLLMAdapter,
        model: "custom-model-v2"
      )
  """

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
  - `schema` - An Ecto schema module or JSON schema map
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
  features. When false, it falls back to parsing JSON from the response.
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

  @optional_callbacks [supports_multimodal?: 0]

  # Default implementation for multimodal
  defmacro __using__(_opts) do
    quote do
      @behaviour DeepEvalEx.LLM.Adapter

      @impl true
      def supports_multimodal?, do: false

      defoverridable supports_multimodal?: 0
    end
  end

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

  ## Options

  - `:adapter` - Adapter module or provider atom
  - `:model` - Model name
  - All other options are passed to the adapter
  """
  @spec generate(prompt(), opts()) :: {:ok, String.t()} | error()
  def generate(prompt, opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)
    adapter.generate(prompt, opts)
  end

  @doc """
  Generates a structured response using the default or specified adapter.
  """
  @spec generate_with_schema(prompt(), schema(), opts()) :: {:ok, map()} | error()
  def generate_with_schema(prompt, schema, opts \\ []) do
    {adapter, model} = resolve_adapter(opts)
    opts = Keyword.put_new(opts, :model, model)
    adapter.generate_with_schema(prompt, schema, opts)
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
