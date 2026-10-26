defmodule DeepEvalEx.Metrics.BaseConversationalMetricTest do
  # The metrics below send what they see to the test process.
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, MetricError, MissingTestCaseParamsError}
  alias DeepEvalEx.{Result, TestCase}
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Context, Ledger}

  defmodule Probe do
    @moduledoc false
    # A conversational metric with a whole-chain form that reports what it
    # measured with.
    use DeepEvalEx.Metrics.BaseConversationalMetric

    @impl true
    def metric_name, do: "Conversational Probe"

    @impl true
    def required_params, do: [:role, :content, :scenario]

    @impl true
    def system_one_eval_spec(_test_case, _opts), do: nil

    def do_measure(test_case, opts) do
      if pid = opts[:test_pid], do: send(pid, {:measured, test_case, opts[:system_one]})
      Enum.each(Keyword.get(opts, :confidences, []), &Ledger.record_confidence/1)

      {:ok,
       Result.new(
         metric: metric_name(),
         score: Keyword.get(opts, :score, 1.0),
         threshold: Keyword.get(opts, :threshold, default_threshold())
       )}
    end
  end

  defmodule RoleProbe do
    @moduledoc false
    # deepeval's `_requires_chatbot_role = True` (RoleAdherenceMetric).
    use DeepEvalEx.Metrics.BaseConversationalMetric,
      default_threshold: 0.7,
      requires_chatbot_role: true

    @impl true
    def metric_name, do: "Role Probe"

    @impl true
    def required_params, do: [:role, :content]

    @impl true
    def system_one?, do: false

    def do_measure(_test_case, opts) do
      send(opts[:test_pid], {:measured, opts[:system_one]})

      {:ok,
       Result.new(
         metric: metric_name(),
         score: 0.5,
         threshold: Keyword.get(opts, :threshold, default_threshold())
       )}
    end
  end

  defp conversation(attrs \\ []) do
    ConversationalTestCase.new!(
      Keyword.merge(
        [
          scenario: "A refund request",
          turns: [%{role: :user, content: "Refund me"}, %{role: :assistant, content: "Sure"}]
        ],
        attrs
      )
    )
  end

  describe "use" do
    test "requires_chatbot_role?/0 defaults to false" do
      refute Probe.requires_chatbot_role?()
      assert RoleProbe.requires_chatbot_role?()
    end

    test "default_threshold/0 defaults to 0.5" do
      assert Probe.default_threshold() == 0.5
      assert RoleProbe.default_threshold() == 0.7
    end
  end

  describe "validate_test_case/1" do
    test "checks the metric's required params" do
      assert Probe.validate_test_case(conversation()) == :ok

      assert Probe.validate_test_case(conversation(scenario: nil)) ==
               {:error, {:missing_conversational_param, :scenario}}
    end

    test "checks the chatbot role of a metric that requires it" do
      assert RoleProbe.validate_test_case(conversation()) ==
               {:error, {:missing_conversational_param, :chatbot_role}}

      assert RoleProbe.validate_test_case(conversation(chatbot_role: "A clerk")) == :ok
    end

    test "rejects a single-turn test case" do
      test_case = TestCase.new!(input: "Q", actual_output: "A")
      assert Probe.validate_test_case(test_case) == {:error, :not_conversational_test_case}
    end
  end

  describe "measure/2" do
    test "measures a valid conversation with strict mode and the System One context" do
      test_case = conversation()

      assert {:ok, %Result{} = result} =
               Probe.measure(test_case,
                 test_pid: self(),
                 score: 0.4,
                 strict_mode: true,
                 eval_mode: :system_one,
                 system_one_model: Mock.new(),
                 confidences: [0.9, 0.3]
               )

      assert_received {:measured, ^test_case, %Context{mode: :system_one, llm?: false}}
      assert result.score == 0
      assert result.threshold == 1
      assert result.strict_mode
      assert result.confidence == 0.3
      assert result.evaluation_model == "fake-jev"
      assert result.evaluation_cost == 0
    end

    test "a metric without a whole-chain form runs :system_one as :hybrid" do
      defmodule NoSpec do
        @moduledoc false
        use DeepEvalEx.Metrics.BaseConversationalMetric

        @impl true
        def metric_name, do: "No Spec"

        @impl true
        def required_params, do: []

        def do_measure(_test_case, opts) do
          send(opts[:test_pid], {:measured, opts[:system_one]})
          {:ok, Result.new(metric: metric_name(), score: 1.0)}
        end
      end

      assert {:ok, _result} =
               NoSpec.measure(conversation(),
                 test_pid: self(),
                 eval_mode: :system_one,
                 system_one_model: Mock.new()
               )

      assert_received {:measured, %Context{mode: :hybrid, llm?: true}}
    end

    test "a metric that takes no part in System One measures as under :llm" do
      assert {:ok, %Result{score: 0.5, threshold: 0.7}} =
               RoleProbe.measure(conversation(chatbot_role: "A clerk"),
                 test_pid: self(),
                 eval_mode: :system_one
               )

      assert_received {:measured, %Context{mode: :llm, llm?: true}}
    end

    test "returns the missing param without measuring" do
      assert Probe.measure(conversation(scenario: nil), test_pid: self()) ==
               {:error, {:missing_conversational_param, :scenario}}

      refute_received {:measured, _test_case, _context}
    end
  end

  describe "errors through the Evaluator" do
    test "a missing param raises deepeval's MissingTestCaseParamsError" do
      error =
        assert_raise MissingTestCaseParamsError, fn ->
          Evaluator.evaluate_metric(conversation(), RoleProbe, test_pid: self())
        end

      assert error.message ==
               "'chatbot_role' in a conversational test case cannot be empty for the " <>
                 "'Role Probe' metric."
    end

    test "is skipped with skip_on_missing_params" do
      result =
        Evaluator.evaluate_metric(conversation(scenario: nil), Probe,
          skip_on_missing_params: true
        )

      assert result.skipped
    end

    test "is recorded with ignore_errors" do
      result =
        Evaluator.evaluate_metric(conversation(scenario: nil), Probe, ignore_errors: true)

      assert result.error ==
               "'scenario' in a conversational test case cannot be empty for the " <>
                 "'Conversational Probe' metric."
    end

    test "a single-turn test case is a MetricError, not a missing param" do
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      error =
        assert_raise MetricError, fn ->
          Evaluator.evaluate_metric(test_case, Probe, skip_on_missing_params: true)
        end

      assert error.message ==
               "Unable to evaluate test cases that are not of type 'ConversationalTestCase' " <>
                 "using the conversational 'Conversational Probe' metric."
    end
  end

  describe "Result.error/3 renders deepeval's check_conversational_test_case_params messages" do
    test "for a missing case-level param" do
      assert Result.error("M", {:missing_conversational_param, :expected_outcome}).error ==
               "'expected_outcome' in a conversational test case cannot be empty for the 'M' metric."
    end

    test "for empty turns" do
      assert Result.error("M", :empty_turns).error ==
               "'turns' in conversational test case cannot be empty."
    end

    test "for a provider transcript no turn has" do
      assert Result.error("M", {:no_turn_with, :provider_transcript}).error ==
               "No turn in the conversational test case has a 'provider_transcript', which the " <>
                 "'M' metric needs. Only voice connectors that report the agent's own " <>
                 "transcription of the caller populate it, so a phone call or a text " <>
                 "conversation will never have one."
    end

    test "for audio no turn has" do
      assert Result.error("M", {:no_turn_with, :audio}).error ==
               "No turn in the conversational test case has 'audio', which the 'M' metric " <>
                 "needs. Voice simulations attach each turn's clip as `Turn.audio`; for a " <>
                 "recorded call, cut the recording into one clip per turn and attach them " <>
                 "with `Audio.from_bytes(..., start_time=...)`."
    end
  end
end
