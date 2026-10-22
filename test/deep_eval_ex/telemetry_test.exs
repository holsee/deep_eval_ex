defmodule DeepEvalEx.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Batch, Context, Decision, Error, EvalSpec, Model, Scored, Spec}
  alias DeepEvalEx.Telemetry

  describe "handle_event/4 for metric stop" do
    test "logs an errored result, which has no score, without raising" do
      log = capture_log([level: :debug], fn -> stop_event(nil) end)

      assert log =~ "score: none (errored)"
    end

    test "logs a scored result rounded to three places" do
      log = capture_log([level: :debug], fn -> stop_event(0.12345) end)

      assert log =~ "score: 0.123"
    end
  end

  defp stop_event(score) do
    Telemetry.handle_event(
      [:deep_eval_ex, :metric, :stop],
      %{duration: 5, score: score},
      %{metric: "GEval"},
      nil
    )
  end

  describe "[:deep_eval_ex, :metric, :stop] measurements" do
    defmodule UsageMetric do
      use DeepEvalEx.Metrics.BaseMetric

      alias DeepEvalEx.LLM.Adapter

      @impl true
      def metric_name, do: "Telemetry Usage Metric"

      @impl true
      def required_params, do: []

      def do_measure(_test_case, opts) do
        if Keyword.get(opts, :call_llm, true) do
          {:ok, _} = Adapter.generate("judge", opts)
        end

        {:ok, Result.new(metric: metric_name(), score: 1.0)}
      end
    end

    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:deep_eval_ex, :metric, :stop],
        fn _event, measurements, %{metric: "Telemetry Usage Metric"}, _config ->
          send(test_pid, {:stop, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "include token counts when the metric made LLM calls" do
      opts = [adapter: :mock, mock_usage: [input_tokens: 12, output_tokens: 3]]

      assert {:ok, _} = UsageMetric.measure(%DeepEvalEx.TestCase{input: "Q"}, opts)
      assert_received {:stop, measurements}
      assert %{input_tokens: 12, output_tokens: 3, score: 1.0} = measurements
      # mock-model has no price, so no cost is reported
      refute Map.has_key?(measurements, :cost)
    end

    test "omit usage when the metric made no LLM calls" do
      assert {:ok, _} = UsageMetric.measure(%DeepEvalEx.TestCase{input: "Q"}, call_llm: false)
      assert_received {:stop, measurements}
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :score]
    end
  end

  describe "System One events" do
    defmodule Judged do
      @moduledoc false
      # A whole-chain metric whose spec comes from opts[:test_spec].
      use DeepEvalEx.Metrics.BaseMetric

      alias DeepEvalEx.SystemOne.Runner

      @impl true
      def metric_name, do: "Telemetry Judged"

      @impl true
      def required_params, do: []

      @impl true
      def system_one_eval_spec(_test_case, opts), do: Keyword.get(opts, :test_spec)

      def do_measure(test_case, opts) do
        {:ok, result} = Runner.run(__MODULE__, test_case, opts)
        {:ok, result}
      end
    end

    @test_case %DeepEvalEx.TestCase{input: "Q?", actual_output: "A."}

    @jev_down %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}
      # Handlers are global and other tests run concurrently, so each test
      # names its own System One model and only its events come back.
      model = "telemetry-jev-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:deep_eval_ex, :system_one, :request, :start],
          [:deep_eval_ex, :system_one, :request, :stop],
          [:deep_eval_ex, :system_one, :fallback]
        ],
        fn event, measurements, metadata, _config ->
          if metadata[:model] == model or metadata[:metric] == model,
            do: send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      %{model: model}
    end

    defp spec(statement) do
      %EvalSpec{evaluation_params: [:input], questions: [%Scored.Noul{statement: statement}]}
    end

    test "span an unbatched whole-chain request with its metric", %{model: model} do
      mock = Mock.new(model: model, answer_fn: Mock.noul_answers(0.8), cost: {4.2e-05, 1000, 0})

      opts = [eval_mode: :system_one, system_one_model: mock, test_spec: spec("S")]
      assert {:ok, _} = Judged.measure(@test_case, opts)

      assert_received {[:deep_eval_ex, :system_one, :request, :start], _, start_meta}

      assert %{
               model: ^model,
               mode: :system_one,
               metrics: ["Telemetry Judged"],
               question_count: 1,
               batched?: false
             } = start_meta

      assert_received {[:deep_eval_ex, :system_one, :request, :stop], measurements, _}
      assert %{duration: _, input_tokens: 1000, output_tokens: 0, cost: 4.2e-05} = measurements
    end

    test "span one batched request for every metric it decides for", %{model: model} do
      mock = Mock.new(model: model, answer_fn: Mock.noul_answers(0.8))

      entries =
        for statement <- ["S1", "S2"] do
          opts = [eval_mode: :system_one, system_one_model: mock, test_spec: spec(statement)]
          {Judged, Keyword.put(opts, :system_one, Context.resolve!(Judged, opts))}
        end

      Batch.prefetch(@test_case, entries)

      assert_received {[:deep_eval_ex, :system_one, :request, :start], _, start_meta}

      assert %{
               mode: :system_one,
               metrics: ["Telemetry Judged", "Telemetry Judged"],
               question_count: 2,
               batched?: true
             } = start_meta

      assert_received {[:deep_eval_ex, :system_one, :request, :stop], _, _}
      refute_received {[:deep_eval_ex, :system_one, :request, :start], _, _}
    end

    test "emit a fallback with the metric and reason when a hybrid decision falls back",
         %{model: model} do
      mock = Mock.new(model: model, raises: @jev_down)
      spec = %Spec.Binary{instructions: "`input` is a question.", state: [input: "Q?"]}
      context = %Context{mode: :hybrid, model: Model.resolve(mock), llm?: true}

      assert Decision.probability(spec, system_one: context, metric_name: model) == :llm

      assert_received {[:deep_eval_ex, :system_one, :request, :start], _,
                       %{mode: :hybrid, metrics: [^model], batched?: false}}

      assert_received {[:deep_eval_ex, :system_one, :request, :stop], _, %{error: @jev_down}}

      assert_received {[:deep_eval_ex, :system_one, :fallback], %{system_time: _},
                       %{metric: ^model, reason: "ConnectionError: Jev is down"}}
    end

    test "emit no fallback when a System One error fails the metric", %{model: model} do
      context = %Context{mode: :system_one, model: Model.resolve(Mock.new()), llm?: false}

      assert_raise Error, fn ->
        Decision.handle_failure(@jev_down, system_one: context, metric_name: model)
      end

      refute_received {[:deep_eval_ex, :system_one, :fallback], _, _}
    end
  end

  describe "handle_event/4 for System One events" do
    test "logs a request with its model, metrics and duration" do
      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:deep_eval_ex, :system_one, :request, :stop],
            %{duration: System.convert_time_unit(12, :millisecond, :native)},
            %{model: "jev-1", metrics: ["Faithfulness", "Hallucination"], question_count: 3},
            nil
          )
        end)

      assert log =~
               "System One request: jev-1, 3 questions for Faithfulness, Hallucination, duration: 12ms"
    end

    test "logs a failed request with its error" do
      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:deep_eval_ex, :system_one, :request, :stop],
            %{duration: 0},
            %{
              model: "jev-1",
              metrics: ["Faithfulness"],
              question_count: 1,
              error: %Error{reason: :connection, type: "ConnectionError", message: "down"}
            },
            nil
          )
        end)

      assert log =~ "System One request failed: jev-1, Faithfulness, ConnectionError: down"
    end

    test "logs a fallback with its metric and reason" do
      log =
        capture_log(fn ->
          Telemetry.handle_event(
            [:deep_eval_ex, :system_one, :fallback],
            %{system_time: 0},
            %{metric: "Faithfulness", reason: "ConnectionError: Jev is down"},
            nil
          )
        end)

      assert log =~ "Faithfulness fell back to the LLM: ConnectionError: Jev is down"
    end

    test "are attached by the default logger" do
      on_exit(fn -> Telemetry.detach_default_logger() end)
      :ok = Telemetry.attach_default_logger()

      handled =
        for %{id: "deep-eval-ex-default-logger", event_name: event} <-
              :telemetry.list_handlers([:deep_eval_ex, :system_one]),
            do: event

      assert Enum.sort(handled) == [
               [:deep_eval_ex, :system_one, :fallback],
               [:deep_eval_ex, :system_one, :request, :exception],
               [:deep_eval_ex, :system_one, :request, :stop]
             ]
    end
  end
end
