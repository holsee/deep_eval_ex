defmodule DeepEvalEx.Tracing.TimeTest do
  # Not async: the clock tests change the :tracing application config.
  use ExUnit.Case, async: false

  alias DeepEvalEx.Tracing.Time

  doctest DeepEvalEx.Tracing.Time

  @iso_table "test/fixtures/deepeval/traced/iso_table.json"
             |> File.read!()
             |> Jason.decode!()

  describe "to_zod_iso/2 matches deepeval's to_zod_compatible_iso" do
    test "truncates to milliseconds by default" do
      for %{"epoch_us" => epoch_us, "milliseconds" => expected} <- @iso_table do
        assert Time.to_zod_iso(epoch_us) == expected, "epoch_us #{epoch_us}"
        assert Time.to_zod_iso(epoch_us, :millisecond) == expected, "epoch_us #{epoch_us}"
      end
    end

    test "keeps microseconds for tokenTimes keys" do
      for %{"epoch_us" => epoch_us, "microseconds" => expected} <- @iso_table do
        assert Time.to_zod_iso(epoch_us, :microsecond) == expected, "epoch_us #{epoch_us}"
      end
    end
  end

  describe "now_us/0" do
    setup do
      previous = Application.fetch_env(:deep_eval_ex, :tracing)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:deep_eval_ex, :tracing, value)
          :error -> Application.delete_env(:deep_eval_ex, :tracing)
        end
      end)
    end

    test "reads the system clock in microseconds by default" do
      Application.delete_env(:deep_eval_ex, :tracing)
      before = System.os_time(:microsecond)
      now = Time.now_us()
      assert before <= now and now <= System.os_time(:microsecond)
    end

    test "reads an injected clock" do
      Application.put_env(:deep_eval_ex, :tracing, clock: {__MODULE__, :fixed_clock})
      assert Time.now_us() == 1_700_000_000_123_456

      Application.put_env(:deep_eval_ex, :tracing, clock: fn -> 42 end)
      assert Time.now_us() == 42
    end
  end

  def fixed_clock, do: 1_700_000_000_123_456
end
