defmodule DeepEvalEx.Tracing.Span do
  @moduledoc """
  One step of a traced call: deepeval 4.3.1's `BaseSpan` and its subtypes
  `AgentSpan`, `LlmSpan`, `RetrieverSpan` and `ToolSpan`
  (`tracing/types.py`), as one struct with a `:type` (ADR-0011).

  `type/1` replaces deepeval's `isinstance` checks. Each type has its own
  Peri schema: `new/1` rejects a field that belongs to another type (a
  `:model` on an `:agent` span) and requires `:name` on `:agent` and
  `:tool` spans, as `AgentSpan` and `ToolSpan` do.

  ## Fields

  Every type (deepeval's `BaseSpan`), in its declaration order:

  - `:uuid`, `:trace_uuid`, `:parent_uuid` - The span, its trace and its
    parent span (`nil` for a root)
  - `:name` - The span's name; a traced function's name by default
  - `:input`, `:output` - Any term. A traced function's default input is a
    `Jason.OrderedObject` of its arguments with string keys, in order
  - `:error` - The error text of an `:errored` span
  - `:metadata` - A map
  - `:integration` - The integration that opened the span
  - `:retrieval_context`, `:context` - Lists of strings
  - `:expected_output` - A string
  - `:tools_called`, `:expected_tools` - `DeepEvalEx.Schemas.ToolCall`s;
    maps are built into structs
  - `:llm_test_case` - A `DeepEvalEx.TestCase` set on the span
  - `:metric_collection` - A Confident AI metric collection name
  - `:type` - `:base` (default), `:agent`, `:llm`, `:retriever` or `:tool`
  - `:status` - `:in_progress` (default), `:success` or `:errored`,
    deepeval's `TraceSpanStatus`
  - `:metrics` - Metric specs to run on the span: a metric module,
    `{module, keyword}` or a metric struct. Results are kept by the
    evaluator, not on the span
  - `:children` - Child spans, in start order
  - `:drop` - Whether the span is left out of exports
  - `:start_us`, `:end_us` - Wall-clock times in microseconds since the
    epoch, exported with `DeepEvalEx.Tracing.Time.to_zod_iso/2`
  - `:seq` - Start order among the trace's spans

  `:agent` spans (`AgentSpan`): `:available_tools` and `:agent_handoffs`,
  lists of strings defaulting to `[]`.

  `:llm` spans (`LlmSpan`): `:model`, `:provider`, `:prompt` (a map with
  the prompt's alias, version, label and hash), `:prompt_alias`,
  `:prompt_version`, `:prompt_label`, `:prompt_commit_hash`, the floats
  `:input_token_count`, `:output_token_count`, `:cost_per_input_token`
  and `:cost_per_output_token` (an integer is cast to a float, as
  pydantic's `float` fields, so `42` exports as `42.0`), and
  `:token_intervals`, a map of microsecond epoch times to the text
  streamed at each.

  `:retriever` spans (`RetrieverSpan`): `:embedder`, and the integers
  `:top_k` and `:chunk_size`.

  `:tool` spans (`ToolSpan`): `:description`.

  ## Divergences

  - deepeval's `AgentSpan(model=...)` ignores the extra field; `new/1`
    rejects it, unless it is left at its default (`nil` or `[]`), so a
    span's `Map.from_struct/1` builds it again.
  - Span and trace uuids, statuses and start times are required by deepeval's
    pydantic models but optional here: the tracing store fills them in.
  - `:token_intervals` keys are epoch microseconds, not `perf_counter`
    floats.

  ## Examples

      iex> alias DeepEvalEx.Tracing.Span
      iex> {:ok, span} = Span.new(type: :retriever, name: "retrieve", top_k: 2)
      iex> {Span.type(span), span.status, span.top_k}
      {:retriever, :in_progress, 2}
      iex> {:error, [error]} = Span.new(type: :tool, name: "search", model: "gpt-4o")
      iex> error.message
      "is not a field of a :tool span"
  """

  import Peri

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.Fields

  @types [:base, :agent, :llm, :retriever, :tool]

  @typedoc "The span type, deepeval's `SpanApiType`."
  @type type :: :base | :agent | :llm | :retriever | :tool

  @typedoc "deepeval's `TraceSpanStatus`."
  @type status :: :in_progress | :success | :errored

  @typedoc "A metric to run on a span or trace: a module, a module with options, or a struct."
  @type metric_spec :: module() | {module(), keyword()} | struct()

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          trace_uuid: String.t() | nil,
          parent_uuid: String.t() | nil,
          name: String.t() | nil,
          input: term(),
          output: term(),
          error: String.t() | nil,
          metadata: map() | nil,
          integration: String.t() | nil,
          retrieval_context: [String.t()] | nil,
          context: [String.t()] | nil,
          expected_output: String.t() | nil,
          tools_called: [ToolCall.t()] | nil,
          expected_tools: [ToolCall.t()] | nil,
          llm_test_case: TestCase.t() | nil,
          metric_collection: String.t() | nil,
          type: type(),
          status: status(),
          metrics: [metric_spec()],
          children: [t()],
          drop: boolean(),
          start_us: integer() | nil,
          end_us: integer() | nil,
          seq: integer() | nil,
          available_tools: [String.t()],
          agent_handoffs: [String.t()],
          model: String.t() | nil,
          provider: String.t() | nil,
          prompt: map() | nil,
          prompt_alias: String.t() | nil,
          prompt_version: String.t() | nil,
          prompt_label: String.t() | nil,
          prompt_commit_hash: String.t() | nil,
          input_token_count: float() | nil,
          output_token_count: float() | nil,
          cost_per_input_token: float() | nil,
          cost_per_output_token: float() | nil,
          token_intervals: %{optional(integer()) => String.t()} | nil,
          embedder: String.t() | nil,
          top_k: integer() | nil,
          chunk_size: integer() | nil,
          description: String.t() | nil
        }

  # One struct for the five deepeval span classes (ADR-0011 decision 15)
  # carries all their fields, so it is larger than credo's 31-field limit.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    # BaseSpan (types.py), declaration order kept for the exports' key order
    :uuid,
    :trace_uuid,
    :parent_uuid,
    :name,
    :input,
    :output,
    :error,
    :metadata,
    :integration,
    :retrieval_context,
    :context,
    :expected_output,
    :tools_called,
    :expected_tools,
    :llm_test_case,
    :metric_collection,
    type: :base,
    status: :in_progress,
    metrics: [],
    children: [],
    drop: false,
    # timing: wall clock for export, seq = start order
    start_us: nil,
    end_us: nil,
    seq: nil,
    # AgentSpan
    available_tools: [],
    agent_handoffs: [],
    # LlmSpan
    model: nil,
    provider: nil,
    prompt: nil,
    prompt_alias: nil,
    prompt_version: nil,
    prompt_label: nil,
    prompt_commit_hash: nil,
    input_token_count: nil,
    output_token_count: nil,
    cost_per_input_token: nil,
    cost_per_output_token: nil,
    token_intervals: nil,
    # RetrieverSpan
    embedder: nil,
    top_k: nil,
    chunk_size: nil,
    # ToolSpan
    description: nil
  ]

  @base_schema Map.merge(
                 %{
                   uuid: :string,
                   trace_uuid: :string,
                   parent_uuid: :string,
                   name: :string,
                   input: :any,
                   output: :any,
                   error: :string,
                   metadata: :map,
                   integration: :string,
                   llm_test_case: {:custom, {__MODULE__, :cast_test_case}},
                   metric_collection: :string,
                   type: {{:enum, @types}, {:default, :base}},
                   status: {{:enum, Fields.statuses()}, {:default, :in_progress}},
                   metrics:
                     {{:list, {:required, {:custom, {Fields, :cast_metric}}}}, {:default, []}},
                   children:
                     {{:list, {:required, {:custom, {__MODULE__, :cast_child}}}}, {:default, []}},
                   drop: {:boolean, {:default, false}},
                   start_us: :integer,
                   end_us: :integer,
                   seq: :integer
                 },
                 Fields.test_case_params()
               )

  @type_schemas %{
    base: %{},
    agent: %{
      name: {:required, :string},
      available_tools: {{:list, :string}, {:default, []}},
      agent_handoffs: {{:list, :string}, {:default, []}}
    },
    llm: %{
      model: :string,
      provider: :string,
      prompt: :map,
      prompt_alias: :string,
      prompt_version: :string,
      prompt_label: :string,
      prompt_commit_hash: :string,
      input_token_count: :float,
      output_token_count: :float,
      cost_per_input_token: :float,
      cost_per_output_token: :float,
      token_intervals: {:map, :integer, :string}
    },
    retriever: %{embedder: :string, top_k: :integer, chunk_size: :integer},
    tool: %{name: {:required, :string}, description: :string}
  }

  @float_fields [
    :input_token_count,
    :output_token_count,
    :cost_per_input_token,
    :cost_per_output_token
  ]

  # Every type-specific field, with the type it belongs to.
  @typed_fields for {type, schema} <- @type_schemas,
                    field <- Map.keys(schema),
                    field != :name,
                    into: %{},
                    do: {field, type}

  # The struct defaults of the type-specific fields that are not nil.
  @typed_defaults %{available_tools: [], agent_handoffs: []}

  defschema(:base_span_schema, Map.merge(@base_schema, @type_schemas.base))
  defschema(:agent_span_schema, Map.merge(@base_schema, @type_schemas.agent))
  defschema(:llm_span_schema, Map.merge(@base_schema, @type_schemas.llm))
  defschema(:retriever_span_schema, Map.merge(@base_schema, @type_schemas.retriever))
  defschema(:tool_span_schema, Map.merge(@base_schema, @type_schemas.tool))

  @doc "The span types, in deepeval's `SpanApiType` order."
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  Creates a span from a keyword list or map with atom keys.

  `:type` picks the schema, `:base` by default. Returns
  `{:error, [%Peri.Error{}]}` for an invalid field, a missing `:name` on an
  `:agent` or `:tool` span, or a field set on a span of another type.
  Unknown keys are dropped, as pydantic's `extra="ignore"`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Peri.Error.t()]}
  def new(attrs) do
    attrs = Fields.to_map(attrs)
    type = Map.get(attrs, :type) || :base

    with :ok <- check_type(type),
         :ok <- check_foreign_fields(type, attrs),
         {:ok, validated} <- validate_type(type, normalize(attrs)) do
      {:ok, struct(__MODULE__, Fields.convert_tool_calls(validated))}
    end
  end

  @doc """
  Creates a span, raising `ArgumentError` on invalid attributes.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, span} -> span
      {:error, errors} -> raise ArgumentError, "Invalid span: #{inspect(errors)}"
    end
  end

  @doc """
  Returns the span's type, deepeval's `isinstance(span, AgentSpan)` and
  friends.
  """
  @spec type(t()) :: type()
  def type(%__MODULE__{type: type}), do: type

  @doc """
  Returns a status as deepeval's `TraceSpanStatus` value: `"SUCCESS"`,
  `"ERRORED"` or `"IN_PROGRESS"`.
  """
  @spec status_value(status()) :: String.t()
  defdelegate status_value(status), to: Fields

  @doc """
  Returns a span type as deepeval's `SpanApiType` value: `"base"`,
  `"agent"`, `"llm"`, `"retriever"` or `"tool"`.
  """
  @spec type_value(type()) :: String.t()
  def type_value(type) when type in @types, do: Atom.to_string(type)

  @doc false
  def cast_child(%__MODULE__{}), do: :ok
  def cast_child(child), do: {:error, "expected a span, got %{value}", [value: inspect(child)]}

  @doc false
  def cast_test_case(%TestCase{}), do: :ok

  def cast_test_case(test_case),
    do: {:error, "expected a DeepEvalEx.TestCase, got %{value}", [value: inspect(test_case)]}

  defp check_type(type) when type in @types, do: :ok

  defp check_type(type) do
    {:error,
     [
       %Peri.Error{
         path: [:type],
         key: :type,
         content: %{value: type, expected: @types},
         message: "expected one of #{inspect(@types)}, got #{inspect(type)}"
       }
     ]}
  end

  # A field of another type is an error unless it holds the struct default,
  # so a span's own `Map.from_struct/1` passes.
  defp check_foreign_fields(type, attrs) do
    attrs
    |> Enum.filter(fn {key, value} ->
      case Map.fetch(@typed_fields, key) do
        {:ok, ^type} -> false
        {:ok, _other} -> value != Map.get(@typed_defaults, key)
        :error -> false
      end
    end)
    |> Enum.sort()
    |> case do
      [] -> :ok
      foreign -> {:error, Enum.map(foreign, fn {key, _} -> foreign_error(type, key) end)}
    end
  end

  defp foreign_error(type, key) do
    article = if type == :agent, do: "an", else: "a"

    %Peri.Error{
      path: [key],
      key: key,
      content: %{type: type, field_type: Map.fetch!(@typed_fields, key)},
      message: "is not a field of #{article} #{inspect(type)} span"
    }
  end

  defp normalize(attrs) do
    attrs
    |> Fields.to_floats(@float_fields)
    |> Fields.normalize_tool_calls()
  end

  defp validate_type(:base, attrs), do: base_span_schema(attrs)
  defp validate_type(:agent, attrs), do: agent_span_schema(attrs)
  defp validate_type(:llm, attrs), do: llm_span_schema(attrs)
  defp validate_type(:retriever, attrs), do: retriever_span_schema(attrs)
  defp validate_type(:tool, attrs), do: tool_span_schema(attrs)
end
