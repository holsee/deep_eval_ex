defmodule DeepEvalEx.Evaluator.Agentic do
  @moduledoc """
  Evaluates one captured trace against its golden: the trace-level
  (end-to-end) metrics on a test case built from the trace and the golden,
  then the component-level metrics each span declares, as deepeval 4.3.1's
  `evals_iterator` does once user code has run.

  `evaluate/3` ports both of deepeval's walkers, which differ:

  - **`mode: :async`** (the default, `AsyncConfig(run_async=True)`) ports
    `evaluate/execute/agentic.py`'s `_a_execute_agentic_test_case`. Span
    metrics are measured on a test case built when the span's input is
    truthy in Python's sense, so a zero-argument span (`%{}`) has none.
    The spans are walked in breadth-first level order, every root first,
    which is the order asyncio runs deepeval's `create_task` walk when no
    metric suspends; here the span metrics are measured concurrently but
    the buckets always keep that order. A trace without a test case
    (no truthy input and no expectations) for its metrics is marked
    errored, and a trace that never measured its metrics gets their
    unmeasured rows, as deepeval's `finally` block writes.
  - **`mode: :sync`** (`run_async=False`) ports `evaluate/execute/loop.py`'s
    `execute_agentic_test_cases_from_loop` walker. A span test case is
    built when the span's input is not `nil`, so `%{}` has one. Spans are
    exported in pre-order, depth first, and their metrics measured in
    post-order, one at a time; an ignored metric error is recorded as
    `DeepEvalEx.Result.format_error_text/2`'s `"<type>: <message>"`, as
    deepeval's synchronous `_execute_metric` records it. The trace-level
    test case always takes the golden's input.
  - **`mode: :trace_scope`** ports `evaluate/execute/trace_scope.py`'s
    `_assert_test_from_current_trace`, deepeval's `assert_test(golden=...)`
    (`DeepEvalEx.ExUnit.assert_trace/3`). Spans are walked as `:sync` walks
    them. The trace's output, when unset, is its first root's, and the
    trace-level test case falls back to the golden for its input (`"None"`
    without one), expected output, context, retrieval context and expected
    tools; it is measured after the spans, and never marked for a missing
    test case.

  In both modes the trace-level metrics run first, and then every root is
  walked. A span that errored, or every span of a trace that errored, has
  its metrics skipped (deepeval's `_skip_metrics_for_error`) and its
  children are not walked: it is exported `ERRORED` with its own error, or
  the trace's first span error (`_trace_error`), and its metrics'
  unmeasured rows. A span with metrics but no test case is exported
  `ERRORED` with deepeval's text, through `format_error_text`:

      DeepEvalError: Span has metrics but no LLMTestCase. Are you sure you
      called `update_current_span()`?

  (on one line), and a trace with metrics but no test case marks its first
  root `ERRORED` with `"DeepEvalError: Trace has metrics but no
  LLMTestCase (missing input/output). Are you sure you called
  `update_current_trace()`?"`.

  A metric that requires the trace (`DeepEvalEx.Metrics.BaseMetric.requires_trace?/1`)
  is measured with the nested trace dict (`DeepEvalEx.Tracing.NestedDict`)
  of its span, or of the trace's first root, as the test case's
  `:trace_dict`, on a test case whose input is the placeholder `"None"`
  when there is none.

  ## Results

  `evaluate/3` returns:

  - `:test_case` - the `DeepEvalEx.TestRun.TestCase` of the golden
    (deepeval's `LLMApiTestCase`), named and ordered after it, with the
    trace-level metric data and cost and, as its `:trace`, the trace's
    `TraceApi` (`DeepEvalEx.Tracing.Api.eval_trace_api/2`) holding every
    walked span and its metric data. It fails when a non-flaky trace or
    span metric failed. `DeepEvalEx.TestRun.from_test_cases/2` builds the
    run, `traceMetricsScores` included;
  - `:test_results` - the golden's `DeepEvalEx.TestResult`, then one per
    span with metric data, bucket by bucket (base, agent, llm, retriever,
    tool), as deepeval's `extract_trace_test_results`, leaving out one
    identical to the golden's (`filter_duplicate_results`). A span's test
    result succeeds when the span exported `SUCCESS`, and carries the
    span's exported input and output;
  - `:prompts` - the prompts of the walked LLM spans, once per alias, as
    deepeval's `log_prompt` adds them to the test run.

  The trace is the one `DeepEvalEx.Tracing.capture/2` returns; under
  `mode: :sync` it is expected to have been built with
  `DeepEvalEx.Tracing.Tree.build/3`'s `mode: :sync` wrapper strip, as
  deepeval's sync iterator ends its traces.
  """

  alias DeepEvalEx.Dataset.Expectations
  alias DeepEvalEx.{DeepEvalError, Evaluator, Result, TestCase, TestResult}
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.MetricData
  alias DeepEvalEx.Tracing.{Api, Fields, NestedDict, Span, Trace}
  alias Jason.OrderedObject

  @span_error "Span has metrics but no LLMTestCase. " <>
                "Are you sure you called `update_current_span()`?"

  @trace_error "Trace has metrics but no LLMTestCase (missing input/output). " <>
                 "Are you sure you called `update_current_trace()`?"

  # extract_trace_test_results' bucket order.
  @result_buckets ~w(baseSpans agentSpans llmSpans retrieverSpans toolSpans)

  @typedoc "The golden a trace was captured for: its input, and optionally its other fields."
  @type golden :: %{
          required(:input) => term(),
          optional(:name) => String.t() | nil,
          optional(:actual_output) => String.t() | nil,
          optional(:expectations) => Expectations.t() | nil,
          optional(:additional_metadata) => map() | nil,
          optional(:comments) => String.t() | nil,
          optional(atom()) => term()
        }

  @type outcome :: %{
          test_case: TestRun.TestCase.t(),
          test_results: [TestResult.t()],
          prompts: [term()]
        }

  # One walked span: the span as it is exported (status and error set when
  # it is skipped), the test case its metrics measure on (nil when they do
  # not run) and, once measured, their results.
  @typep entry :: %{span: Span.t(), job: {TestCase.t(), [Span.metric_spec()]} | nil}

  @doc """
  Evaluates `trace`, captured for `golden`, as deepeval's `evals_iterator`
  (see the moduledoc).

  ## Options

  - `:mode` - `:async` (default), `:sync` or `:trace_scope`, the walker
    to port
  - `:metrics` - The iterator's trace-level metrics (deepeval's
    `evals_iterator(metrics=...)`); when given, they replace the trace's
    own (`update_current_trace(metrics: ...)`)
  - `:index` - The test case's order, and its name's suffix when the
    golden has no name (default: `0`); `nil` for none, as an
    `assert_test`'s (named `"test_case_None"`)

  Any other option is `DeepEvalEx.Evaluator.evaluate_single/3`'s, such as
  `:ignore_errors`, `:skip_on_missing_params`, `:model` or `:timeout`. A
  metric error is raised unless `:ignore_errors` is set.
  """
  @spec evaluate(Trace.t(), golden(), keyword()) :: outcome()
  def evaluate(%Trace{} = trace, golden, opts \\ []) do
    started = System.monotonic_time()
    {mode, opts} = Keyword.pop(opts, :mode, :async)
    {iterator_metrics, opts} = Keyword.pop(opts, :metrics)
    {index, opts} = Keyword.pop(opts, :index, 0)
    mode in [:async, :sync, :trace_scope] || raise ArgumentError, "unknown mode #{inspect(mode)}"

    trace =
      if iterator_metrics in [nil, []], do: trace, else: %{trace | metrics: iterator_metrics}

    trace = if mode == :trace_scope, do: with_root_output(trace), else: trace

    eval_opts =
      if mode == :async, do: [], else: [run_async: false, error_text: :format_error_text]

    eval_opts = Keyword.merge(opts, eval_opts)

    test_case = golden_test_case(trace, golden)
    {trace, measured, entries} = evaluate_trace_and_spans(mode, trace, golden, eval_opts)

    trace_api =
      trace
      |> Api.eval_trace_api(golden)
      |> put_trace_metrics_data(measured)

    trace_api = Enum.reduce(entries, trace_api, &Api.add_span(&2, &1.api))
    case_results = measured || unmeasured_trace_results(mode, iterator_metrics)

    api_test_case =
      test_case
      |> api_test_case(case_results, entries, index)
      |> Map.put(:trace, trace_api)
      |> Map.put(:run_duration, seconds_since(started))

    %{
      test_case: api_test_case,
      test_results: test_results(test_case, api_test_case, case_results, entries, index),
      prompts: prompts(entries)
    }
  end

  # The golden's test case (both iterators build the same one): the
  # golden's input, name and metadata, the trace's output and test-case
  # fields.
  # trace_scope's effective_trace_output: the trace's, else its first root's.
  defp with_root_output(%Trace{output: nil, root_spans: [root | _]} = trace),
    do: %{trace | output: root.output}

  defp with_root_output(trace), do: trace

  defp golden_test_case(trace, golden) do
    %TestCase{
      input: golden.input,
      expectations: Map.get(golden, :expectations),
      actual_output: str_or_nil(trace.output),
      expected_output: trace.expected_output,
      context: trace.context,
      retrieval_context: trace.retrieval_context,
      tools_called: trace.tools_called,
      expected_tools: trace.expected_tools,
      metadata: Map.get(golden, :additional_metadata),
      comments: Map.get(golden, :comments),
      name: Map.get(golden, :name)
    }
  end

  # trace_scope.py measures the spans first, the iterators the trace (whose
  # metrics' outcome can mark it).
  defp evaluate_trace_and_spans(:trace_scope, trace, golden, opts) do
    entries = evaluate_spans(:trace_scope, trace, opts)
    {trace, measured} = evaluate_trace(:trace_scope, trace, golden, opts)
    {trace, measured, entries}
  end

  defp evaluate_trace_and_spans(mode, trace, golden, opts) do
    {trace, measured} = evaluate_trace(mode, trace, golden, opts)
    {trace, measured, evaluate_spans(mode, trace, opts)}
  end

  defp evaluate_spans(mode, trace, opts) do
    trace.root_spans
    |> walk(mode, trace)
    |> measure(mode, opts)
  end

  ## Trace-level metrics

  # {trace, results}: results nil when the trace-level metrics did not run.
  # The async walker marks a trace without a test case errored.
  defp evaluate_trace(mode, trace, golden, opts) do
    expectations = Map.get(golden, :expectations)

    cond do
      trace.status == :errored ->
        {trace, nil}

      trace.metrics == [] and not Expectations.present?(expectations) ->
        {trace, nil}

      true ->
        measure_trace(mode, trace, golden, opts)
    end
  end

  defp measure_trace(mode, trace, golden, opts) do
    requires_trace? = Enum.any?(trace.metrics, &BaseMetric.requires_trace?/1)

    case trace_test_case(mode, trace, golden, requires_trace?) do
      nil ->
        {mark_missing_test_case(trace), nil}

      test_case ->
        test_case = if requires_trace?, do: put_trace_dict(test_case, trace), else: test_case
        {trace, measure_metrics(test_case, trace.metrics, opts)}
    end
  end

  # loop.py: always from the golden, its actual output when the trace has
  # none.
  defp trace_test_case(:sync, trace, golden, _requires_trace?) do
    %TestCase{
      input: golden.input,
      expectations: Map.get(golden, :expectations),
      actual_output: str_or_nil(trace.output) || Map.get(golden, :actual_output),
      expected_output: trace.expected_output,
      context: trace.context,
      retrieval_context: trace.retrieval_context,
      tools_called: trace.tools_called,
      expected_tools: trace.expected_tools
    }
  end

  # trace_scope.py: the golden's input ("None" without one), and its
  # fields where the trace's are falsy.
  defp trace_test_case(:trace_scope, trace, golden, _requires_trace?) do
    %TestCase{
      input: if(Fields.truthy?(golden.input), do: golden.input, else: "None"),
      expectations: Map.get(golden, :expectations),
      actual_output: str_or_nil(trace.output),
      expected_output: trace.expected_output || golden_field(golden, :expected_output),
      context: or_golden(trace.context, golden, :context),
      retrieval_context: or_golden(trace.retrieval_context, golden, :retrieval_context),
      tools_called: trace.tools_called,
      expected_tools: or_golden(trace.expected_tools, golden, :expected_tools)
    }
  end

  # _a_execute_trace_test_case: from a truthy trace input or the golden's
  # expectations, else the "None" placeholder of a requires_trace metric.
  defp trace_test_case(:async, trace, golden, requires_trace?) do
    expectations = Map.get(golden, :expectations)

    cond do
      Fields.truthy?(trace.input) or Expectations.present?(expectations) ->
        %TestCase{
          input: if(is_nil(trace.input), do: golden.input, else: Python.str(trace.input)),
          expectations: expectations,
          actual_output: str_or_nil(trace.output),
          expected_output: trace.expected_output,
          context: trace.context,
          retrieval_context: trace.retrieval_context,
          tools_called: trace.tools_called,
          expected_tools: trace.expected_tools
        }

      requires_trace? ->
        %TestCase{input: "None"}

      true ->
        nil
    end
  end

  defp or_golden(value, golden, field),
    do: if(Fields.truthy?(value), do: value, else: golden_field(golden, field))

  defp golden_field(golden, field) do
    value = Map.get(golden, field)
    if Fields.truthy?(value), do: value
  end

  defp put_trace_dict(test_case, %Trace{root_spans: [root | _]}),
    do: %{test_case | trace_dict: NestedDict.build(root)}

  defp put_trace_dict(test_case, _trace), do: test_case

  defp mark_missing_test_case(trace) do
    roots =
      case trace.root_spans do
        [root | rest] -> [%{root | status: :errored, error: error_text(@trace_error)} | rest]
        [] -> []
      end

    %{trace | status: :errored, root_spans: roots}
  end

  # The finally block of _a_execute_agentic_test_case: when the trace-level
  # metrics never ran, the iterator's are written to the test case
  # unmeasured.
  defp unmeasured_trace_results(:async, [_ | _] = metrics), do: unmeasured(metrics)
  defp unmeasured_trace_results(_mode, _metrics), do: []

  defp put_trace_metrics_data(trace_api, nil), do: trace_api

  defp put_trace_metrics_data(trace_api, results),
    do: Api.put_metrics_data(trace_api, Enum.map(results, &MetricData.from_result/1))

  ## Span walk

  # The walked spans in bucket order: pre-order for :sync, breadth-first
  # level order for :async. A skipped span's children are not walked.
  @spec walk([Span.t()], :async | :sync | :trace_scope, Trace.t()) ::
          [{entry(), non_neg_integer()}]
  defp walk(roots, :sync, trace) do
    {entries, post_order, _count} =
      Enum.reduce(roots, {[], [], 0}, &sync_walk(&1, trace, &2))

    positions = post_order |> Enum.reverse() |> Enum.with_index() |> Map.new()

    entries
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> {entry, Map.get(positions, index, index)} end)
  end

  defp walk(roots, :trace_scope, trace), do: walk(roots, :sync, trace)

  defp walk(roots, :async, trace) do
    roots |> bfs(trace) |> Enum.with_index()
  end

  # loop.py's dfs: the span is exported before its children, its metrics
  # measured after them (the measure position).
  defp sync_walk(span, trace, {entries, post_order, count}) do
    entry = plan(span, trace, :sync)
    acc = {[entry | entries], post_order, count + 1}

    if skip?(span, trace) do
      acc
    else
      {entries, post_order, next} = Enum.reduce(span.children, acc, &sync_walk(&1, trace, &2))
      {entries, [count | post_order], next}
    end
  end

  defp bfs([], _trace), do: []

  defp bfs(level, trace) do
    entries = Enum.map(level, &plan(&1, trace, :async))
    next = for span <- level, not skip?(span, trace), child <- span.children, do: child
    entries ++ bfs(next, trace)
  end

  # _skip_metrics_for_error.
  defp skip?(span, trace), do: trace.status == :errored or span.status == :errored

  # What the walker does with one span: skip it, leave it (no metrics),
  # report its missing test case, or measure its metrics on a test case.
  defp plan(span, trace, mode) do
    cond do
      skip?(span, trace) ->
        error = if Fields.truthy?(span.error), do: span.error, else: trace_error(trace)
        %{span: %{span | status: :errored, error: error}, job: nil}

      span.metrics == [] ->
        %{span: span, job: nil}

      true ->
        requires_trace? = Enum.any?(span.metrics, &BaseMetric.requires_trace?/1)

        case {span_test_case(span, mode), requires_trace?} do
          {nil, false} ->
            %{span: %{span | status: :errored, error: error_text(@span_error)}, job: nil}

          {test_case, true} ->
            test_case = %{
              (test_case || %TestCase{input: "None"})
              | trace_dict: NestedDict.build(span)
            }

            %{span: span, job: {test_case, span.metrics}}

          {test_case, false} ->
            %{span: span, job: {test_case, span.metrics}}
        end
    end
  end

  # A span test case when its input is not None (sync) or truthy (async).
  defp span_test_case(span, mode) do
    input? = if mode == :async, do: Fields.truthy?(span.input), else: not is_nil(span.input)

    if input? do
      %TestCase{
        input: Python.str(span.input),
        actual_output: str_or_nil(span.output),
        expected_output: span.expected_output,
        context: span.context,
        retrieval_context: span.retrieval_context,
        tools_called: span.tools_called,
        expected_tools: span.expected_tools
      }
    end
  end

  # _trace_error: the first errored span's error, depth first.
  defp trace_error(trace), do: Enum.find_value(trace.root_spans, &first_error/1)

  defp first_error(%Span{status: :errored, error: error} = span) do
    if Fields.truthy?(error), do: error, else: Enum.find_value(span.children, &first_error/1)
  end

  defp first_error(span), do: Enum.find_value(span.children, &first_error/1)

  ## Measuring

  # Measures every planned job, in measure position order (:sync, one at a
  # time) or concurrently (:async), and returns the entries in bucket order
  # with their results and exported spans.
  defp measure(planned, mode, opts) do
    jobs =
      planned
      |> Enum.with_index()
      |> Enum.filter(fn {{entry, _position}, _index} -> entry.job end)
      |> Enum.sort_by(fn {{_entry, position}, _index} -> position end)
      |> Enum.map(fn {{entry, _position}, index} -> {index, entry.job} end)

    results = jobs |> run_jobs(mode, opts) |> Map.new()

    planned
    |> Enum.with_index()
    |> Enum.map(fn {{entry, _position}, index} -> finish(entry, Map.get(results, index)) end)
  end

  defp run_jobs(jobs, :async, opts) do
    jobs
    |> Task.async_stream(
      fn {index, {test_case, metrics}} ->
        try do
          {:ok, {index, measure_metrics(test_case, metrics, opts)}}
        rescue
          exception -> {:raise, exception, __STACKTRACE__}
        end
      end,
      ordered: true,
      max_concurrency: Evaluator.max_concurrency!(opts),
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {:ok, result}} -> result
      {:ok, {:raise, exception, stacktrace}} -> reraise exception, stacktrace
    end)
  end

  defp run_jobs(jobs, _mode, opts),
    do:
      Enum.map(jobs, fn {index, {test_case, metrics}} ->
        {index, measure_metrics(test_case, metrics, opts)}
      end)

  # The metrics' results, the skipped ones left out.
  defp measure_metrics(test_case, metrics, opts) do
    test_case
    |> Evaluator.evaluate_single(metrics, opts)
    |> Enum.reject(& &1.skipped)
  end

  # The exported span and the results its test result reports: measured,
  # or a skipped span's unmeasured rows.
  defp finish(%{span: span, job: nil}, nil) do
    %{span: span, measured: nil, api: Api.span_api(span), results: unmeasured(span.metrics)}
  end

  defp finish(%{span: span}, results) do
    rows = Enum.map(results, &MetricData.from_result/1)

    %{
      span: span,
      measured: results,
      api: Api.span_api(span, metrics_data: rows),
      results: results
    }
  end

  defp unmeasured(metrics), do: Enum.map(metrics, &unmeasured_result/1)

  defp unmeasured_result(metric),
    do: metric |> Api.unmeasured_metric_data() |> MetricData.to_result()

  ## Results

  # create_api_test_case, then update_metric_data for the trace's rows and
  # update_status for each measured span's.
  defp api_test_case(test_case, trace_results, entries, index) do
    trace_rows = Enum.map(trace_results, &MetricData.from_result/1)

    span_rows =
      for %{measured: [_ | _] = results} <- entries,
          result <- results,
          do: MetricData.from_result(result)

    {expectations_data, metrics_data} = TestRun.split_expectations(trace_rows)

    %TestRun.TestCase{
      expectations_data: expectations_data,
      name: test_case.name || "test_case_#{Python.str(index)}",
      input: test_case.input,
      actual_output: test_case.actual_output,
      expected_output: test_case.expected_output,
      context: test_case.context,
      retrieval_context: TestRun.flat_contexts(test_case.retrieval_context),
      tools_called: test_case.tools_called,
      expected_tools: test_case.expected_tools,
      success: not Enum.any?(trace_rows ++ span_rows, &(not &1.flaky and &1.success == false)),
      metrics_data: metrics_data,
      evaluation_cost: sum_costs(trace_rows),
      order: index,
      metadata: test_case.metadata,
      comments: test_case.comments
    }
  end

  defp sum_costs(rows) do
    Enum.reduce(rows, nil, fn
      %MetricData{evaluation_cost: nil}, total -> total
      %MetricData{evaluation_cost: cost}, nil -> cost
      %MetricData{evaluation_cost: cost}, total -> total + cost
    end)
  end

  # create_test_result of the golden's test case, then the spans' unique
  # results (extract_trace_test_results, filter_duplicate_results).
  defp test_results(test_case, api_test_case, trace_results, entries, index) do
    main = %{
      TestResult.new(test_case, trace_results, index || 0)
      | name: api_test_case.name,
        success: api_test_case.success,
        index: index
    }

    span_results =
      for bucket <- @result_buckets,
          %{api: api, results: [_ | _] = results} <- entries,
          bucket_of(api) == bucket,
          result = span_result(api, results),
          not duplicate?(result, main, api_test_case.metrics_data),
          do: result

    [main | span_results]
  end

  defp bucket_of(%OrderedObject{} = api), do: api["type"] <> "Spans"

  defp span_result(api, results) do
    %TestResult{
      name: api["name"],
      success: api["status"] == "SUCCESS",
      metrics_data: results,
      input: api["input"],
      actual_output: api["output"],
      expected_output: api["expectedOutput"],
      context: api["context"],
      retrieval_context: api["retrievalContext"]
    }
  end

  # filter_duplicate_results compares deepeval's MetricData rows: the
  # span's against the golden API test case's (its expectation row split
  # out). A result's latency, confidence and metadata are no part of them,
  # and differ between two measurements of the same metric.
  defp duplicate?(result, main, main_rows) do
    result.input == main.input and result.actual_output == main.actual_output and
      Enum.map(result.metrics_data, &MetricData.from_result/1) == main_rows
  end

  # log_prompt: each walked LLM span's prompt, once per key (its alias; the
  # hash is only read with Confident AI).
  defp prompts(entries) do
    entries
    |> Enum.flat_map(fn
      %{span: %Span{type: :llm, prompt: prompt}} when not is_nil(prompt) -> [prompt]
      _entry -> []
    end)
    |> Enum.uniq_by(&prompt_alias/1)
  end

  defp prompt_alias(%OrderedObject{} = prompt), do: prompt["alias"]

  defp prompt_alias(prompt) when is_map(prompt),
    do: Map.get(prompt, :alias, Map.get(prompt, "alias"))

  ## Helpers

  defp error_text(message), do: Result.format_error_text(%DeepEvalError{message: message})

  defp str_or_nil(nil), do: nil
  defp str_or_nil(value), do: Python.str(value)

  defp seconds_since(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
      1_000_000
  end
end
