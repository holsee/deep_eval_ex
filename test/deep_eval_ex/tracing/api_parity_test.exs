defmodule DeepEvalEx.Tracing.ApiParityTest do
  @moduledoc """
  Exports the traces the traced fixtures' agent scripts capture with
  `DeepEvalEx.Tracing.Api.trace_api/2` and compares them byte for byte,
  after the fixtures' normalisation, with the TraceApi bodies deepeval
  4.3.1 built outside evaluation (`trace_api.json`): buckets in LIFO
  order, every field in pydantic order, truncated times, the prompt
  fields, token interval keys, normalised providers, dropped spans and
  the unmeasured metric data of each span's metrics.

  `eval_trace_api/2` is compared with the traces of the async
  `evals_iterator`'s test runs (`test_run_async.json`), which capture the
  same traces: everything but the buckets and metric data the evaluation
  walker adds.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.Test.{TracedFixtures, TracingScenarios}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Tracing.Api
  alias Jason.OrderedObject

  @moduletag :parity

  @scenarios TracedFixtures.scenarios()

  test "covers every traced scenario: their metrics are all ported" do
    for scenario <- @scenarios do
      input = TracedFixtures.load!(scenario, "input.json")
      assert TracingScenarios.supported_metrics?(input), scenario
    end
  end

  for scenario <- @scenarios do
    @external_resource Path.join([TracedFixtures.dir(), scenario, "input.json"])
    @external_resource Path.join([TracedFixtures.dir(), scenario, "trace_api.json"])

    test "exports deepeval's TraceApi bodies for #{scenario}" do
      scenario = unquote(scenario)
      input = TracedFixtures.load!(scenario, "input.json")

      exported =
        scenario
        |> TracingScenarios.run_app(input)
        |> List.flatten()
        |> Enum.map(&Api.trace_api/1)
        |> JSON.encode!(indent: 2, ensure_ascii: false)

      expected = TracedFixtures.read!(scenario, "trace_api.json")

      assert TracedFixtures.normalise(exported <> "\n") == TracedFixtures.normalise(expected)
    end
  end

  for scenario <- @scenarios do
    @external_resource Path.join([TracedFixtures.dir(), scenario, "test_run_async.json"])

    test "starts deepeval's evaluated traces for #{scenario}" do
      scenario = unquote(scenario)
      input = TracedFixtures.load!(scenario, "input.json")

      started =
        for {traces, golden} <-
              Enum.zip(TracingScenarios.run_app(scenario, input), input["goldens"]),
            trace <- traces,
            do: Api.eval_trace_api(trace, %Golden{input: golden["input"]})

      expected =
        for test_case <- TracedFixtures.load!(scenario, "test_run_async.json")["testCases"] do
          OrderedObject.new(
            for {key, value} <- test_case["trace"].values, key != "metricsData" do
              if String.ends_with?(key, "Spans"), do: {key, []}, else: {key, value}
            end
          )
        end

      assert TracedFixtures.normalise(JSON.encode!(started, indent: 2)) ==
               TracedFixtures.normalise(JSON.encode!(expected, indent: 2))
    end
  end
end
