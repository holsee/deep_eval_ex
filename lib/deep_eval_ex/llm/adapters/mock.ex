defmodule DeepEvalEx.LLM.Adapters.Mock do
  @moduledoc """
  Mock LLM adapter for testing.

  This adapter allows you to provide pre-configured responses
  for testing without making actual API calls.

  ## Usage in Tests

      # Configure mock responses
      DeepEvalEx.LLM.Adapters.Mock.set_response("What is 2+2?", "4")

      # Or use pattern matching
      DeepEvalEx.LLM.Adapters.Mock.set_response(~r/capital.*France/, "Paris")

      # Use the mock adapter
      {:ok, result} = DeepEvalEx.evaluate(test_case, [metric],
        adapter: :mock
      )

  ## With Structured Outputs

      DeepEvalEx.LLM.Adapters.Mock.set_schema_response(
        ~r/extract claims/,
        %{"claims" => ["claim 1", "claim 2"]}
      )
  """

  use DeepEvalEx.LLM.Adapter

  @default_response "This is a mock response."
  @ets_table :deep_eval_ex_mock_responses

  @impl true
  def generate(prompt, opts \\ []) do
    response =
      case get_configured_response(prompt) do
        nil -> Keyword.get(opts, :default_response, @default_response)
        response -> response
      end

    {:ok, response}
  end

  @impl true
  def generate_with_schema(prompt, _schema, opts \\ []) do
    response =
      case get_configured_schema_response(prompt) do
        nil ->
          Keyword.get(opts, :default_response, %{})

        response ->
          response
      end

    {:ok, response}
  end

  @impl true
  def model_name(_opts), do: "mock-model"

  @impl true
  def supports_structured_outputs?, do: true

  @impl true
  def supports_log_probs?, do: false

  # Configuration API

  @doc """
  Sets a mock response for a given prompt pattern.

  ## Parameters

  - `pattern` - String (exact match) or Regex (pattern match)
  - `response` - The response to return
  """
  @spec set_response(String.t() | Regex.t(), String.t()) :: :ok
  def set_response(pattern, response) do
    ensure_table_exists()
    :ets.insert(@ets_table, {{:response, pattern}, response})
    :ok
  end

  @doc """
  Sets a mock response for structured output requests.
  """
  @spec set_schema_response(String.t() | Regex.t(), map()) :: :ok
  def set_schema_response(pattern, response) do
    ensure_table_exists()
    :ets.insert(@ets_table, {{:schema_response, pattern}, response})
    :ok
  end

  @doc """
  Clears all configured mock responses.
  """
  @spec clear_responses() :: :ok
  def clear_responses do
    ensure_table_exists()
    :ets.delete_all_objects(@ets_table)
    :ok
  end

  @doc """
  Records all prompts sent to this adapter (for assertions).
  """
  @spec get_recorded_prompts() :: [String.t()]
  def get_recorded_prompts do
    ensure_table_exists()

    @ets_table
    |> :ets.match({{:recorded_prompt, :"$1"}, :"$2"})
    |> Enum.sort_by(fn [idx, _] -> idx end)
    |> Enum.map(fn [_, prompt] -> prompt end)
  end

  @doc """
  Clears recorded prompts.
  """
  @spec clear_recorded_prompts() :: :ok
  def clear_recorded_prompts do
    ensure_table_exists()
    :ets.match_delete(@ets_table, {{:recorded_prompt, :_}, :_})
    :ok
  end

  # Private helpers

  defp ensure_table_exists do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :public, :set])

      _ref ->
        :ok
    end
  end

  defp get_configured_response(prompt) do
    record_prompt(prompt)
    ensure_table_exists()

    @ets_table
    |> :ets.match({{:response, :"$1"}, :"$2"})
    |> find_matching_response(prompt)
  end

  defp get_configured_schema_response(prompt) do
    record_prompt(prompt)
    ensure_table_exists()

    @ets_table
    |> :ets.match({{:schema_response, :"$1"}, :"$2"})
    |> find_matching_response(prompt)
  end

  defp find_matching_response(entries, prompt) do
    Enum.find_value(entries, fn
      [%Regex{} = pattern, response] ->
        if Regex.match?(pattern, prompt), do: response

      [pattern, response] when is_binary(pattern) ->
        if String.contains?(prompt, pattern), do: response

      _ ->
        nil
    end)
  end

  defp record_prompt(prompt) do
    ensure_table_exists()
    idx = :ets.info(@ets_table, :size)
    :ets.insert(@ets_table, {{:recorded_prompt, idx}, prompt})
  end
end
