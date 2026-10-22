defmodule DeepEvalEx.Metrics.GEvalTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.GEval
  alias DeepEvalEx.TestCase

  doctest GEval, only: [calculate_weighted_summed_score: 2]

  setup do
    Mock.clear_responses()
    :ok
  end

  describe "new/1" do
    test "creates GEval metric with criteria" do
      metric =
        GEval.new(
          name: "Helpfulness",
          criteria: "Is the response helpful?",
          evaluation_params: [:input, :actual_output]
        )

      assert metric.name == "Helpfulness"
      assert metric.criteria == "Is the response helpful?"
      assert metric.evaluation_params == [:input, :actual_output]
      assert metric.threshold == 0.5
      assert metric.score_range == {0, 10}
    end

    test "creates GEval metric with evaluation_steps" do
      metric =
        GEval.new(
          name: "Custom",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Step 1", "Step 2", "Step 3"]
        )

      assert metric.evaluation_steps == ["Step 1", "Step 2", "Step 3"]
      assert is_nil(metric.criteria)
    end

    test "creates GEval metric with rubric" do
      metric =
        GEval.new(
          name: "Quality",
          criteria: "Evaluate quality",
          evaluation_params: [:input, :actual_output],
          rubric: [
            {10, "Perfect"},
            {5, "Average"},
            {1, "Poor"}
          ]
        )

      assert metric.rubric == [{10, "Perfect"}, {5, "Average"}, {1, "Poor"}]
    end

    test "raises without criteria or evaluation_steps" do
      assert_raise ArgumentError, ~r/requires either :criteria or :evaluation_steps/, fn ->
        GEval.new(
          name: "Invalid",
          evaluation_params: [:input]
        )
      end
    end

    test "supports strict_mode" do
      metric =
        GEval.new(
          name: "Strict",
          criteria: "Binary check",
          evaluation_params: [:input],
          strict_mode: true
        )

      assert metric.strict_mode == true
    end

    test "strict_mode forces the threshold to the integer 1, as deepeval's constructor" do
      metric =
        GEval.new(
          name: "Strict",
          criteria: "Binary check",
          evaluation_params: [:input],
          strict_mode: true,
          threshold: 0.3
        )

      assert metric.threshold === 1
    end

    test "accepts a nil threshold for score-only evaluation and a flaky flag" do
      metric =
        GEval.new(
          name: "Scored",
          criteria: "Quality",
          evaluation_params: [:input],
          threshold: nil,
          flaky: true
        )

      assert metric.threshold == nil
      assert metric.flaky == true
      refute GEval.new(name: "D", criteria: "c", evaluation_params: [:input]).flaky
    end

    test "supports custom score_range" do
      metric =
        GEval.new(
          name: "Custom Range",
          criteria: "Test",
          evaluation_params: [:input],
          score_range: {1, 5}
        )

      assert metric.score_range == {1, 5}
    end
  end

  describe "metric_name/0" do
    test "returns GEval" do
      assert GEval.metric_name() == "GEval"
    end
  end

  describe "metric_name/1" do
    test "suffixes the configured name with [GEval] like deepeval's __name__" do
      metric = GEval.new(name: "Helpfulness", criteria: "c", evaluation_params: [:input])

      assert GEval.metric_name(metric) == "Helpfulness [GEval]"
    end

    test "returns the bare name when the suffix is disabled" do
      metric =
        GEval.new(
          name: "Helpfulness",
          criteria: "c",
          evaluation_params: [:input],
          include_g_eval_suffix: false
        )

      assert GEval.metric_name(metric) == "Helpfulness"
    end
  end

  describe "evaluate/2 with mock adapter" do
    test "evaluates test case with pre-defined steps" do
      # Mock the evaluation response
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 8, "reason" => "The response is helpful and accurate."}
      )

      metric =
        GEval.new(
          name: "Helpfulness",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: [
            "Check if the response addresses the question",
            "Verify the information is accurate",
            "Assess if the response is clear"
          ]
        )

      test_case =
        TestCase.new!(
          input: "How do I boil water?",
          actual_output: "Fill a pot with water, place on stove, heat until bubbles form."
        )

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # 8/10 normalized
      assert result.score == 0.8
      assert result.reason == "The response is helpful and accurate."
      assert result.metric == "Helpfulness [GEval]"
    end

    test "generates steps when not provided" do
      # Mock the steps generation
      Mock.set_schema_response(
        ~r/generate.*evaluation steps/i,
        %{"steps" => ["Step 1: Check accuracy", "Step 2: Check completeness"]}
      )

      # Mock the evaluation response
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 7, "reason" => "Good but could be more detailed."}
      )

      metric =
        GEval.new(
          name: "Accuracy",
          criteria: "Is the response accurate?",
          evaluation_params: [:input, :actual_output]
        )

      test_case =
        TestCase.new!(
          input: "What is 2+2?",
          actual_output: "4"
        )

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert result.score == 0.7

      assert result.metadata.evaluation_steps == [
               "Step 1: Check accuracy",
               "Step 2: Check completeness"
             ]
    end

    test "normalizes score to 0-1 range" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 5, "reason" => "Average response."}
      )

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          score_range: {0, 10}
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # 5/10 = 0.5
      assert result.score == 0.5
    end

    test "sends its rubric as deepeval's format_rubrics does, lowest score first" do
      Mock.script(%{"reason,score" => [%{"score" => 7, "reason" => "Good."}]})

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          rubric: [{10, "Perfect"}, {1, "Poor"}]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, _result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert [%{prompt: prompt}] = Mock.scripted_prompts()
      assert prompt =~ "\n\nRubric:\n1: Poor\n10: Perfect\n\nTest Case:\nInput:\nQ \n\n"
    end

    test "a nil threshold measures score-only, through the evaluator too" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 5, "reason" => "Average."})

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          threshold: nil,
          flaky: true
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, %{score: 0.5, threshold: nil, success: nil}} =
               GEval.evaluate(metric, test_case, adapter: :mock)

      assert %{score: 0.5, threshold: nil, success: nil, flaky: true} =
               DeepEvalEx.Evaluator.evaluate_metric(test_case, metric,
                 adapter: :mock,
                 threshold: 0.7
               )
    end

    test "handles custom score range" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 3, "reason" => "Meets expectations."}
      )

      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Check quality"],
          # 1-5 range
          score_range: {1, 5}
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      # Score 3 in range 1-5: (3-1)/(5-1) = 2/4 = 0.5
      assert result.score == 0.5
    end

    test "returns error for missing evaluation params" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output, :expected_output],
          evaluation_steps: ["Check"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")
      # missing expected_output

      assert {:error, {:missing_params, [:expected_output]}} =
               GEval.evaluate(metric, test_case, adapter: :mock)
    end

    test "validates params as deepeval: an empty actual_output is rejected, other empties are not" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:input, :actual_output, :expected_output],
          evaluation_steps: ["Check"]
        )

      assert {:error, {:empty_param, :actual_output}} =
               GEval.evaluate(
                 metric,
                 %TestCase{input: "Q", actual_output: "", expected_output: nil},
                 adapter: :mock
               )

      Mock.set_schema_response(~r/evaluator/i, %{"score" => 10, "reason" => "Fine."})

      assert {:ok, %{score: 1.0}} =
               GEval.evaluate(
                 metric,
                 %TestCase{input: "Q", actual_output: "A", expected_output: ""},
                 adapter: :mock
               )
    end

    test "does not accept context for retrieval_context" do
      metric =
        GEval.new(
          name: "Test",
          evaluation_params: [:actual_output, :retrieval_context],
          evaluation_steps: ["Check"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A", context: ["ctx"])

      assert {:error, {:missing_params, [:retrieval_context]}} =
               GEval.evaluate(metric, test_case, adapter: :mock)
    end

    test "includes metadata in result" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 9, "reason" => "Excellent."}
      )

      metric =
        GEval.new(
          name: "Quality",
          criteria: "Is it good?",
          evaluation_params: [:input, :actual_output],
          evaluation_steps: ["Step 1"]
        )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert result.metadata.raw_score == 9
      assert result.metadata.score_range == {0, 10}
      assert result.metadata.evaluation_steps == ["Step 1"]
      assert result.metadata.criteria == "Is it good?"
    end
  end

  describe "do_measure/2" do
    test "works with inline configuration" do
      Mock.set_schema_response(
        ~r/evaluator/i,
        %{"score" => 8, "reason" => "Good."}
      )

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} =
               GEval.do_measure(test_case,
                 name: "Inline",
                 criteria: "Is it good?",
                 evaluation_params: [:input, :actual_output],
                 evaluation_steps: ["Check"],
                 adapter: :mock
               )

      assert result.score == 0.8
      assert result.metric == "Inline [GEval]"
    end

    test "names the result with the bare name when the suffix is disabled" do
      Mock.set_schema_response(~r/evaluator/i, %{"score" => 8, "reason" => "Good."})

      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:ok, result} =
               GEval.do_measure(test_case,
                 name: "Inline",
                 evaluation_params: [:input, :actual_output],
                 evaluation_steps: ["Check"],
                 include_g_eval_suffix: false,
                 adapter: :mock
               )

      assert result.metric == "Inline"
    end

    test "returns error without configuration" do
      test_case = TestCase.new!(input: "Q", actual_output: "A")

      assert {:error, {:missing_config, _}} = GEval.do_measure(test_case, [])
    end
  end

  # An OpenAI chat completion answering `content`, with `tokens` as its
  # logprobs: {token, logprob, [{top_token, top_logprob}]}.
  defp completion(content, tokens) do
    logprobs =
      if tokens do
        %{
          "content" =>
            Enum.map(tokens, fn {token, logprob, top} ->
              %{
                "token" => token,
                "logprob" => logprob,
                "top_logprobs" =>
                  Enum.map(top, fn {t, lp} -> %{"token" => t, "logprob" => lp} end)
              }
            end)
        }
      end

    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}, "logprobs" => logprobs}
      ]
    }
  end

  @answer ~s({"reason": "Close.", "score": 7})

  # Expected values computed by deepeval 4.3.1's calculate_weighted_summed_score
  # on the same payloads.
  describe "calculate_weighted_summed_score/2" do
    test "weights the score by its token's top logprobs" do
      raw = completion(@answer, [{"7", -0.1, [{"7", -0.1}, {"8", -2.5}]}])

      assert GEval.calculate_weighted_summed_score(7, raw) == 7.083172696493922
    end

    test "uses the last token equal to the score, not one in the reasoning" do
      raw =
        completion(@answer, [
          {"7", -0.01, [{"7", -0.01}]},
          {"7", -0.1, [{"7", -0.1}, {"8", -2.5}]}
        ])

      assert GEval.calculate_weighted_summed_score(7, raw) == 7.083172696493922
    end

    test "sums tokens naming the same score and drops non-decimal tokens" do
      raw =
        completion(@answer, [
          {"3", -0.5, [{"3", -0.5}, {"4", -1.0}, {"3", -2.0}, {"x", -0.2}]}
        ])

      assert GEval.calculate_weighted_summed_score(3, raw) == 3.331498960424092
    end

    test "drops tokens under 1% probability, keeping the raw score when none is left" do
      raw = completion(@answer, [{"5", -0.1, [{"five", -0.1}, {"5", -5.0}]}])

      assert GEval.calculate_weighted_summed_score(5, raw) === 5
    end

    test "keeps the raw score without a token for it or without logprobs" do
      assert GEval.calculate_weighted_summed_score(5, completion(@answer, [{"6", -0.1, []}])) ===
               5

      assert GEval.calculate_weighted_summed_score(5, completion(@answer, nil)) === 5
      assert GEval.calculate_weighted_summed_score(5, %{}) === 5
    end
  end

  # A judge with logprobs reporting the top_logprobs it is asked for.
  defmodule TopLogprobsJudge do
    use DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: raise("not called")

    @impl true
    def generate_with_schema(_prompt, _schema, _opts), do: raise("not called")

    @impl true
    def generate_raw_response(_prompt, opts) do
      send(self(), {:top_logprobs, opts[:top_logprobs]})

      {:ok,
       %{"choices" => [%{"message" => %{"content" => ~s({"reason": "Close.", "score": 7})}}]}}
    end

    @impl true
    def model_name(_opts), do: "top-logprobs-judge"

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: true
  end

  describe "logprob-weighted scoring" do
    @steps_metric [
      name: "Test",
      evaluation_params: [:input, :actual_output],
      evaluation_steps: ["Check quality"]
    ]

    @weighted [{"7", -0.1, [{"7", -0.1}, {"8", -2.5}]}]

    setup do
      %{test_case: TestCase.new!(input: "Q", actual_output: "A")}
    end

    test "asks a judge with logprobs for a raw response and weights its score",
         %{test_case: test_case} do
      Mock.script(%{"raw_response" => [completion(@answer, @weighted)]})

      assert {:ok, result} = GEval.evaluate(GEval.new(@steps_metric), test_case, adapter: :mock)

      assert result.score == 7.083172696493922 / 10
      assert result.reason == "Close."
      assert [%{step: "raw_response", prompt: prompt}] = Mock.scripted_prompts()
      assert prompt =~ "Check quality"
    end

    test "asks for the metric's top_logprobs, 20 by default", %{test_case: test_case} do
      opts = [adapter: TopLogprobsJudge]

      assert {:ok, _} = GEval.evaluate(GEval.new(@steps_metric), test_case, opts)
      assert_received {:top_logprobs, 20}

      metric = GEval.new([top_logprobs: 5] ++ @steps_metric)
      assert {:ok, _} = GEval.evaluate(metric, test_case, opts)
      assert_received {:top_logprobs, 5}
    end

    test "keeps the raw score of a raw response without logprobs", %{test_case: test_case} do
      Mock.script(%{"raw_response" => [completion(@answer, nil)]})

      assert {:ok, result} = GEval.evaluate(GEval.new(@steps_metric), test_case, adapter: :mock)
      assert result.score == 0.7
    end

    test "loads the raw response's content with trimAndLoadJson", %{test_case: test_case} do
      content = ~s(Sure:\n```json\n{"reason": "Close.", "score": 7,}\n```)
      Mock.script(%{"raw_response" => [completion(content, @weighted)]})

      assert {:ok, result} = GEval.evaluate(GEval.new(@steps_metric), test_case, adapter: :mock)
      assert result.score == 7.083172696493922 / 10
    end

    test "fails with deepeval's error when the raw response holds no JSON",
         %{test_case: test_case} do
      Mock.script(%{"raw_response" => [completion("No.", @weighted)]})

      assert {:error, %DeepEvalEx.LLM.InvalidJSONError{}} =
               GEval.evaluate(GEval.new(@steps_metric), test_case, adapter: :mock)
    end

    test "in strict mode, takes the raw response's score unweighted", %{test_case: test_case} do
      answer = ~s({"reason": "Meets it.", "score": 1})

      Mock.script(%{
        "raw_response" => [completion(answer, [{"1", -0.5, [{"1", -0.5}, {"0", -1.0}]}])]
      })

      metric = GEval.new([strict_mode: true] ++ @steps_metric)

      assert {:ok, result} = GEval.evaluate(metric, test_case, adapter: :mock)
      assert result.metadata.raw_score === 1
    end

    test "falls back to the schema call for a judge without logprobs",
         %{test_case: test_case} do
      Mock.script(%{"reason,score" => [%{"reason" => "Close.", "score" => 7}]})

      assert {:ok, result} = GEval.evaluate(GEval.new(@steps_metric), test_case, adapter: :mock)
      assert result.score == 0.7
      assert [%{step: "reason,score"}] = Mock.scripted_prompts()
    end
  end
end
