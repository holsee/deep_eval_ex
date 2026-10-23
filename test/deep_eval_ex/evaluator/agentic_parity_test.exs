defmodule DeepEvalEx.Evaluator.AgenticParityTest do
  @moduledoc """
  Evaluates the traces the traced fixtures' agent scripts capture with
  `DeepEvalEx.Evaluator.Agentic.evaluate/3`, in both of the iterator's
  modes, and compares the test run they make, byte for byte after the
  fixtures' normalisation, with the one deepeval 4.3.1's `evals_iterator`
  wrote (`test_run_sync.json`, `test_run_async.json`): every test case
  with its trace, buckets in walk order, span and trace metric data,
  statuses and errors, and the run's `metricsScores`,
  `traceMetricsScores`, pass and fail counts and cost.

  The sync iterator's traces are captured inside its wrapper span and
  rebuilt with `DeepEvalEx.Tracing.Tree.build/3`'s `mode: :sync` strip,
  as deepeval ends them. The run's `prompts` and `hyperparameters` and
  the iterator itself (one capture per golden, the uncaught error's
  marking) are `evaluate_traced/3`'s, so `raised_uncaught` is left to
  `DeepEvalEx.Evaluator.TracedParityTest`;
  `requires_trace` declares metrics ported by later units.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Evaluator.Agentic
  alias DeepEvalEx.Test.{TracedFixtures, TracingScenarios}
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.{Span, Tree}
  alias Jason.OrderedObject

  @moduletag :parity

  @compared ~w(testCases metricsScores traceMetricsScores testPassed testFailed evaluationCost)

  @wrapper "__deepeval_internal_pytest_test_wrapper__"

  @skipped ["raised_uncaught", "requires_trace"]

  for scenario <- TracedFixtures.scenarios(),
      scenario not in @skipped,
      mode <- ["sync", "async"] do
    @external_resource Path.join([TracedFixtures.dir(), scenario, "test_run_#{mode}.json"])

    test "evaluates #{scenario} as deepeval's #{mode} evals_iterator" do
      scenario = unquote(scenario)
      mode = unquote(mode)
      input = TracedFixtures.load!(scenario, "input.json")
      metrics = Enum.map(input["metrics"] || [], &TracingScenarios.metric/1)

      test_cases =
        scenario
        |> captured(input, mode)
        |> Enum.with_index()
        |> Enum.map(fn {{trace, golden}, index} ->
          index = if mode == "sync", do: golden.index + 1, else: index

          %{test_case: test_case} =
            Agentic.evaluate(trace, golden.golden,
              mode: String.to_existing_atom(mode),
              metrics: metrics,
              index: index,
              ignore_errors: true
            )

          test_case
        end)

      evaluated = test_cases |> TestRun.from_test_cases() |> TestRun.to_map() |> compared()

      expected =
        scenario
        |> TracedFixtures.load!("test_run_#{mode}.json")
        |> compared()

      assert TracedFixtures.normalise(JSON.encode!(evaluated, indent: 2)) ==
               TracedFixtures.normalise(JSON.encode!(expected, indent: 2))
    end
  end

  test "covers every traced scenario but the ones left to later units" do
    for scenario <- TracedFixtures.scenarios() -- @skipped do
      input = TracedFixtures.load!(scenario, "input.json")
      assert TracingScenarios.supported_metrics?(input), scenario
      assert input["modes"] == ["sync", "async"], scenario
    end
  end

  defp compared(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, key in @compared, do: {key, value})

  # [{trace, %{golden: golden, index: i}}] for every trace captured, in
  # order. Sync runs each golden's steps inside the iterator's wrapper span.
  defp captured(scenario, input, "async") do
    for {traces, golden} <- Enum.zip(TracingScenarios.run_app(scenario, input), goldens(input)),
        trace <- traces,
        do: {trace, golden}
  end

  defp captured(scenario, input, "sync") do
    module = TracingScenarios.compile(scenario)

    for golden <- goldens(input) do
      {nil, [trace]} =
        Tracing.capture([], fn ->
          Tracing.span(:base, [name: @wrapper, input: %{}], fn ->
            TracingScenarios.run_steps(module, input["app"], %{"input" => golden.golden.input})
            nil
          end)
        end)

      {Tree.build(%{trace | root_spans: []}, flatten(trace.root_spans), mode: :sync), golden}
    end
  end

  defp goldens(input) do
    input["goldens"]
    |> Enum.with_index()
    |> Enum.map(fn {golden, index} ->
      %{
        golden: %Golden{
          input: golden["input"],
          expected_output: golden["expected_output"],
          name: golden["name"]
        },
        index: index
      }
    end)
  end

  defp flatten(spans),
    do: Enum.flat_map(spans, fn %Span{} = span -> [span | flatten(span.children)] end)
end
