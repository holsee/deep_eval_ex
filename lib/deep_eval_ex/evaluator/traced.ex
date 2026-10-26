defmodule DeepEvalEx.Evaluator.Traced do
  @moduledoc """
  Runs a traced task over goldens and evaluates what it did: deepeval
  4.3.1's `dataset.evals_iterator()` (`dataset/dataset.py`) and the loops
  behind it (`evaluate/execute/loop.py`), ADR-0011. `DeepEvalEx.evaluate_traced/3`
  is its entry point.

  For each golden the task is called with the golden, and every trace its
  spans make (see `DeepEvalEx.Tracing`) is captured for that golden. Each
  trace is then evaluated by `DeepEvalEx.Evaluator.Agentic.evaluate/3`:
  the trace-level metrics (the `:metrics` option, else the trace's own) on
  a test case built from the trace and the golden, and the metrics each
  span declares. The test cases make one `DeepEvalEx.TestRun`, saved and
  wrapped up as `DeepEvalEx.evaluate_run/3` saves its run.

  ## Modes

  - **`mode: :async`** (the default, deepeval's `AsyncConfig(run_async=True)`,
    `a_execute_agentic_test_cases_from_loop`): the goldens run concurrently,
    each in a task of its own (up to `:max_concurrent` at once), whose
    capture replaces deepeval's `EvalSession.trace_uuid_to_golden`. Every
    trace the task starts becomes its own test case, in start order, golden
    after golden, numbered across the run. A task that raises, throws or
    exits marks its last trace and that trace's root `ERRORED` with the
    error as `DeepEvalEx.Result.format_error_text/2` writes it
    (`"RuntimeError: agent gave up"`), as deepeval's `on_task_done`; a
    throw or exit is written `"throw: <reason>"` or `"exit: <reason>"`. A
    task still running after `:timeout` is killed, and its trace marked
    with deepeval's `"DeepEvalError: Task was cancelled (likely due to
    timeout)."`. The run goes on with the other goldens.
  - **`mode: :sync`** (`run_async=False`, `execute_agentic_test_cases_from_loop`):
    the goldens run one after the other in the calling process, each inside
    deepeval's wrapper span (`"__deepeval_internal_pytest_test_wrapper__"`,
    input `%{}`), and are evaluated as they finish. Each golden is one test
    case, numbered from 1: the trace keeps only the wrapper's first child,
    as deepeval's `end_trace` does, so a second top-level span is dropped.
    The trace's input is the wrapper's `%{}`, so the test case takes the
    golden's input, and its output stays `nil` unless the task sets it
    (`DeepEvalEx.Tracing.update_current_trace/1`). An error the task raises
    is raised again, and nothing is saved, as in deepeval, where it leaves
    the user's loop.

  ## The run

  The test run has the test cases' traces and `traceMetricsScores`, the
  `:identifier`, and the dataset's alias, id and version when evaluating a
  `DeepEvalEx.Dataset.EvaluationDataset`. Its `prompts` are the walked LLM
  spans' prompts, once per alias (deepeval's `log_prompt`), with
  `hyperparameters` then `{}`; given `:hyperparameters`, they replace both,
  and `prompts` is `[]`, as `evals_iterator` sets them after the loop.

  When no metric is declared anywhere (no `:metrics`, no trace or span
  metrics) and no golden has expectations, `DeepEvalEx.DeepEvalError` is
  raised with deepeval's `NoMetricsError` message before anything is
  evaluated (after the sync loop).
  """

  alias DeepEvalEx.{Config, DeepEvalError, EvaluationResult, Result, TestRun}
  alias DeepEvalEx.Dataset.{EvaluationDataset, Expectations, Golden}
  alias DeepEvalEx.Evaluator
  alias DeepEvalEx.Evaluator.Agentic
  alias DeepEvalEx.Report.{Console, Terminal}
  alias DeepEvalEx.TestRun.Manager
  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Span, Trace, Tree}
  alias Jason.OrderedObject

  @wrapper "__deepeval_internal_pytest_test_wrapper__"

  @no_metrics "evals_iterator was started but no metrics were declared anywhere. " <>
                "An evaluation run with zero metric sources cannot produce results.\n"

  @cancelled "Task was cancelled (likely due to timeout)."

  @export_opts [
    :results_folder,
    :results_subfolder,
    :cache_folder,
    :identifier,
    :hyperparameters,
    :dataset_alias,
    :dataset_id,
    :dataset_version,
    :print_results,
    :display,
    :truncate_passing_cases
  ]

  # PromptData's fields, in its order (test_run.py).
  @prompt_data ~w(alias hash version text_template messages_template model_settings output_type
                  interpolation_type)a

  @typedoc "What a traced task is run over."
  @type goldens :: [Golden.t()] | EvaluationDataset.t()

  @doc """
  The wrapper span's name in `:sync` mode, deepeval's
  `PYTEST_TRACE_TEST_WRAPPER_SPAN_NAME`.
  """
  @spec wrapper_name() :: String.t()
  def wrapper_name, do: @wrapper

  @doc """
  Runs `task` over `goldens` and evaluates its traces (see the moduledoc).

  Returns `{evaluation, test_run, path}`: the `DeepEvalEx.EvaluationResult`
  (deepeval's: each test case's result, then one per span with metric
  data, `filter_duplicate_results` applied), the `DeepEvalEx.TestRun` and
  the path of the `test_run_<timestamp>.json` written, or `nil`.

  Takes the options of `DeepEvalEx.evaluate_traced/3`.
  """
  @spec run(goldens(), (Golden.t() -> term()), keyword()) ::
          {EvaluationResult.t(), TestRun.t(), Path.t() | nil}
  def run(goldens, task, opts \\ []) when is_function(task, 1) do
    {goldens, dataset_opts} = goldens(goldens)
    if goldens == [], do: raise(ArgumentError, "Unable to evaluate dataset with no goldens.")

    {mode, opts} = Keyword.pop(opts, :mode, :async)
    mode in [:async, :sync] || raise ArgumentError, "unknown mode #{inspect(mode)}"

    {export_opts, eval_opts} = Keyword.split(opts, @export_opts)
    export_opts = Keyword.merge(export_opts, dataset_opts)
    TestRun.process_hyperparameters(export_opts[:hyperparameters])
    Console.display!(Keyword.get(export_opts, :display, :all))
    Evaluator.max_concurrency!(eval_opts)
    export_opts = Keyword.put(export_opts, :read_only, Config.read_only?())

    started = System.monotonic_time()
    outcomes = evaluate(mode, goldens, task, eval_opts)
    elapsed = System.monotonic_time() - started

    test_results = Enum.flat_map(outcomes, & &1.test_results)
    print? = Keyword.get_lazy(export_opts, :print_results, fn -> Config.get(:print_results) end)
    if print? == true, do: print_report(test_results, export_opts)

    test_run = test_run(outcomes, elapsed, export_opts)

    {test_run, path} =
      Manager.wrap_up(test_run, export_opts ++ [display_table: false, print: print? == true])

    :telemetry.execute(
      [:deep_eval_ex, :test_run, :stop],
      %{duration: elapsed, test_passed: test_run.test_passed, test_failed: test_run.test_failed},
      %{test_run: test_run, path: path, identifier: test_run.identifier, source: :evaluate_traced}
    )

    {%EvaluationResult{test_results: test_results}, test_run, path}
  end

  defp goldens(%EvaluationDataset{} = dataset),
    do:
      {dataset.goldens,
       [dataset_alias: dataset.alias, dataset_id: dataset.id, dataset_version: dataset.version]}

  defp goldens(goldens) when is_list(goldens), do: {goldens, []}

  ## Modes

  # execute_agentic_test_cases_from_loop: each golden captured inside the
  # wrapper span and evaluated before the next runs.
  defp evaluate(:sync, goldens, task, opts) do
    evaluated =
      goldens
      |> Enum.with_index(1)
      |> Enum.map(fn {golden, count} ->
        trace = capture_sync(golden, task)
        {trace, Agentic.evaluate(trace, golden, [mode: :sync, index: count] ++ opts)}
      end)

    {traces, outcomes} = Enum.unzip(evaluated)
    check_metrics!(goldens, traces, opts)
    outcomes
  end

  # a_execute_agentic_test_cases_from_loop: every golden's task first, then
  # every trace evaluated, numbered across the run.
  defp evaluate(:async, goldens, task, opts) do
    timeout = Keyword.get_lazy(opts, :timeout, &default_timeout/0)

    captured =
      goldens
      |> Task.async_stream(&capture_async(&1, task, timeout),
        max_concurrency: Evaluator.max_concurrency!(opts),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.zip_with(goldens, fn {:ok, traces}, golden -> Enum.map(traces, &{&1, golden}) end)
      |> Enum.concat()

    check_metrics!(goldens, Enum.map(captured, &elem(&1, 0)), opts)

    captured
    |> Enum.with_index()
    |> Task.async_stream(
      fn {{trace, golden}, index} ->
        try do
          {:ok, Agentic.evaluate(trace, golden, [mode: :async, index: index] ++ opts)}
        rescue
          exception -> {:raise, exception, __STACKTRACE__}
        end
      end,
      max_concurrency: Evaluator.max_concurrency!(opts),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, {:ok, outcome}} -> outcome
      {:ok, {:raise, exception, stacktrace}} -> reraise exception, stacktrace
    end)
  end

  defp default_timeout, do: round(Config.per_task_timeout_seconds() * 1000)

  ## Capturing

  # The golden's trace, its wrapper stripped as end_trace strips it under
  # ITERATOR_SYNC.
  defp capture_sync(golden, task) do
    {nil, [trace | _]} =
      Tracing.capture([], fn ->
        Tracing.span(:base, [name: @wrapper, input: %{}], fn ->
          task.(golden)
          nil
        end)
      end)

    Tree.build(%{trace | root_spans: []}, flatten(trace.root_spans), mode: :sync)
  end

  defp flatten(spans), do: Enum.flat_map(spans, &[&1 | flatten(&1.children)])

  # The golden's traces. The task runs in a process of its own, which
  # joins the capture through $callers, so that it can be stopped at the
  # timeout and its spans still closed (see DeepEvalEx.Tracing.Store).
  defp capture_async(golden, task, timeout) do
    {outcome, traces} =
      Tracing.capture([], fn ->
        running =
          Task.async(fn ->
            try do
              {:ok, task.(golden)}
            catch
              kind, reason -> {:raised, kind, reason, __STACKTRACE__}
            end
          end)

        case Task.yield(running, timeout) || Task.shutdown(running, :brutal_kill) do
          {:ok, outcome} -> outcome
          _timed_out_or_exited -> :cancelled
        end
      end)

    mark(traces, outcome)
  end

  # on_task_done: the task's trace (deepeval binds the trace of the last
  # span the task opened) and root (the first root it opened, else the
  # trace's last) marked ERRORED with the error.
  defp mark([], _outcome), do: []
  defp mark(traces, {:ok, _result}), do: traces

  defp mark(traces, outcome) do
    {earlier, [trace]} = Enum.split(traces, -1)
    earlier ++ [mark_trace(trace, error_text(outcome), earlier == [])]
  end

  defp mark_trace(%Trace{root_spans: []} = trace, _error, _first?),
    do: %{trace | status: :errored}

  defp mark_trace(%Trace{root_spans: roots} = trace, error, first?) do
    at = if first?, do: 0, else: -1
    roots = List.update_at(roots, at, &%{&1 | status: :errored, error: error})
    %{trace | status: :errored, root_spans: roots}
  end

  defp error_text({:raised, :error, reason, stacktrace}),
    do: :error |> Exception.normalize(reason, stacktrace) |> Result.format_error_text()

  defp error_text({:raised, kind, reason, _stacktrace}), do: "#{kind}: #{inspect(reason)}"

  defp error_text(:cancelled), do: Result.format_error_text(%DeepEvalError{message: @cancelled})

  # _has_any_evaluable_metrics, unless a golden has expectations.
  defp check_metrics!(goldens, traces, opts) do
    metrics? =
      Keyword.get(opts, :metrics, []) not in [nil, []] or
        Enum.any?(traces, fn trace ->
          trace.metrics != [] or Enum.any?(trace.root_spans, &span_metrics?/1)
        end)

    expectations? = Enum.any?(goldens, &Expectations.present?(Map.get(&1, :expectations)))

    unless metrics? or expectations?, do: raise(DeepEvalError, message: @no_metrics)
  end

  defp span_metrics?(%Span{metrics: [_ | _]}), do: true
  defp span_metrics?(%Span{children: children}), do: Enum.any?(children, &span_metrics?/1)

  ## The run

  defp test_run(outcomes, elapsed, export_opts) do
    prompts =
      outcomes
      |> Enum.flat_map(& &1.prompts)
      |> Enum.uniq_by(&prompt_value(&1, :alias))
      |> Enum.map(&prompt_data/1)

    # evals_iterator: given hyperparameters replace the logged prompts; a
    # logged prompt leaves hyperparameters {}.
    {hyperparameters, prompts} =
      cond do
        export_opts[:hyperparameters] != nil -> {export_opts[:hyperparameters], []}
        prompts == [] -> {nil, []}
        true -> {[], prompts}
      end

    outcomes
    |> Enum.map(& &1.test_case)
    |> TestRun.from_test_cases(
      identifier: export_opts[:identifier],
      hyperparameters: hyperparameters,
      prompts: prompts,
      run_duration: System.convert_time_unit(elapsed, :native, :microsecond) / 1_000_000,
      dataset_alias: export_opts[:dataset_alias],
      dataset_id: export_opts[:dataset_id],
      dataset_version: export_opts[:dataset_version]
    )
  end

  # process_prompts' PromptData of a span's prompt: its hash only with
  # Confident AI, its interpolation type the Prompt's default FSTRING.
  defp prompt_data(prompt) do
    @prompt_data
    |> Enum.map(fn
      :hash ->
        {"hash", nil}

      :interpolation_type ->
        {"interpolation_type", prompt_value(prompt, :interpolation_type) || "FSTRING"}

      field ->
        {Atom.to_string(field), prompt_value(prompt, field)}
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> OrderedObject.new()
  end

  defp prompt_value(%OrderedObject{} = prompt, key), do: prompt[Atom.to_string(key)]

  defp prompt_value(prompt, key) when is_map(prompt),
    do: Map.get(prompt, key, Map.get(prompt, Atom.to_string(key)))

  # evals_iterator's console report, as DeepEvalEx.evaluate_run/3 prints it.
  defp print_report(test_results, export_opts) do
    report =
      Console.build(test_results,
        display: Keyword.get(export_opts, :display, :all),
        truncate_passing_cases: Keyword.get(export_opts, :truncate_passing_cases, true)
      )

    IO.write(["\n", Terminal.render(report), "\n"])
  end
end
