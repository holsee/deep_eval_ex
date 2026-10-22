defmodule DeepEvalEx.Metrics.BaseMetricSystemOneTest do
  # The metrics below send what they see to the test process.
  use ExUnit.Case, async: true

  alias DeepEvalEx.{DeepEvalError, Evaluator, Result, TestCase, TestRun}
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Context, Ledger, Model}

  defmodule Probe do
    @moduledoc false
    # A metric with a whole-chain form that reports its System One context
    # and records what its options tell it to.
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "Probe"

    @impl true
    def required_params, do: []

    @impl true
    def system_one_eval_spec(_test_case, _opts), do: nil

    def do_measure(_test_case, opts) do
      if pid = opts[:test_pid], do: send(pid, {:measured, opts[:system_one], Ledger.current()})
      Enum.each(Keyword.get(opts, :confidences, []), &Ledger.record_confidence/1)
      Enum.each(Keyword.get(opts, :fallbacks, []), &Ledger.note_fallback/1)

      {:ok,
       Result.new(
         metric: metric_name(),
         score: Keyword.get(opts, :score, 1.0),
         threshold: Keyword.get(opts, :threshold, default_threshold()),
         confidence: opts[:result_confidence],
         strict_applied: Keyword.get(opts, :strict_applied, false)
       )}
    end
  end

  defmodule DecisionsOnly do
    @moduledoc false
    # A metric without system_one_eval_spec/2.
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "DecisionsOnly"

    @impl true
    def required_params, do: []

    def do_measure(_test_case, opts) do
      send(opts[:test_pid], {:measured, opts[:system_one], nil})
      {:ok, Result.new(metric: metric_name(), score: 1.0)}
    end
  end

  defmodule CountingAdapter do
    @moduledoc false
    # Reports every init/1 to the test process.
    use DeepEvalEx.SystemOne.Adapter

    @impl true
    def model_name(_opts), do: "counting"

    @impl true
    def init(opts) do
      send(opts[:test_pid], :init)
      {:ok, opts}
    end

    @impl true
    def decide(_state, _questions, _opts), do: {:ok, %DeepEvalEx.SystemOne.Answers{}, nil}
  end

  defp test_case(name \\ "case"), do: TestCase.new!(input: "Q", actual_output: "A", name: name)

  describe "measure/2 System One state" do
    test "puts the measure's confidence and fallback reason on the result" do
      assert {:ok, %Result{} = result} =
               Probe.measure(test_case(),
                 confidences: [0.9, 0.19999999999999996],
                 fallbacks: ["ConnectionError: Jev is down", "timeout (slow)"]
               )

      assert result.confidence == 0.19999999999999996

      assert result.system_one_fallback_reason ==
               "ConnectionError: Jev is down; timeout (slow)"
    end

    test "without System One calls both stay nil" do
      assert {:ok, %Result{confidence: nil, system_one_fallback_reason: nil}} =
               Probe.measure(test_case(), [])
    end

    test "keeps a confidence the metric set itself when the ledger has none" do
      assert {:ok, %Result{confidence: 0.4}} = Probe.measure(test_case(), result_confidence: 0.4)

      assert {:ok, %Result{confidence: 0.1}} =
               Probe.measure(test_case(), result_confidence: 0.4, confidences: [0.1])
    end

    test "every measure starts from a fresh ledger and leaves the caller's alone" do
      {_, outer} =
        Ledger.track(fn ->
          Ledger.record_confidence(0.05)
          Ledger.note_fallback("outer")
          Ledger.disable()

          assert {:ok, %Result{confidence: 0.5}} =
                   Probe.measure(test_case(), test_pid: self(), confidences: [0.5])

          assert_received {:measured, _context, %Ledger{} = inner}
          assert inner == %Ledger{}

          assert {:ok, %Result{confidence: nil, system_one_fallback_reason: nil}} =
                   Probe.measure(test_case(), [])
        end)

      assert outer == %Ledger{confidence: 0.05, fallback_reasons: ["outer"], disabled?: true}
    end
  end

  describe "measure/2 System One context" do
    test "do_measure/2 gets the resolved context in opts[:system_one]" do
      Probe.measure(test_case(), test_pid: self(), eval_mode: :llm)
      assert_received {:measured, %Context{mode: :llm, model: nil, llm?: true}, _}

      Probe.measure(test_case(),
        test_pid: self(),
        eval_mode: :system_one,
        system_one_model: Mock.new(model: "fake-jev")
      )

      assert_received {:measured,
                       %Context{mode: :system_one, llm?: false, model: %Model{name: "fake-jev"}},
                       _}
    end

    test "a metric without system_one_eval_spec/2 runs :system_one as :hybrid" do
      DecisionsOnly.measure(test_case(),
        test_pid: self(),
        eval_mode: :system_one,
        system_one_model: Mock.new()
      )

      assert_received {:measured, %Context{mode: :hybrid, llm?: true}, _}
    end

    test "a System One model whose init/1 fails raises before do_measure/2 runs" do
      assert_raise DeepEvalError, ~r/routes metric decisions to toy-v1/, fn ->
        Probe.measure(test_case(),
          test_pid: self(),
          eval_mode: :hybrid,
          system_one_model: DeepEvalEx.Test.SystemOneToy
        )
      end

      refute_received {:measured, _, _}
    end
  end

  describe "strict_applied" do
    test "a result that applied strict mode itself keeps its float 0.0" do
      assert {:ok, %Result{} = result} =
               Probe.measure(test_case(), score: 0.0, strict_mode: true, strict_applied: true)

      assert result.score === 0.0
      assert result.success == false
      assert result.strict_mode
    end

    test "is kept through the Evaluator" do
      [[result]] =
        Evaluator.evaluate([test_case()], [Probe],
          score: 0.0,
          strict_mode: true,
          strict_applied: true
        )

      assert result.score === 0.0
    end

    test "otherwise strict mode clamps the score to the integer 0" do
      assert {:ok, %Result{} = result} =
               Probe.measure(test_case(), score: 0.0, strict_mode: true)

      assert result.score === 0
    end
  end

  describe "Evaluator preflight" do
    test "a misconfigured System One model raises before any metric runs" do
      assert_raise DeepEvalError, fn ->
        Evaluator.evaluate([test_case()], [Probe, DecisionsOnly],
          test_pid: self(),
          eval_mode: :hybrid,
          system_one_model: DeepEvalEx.Test.SystemOneToy
        )
      end

      refute_received {:measured, _, _}
    end

    test "raises even with ignore_errors" do
      assert_raise DeepEvalError, fn ->
        Evaluator.evaluate([test_case()], [Probe],
          ignore_errors: true,
          eval_mode: :hybrid,
          system_one_model: DeepEvalEx.Test.SystemOneToy
        )
      end
    end

    test "resolves each metric's context once for the whole run" do
      model = {CountingAdapter, test_pid: self()}

      Evaluator.evaluate([test_case("a"), test_case("b")], [Probe, DecisionsOnly],
        test_pid: self(),
        eval_mode: :system_one,
        system_one_model: model
      )

      assert_received :init
      assert_received :init
      refute_received :init

      for _ <- 1..2 do
        assert_received {:measured, %Context{mode: :system_one, llm?: false}, _}
        assert_received {:measured, %Context{mode: :hybrid, llm?: true}, _}
      end
    end

    test "evaluate_single/3 and evaluate_metric/3 preflight too" do
      opts = [eval_mode: :hybrid, system_one_model: DeepEvalEx.Test.SystemOneToy]

      assert_raise DeepEvalError, fn -> Evaluator.evaluate_single(test_case(), [Probe], opts) end
      assert_raise DeepEvalError, fn -> Evaluator.evaluate_metric(test_case(), Probe, opts) end
    end

    test "a run-level confidence reaches the result" do
      [[result]] = Evaluator.evaluate([test_case()], [Probe], confidences: [0.3])
      assert result.confidence == 0.3
    end
  end

  test "confidence, fallback reason and strict_applied are not exported" do
    {:ok, result} =
      Probe.measure(test_case(), confidences: [0.3], fallbacks: ["x"], strict_applied: true)

    plain = %{result | confidence: nil, system_one_fallback_reason: nil, strict_applied: false}

    assert TestRun.MetricData.from_result(result) == TestRun.MetricData.from_result(plain)
  end
end
