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
end
