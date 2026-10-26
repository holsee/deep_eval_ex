defmodule DeepEvalEx.Evaluator.TracedTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.{DeepEvalError, EvaluationResult, TestResult, TestRun}
  alias DeepEvalEx.Evaluator.Traced
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.Tracing

  @moduletag :tmp_dir
  # The run logs where it saved the test run.
  @moduletag :capture_log

  defmodule Planner do
    @moduledoc false
    # A GenServer agent: the trace context is handed over with the call.
    use GenServer
    use DeepEvalEx.Tracing

    def start_link, do: GenServer.start_link(__MODULE__, nil)

    def plan(pid, goal), do: GenServer.call(pid, {:plan, goal, Tracing.context()})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:plan, goal, ctx}, _from, state),
      do: {:reply, Tracing.with_context(ctx, fn -> make_plan(goal) end), state}

    deftraced make_plan(goal), type: :agent, name: "planner" do
      ["look up #{goal}"]
    end
  end

  defmodule Agent do
    @moduledoc false
    use DeepEvalEx.Tracing

    deftraced answer(query, planner), type: :agent, metrics: [ExactMatch] do
      [step] = Planner.plan(planner, query)

      [tool_output] =
        [step]
        |> Task.async_stream(&lookup/1)
        |> Enum.map(fn {:ok, output} -> output end)

      Tracing.update_current_span(expected_output: "Answer to #{query}")
      "Answer to #{query} (#{tool_output})"
    end

    deftraced lookup(step), type: :tool, description: "Looks it up" do
      "found #{step}"
    end

    deftraced draft(query),
      type: :llm,
      model: "gpt-4o",
      prompt: %{alias: "draft", version: "1"} do
      "draft of #{query}"
    end

    deftraced fail(query), type: :agent do
      _ = query
      raise "agent gave up"
    end

    deftraced linger(query), type: :agent do
      Process.sleep(:infinity)
      query
    end
  end

  @goldens [
    %Golden{input: "refunds", name: "refunds"},
    %Golden{input: "invoices", name: "invoices"}
  ]

  defp run!(goldens \\ @goldens, task, opts) do
    Traced.run(goldens, task, [print_results: false] ++ opts)
  end

  # A test case's exported trace as plain maps, to match on.
  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(term), do: term

  describe "run/3 in :async mode" do
    test "captures every process the task fans out to as one trace per golden",
         %{tmp_dir: tmp_dir} do
      {:ok, planner} = Planner.start_link()

      {%EvaluationResult{test_results: results}, test_run, path} =
        run!(&Agent.answer(&1.input, planner), results_folder: tmp_dir, identifier: "smoke")

      assert [%{name: "refunds"} = refunds, %{name: "invoices"}] = test_run.test_cases
      assert test_run.identifier == "smoke"
      assert File.regular?(path)

      trace = plain(refunds.trace)

      assert [%{"name" => "answer", "status" => "SUCCESS"} = agent, planner_span] =
               trace["agentSpans"]

      assert planner_span["name"] == "planner"
      assert planner_span["parentUuid"] == agent["uuid"]
      assert [%{"name" => "lookup", "parentUuid" => parent}] = trace["toolSpans"]
      assert parent == agent["uuid"]
      assert [%{"name" => "Exact Match", "success" => false}] = agent["metricsData"]

      # The golden's result, then the span's, which has metric data.
      assert [
               %TestResult{name: "refunds", metrics_data: []},
               %TestResult{name: "answer", success: true, metrics_data: [exact_match]},
               %TestResult{name: "invoices"},
               %TestResult{name: "answer"}
             ] = results

      assert exact_match.score == 0.0
      assert test_run.trace_metrics_scores != nil
    end

    test "marks the trace of a golden whose task raises, and evaluates the others" do
      task = fn
        %Golden{input: "refunds"} = golden -> Agent.fail(golden.input)
        golden -> Agent.draft(golden.input)
      end

      {_evaluation, test_run, _path} = run!(task, metrics: [ExactMatch], ignore_errors: true)

      assert [failed, drafted] = test_run.test_cases
      assert failed.trace["status"] == "ERRORED"

      assert [%{"status" => "ERRORED", "error" => "RuntimeError: agent gave up"}] =
               plain(failed.trace["agentSpans"])

      assert drafted.trace["status"] == "SUCCESS"
    end

    test "writes a throw or exit as its kind and reason" do
      task = fn golden ->
        Tracing.span(:agent, [name: "thrower"], fn -> throw(golden.input) end)
      end

      {_evaluation, test_run, _path} =
        run!([hd(@goldens)], task, metrics: [ExactMatch], ignore_errors: true)

      assert [%{trace: trace}] = test_run.test_cases
      assert [%{"error" => ~s(throw: "refunds")}] = plain(trace["agentSpans"])
    end

    test "stops a task at the timeout and marks its trace cancelled" do
      task = fn
        %Golden{input: "refunds"} = golden -> Agent.linger(golden.input)
        golden -> Agent.draft(golden.input)
      end

      {_evaluation, test_run, _path} =
        run!(task, metrics: [ExactMatch], ignore_errors: true, timeout: 50)

      assert [cancelled, drafted] = test_run.test_cases
      assert cancelled.trace["status"] == "ERRORED"

      assert [%{"error" => "DeepEvalError: Task was cancelled (likely due to timeout)."}] =
               plain(cancelled.trace["agentSpans"])

      assert drafted.trace["status"] == "SUCCESS"
    end

    test "makes each top-level trace a test case of its own, numbered across the run" do
      task = fn golden ->
        Agent.draft(golden.input)
        Agent.draft(golden.input <> " again")
      end

      {_evaluation, test_run, _path} = run!(task, metrics: [ExactMatch], ignore_errors: true)

      assert Enum.map(test_run.test_cases, & &1.order) == [0, 1, 2, 3]
      assert Enum.map(test_run.test_cases, & &1.name) == ~w(refunds refunds invoices invoices)
    end
  end

  describe "run/3 in :sync mode" do
    test "keeps the wrapper's first child as the golden's one test case" do
      task = fn golden ->
        Agent.draft(golden.input)
        Agent.draft(golden.input <> " again")
      end

      {_evaluation, test_run, _path} =
        run!(task, mode: :sync, metrics: [ExactMatch], ignore_errors: true)

      assert [refunds, invoices] = test_run.test_cases
      assert {refunds.order, invoices.order} == {1, 2}
      assert refunds.input == "refunds"
      assert refunds.actual_output == nil
      assert [%{"input" => %{"query" => "refunds"}} = span] = plain(refunds.trace["llmSpans"])
      refute Map.has_key?(span, "parentUuid")
    end

    test "raises what the task raises" do
      assert_raise RuntimeError, "agent gave up", fn ->
        run!(&Agent.fail(&1.input), mode: :sync, metrics: [ExactMatch])
      end
    end
  end

  describe "the run" do
    test "logs the LLM spans' prompts, with empty hyperparameters" do
      {_evaluation, test_run, _path} =
        run!(&Agent.draft(&1.input), metrics: [ExactMatch], ignore_errors: true)

      assert test_run.hyperparameters == []

      assert [prompt] = test_run.prompts

      assert prompt.values == [
               {"alias", "draft"},
               {"version", "1"},
               {"interpolation_type", "FSTRING"}
             ]
    end

    test "given hyperparameters replace the logged prompts" do
      {_evaluation, test_run, _path} =
        run!(&Agent.draft(&1.input),
          metrics: [ExactMatch],
          ignore_errors: true,
          hyperparameters: [model: "gpt-4o"]
        )

      assert test_run.hyperparameters == [{"model", "gpt-4o"}]
      assert test_run.prompts == []
    end

    test "has neither without logged prompts" do
      {_evaluation, test_run, _path} =
        run!(&Agent.fail(&1.input), metrics: [ExactMatch], ignore_errors: true)

      assert {test_run.hyperparameters, test_run.prompts} == {nil, []}
    end

    test "takes a dataset's goldens, alias, id and version" do
      dataset = EvaluationDataset.new(@goldens, alias: "support", id: "ds-1", version: "3")

      {_evaluation, %TestRun{} = test_run, _path} =
        run!(dataset, &Agent.draft(&1.input), metrics: [ExactMatch], ignore_errors: true)

      assert {test_run.dataset_alias, test_run.dataset_id, test_run.dataset_version} ==
               {"support", "ds-1", "3"}

      assert length(test_run.test_cases) == 2
    end
  end

  describe "errors" do
    test "no goldens" do
      assert_raise ArgumentError, "Unable to evaluate dataset with no goldens.", fn ->
        run!([], &Agent.draft(&1.input), [])
      end
    end

    test "an unknown mode" do
      assert_raise ArgumentError, "unknown mode :later", fn ->
        run!(&Agent.draft(&1.input), mode: :later)
      end
    end

    for mode <- [:async, :sync] do
      test "no metric anywhere (#{mode})" do
        message =
          "evals_iterator was started but no metrics were declared anywhere. " <>
            "An evaluation run with zero metric sources cannot produce results.\n"

        assert_raise DeepEvalError, message, fn ->
          run!(&Agent.draft(&1.input), mode: unquote(mode))
        end
      end
    end

    test "a metric error, unless ignore_errors" do
      assert_raise DeepEvalEx.MissingTestCaseParamsError, fn ->
        run!(&Agent.draft(&1.input), metrics: [ExactMatch])
      end
    end
  end

  test "DeepEvalEx.evaluate_traced/3 returns the evaluation result and prints nothing" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        send(
          self(),
          DeepEvalEx.evaluate_traced(@goldens, &Agent.draft(&1.input),
            metrics: [ExactMatch],
            ignore_errors: true
          )
        )
      end)

    assert output == ""
    assert_received %EvaluationResult{test_results: [_, _]}
  end
end
