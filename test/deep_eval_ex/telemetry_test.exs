defmodule DeepEvalEx.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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
end
