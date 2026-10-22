# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.ExUnitTest do
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.{AnswerRelevancy, ExactMatch, Faithfulness}
  alias DeepEvalEx.{MissingTestCaseParamsError, Result, TestCase}

  # A metric that reports its own failure as an errored result.
  defmodule ErroredMetric do
    @moduledoc false

    def metric_name, do: "ErroredMetric"

    def measure(_test_case, _opts) do
      {:ok, Result.error(metric_name(), "LLM returned invalid JSON", threshold: 0.5)}
    end
  end

  # A metric without a threshold: it scores but neither passes nor fails.
  defmodule ScoreOnlyMetric do
    @moduledoc false

    def metric_name, do: "ScoreOnly"
    def default_threshold, do: nil

    def measure(_test_case, _opts) do
      {:ok, Result.new(metric: metric_name(), score: 0.25, threshold: nil)}
    end
  end

  # A configurable metric that fails, flaky when its struct says so.
  defmodule FailingMetric do
    @moduledoc false

    defstruct threshold: 0.5, flaky: nil

    def metric_name, do: "Failing"

    def measure(_test_case, opts) do
      threshold = Keyword.get(opts, :threshold, 0.5)
      {:ok, Result.new(metric: metric_name(), score: 0.25, threshold: threshold, reason: "Low.")}
    end
  end

  # Reports that it is running to `:test_pid`, then waits to be released, so a
  # test can see which metrics run at once.
  defmodule BlockingMetric do
    @moduledoc false

    defstruct [:name]

    def metric_name, do: "Blocking"
    def metric_name(%__MODULE__{name: name}), do: name

    def measure(_test_case, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:running, Keyword.fetch!(opts, :name), self()})

      receive do
        :release -> {:ok, Result.new(metric: opts[:name], score: 1.0, threshold: 0.5)}
      end
    end
  end

  # Takes longer than any timeout the tests set, then passes.
  # Blocks until released, which no test does: the Evaluator's metric timeout
  # kills it.
  defmodule HangingMetric do
    @moduledoc false

    def metric_name, do: "Hanging"

    def measure(_test_case, _opts) do
      receive do
        :release -> {:ok, Result.new(metric: metric_name(), score: 1.0, threshold: 0.5)}
      end
    end
  end

  defp missing_output_case do
    %TestCase{input: "Question", actual_output: nil, expected_output: "Answer"}
  end

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "assert_passes/2" do
    test "passes when metric evaluation succeeds" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_passes(test_case, ExactMatch)
      assert result.success
      assert result.score == 1.0
    end

    test "fails when metric evaluation fails" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Metrics: Exact Match \(score: 0\.0/, fn ->
        assert_passes(test_case, ExactMatch)
      end
    end

    test "fails with missing params error" do
      test_case = %TestCase{
        input: "Question",
        actual_output: nil,
        expected_output: "Answer"
      }

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch, ignore_errors: true)
        end

      assert error.message =~
               "error: 'actual_output' cannot be None for the 'Exact Match' metric, reason: None"
    end

    test "fails with an empty actual_output error and the missing params hint" do
      test_case = %TestCase{input: "Question", actual_output: "", expected_output: "Answer"}

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch, ignore_errors: true)
        end

      assert error.message =~
               "error: 'actual_output' cannot be empty for the 'Exact Match' metric, reason: None"
    end
  end

  describe "assert_passes/3 with options" do
    test "respects custom threshold" do
      # Mock responses for Faithfulness with correct patterns
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )

      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )

      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )

      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial support."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["Context"]
        )

      # Score of 0.5 passes with threshold 0.5
      result = assert_passes(test_case, Faithfulness, adapter: :mock, threshold: 0.5)
      assert result.score == 0.5

      Mock.clear_responses()

      # Re-mock for higher threshold test
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )

      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )

      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )

      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial support."}
      )

      # Score of 0.5 fails with threshold 0.8
      assert_raise ExUnit.AssertionError, ~r/threshold: 0\.8, strict: False/, fn ->
        assert_passes(test_case, Faithfulness, adapter: :mock, threshold: 0.8)
      end
    end
  end

  describe "assert_fails/2" do
    test "passes when metric evaluation fails" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "5",
          expected_output: "4"
        )

      result = assert_fails(test_case, ExactMatch)
      assert not result.success
      assert result.score == 0.0
    end

    test "fails when metric evaluation passes" do
      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Metric evaluation passed unexpectedly/i, fn ->
        assert_fails(test_case, ExactMatch)
      end
    end
  end

  describe "assert_score/3 with :min" do
    test "passes when score meets minimum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, min: 0.5)
      assert result.score >= 0.5
    end

    test "fails when score is below minimum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score is below minimum/i, fn ->
        assert_score(test_case, ExactMatch, min: 0.5)
      end
    end
  end

  describe "assert_score/3 with :max" do
    test "passes when score is at or below maximum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, max: 0.5)
      assert result.score <= 0.5
    end

    test "fails when score exceeds maximum" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score exceeds maximum/i, fn ->
        assert_score(test_case, ExactMatch, max: 0.5)
      end
    end
  end

  describe "assert_score/3 with :exact" do
    test "passes when score matches exactly" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      result = assert_score(test_case, ExactMatch, exact: 1.0)
      assert result.score == 1.0
    end

    test "fails when score doesn't match" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score does not match expected/i, fn ->
        assert_score(test_case, ExactMatch, exact: 1.0)
      end
    end

    test "respects delta tolerance" do
      # Create a test case that would give a score close to but not exactly 0.5
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )

      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )

      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )

      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["C"]
        )

      # Score of 0.5 should pass with delta 0.01
      result = assert_score(test_case, Faithfulness, [exact: 0.5, delta: 0.01], adapter: :mock)
      assert_in_delta result.score, 0.5, 0.01
    end
  end

  describe "assert_score/3 with :min and :max range" do
    test "passes when score is within range" do
      Mock.set_schema_response(
        ~r/generate a comprehensive list of.*truths/i,
        %{"truths" => ["Truth 1"]}
      )

      Mock.set_schema_response(
        ~r/extract a comprehensive list of FACTUAL/i,
        %{"claims" => ["Claim 1", "Claim 2"]}
      )

      Mock.set_schema_response(
        ~r/indicate whether EACH claim contradicts/i,
        %{"verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "no"}]}
      )

      Mock.set_schema_response(
        ~r/CONCISELY summarize the contradictions/i,
        %{"reason" => "Partial."}
      )

      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "A",
          retrieval_context: ["C"]
        )

      result = assert_score(test_case, Faithfulness, [min: 0.4, max: 0.6], adapter: :mock)
      assert result.score >= 0.4 and result.score <= 0.6
    end

    test "fails when score is outside range" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Score is outside expected range/i, fn ->
        assert_score(test_case, ExactMatch, min: 0.2, max: 0.8)
      end
    end
  end

  describe "assert_evaluation/2" do
    test "passes when all metrics pass" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "4",
          expected_output: "4"
        )

      # ExactMatch will pass with score 1.0
      results = assert_evaluation(test_case, [ExactMatch])
      assert length(results) == 1
      assert Enum.all?(results, & &1.success)
    end

    test "fails when any metric fails" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      assert_raise ExUnit.AssertionError, ~r/Metrics: Exact Match \(.*\) failed\./, fn ->
        assert_evaluation(test_case, [ExactMatch])
      end
    end

    test "fails when metric returns error" do
      test_case = %TestCase{
        input: "Q",
        actual_output: nil,
        expected_output: "A"
      }

      assert_raise ExUnit.AssertionError, ~r/score: None, .* error: 'actual_output'/, fn ->
        assert_evaluation(test_case, [ExactMatch], ignore_errors: true)
      end
    end
  end

  describe "score-only metrics" do
    setup do
      %{test_case: TestCase.new!(input: "Q", actual_output: "4", expected_output: "4")}
    end

    test "assert_evaluation neither passes nor fails on a metric without a threshold",
         %{test_case: test_case} do
      assert [%Result{success: true}, %Result{success: nil}] =
               assert_evaluation(test_case, [ExactMatch, ScoreOnlyMetric])
    end

    test "assert_evaluation raises like deepeval when no metric has a threshold",
         %{test_case: test_case} do
      assert_raise ArgumentError, ~r/at least one non-flaky metric with a 'threshold'/, fn ->
        assert_evaluation(test_case, [ExactMatch], threshold: nil)
      end
    end

    test "assert_passes raises like deepeval's assert_test when the metric has no threshold",
         %{test_case: test_case} do
      assert_raise ArgumentError, ~r/at least one non-flaky metric with a 'threshold'/, fn ->
        assert_passes(test_case, ScoreOnlyMetric)
      end
    end

    test "assert_fails reports that the metric has no threshold", %{test_case: test_case} do
      assert_raise ExUnit.AssertionError, ~r/ScoreOnly has no threshold/, fn ->
        assert_fails(test_case, ScoreOnlyMetric)
      end
    end
  end

  describe "assert_evaluation/3 with options" do
    test "passes options to all metrics" do
      # Mock statements extraction
      Mock.set_schema_response(
        ~r/breakdown and generate a list of statements/i,
        %{"statements" => ["Statement 1"]}
      )

      # Mock verdicts
      Mock.set_schema_response(
        ~r/determine whether each statement is relevant/i,
        %{"verdicts" => [%{"verdict" => "yes"}]}
      )

      # Mock reason
      Mock.set_schema_response(
        ~r/provide a CONCISE reason for the score/i,
        %{"reason" => "Good."}
      )

      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer with a statement."
        )

      results = assert_evaluation(test_case, [AnswerRelevancy], adapter: :mock)
      assert length(results) == 1
      assert Enum.all?(results, & &1.success)
    end
  end

  describe "error messages" do
    test "includes metric name and score in failure message" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "5",
          expected_output: "4"
        )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch)
        end

      assert error.message =~ "Exact Match (score: 0.0, threshold: 1.0"
    end

    test "includes reason when available" do
      test_case =
        TestCase.new!(
          input: "Q",
          actual_output: "Different answer",
          expected_output: "Expected answer"
        )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(test_case, ExactMatch)
        end

      assert error.message =~ "reason: The actual and expected outputs are different.)"
    end
  end

  describe "errored metrics" do
    test "assert_passes reports the error rather than a low score" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(missing_output_case(), ExactMatch, ignore_errors: true)
        end

      assert error.message ==
               "Metrics: Exact Match (score: None, threshold: 1.0, strict: False, " <>
                 "error: 'actual_output' cannot be None for the 'Exact Match' metric, " <>
                 "reason: None) failed."
    end

    test "assert_passes reports an errored result returned by the metric" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(missing_output_case(), ErroredMetric)
        end

      assert error.message ==
               "Metrics: ErroredMetric (score: None, threshold: 0.5, strict: False, " <>
                 "error: LLM returned invalid JSON, reason: None) failed."
    end

    test "assert_fails does not treat an errored result as an expected failure" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_fails(missing_output_case(), ErroredMetric)
        end

      assert error.message =~ "metric errored: LLM returned invalid JSON"
    end

    test "assert_fails reports an error from measure distinctly" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_fails(missing_output_case(), ExactMatch, ignore_errors: true)
        end

      assert error.message =~ "metric errored: 'actual_output' cannot be None"
    end

    test "assert_score reports the error instead of comparing a missing score" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_score(missing_output_case(), ErroredMetric, min: 0.5)
        end

      assert error.message =~ "metric errored: LLM returned invalid JSON"
    end

    test "assert_evaluation lists errored metrics distinctly" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_evaluation(missing_output_case(), [ExactMatch, ErroredMetric],
            ignore_errors: true
          )
        end

      assert error.message ==
               "Metrics: Exact Match (score: None, threshold: 1.0, strict: False, " <>
                 "error: 'actual_output' cannot be None for the 'Exact Match' metric, " <>
                 "reason: None), ErroredMetric (score: None, threshold: 0.5, strict: False, " <>
                 "error: LLM returned invalid JSON, reason: None) failed."
    end
  end

  describe "IGNORE_DEEPEVAL_ERRORS and SKIP_DEEPEVAL_MISSING_PARAMS" do
    setup do
      vars = ~w(IGNORE_DEEPEVAL_ERRORS SKIP_DEEPEVAL_MISSING_PARAMS)
      keys = [:ignore_errors, :skip_on_missing_params]
      previous = Map.new(vars, &{&1, System.get_env(&1)})
      previous_config = Map.new(keys, &{&1, Application.fetch_env(:deep_eval_ex, &1)})
      Enum.each(vars, &System.delete_env/1)
      Enum.each(keys, &Application.delete_env(:deep_eval_ex, &1))

      on_exit(fn ->
        for {var, value} <- previous,
            do: if(value, do: System.put_env(var, value), else: System.delete_env(var))

        for {key, value} <- previous_config do
          case value do
            {:ok, value} -> Application.put_env(:deep_eval_ex, key, value)
            :error -> Application.delete_env(:deep_eval_ex, key)
          end
        end
      end)
    end

    test "unset, an erroring metric raises its error, as deepeval's assert_test" do
      assert_raise MissingTestCaseParamsError,
                   "'actual_output' cannot be None for the 'Exact Match' metric",
                   fn -> assert_passes(missing_output_case(), ExactMatch) end
    end

    test "IGNORE_DEEPEVAL_ERRORS reports the error as a failed assertion instead" do
      System.put_env("IGNORE_DEEPEVAL_ERRORS", "true")

      assert_raise ExUnit.AssertionError,
                   ~r/error: 'actual_output' cannot be None/,
                   fn ->
                     assert_passes(missing_output_case(), ExactMatch)
                   end
    end

    test "config :deep_eval_ex, :ignore_errors is read first and the option wins over both" do
      System.put_env("IGNORE_DEEPEVAL_ERRORS", "true")
      Application.put_env(:deep_eval_ex, :ignore_errors, false)

      assert_raise MissingTestCaseParamsError, fn ->
        assert_passes(missing_output_case(), ExactMatch)
      end

      assert_raise ExUnit.AssertionError, ~r/error: 'actual_output' cannot be None/, fn ->
        assert_passes(missing_output_case(), ExactMatch, ignore_errors: true)
      end
    end

    test "SKIP_DEEPEVAL_MISSING_PARAMS skips the metric, which neither passes nor fails" do
      System.put_env("SKIP_DEEPEVAL_MISSING_PARAMS", "1")

      assert %Result{skipped: true} = assert_passes(missing_output_case(), ExactMatch)

      assert [%Result{skipped: true}, %Result{metric: "ScoreOnly"}] =
               assert_evaluation(missing_output_case(), [ExactMatch, ScoreOnlyMetric])

      assert_raise ExUnit.AssertionError, ~r/Exact Match was skipped/, fn ->
        assert_fails(missing_output_case(), ExactMatch)
      end

      assert_raise ExUnit.AssertionError, ~r/Exact Match was skipped/, fn ->
        assert_score(missing_output_case(), ExactMatch, min: 0.5)
      end
    end
  end

  describe "DEEPEVAL_VERBOSE_MODE" do
    setup do
      previous = System.get_env("DEEPEVAL_VERBOSE_MODE")
      previous_config = Application.fetch_env(:deep_eval_ex, :verbose_mode)
      Application.delete_env(:deep_eval_ex, :verbose_mode)

      on_exit(fn ->
        if previous,
          do: System.put_env("DEEPEVAL_VERBOSE_MODE", previous),
          else: System.delete_env("DEEPEVAL_VERBOSE_MODE")

        case previous_config do
          {:ok, value} -> Application.put_env(:deep_eval_ex, :verbose_mode, value)
          :error -> Application.delete_env(:deep_eval_ex, :verbose_mode)
        end
      end)

      %{test_case: TestCase.new!(input: "Q", actual_output: "4", expected_output: "4")}
    end

    test "puts every metric in verbose mode, as deepeval's assert_test", %{test_case: test_case} do
      System.put_env("DEEPEVAL_VERBOSE_MODE", "true")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert %Result{verbose_logs: "Score: 1.00"} = assert_passes(test_case, ExactMatch)
        end)

      assert output =~ "Exact Match Verbose Logs"
    end

    test "leaves verbose mode off when unset or false", %{test_case: test_case} do
      System.delete_env("DEEPEVAL_VERBOSE_MODE")
      assert %Result{verbose_logs: nil} = assert_passes(test_case, ExactMatch)

      System.put_env("DEEPEVAL_VERBOSE_MODE", "0")
      assert %Result{verbose_logs: nil} = assert_passes(test_case, ExactMatch)
    end

    test "is read from config :deep_eval_ex, :verbose_mode first", %{test_case: test_case} do
      System.put_env("DEEPEVAL_VERBOSE_MODE", "true")
      Application.put_env(:deep_eval_ex, :verbose_mode, false)
      assert %Result{verbose_logs: nil} = assert_passes(test_case, ExactMatch)

      System.delete_env("DEEPEVAL_VERBOSE_MODE")
      Application.put_env(:deep_eval_ex, :verbose_mode, true)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert %Result{verbose_logs: "Score: 1.00"} = assert_passes(test_case, ExactMatch)
        end)

      assert output =~ "Exact Match Verbose Logs"
    end

    test "is overridden by an explicit :verbose_mode", %{test_case: test_case} do
      System.put_env("DEEPEVAL_VERBOSE_MODE", "true")

      assert %Result{verbose_logs: nil} =
               assert_passes(test_case, ExactMatch, verbose_mode: false)
    end
  end

  describe "deepeval's assert_test" do
    setup do
      %{
        passing: TestCase.new!(input: "Q", actual_output: "4", expected_output: "4"),
        failing: TestCase.new!(input: "Q", actual_output: "5", expected_output: "4")
      }
    end

    test "fails with deepeval's message, Python's str() of each field", %{failing: failing} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_evaluation(failing, [ExactMatch, %FailingMetric{threshold: 0.3}])
        end

      assert error.message ==
               "Metrics: Exact Match (score: 0.0, threshold: 1.0, strict: False, error: None, " <>
                 "reason: The actual and expected outputs are different.), " <>
                 "Failing (score: 0.25, threshold: 0.3, strict: False, error: None, " <>
                 "reason: Low.) failed."
    end

    test "prints strict mode's integer threshold and clamped score as floats",
         %{failing: failing} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(failing, FailingMetric, strict_mode: true)
        end

      assert error.message ==
               "Metrics: Failing (score: 0.0, threshold: 1.0, strict: True, error: None, " <>
                 "reason: Low.) failed."
    end

    test "lists score-only metrics among the failures, as `not None` is true",
         %{failing: failing} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_evaluation(failing, [ExactMatch, ScoreOnlyMetric])
        end

      assert error.message =~
               ~r/different\.\), ScoreOnly \(score: 0\.25, threshold: None, strict: False, error: None, reason: None\) failed\.$/
    end

    test "a failing flaky metric does not fail the test case", %{passing: passing} do
      assert [%Result{success: true}, %Result{success: false, flaky: true}] =
               assert_evaluation(passing, [ExactMatch, %FailingMetric{flaky: true}])
    end

    test "a failing flaky metric is listed when another metric fails", %{failing: failing} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_evaluation(failing, [ExactMatch, %FailingMetric{flaky: true}])
        end

      assert error.message =~ ~r/, Failing \(score: 0\.25, .*\) failed\.$/
    end

    test "a flaky test case only warns, as deepeval's warnings.warn", %{failing: failing} do
      flaky = %{failing | flaky: true}

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert %Result{success: false} = assert_passes(flaky, ExactMatch)
        end)

      assert stderr =~
               "Flaky test case failed (no assertion raised): Metrics: Exact Match " <>
                 "(score: 0.0, threshold: 1.0, strict: False, error: None, " <>
                 "reason: The actual and expected outputs are different.) failed."
    end

    test "runs the metrics concurrently through the Evaluator", %{passing: passing} do
      metrics = [%BlockingMetric{name: "A"}, %BlockingMetric{name: "B"}]
      test_pid = self()
      task = Task.async(fn -> assert_evaluation(passing, metrics, test_pid: test_pid) end)

      assert_receive {:running, "A", a}, 1_000
      assert_receive {:running, "B", b}, 1_000
      Enum.each([a, b], &send(&1, :release))

      assert [%Result{metric: "A"}, %Result{metric: "B"}] = Task.await(task)
    end

    test "applies the Evaluator's metric timeout", %{passing: passing} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_passes(passing, HangingMetric, metric_timeout: 50, ignore_errors: true)
        end

      assert error.message =~ "error: Timed out/cancelled while evaluating metric."
    end

    test "raises the timeout without ignore_errors", %{passing: passing} do
      assert_raise DeepEvalEx.MetricError, ~r/^Timed out\/cancelled/, fn ->
        assert_score(passing, HangingMetric, [min: 0.5], metric_timeout: 50)
      end
    end

    test "raises like deepeval when there are no metrics", %{passing: passing} do
      message =
        "1 test case is missing expectations. Fill in non-empty expectations for " <>
          "these test cases and/or provide at least one metric and/or classifier."

      assert_raise ArgumentError, message, fn -> assert_evaluation(passing, []) end
    end

    test "raises like deepeval when every metric with a threshold is flaky",
         %{passing: passing} do
      assert_raise ArgumentError, ~r/at least one non-flaky metric/, fn ->
        assert_passes(passing, %FailingMetric{flaky: true})
      end
    end
  end

  describe "use DeepEvalEx.ExUnit" do
    test "imports all assertion macros" do
      # This test verifies that using the module makes all macros available
      # Macros are imported, not exported as functions, so we check the source module
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_passes, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_passes, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_fails, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_fails, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_score, 3)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_score, 4)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_evaluation, 2)
      assert macro_exported?(DeepEvalEx.ExUnit, :assert_evaluation, 3)
    end
  end
end
