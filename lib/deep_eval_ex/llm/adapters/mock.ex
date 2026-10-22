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

  ## Fake Token Usage

  Pass `:mock_usage` (a keyword list or map with `:input_tokens` and
  `:output_tokens`) to have every call record that usage, priced for
  `"mock-model"` (unpriced unless set in the `:model_pricing` config):

      DeepEvalEx.evaluate(test_case, [metric],
        adapter: :mock,
        mock_usage: [input_tokens: 100, output_tokens: 20]
      )

  Without it calls report no usage, so results carry the evaluation model
  but `nil` token counts and cost.

  ## Scripted Mode

  `script/2` replays a judge script, the same one deepeval's scripted judge
  answers from in `scripts/parity/generate_fixtures.py`: responses keyed by
  step, then by call index. A call's step is named by the schema it asks
  for, not by its prompt (see `step_key/1`), so a script replays the same
  answers to DeepEvalEx and to deepeval even where their prompts differ:

      DeepEvalEx.LLM.Adapters.Mock.script(
        %{
          "claims" => [%{"claims" => ["Paris is in France."]}],
          "verdicts" => [%{"verdicts" => [%{"verdict" => "yes"}]}]
        },
        model: "scripted-judge"
      )

      DeepEvalEx.evaluate(test_case, [metric], adapter: :mock)

      DeepEvalEx.LLM.Adapters.Mock.scripted_prompts()
      #=> [%{step: "claims", prompt: "..."}, %{step: "verdicts", prompt: "..."}]

  A script belongs to the process that loads it and serves every process it
  starts (found through `$callers`, as with `Task`), so async tests each
  replay their own script. A step with no response left returns
  `{:error, {:no_scripted_response, step, index}}`. While a script is
  loaded, `model_name/1` is the script's `:model` and the configured
  responses above are not used.
  """

  use DeepEvalEx.LLM.Adapter

  alias DeepEvalEx.LLM.Usage

  @default_response "This is a mock response."
  @ets_table :deep_eval_ex_mock_responses

  @impl true
  def generate(prompt, opts \\ []) do
    case script_agent() do
      nil -> configured_generate(prompt, opts)
      agent -> scripted_call(agent, prompt, nil, opts)
    end
  end

  @impl true
  def generate_with_schema(prompt, schema, opts \\ []) do
    case script_agent() do
      nil -> configured_generate_with_schema(prompt, opts)
      agent -> scripted_call(agent, prompt, schema, opts)
    end
  end

  defp configured_generate(prompt, opts) do
    response =
      case get_configured_response(prompt) do
        nil -> Keyword.get(opts, :default_response, @default_response)
        response -> response
      end

    record_usage(opts)
    {:ok, response}
  end

  defp configured_generate_with_schema(prompt, opts) do
    response =
      case get_configured_schema_response(prompt) do
        nil ->
          Keyword.get(opts, :default_response, %{})

        response ->
          response
      end

    record_usage(opts)
    {:ok, response}
  end

  @impl true
  def model_name(_opts) do
    case script_agent() do
      nil -> "mock-model"
      agent -> Agent.get(agent, & &1.model)
    end
  end

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

  # Scripted mode

  @doc """
  Loads a judge script for the calling process and the processes it starts.

  `responses` maps a step (see `step_key/1`) to the responses of its
  successive calls: maps for `generate_with_schema/3`, strings for
  `generate/2` (step `"text"`). Replaces any script the process loaded
  before, along with its recorded prompts. The script is dropped when the
  process exits, or with `stop_script/0`.

  ## Options

  - `:model` - the judge model name `model_name/1` reports (default:
    `"mock-model"`)
  """
  @spec script(%{String.t() => [map() | String.t()]}, keyword()) :: :ok
  def script(responses, opts \\ []) when is_map(responses) do
    stop_script()

    state = %{
      responses: responses,
      model: Keyword.get(opts, :model, "mock-model"),
      calls: %{},
      prompts: []
    }

    owner = self()
    {:ok, agent} = Agent.start(fn -> state end, name: {:global, script_key(owner)})
    spawn(fn -> drop_script_with(owner, agent) end)
    :ok
  end

  # Stops the script's agent when its owner exits, whatever the reason; ends
  # quietly when the agent is stopped first.
  defp drop_script_with(owner, agent) do
    owner_ref = Process.monitor(owner)
    agent_ref = Process.monitor(agent)

    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> stop_agent(agent)
      {:DOWN, ^agent_ref, :process, _pid, _reason} -> :ok
    end
  end

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Drops the calling process's script, if any.
  """
  @spec stop_script() :: :ok
  def stop_script do
    case :global.whereis_name(script_key(self())) do
      :undefined -> :ok
      agent -> stop_agent(agent)
    end
  end

  @doc """
  Returns the prompts sent under the calling process's script, in call
  order, each with its step. Empty when no script is loaded.
  """
  @spec scripted_prompts() :: [%{step: String.t(), prompt: String.t()}]
  def scripted_prompts do
    case script_agent() do
      nil -> []
      agent -> agent |> Agent.get(& &1.prompts) |> Enum.reverse()
    end
  end

  @doc """
  Returns the step a call with `schema` is scripted under: the schema's
  top-level property names, sorted and joined with commas, or `"text"` for a
  call without a schema.

  deepeval's scripted judge names a pydantic schema the same way, so
  `"verdicts"` or `"reason,score"` name the same call in both.

  ## Examples

      iex> DeepEvalEx.LLM.Adapters.Mock.step_key(%{"properties" => %{"score" => %{}, "reason" => %{}}})
      "reason,score"

      iex> DeepEvalEx.LLM.Adapters.Mock.step_key(nil)
      "text"
  """
  @spec step_key(map() | module() | nil) :: String.t()
  def step_key(nil), do: "text"
  def step_key(%{"properties" => properties}), do: join_keys(properties)
  def step_key(%{properties: properties}), do: join_keys(properties)

  def step_key(schema) when is_atom(schema) do
    if Code.ensure_loaded?(schema) and function_exported?(schema, :json_schema, 0) do
      step_key(schema.json_schema())
    else
      raise ArgumentError, "cannot name the step of schema #{inspect(schema)}"
    end
  end

  defp join_keys(properties) do
    properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")
  end

  defp scripted_call(agent, prompt, schema, opts) do
    step = step_key(schema)

    reply =
      Agent.get_and_update(agent, fn state ->
        index = Map.get(state.calls, step, 0)

        reply =
          case state.responses |> Map.get(step, []) |> Enum.at(index) do
            nil -> {:error, {:no_scripted_response, step, index}}
            response -> {:ok, response}
          end

        {reply,
         %{
           state
           | calls: Map.put(state.calls, step, index + 1),
             prompts: [%{step: step, prompt: prompt} | state.prompts]
         }}
      end)

    with {:ok, _response} <- reply, do: record_usage(opts)
    reply
  end

  # The script of the calling process or of the nearest process that
  # started it.
  defp script_agent do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case :global.whereis_name(script_key(pid)) do
        :undefined -> nil
        agent -> agent
      end
    end)
  end

  defp script_key(pid), do: {__MODULE__, :script, pid}

  # Private helpers

  defp record_usage(opts) do
    case Keyword.get(opts, :mock_usage) do
      nil ->
        :ok

      usage ->
        usage = Map.new(usage)
        Usage.record(Usage.new(model_name(opts), usage[:input_tokens], usage[:output_tokens]))
    end
  end

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
