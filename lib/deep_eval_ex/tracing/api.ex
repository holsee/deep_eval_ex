defmodule DeepEvalEx.Tracing.Api do
  @moduledoc """
  Exports a trace as deepeval 4.3.1's `TraceApi` (`tracing/api.py`): the
  body deepeval posts for a trace, and the `trace` of a test case in a
  `test_run_<timestamp>.json`.

  `trace_api/2` ports `TraceManager.create_trace_api` and
  `_convert_span_to_api_span` (`tracing/tracing.py`), the export of a trace
  closed outside evaluation:

      {_answer, [trace]} = DeepEvalEx.Tracing.capture([], fn -> MyApp.Support.answer("hi") end)

      trace
      |> DeepEvalEx.Tracing.Api.trace_api()
      |> DeepEvalEx.TestRun.JSON.encode!(indent: 2)

  `eval_trace_api/2` ports `evaluate/utils.create_api_trace`, the trace of
  an evaluated test case, whose buckets the evaluation walker fills with
  `span_api/2` and `add_span/2`, and whose metric data it sets with
  `put_metrics_data/2`.

  ## Shape

  Both return a `Jason.OrderedObject` with deepeval's camelCase keys in
  the declaration order of its pydantic models, leaving out `nil` values,
  as `model_dump(by_alias=True, exclude_none=True)`. Encode it with
  `DeepEvalEx.TestRun.JSON.encode!/1` for deepeval's exact bytes.

  - Spans are bucketed by type into `baseSpans`, `agentSpans`, `llmSpans`,
    `retrieverSpans` and `toolSpans`, in the order deepeval pops them off
    its `span_stack`: the last root first, then each span's children last
    first.
  - A dropped span (`DeepEvalEx.Tracing.drop_current_span/0`) is left out
    and its children get its parent.
  - Span and trace times are UTC ISO 8601, truncated to milliseconds, and
    an LLM span's `tokenIntervals` keys to microseconds
    (`DeepEvalEx.Tracing.Time.to_zod_iso/2`). A span or trace without a
    start or end time gets the current time, as deepeval does.
  - A span's `input`, `output`, `metadata` and the like go through
    `DeepEvalEx.Tracing.JSON.make_serializable/1`.
  - An LLM span's `promptAlias`, `promptVersion`, `promptLabel` and
    `promptCommitHash` come from its `:prompt`, overridden by its own
    `:prompt_*` fields when they are set.
  - `trace_api/2` normalises LLM providers as deepeval's
    `normalize_trace_api_span_providers`: `"openai"` becomes `"OpenAI"`,
    `"anthropic/claude-3"` `"Anthropic"`; an unknown one is kept, trimmed.
    `span_api/2` keeps the raw provider, as the evaluation walker does.
  - A span with metrics gets `metricsData`, deepeval's
    `create_metric_data` of each metric. Outside evaluation the metrics
    have not run: each row has the metric's name, threshold and strict
    mode, `success: false` and the judge model it is configured with, as
    deepeval exports an unmeasured metric.
  - The trace's `metricsData` (`put_metrics_data/2`) leaves out an
    expectation evaluator's row, as deepeval's `ApiMetricsData`.

  ## Divergences

  - `tokenIntervals` keys are written in time order: Elixir maps do not
    keep insertion order.
  - deepeval's MLLM `attachments` are not ported, and `infer_provider_from_model`
    is not called: `create_trace_api` never calls it either (only
    deepeval's framework integrations do).
  """

  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.MetricData
  alias DeepEvalEx.Tracing.{Fields, JSON, Span, Time, Trace}
  alias Jason.OrderedObject

  @buckets [
    base: "baseSpans",
    agent: "agentSpans",
    llm: "llmSpans",
    retriever: "retrieverSpans",
    tool: "toolSpans"
  ]

  # TraceApi's keys, in declaration order.
  @trace_keys ~w(uuid baseSpans agentSpans llmSpans retrieverSpans toolSpans startTime endTime
                 name metadata tags environment threadId userId input output status testCaseId
                 testRunId turnId retrievalContext context expectedOutput toolsCalled
                 expectedTools metricCollection metricsData)

  # deepeval's Provider enum: {name, value}, in declaration order.
  @providers [
    {"OPEN_AI", "OpenAI"},
    {"ANTHROPIC", "Anthropic"},
    {"GEMINI", "Gemini"},
    {"X_AI", "XAI"},
    {"DEEP_SEEK", "DeepSeek"},
    {"MISTRAL", "Mistral"},
    {"PERPLEXITY", "Perplexity"},
    {"BEDROCK", "Bedrock"},
    {"VERTEX_AI", "VertexAI"},
    {"AZURE", "Azure"},
    {"OPEN_ROUTER", "OpenRouter"},
    {"PORTKEY", "Portkey"},
    {"TRUE_FOUNDRY", "TrueFoundry"},
    {"MOONSHOT", "Moonshot"}
  ]

  @typedoc "Measured metric data per span uuid (see `trace_api/2`)."
  @type metrics_data :: %{optional(String.t()) => [MetricData.t()]}

  @doc """
  Exports a trace closed outside evaluation, as deepeval's
  `create_trace_api` (see the moduledoc).

  ## Options

  - `:metrics_data` - Measured metric data per span uuid, written as the
    span's `metricsData` in place of its metrics' unmeasured rows
    (default: `%{}`)
  - `:environment` - The trace's `environment` (default:
    `"development"`, deepeval's default `CONFIDENT_TRACE_ENVIRONMENT`)

  ## Examples

      iex> alias DeepEvalEx.Tracing.{Api, Span, Trace}
      iex> root = Span.new!(uuid: "s1", type: :agent, name: "answer", status: :success,
      ...>   start_us: 1_700_000_000_999_999, end_us: 1_700_000_001_000_000)
      iex> trace = Trace.new!(uuid: "t1", status: :success, root_spans: [root],
      ...>   start_us: 1_700_000_000_999_999, end_us: 1_700_000_001_000_000, output: "hi")
      iex> api = Api.trace_api(trace)
      iex> {Enum.map(api["agentSpans"], & &1["name"]), api["startTime"], api["status"]}
      {["answer"], "2023-11-14T22:13:20.999Z", "SUCCESS"}
  """
  @spec trace_api(Trace.t(), keyword()) :: OrderedObject.t()
  def trace_api(%Trace{} = trace, opts \\ []) do
    metrics_data = Keyword.get(opts, :metrics_data, %{})

    buckets =
      trace.root_spans
      |> Enum.reverse()
      |> pop_spans(metrics_data, Map.new(@buckets, fn {_type, key} -> {key, []} end))

    trace
    |> trace_pairs(
      Enum.map(@buckets, fn {_type, key} -> {key, Enum.reverse(buckets[key])} end),
      environment: Keyword.get(opts, :environment, "development")
    )
    |> ordered()
  end

  # create_trace_api's span_stack: the top is the list's head, so the last
  # child pushed is popped first.
  defp pop_spans([], _metrics_data, buckets), do: buckets

  defp pop_spans([%Span{drop: true} = span | stack], metrics_data, buckets) do
    children =
      span.children
      |> Enum.map(&%{&1 | parent_uuid: span.parent_uuid})
      |> Enum.reverse()

    pop_spans(children ++ stack, metrics_data, buckets)
  end

  defp pop_spans([span | stack], metrics_data, buckets) do
    api_span =
      span
      |> span_api(Keyword.new(metrics_data_opt(metrics_data, span.uuid)))
      |> normalize_provider()

    buckets = Map.update!(buckets, bucket(span.type), &[api_span | &1])
    pop_spans(Enum.reverse(span.children) ++ stack, metrics_data, buckets)
  end

  defp metrics_data_opt(metrics_data, uuid) do
    case Map.fetch(metrics_data, uuid) do
      {:ok, data} -> [metrics_data: data]
      :error -> []
    end
  end

  @doc """
  Starts the trace of an evaluated test case, as deepeval's
  `create_api_trace`: every bucket empty, the trace's input, or the
  golden's when the trace's is falsy in Python's sense (`nil`, `""`,
  `{}`), and no `environment`. A missing start or end time is left out.

  Only the fields `create_api_trace` sets reach the export: the name,
  metadata, tags, thread and user ids, input, output, status and
  `context`. It passes the expected output, retrieval context and tool
  calls by field name, which `TraceApi` (aliases only) ignores, so they
  are left out, as are the metric collection and Confident AI ids.

  ## Examples

      iex> alias DeepEvalEx.Tracing.{Api, Trace}
      iex> trace = Trace.new!(uuid: "t1", status: :success, input: %{})
      iex> api = Api.eval_trace_api(trace, %DeepEvalEx.Dataset.Golden{input: "Hi"})
      iex> {api["input"], api["agentSpans"], api["status"]}
      {"Hi", [], "SUCCESS"}
  """
  @spec eval_trace_api(Trace.t(), %{:input => term(), optional(atom()) => term()}) ::
          OrderedObject.t()
  def eval_trace_api(%Trace{} = trace, golden) do
    input = if Fields.truthy?(trace.input), do: trace.input, else: golden.input

    ordered(
      [{"uuid", trace.uuid}] ++
        Enum.map(@buckets, fn {_type, key} -> {key, []} end) ++
        [
          {"startTime", trace.start_us && Time.to_zod_iso(trace.start_us)},
          {"endTime", trace.end_us && Time.to_zod_iso(trace.end_us)},
          {"name", trace.name},
          {"metadata", serializable(trace.metadata)},
          {"tags", trace.tags},
          {"threadId", trace.thread_id},
          {"userId", trace.user_id},
          {"input", serializable(input)},
          {"output", serializable(trace.output)},
          {"status", status(trace)},
          {"context", trace.context}
        ]
    )
  end

  defp status(%Trace{status: :success}), do: "SUCCESS"
  defp status(%Trace{}), do: "ERRORED"

  defp trace_pairs(trace, buckets, fields) do
    [{"uuid", trace.uuid}] ++
      buckets ++
      [
        {"startTime", time(trace.start_us)},
        {"endTime", time(trace.end_us)},
        {"name", trace.name},
        {"metadata", serializable(trace.metadata)},
        {"tags", trace.tags},
        {"environment", fields[:environment]},
        {"threadId", trace.thread_id},
        {"userId", trace.user_id},
        {"input", serializable(trace.input)},
        {"output", serializable(trace.output)},
        {"status", status(trace)},
        {"testCaseId", trace.test_case_id},
        {"testRunId", trace.test_run_id},
        {"turnId", trace.turn_id},
        {"retrievalContext", TestRun.flat_contexts(trace.retrieval_context)},
        {"context", trace.context},
        {"expectedOutput", trace.expected_output},
        {"toolsCalled", tool_calls(trace.tools_called)},
        {"expectedTools", tool_calls(trace.expected_tools)},
        {"metricCollection", trace.metric_collection}
      ]
  end

  @doc """
  Exports one span as deepeval's `BaseApiSpan`
  (`_convert_span_to_api_span`), its children left out. The provider is
  kept as it is (see the moduledoc).

  ## Options

  - `:metrics_data` - The span's measured metric data, written as its
    `metricsData` (expectation rows included, as deepeval's span field
    keeps them). Without it, a span with metrics gets their unmeasured
    rows and one without gets none.
  """
  @spec span_api(Span.t(), keyword()) :: OrderedObject.t()
  def span_api(%Span{} = span, opts \\ []) do
    metrics_data =
      case Keyword.fetch(opts, :metrics_data) do
        {:ok, data} -> data
        :error when span.metrics == [] -> nil
        :error -> Enum.map(span.metrics, &unmeasured_metric_data/1)
      end

    ([
       {"uuid", span.uuid},
       {"name", span.name},
       {"status", Span.status_value(span.status)},
       {"type", Span.type_value(span.type)},
       {"parentUuid", span.parent_uuid},
       {"startTime", time(span.start_us)},
       {"endTime", time(span.end_us)},
       {"metadata", serializable(span.metadata)},
       {"input", serializable(span.input)},
       {"output", serializable(span.output)},
       {"error", span.error},
       {"integration", span.integration},
       {"retrievalContext", TestRun.flat_contexts(span.retrieval_context)},
       {"context", span.context},
       {"expectedOutput", span.expected_output},
       {"toolsCalled", tool_calls(span.tools_called)},
       {"expectedTools", tool_calls(span.expected_tools)}
     ] ++
       typed_pairs(span) ++
       [
         {"metricCollection", span.metric_collection},
         {"metricsData", metrics_data && Enum.map(metrics_data, &TestRun.metric_data_to_map/1)}
       ] ++ prompt_pairs(span))
    |> ordered()
  end

  # BaseApiSpan's type-specific fields, each set on its type's spans only.
  defp typed_pairs(%Span{type: :agent} = span),
    do: [{"availableTools", span.available_tools}, {"agentHandoffs", span.agent_handoffs}]

  defp typed_pairs(%Span{type: :tool} = span), do: [{"description", span.description}]

  defp typed_pairs(%Span{type: :retriever} = span),
    do: [{"embedder", span.embedder}, {"topK", span.top_k}, {"chunkSize", span.chunk_size}]

  defp typed_pairs(%Span{type: :llm} = span) do
    [
      {"model", span.model},
      {"provider", span.provider},
      {"inputTokenCount", span.input_token_count},
      {"outputTokenCount", span.output_token_count},
      {"costPerInputToken", span.cost_per_input_token},
      {"costPerOutputToken", span.cost_per_output_token},
      {"tokenIntervals", token_intervals(span.token_intervals)}
    ]
  end

  defp typed_pairs(%Span{}), do: []

  # The prompt's fields, then the span's own when truthy, last in
  # BaseApiSpan's order.
  @prompt_fields [
    {"promptAlias", :prompt_alias, :alias},
    {"promptVersion", :prompt_version, :version},
    {"promptLabel", :prompt_label, :label},
    {"promptCommitHash", :prompt_commit_hash, :hash}
  ]

  defp prompt_pairs(%Span{type: :llm} = span) do
    for {key, field, prompt_key} <- @prompt_fields do
      own = Map.fetch!(span, field)

      value =
        if Fields.truthy?(own),
          do: own,
          else: span.prompt && prompt_value(span.prompt, prompt_key)

      {key, value}
    end
  end

  defp prompt_pairs(%Span{}), do: []

  defp prompt_value(%OrderedObject{} = prompt, key), do: prompt[Atom.to_string(key)]

  defp prompt_value(prompt, key) when is_map(prompt),
    do: Map.get(prompt, key, Map.get(prompt, Atom.to_string(key)))

  defp token_intervals(intervals) when is_map(intervals) and map_size(intervals) > 0 do
    intervals
    |> Enum.sort()
    |> Enum.map(fn {us, text} -> {Time.to_zod_iso(us, :microsecond), text} end)
    |> OrderedObject.new()
  end

  defp token_intervals(_intervals), do: nil

  @doc """
  Appends an exported span (`span_api/2`) to its type's bucket of a
  trace export, as deepeval's evaluation walker appends each span it
  visits.
  """
  @spec add_span(OrderedObject.t(), OrderedObject.t()) :: OrderedObject.t()
  def add_span(%OrderedObject{} = trace_api, %OrderedObject{} = api_span) do
    key = bucket(String.to_existing_atom(api_span["type"]))
    put(trace_api, key, (trace_api[key] || []) ++ [api_span])
  end

  @doc """
  Sets a trace export's `metricsData` to the trace-level metric data,
  leaving out an expectation evaluator's row, as deepeval's
  `ApiMetricsData` serializer.
  """
  @spec put_metrics_data(OrderedObject.t(), [MetricData.t()]) :: OrderedObject.t()
  def put_metrics_data(%OrderedObject{} = trace_api, metrics_data) do
    rows =
      for %MetricData{expectations_data: nil} = data <- metrics_data,
          do: TestRun.metric_data_to_map(data)

    put(trace_api, "metricsData", rows)
  end

  # Sets a TraceApi key, in its declaration position.
  defp put(%OrderedObject{values: values}, key, value) do
    values
    |> List.keystore(key, 0, {key, value})
    |> Enum.sort_by(fn {k, _v} ->
      Enum.find_index(@trace_keys, &(&1 == k)) || length(@trace_keys)
    end)
    |> OrderedObject.new()
  end

  # create_metric_data of a metric that has not measured: its configured
  # name, threshold, strict mode and judge model, and is_successful() False.
  defp unmeasured_metric_data(spec) do
    {module, opts} = metric_config(spec)
    default = if function_exported?(module, :default_threshold, 0), do: module.default_threshold()

    %MetricData{
      name: metric_name(spec, module),
      threshold: BaseMetric.threshold(opts, default),
      success: false,
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      evaluation_model: BaseMetric.usage_fields(module, opts, []).evaluation_model
    }
  end

  # The metric's module and options, as the evaluator merges them: a
  # struct's set fields (and its threshold, nil included) over its module's
  # default options.
  defp metric_config({module, opts}) do
    Code.ensure_loaded(module)
    {module, BaseMetric.with_default_opts(opts, module)}
  end

  defp metric_config(%module{} = metric) do
    struct_opts =
      metric
      |> Map.from_struct()
      |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)

    {module, opts} = metric_config({module, []})
    {module, Keyword.merge(opts, struct_opts)}
  end

  defp metric_config(module) when is_atom(module), do: metric_config({module, []})

  defp metric_name(%module{} = metric, module) do
    if function_exported?(module, :metric_name, 1),
      do: module.metric_name(metric),
      else: module.metric_name()
  end

  defp metric_name(_spec, module), do: module.metric_name()

  defp bucket(type), do: Keyword.fetch!(@buckets, type)

  defp time(nil), do: Time.to_zod_iso(Time.now_us())
  defp time(us), do: Time.to_zod_iso(us)

  defp serializable(nil), do: nil
  defp serializable(value), do: JSON.make_serializable(value)

  defp tool_calls(nil), do: nil

  defp tool_calls(tool_calls),
    do: tool_calls |> TestRun.tool_calls_to_maps() |> JSON.make_serializable()

  defp ordered(pairs), do: pairs |> Enum.reject(&match?({_key, nil}, &1)) |> OrderedObject.new()

  # normalize_span_provider_for_platform, on a truthy provider.
  defp normalize_provider(%OrderedObject{} = api_span) do
    case api_span["provider"] do
      provider when is_binary(provider) and provider != "" ->
        put_value(api_span, "provider", normalize_provider_name(provider))

      _ ->
        api_span
    end
  end

  # A provider that normalises to None is left out, as exclude_none does.
  defp put_value(%OrderedObject{values: values}, key, nil),
    do: OrderedObject.new(List.keydelete(values, key, 0))

  defp put_value(%OrderedObject{values: values}, key, value),
    do: OrderedObject.new(List.keyreplace(values, key, 0, {key, value}))

  @doc false
  # deepeval's normalize_span_provider_for_platform: a raw provider string
  # (LangChain's "openai", "anthropic/claude-3") as a Provider value, or
  # trimmed when it is none.
  @spec normalize_provider_name(String.t()) :: String.t() | nil
  def normalize_provider_name(raw) do
    case String.trim(raw) do
      "" -> nil
      trimmed -> provider_value(trimmed) || trimmed
    end
  end

  defp provider_value(trimmed) do
    whole = loose(trimmed)
    head = trimmed |> String.split(~r/[\s.\/\\]+/, parts: 2) |> hd() |> loose()

    Enum.find_value(@providers, fn {name, value} ->
      if whole in [loose(value), loose(name)] or head in [loose(value), loose(name)], do: value
    end)
  end

  defp loose(value), do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "")
end
