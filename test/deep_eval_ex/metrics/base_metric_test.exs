defmodule DeepEvalEx.Metrics.BaseMetricTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.{Result, TestCase}

  doctest BaseMetric, only: [threshold: 2, strict_score: 2]

  defmodule FixedScore do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "FixedScore"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, opts) do
      {:ok,
       Result.new(
         metric: metric_name(),
         score: Keyword.fetch!(opts, :score),
         threshold: Keyword.get(opts, :threshold, default_threshold())
       )}
    end
  end

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

  defmodule RaisingJudge do
    @moduledoc false

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "BaseMetric RaisingJudge"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, _opts) do
      Usage.record(Usage.new("gpt-4o-mini", 1_000, 200))
      raise ArgumentError, "judge returned invalid JSON"
    end
  end

  defmodule PricedJudge do
    @moduledoc false
    # Records the judge calls opts[:calls] lists, then passes.

    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "PricedJudge"

    @impl true
    def required_params, do: [:input]

    @impl true
    defdelegate evaluation_model(opts), to: DeepEvalEx.LLM.Adapter, as: :model_name

    def do_measure(_test_case, opts) do
      Usage.record_all(Keyword.get(opts, :calls, []))
      {:ok, Result.new(metric: metric_name(), score: 1.0)}
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

    test "an exception raised by the metric propagates from measure/2" do
      assert_raise ArgumentError, "judge returned invalid JSON", fn ->
        RaisingJudge.measure(test_case(), [])
      end
    end

    test "usage spent before an exception is passed on to the enclosing scope" do
      {_raised, usages} =
        Usage.track(fn ->
          try do
            RaisingJudge.measure(test_case(), [])
          rescue
            ArgumentError -> :raised
          end
        end)

      assert [%Usage{model: "gpt-4o-mini", input_tokens: 1_000}] = usages
    end

    test "usage of an errored measurement is passed on to the enclosing scope" do
      assert {{:error, :bad_json}, [%Usage{model: "gpt-4o-mini", input_tokens: 1_000}]} =
               Usage.track(fn -> JudgeThenFail.measure(test_case(), []) end)
    end
  end

  # deepeval's prepare_measure seeds evaluation_cost and the token counts
  # with 0 for a native judge and None for a custom one.
  describe "measure/2 cost seed" do
    test "a native judge that made no call reports zero cost and tokens" do
      assert {:ok,
              %Result{
                evaluation_model: "gpt-4o",
                evaluation_cost: +0.0,
                input_tokens: 0,
                output_tokens: 0
              }} = NoCallJudge.measure(test_case(), adapter: :openai, model: "gpt-4o")
    end

    test "a native judge's priced calls add up from zero" do
      calls = [Usage.new("gpt-4o-mini", 1_000, 200), Usage.new("gpt-4o-mini", 0, 0)]

      assert {:ok, %Result{input_tokens: 1_000, output_tokens: 200} = result} =
               PricedJudge.measure(test_case(),
                 adapter: :openai,
                 model: "gpt-4o-mini",
                 calls: calls
               )

      assert_in_delta result.evaluation_cost, (1_000 * 0.15 + 200 * 0.60) / 1_000_000, 1.0e-12
    end

    test "a custom judge has no cost, even for priced calls, but keeps its tokens" do
      calls = [Usage.new("gpt-4o-mini", 1_000, 200)]

      assert {:ok,
              %Result{
                evaluation_model: "gpt-4o-mini",
                evaluation_cost: nil,
                input_tokens: 1_000,
                output_tokens: 200
              }} = PricedJudge.measure(test_case(), adapter: :mock, calls: calls)

      assert {:ok, %Result{evaluation_cost: nil, input_tokens: nil, output_tokens: nil}} =
               NoCallJudge.measure(test_case(), adapter: :mock)
    end

    test "a metric without a judge is not seeded" do
      assert {{:ok, %Result{evaluation_cost: nil, input_tokens: nil}}, []} =
               Usage.track(fn -> FixedScore.measure(test_case(), adapter: :openai, score: 1) end)
    end

    test "a test case missing params is rejected before the seed" do
      assert {{:error, {:missing_params, [:input]}}, []} =
               Usage.track(fn ->
                 PricedJudge.measure(%TestCase{actual_output: "A"}, adapter: :openai)
               end)
    end

    test "is passed on to the enclosing scope as a :seed usage" do
      assert {{:ok, _result}, [%Usage{source: :seed, cost: +0.0}]} =
               Usage.track(fn -> NoCallJudge.measure(test_case(), adapter: :openai) end)
    end
  end

  describe "measure/2 strict mode, score-only and flaky" do
    test "strict_mode forces the threshold to the integer 1, as deepeval's constructors do" do
      assert {:ok, %Result{score: 1.0, threshold: 1, success: true, strict_mode: true} = result} =
               FixedScore.measure(test_case(), score: 1.0, threshold: 0.3, strict_mode: true)

      assert result.threshold === 1
    end

    test "strict_mode clamps a score below the threshold to the integer 0" do
      assert {:ok, %Result{threshold: 1, success: false} = result} =
               FixedScore.measure(test_case(), score: 0.9, strict_mode: true)

      assert result.score === 0
    end

    test "without strict_mode the threshold and score are kept" do
      assert {:ok, %Result{score: 0.9, threshold: 0.5, success: true, strict_mode: false}} =
               FixedScore.measure(test_case(), score: 0.9)
    end

    test "threshold: nil measures score-only: no success, as deepeval's is_successful" do
      assert {:ok, %Result{score: 0.25, threshold: nil, success: nil}} =
               FixedScore.measure(test_case(), score: 0.25, threshold: nil)
    end

    test "results carry the :flaky option" do
      assert {:ok, %Result{flaky: true}} =
               FixedScore.measure(test_case(), score: 1.0, flaky: true)

      assert {:ok, %Result{flaky: false}} = FixedScore.measure(test_case(), score: 1.0)
    end
  end

  describe "threshold/2" do
    test "is the integer 1 in strict mode, whatever :threshold says" do
      assert BaseMetric.threshold([strict_mode: true, threshold: 0.3], 0.5) === 1
      assert BaseMetric.threshold([strict_mode: true, threshold: nil], 0.5) === 1
    end

    test "is :threshold when given, nil included, else the default" do
      assert BaseMetric.threshold([threshold: 0.3], 0.5) == 0.3
      assert BaseMetric.threshold([threshold: nil], 0.5) == nil
      assert BaseMetric.threshold([], 0.5) == 0.5
      assert BaseMetric.threshold([strict_mode: false], 1) === 1
    end
  end

  describe "strict_score/2" do
    test "clamps a score below the threshold to the integer 0 in strict mode only" do
      assert BaseMetric.strict_score(0.5, strict_mode: true, threshold: 1) === 0
      assert BaseMetric.strict_score(1.0, strict_mode: true, threshold: 1) === 1.0
      assert BaseMetric.strict_score(0.5, strict_mode: false, threshold: 1) === 0.5
      assert BaseMetric.strict_score(0.5, threshold: 1) === 0.5
    end

    test "leaves a score-only or missing score alone" do
      assert BaseMetric.strict_score(0.5, strict_mode: true, threshold: nil) === 0.5
      assert BaseMetric.strict_score(nil, strict_mode: true, threshold: 1) == nil
    end
  end

  describe "[:deep_eval_ex, :metric, :exception] measurements" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:deep_eval_ex, :metric, :exception],
        fn _event, measurements, %{metric: metric} = metadata, _config ->
          send(test_pid, {:exception, metric, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "carry the tokens and cost spent before the error" do
      JudgeThenFail.measure(test_case(), [])

      assert_receive {:exception, "BaseMetric JudgeThenFail",
                      %{input_tokens: 1_000, output_tokens: 200, cost: cost}, _metadata}

      assert_in_delta cost, (1_000 * 0.15 + 200 * 0.60) / 1_000_000, 1.0e-12
    end

    test "are emitted for a raised exception, with the exception as the error" do
      assert_raise ArgumentError, fn -> RaisingJudge.measure(test_case(), []) end

      assert_receive {:exception, "BaseMetric RaisingJudge", %{input_tokens: 1_000},
                      %{error: %ArgumentError{message: "judge returned invalid JSON"}}}
    end
  end
end
