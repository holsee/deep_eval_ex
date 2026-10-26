defmodule DeepEvalEx.Tracing.Trace do
  @moduledoc """
  A tree of spans from one traced run: deepeval 4.3.1's `Trace`
  (`tracing/types.py`).

  ## Fields

  - `:uuid` - The trace's id
  - `:status` - `:in_progress` (default), `:success` or `:errored`,
    deepeval's `TraceSpanStatus`
  - `:root_spans` - The top-level `DeepEvalEx.Tracing.Span`s, children
    nested
  - `:start_us`, `:end_us` - Wall-clock times in microseconds since the
    epoch
  - `:name`, `:tags`, `:metadata`, `:thread_id`, `:user_id` - Set by
    `update_current_trace`
  - `:input`, `:output` - Any term; the first root span's when not set
  - `:metrics` - Trace-level metric specs: a metric module,
    `{module, keyword}` or a metric struct
  - `:metric_collection` - A Confident AI metric collection name
  - `:test_case_id`, `:test_run_id`, `:turn_id` - Confident AI ids
  - `:retrieval_context`, `:context`, `:expected_output`,
    `:tools_called`, `:expected_tools` - The test-case parameters, as on a
    span
  - `:drop` - Whether the trace is left out of exports

  deepeval's Confident AI `confident_api_key` and `environment` and its
  OpenTelemetry marker are not ported. As on a span, the uuid, status and
  start time deepeval requires are optional here.

  ## Examples

      iex> alias DeepEvalEx.Tracing.{Span, Trace}
      iex> root = Span.new!(type: :agent, name: "support")
      iex> {:ok, trace} = Trace.new(uuid: "t1", root_spans: [root], tags: ["beta"])
      iex> {trace.status, Enum.map(trace.root_spans, & &1.name)}
      {:in_progress, ["support"]}
  """

  import Peri

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.{Fields, Span}

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          status: Span.status(),
          root_spans: [Span.t()],
          start_us: integer() | nil,
          end_us: integer() | nil,
          name: String.t() | nil,
          tags: [String.t()] | nil,
          metadata: map() | nil,
          thread_id: String.t() | nil,
          user_id: String.t() | nil,
          input: term(),
          output: term(),
          metrics: [Span.metric_spec()],
          metric_collection: String.t() | nil,
          test_case_id: String.t() | nil,
          test_run_id: String.t() | nil,
          turn_id: String.t() | nil,
          retrieval_context: [String.t()] | nil,
          context: [String.t()] | nil,
          expected_output: String.t() | nil,
          tools_called: [ToolCall.t()] | nil,
          expected_tools: [ToolCall.t()] | nil,
          drop: boolean()
        }

  # The fields of deepeval's Trace (types.py); the exports set their own order.
  defstruct [
    :uuid,
    :start_us,
    :end_us,
    :name,
    :tags,
    :metadata,
    :thread_id,
    :user_id,
    :input,
    :output,
    :metric_collection,
    :test_case_id,
    :test_run_id,
    :turn_id,
    :retrieval_context,
    :context,
    :expected_output,
    :tools_called,
    :expected_tools,
    status: :in_progress,
    root_spans: [],
    metrics: [],
    drop: false
  ]

  defschema(
    :trace_schema,
    Map.merge(
      %{
        uuid: :string,
        status: {{:enum, Fields.statuses()}, {:default, :in_progress}},
        root_spans: {{:list, {:required, {:custom, {Span, :cast_child}}}}, {:default, []}},
        start_us: :integer,
        end_us: :integer,
        name: :string,
        tags: {:list, :string},
        metadata: :map,
        thread_id: :string,
        user_id: :string,
        input: :any,
        output: :any,
        metrics: {{:list, {:required, {:custom, {Fields, :cast_metric}}}}, {:default, []}},
        metric_collection: :string,
        test_case_id: :string,
        test_run_id: :string,
        turn_id: :string,
        drop: {:boolean, {:default, false}}
      },
      Fields.test_case_params()
    )
  )

  @doc """
  Creates a trace from a keyword list or map with atom keys.

  Returns `{:error, [%Peri.Error{}]}` for an invalid field. Unknown keys
  are dropped, as pydantic's `extra="ignore"`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [Peri.Error.t()]}
  def new(attrs) do
    case attrs |> Fields.to_map() |> Fields.normalize_tool_calls() |> trace_schema() do
      {:ok, validated} -> {:ok, struct(__MODULE__, Fields.convert_tool_calls(validated))}
      {:error, _} = err -> err
    end
  end

  @doc """
  Creates a trace, raising `ArgumentError` on invalid attributes.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, trace} -> trace
      {:error, errors} -> raise ArgumentError, "Invalid trace: #{inspect(errors)}"
    end
  end
end
