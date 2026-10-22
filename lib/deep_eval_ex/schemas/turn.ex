defmodule DeepEvalEx.Turn do
  @moduledoc """
  One turn of a conversation, deepeval 4.3.1's `Turn`
  (`test_case/conversational_test_case.py`).

  A `DeepEvalEx.ConversationalTestCase` holds a list of turns, alternating
  between the user and the assistant (the chatbot under test).

  ## Fields

  - `:role` - `:user` or `:assistant` (required)
  - `:content` - What was said (required)
  - `:user_id` - Which user spoke, for conversations with several
  - `:audio` - The turn's audio, deepeval's `Audio`, kept as plain data (a
    map, e.g. `%{"url" => ..., "mimeType" => ...}`): DeepEvalEx neither
    loads nor transcribes it. A turn with audio makes its test case `:voice`
  - `:latency_ms` - How long the turn took to start, in milliseconds (float)
  - `:interrupted` - Whether the turn was cut short (boolean)
  - `:provider_transcript` - The voice provider's own transcript of the turn
  - `:retrieval_context` - Context retrieved for the turn: strings or
    `DeepEvalEx.Schemas.RetrievedContextData` structs, in any mix
  - `:tools_called` - Tool calls made in the turn
    (`DeepEvalEx.Schemas.ToolCall`)
  - `:metadata` - A map of metadata

  deepeval's MCP fields (`mcp_tools_called`, `mcp_resources_called`,
  `mcp_prompts_called`) are not ported, as for `DeepEvalEx.TestCase`;
  `model_dump_for_prompt/1` still writes them as `null`, as deepeval does
  when they are unset.

  ## deepeval keys

  `new/1` accepts the keys deepeval's `Turn` validates, as atoms or strings:
  each field name and deepeval's aliases `userId`, `latencyMs`,
  `providerTranscript`, `retrievalContext`, `toolsCalled`,
  `additionalMetadata` and `additional_metadata`. When several keys name one
  field, the one deepeval lists first wins (the camelCase alias, or
  `metadata`). Any other key is dropped, as deepeval's `extra="ignore"`.

  ## Examples

      iex> {:ok, turn} = DeepEvalEx.Turn.new(%{"role" => "user", "content" => "Hi", "latencyMs" => 80})
      iex> {turn.role, turn.content, turn.latency_ms}
      {:user, "Hi", 80.0}
  """

  import Peri

  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias Jason.OrderedObject

  @type role :: :user | :assistant

  @type t :: %__MODULE__{
          role: role(),
          content: String.t(),
          user_id: String.t() | nil,
          audio: map() | nil,
          latency_ms: float() | nil,
          interrupted: boolean() | nil,
          provider_transcript: String.t() | nil,
          retrieval_context: [String.t() | RetrievedContextData.t()] | nil,
          tools_called: [ToolCall.t()] | nil,
          metadata: map() | nil
        }

  @enforce_keys [:role, :content]
  defstruct [
    :role,
    :content,
    :user_id,
    :audio,
    :latency_ms,
    :interrupted,
    :provider_transcript,
    :retrieval_context,
    :tools_called,
    :metadata
  ]

  @roles %{"user" => :user, "assistant" => :assistant}

  # deepeval 4.3.1's Turn validation aliases, in its order of precedence.
  # Keys not listed here are dropped, as deepeval's extra="ignore".
  @key_aliases [
    role: ["role"],
    content: ["content"],
    user_id: ["userId", "user_id"],
    audio: ["audio"],
    latency_ms: ["latencyMs", "latency_ms"],
    interrupted: ["interrupted"],
    provider_transcript: ["providerTranscript", "provider_transcript"],
    retrieval_context: ["retrievalContext", "retrieval_context"],
    tools_called: ["toolsCalled", "tools_called"],
    metadata: ["metadata", "additionalMetadata", "additional_metadata"]
  ]

  defschema(:turn_schema, %{
    role: {:required, {:custom, {__MODULE__, :cast_role}}},
    content: {:required, :string},
    user_id: :string,
    audio: :map,
    latency_ms: :float,
    interrupted: :boolean,
    provider_transcript: :string,
    retrieval_context: {:list, {:custom, {RetrievedContextData, :cast_item}}},
    tools_called: {:list, ToolCall.schema()},
    metadata: :map
  })

  @doc """
  Builds a turn from a keyword list or a map (see "deepeval keys" above).

  `:role` may be an atom or a string. An integer `:latency_ms` is cast to a
  float, as pydantic does. Tool calls may be `DeepEvalEx.Schemas.ToolCall`
  structs or maps, and retrieval context items maps with `context` and
  `source` keys, which are built into `RetrievedContextData`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    case attrs |> normalize_attrs() |> turn_schema() do
      {:ok, validated} -> {:ok, struct(__MODULE__, convert_tool_calls(validated))}
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds a turn, raising on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, turn} -> turn
      {:error, errors} -> raise "Invalid turn: #{inspect(errors)}"
    end
  end

  @doc """
  The turn as data for an LLM prompt, deepeval's `model_dump_for_prompt()`:
  `model_dump()` without `audio` and `provider_transcript`.

  Returns a `Jason.OrderedObject` with deepeval's field names in its order,
  unset fields as `nil` and the unported MCP fields as `nil`. A
  `RetrievedContextData` dumps as its `"source: context"` string (its
  `model_serializer`) and a tool call as `ToolCall.model_dump()`, its type
  as `"FUNCTION"` or `"MCP"`.

  ## Examples

      iex> turn = DeepEvalEx.Turn.new!(role: :user, content: "Hi")
      iex> dump = DeepEvalEx.Turn.model_dump_for_prompt(turn)
      iex> {dump["role"], dump["content"], dump["latency_ms"]}
      {"user", "Hi", nil}
  """
  @spec model_dump_for_prompt(t()) :: OrderedObject.t()
  def model_dump_for_prompt(%__MODULE__{} = turn) do
    OrderedObject.new([
      {"role", Atom.to_string(turn.role)},
      {"content", turn.content},
      {"user_id", turn.user_id},
      {"latency_ms", turn.latency_ms},
      {"interrupted", turn.interrupted},
      {"retrieval_context", dump_retrieval_context(turn.retrieval_context)},
      {"tools_called", dump_tools_called(turn.tools_called)},
      {"mcp_tools_called", nil},
      {"mcp_resources_called", nil},
      {"mcp_prompts_called", nil},
      {"metadata", turn.metadata}
    ])
  end

  @doc false
  # Peri custom validator for a turn's role: :user or :assistant, as an atom
  # or string (deepeval's Literal["user", "assistant"]).
  @spec cast_role(term()) :: {:ok, role()} | {:error, String.t(), keyword()}
  def cast_role(role) when role in [:user, :assistant], do: {:ok, role}

  def cast_role(role) when is_binary(role) and is_map_key(@roles, role),
    do: {:ok, Map.fetch!(@roles, role)}

  def cast_role(role),
    do: {:error, "must be 'user' or 'assistant', got %{role}", [role: inspect(role)]}

  @doc false
  # Peri custom validator for one item of a conversational test case's
  # turns: a Turn, or a map or keyword list that builds one. The messages
  # are deepeval's validate_input TypeErrors.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t(), keyword()}
  def cast(%__MODULE__{} = turn), do: {:ok, turn}

  def cast(attrs) when (is_map(attrs) and not is_struct(attrs)) or is_list(attrs) do
    case new(attrs) do
      {:ok, turn} ->
        {:ok, turn}

      {:error, errors} ->
        {:error, "Invalid dict for Turn: %{turn} (%{errors})",
         [turn: inspect(attrs), errors: inspect(errors)]}
    end
  end

  def cast(other) do
    {:error, "'turns' must be a list of Turn or dict, got %{type}", [type: inspect(other)]}
  end

  defp dump_retrieval_context(nil), do: nil
  defp dump_retrieval_context(items), do: Enum.map(items, &dump_context_item/1)

  defp dump_context_item(%RetrievedContextData{} = data), do: to_string(data)
  defp dump_context_item(text), do: text

  defp dump_tools_called(nil), do: nil
  defp dump_tools_called(tools), do: Enum.map(tools, &dump_tool_call/1)

  # ToolCall.model_dump(), in deepeval's field order
  defp dump_tool_call(%ToolCall{} = tool_call) do
    OrderedObject.new([
      {"name", tool_call.name},
      {"type", tool_call.type |> Atom.to_string() |> String.upcase()},
      {"description", tool_call.description},
      {"reasoning", tool_call.reasoning},
      {"output", tool_call.output},
      {"input_parameters", tool_call.input_parameters}
    ])
  end

  # Maps deepeval's keys (atoms or strings, field names or aliases) to
  # fields, dropping the rest
  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {key_string(k), v} end)

    @key_aliases
    |> Enum.flat_map(fn {field, aliases} ->
      case Enum.find(aliases, &Map.has_key?(attrs, &1)) do
        nil -> []
        key -> [{field, Map.fetch!(attrs, key)}]
      end
    end)
    |> Map.new()
    |> normalize_tool_calls()
    |> normalize_latency()
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key

  defp normalize_tool_calls(%{tools_called: tools} = attrs) when is_list(tools) do
    %{attrs | tools_called: Enum.map(tools, &normalize_tool_call/1)}
  end

  defp normalize_tool_calls(attrs), do: attrs

  defp normalize_tool_call(tool) when is_map(tool) or is_list(tool), do: ToolCall.normalize(tool)
  defp normalize_tool_call(tool), do: tool

  # pydantic accepts an int for a float field; so does new/1
  defp normalize_latency(%{latency_ms: latency} = attrs) when is_integer(latency),
    do: %{attrs | latency_ms: latency / 1}

  defp normalize_latency(attrs), do: attrs

  defp convert_tool_calls(%{tools_called: tools} = validated) when is_list(tools),
    do: %{validated | tools_called: Enum.map(tools, &struct(ToolCall, &1))}

  defp convert_tool_calls(validated), do: validated
end
