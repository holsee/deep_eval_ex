defmodule DeepEvalEx.Metrics.BaseMetricTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.{Result, TestCase}

  defmodule NoCallJudge do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "NoCallJudge"

    @impl true
    def required_params, do: []

    @impl true
    defdelegate evaluation_model(opts), to: DeepEvalEx.LLM.Adapter, as: :model_name

    # Decides without asking the judge, as deepeval's metrics do for
    # trivially empty inputs.
    def do_measure(_test_case, _opts), do: {:ok, Result.new(metric: metric_name(), score: 1.0)}
  end

  defmodule JudgeThenFail do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "BaseMetric JudgeThenFail"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, _opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 200))
      {:error, :bad_json}
    end
  end

  defp test_case, do: TestCase.new!(input: "Q", actual_output: "A")

  describe "measure/2 evaluation model" do
    test "an LLM metric reports its configured judge model even when it made no call" do
      assert {:ok, %Result{evaluation_model: "mock-model", input_tokens: nil}} =
               NoCallJudge.measure(test_case(), adapter: :mock)
    end

    test "the public contract stays {:error, reason} when a metric errors after judge calls" do
      assert {:error, :bad_json} = JudgeThenFail.measure(test_case(), [])
    end

    test "usage of an errored measurement is passed on to the enclosing scope" do
      assert {{:error, :bad_json}, [%Usage{model: "gpt-4o-mini", input_tokens: 1_000}]} =
               Usage.track(fn -> JudgeThenFail.measure(test_case(), []) end)
    end
  end

  describe "[:deep_eval_ex, :metric, :exception] measurements" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:deep_eval_ex, :metric, :exception],
        fn _event, measurements, %{metric: "BaseMetric JudgeThenFail"}, _config ->
          send(test_pid, {:exception, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "carry the tokens and cost spent before the error" do
      JudgeThenFail.measure(test_case(), [])

      assert_receive {:exception, %{input_tokens: 1_000, output_tokens: 200, cost: cost}}
      assert_in_delta cost, (1_000 * 0.15 + 200 * 0.60) / 1_000_000, 1.0e-12
    end
  end
end
