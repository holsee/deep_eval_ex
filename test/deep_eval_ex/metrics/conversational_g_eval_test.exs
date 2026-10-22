defmodule DeepEvalEx.Metrics.ConversationalGEvalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, MissingTestCaseParamsError, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.ConversationalGEval
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Prompts.ConversationalGEval, as: Prompts

  doctest ConversationalGEval, only: [calculate_weighted_summed_score: 2]
  doctest Prompts

  @criteria "Determine whether the assistant resolves the user's request."

  defp test_case(attrs \\ []) do
    ConversationalTestCase.new!(
      Keyword.merge(
        [
          turns: [
            %{role: :user, content: "My order is late, I want a refund."},
            %{role: :assistant, content: "I've started a refund for order 42."}
          ]
        ],
        attrs
      )
    )
  end

  defp metric(opts \\ []) do
    ConversationalGEval.new(
      Keyword.merge(
        [name: "Helpfulness", criteria: @criteria, evaluation_params: [:content]],
        opts
      )
    )
  end

  defp measure(metric, test_case, opts \\ []),
    do: Evaluator.evaluate_metric(test_case, metric, [adapter: :mock] ++ opts)

  # A chat completion whose logprobs list `tokens`, as {token, top_logprobs}.
  defp completion(content, tokens) do
    %{
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content},
          "logprobs" => %{
            "content" =>
              Enum.map(tokens, fn {token, top} ->
                %{
                  "token" => token,
                  "logprob" => 0.0,
                  "top_logprobs" =>
                    Enum.map(top, fn {t, logprob} -> %{"token" => t, "logprob" => logprob} end)
                }
              end)
          }
        }
      ]
    }
  end

  describe "new/1" do
    test "appends :content then :role to the evaluation params, as deepeval's constructor" do
      assert metric(evaluation_params: [:scenario]).evaluation_params ==
               [:scenario, :content, :role]

      assert metric(evaluation_params: [:role, :content]).evaluation_params == [:role, :content]
      assert metric(evaluation_params: [:content]).evaluation_params == [:content, :role]
    end

    test "keeps deepeval's defaults" do
      metric = metric()

      assert metric.threshold == 0.5
      assert metric.top_logprobs == 20
      assert metric.strict_mode == false
      assert metric.include_g_eval_suffix == true
      assert metric.rubric == nil
      assert metric.audio_model == nil
    end

    test "forces the threshold to the integer 1 in strict mode" do
      assert metric(strict_mode: true, threshold: 0.3).threshold == 1
    end

    test "sorts the rubric, taking an empty one as none" do
      metric =
        metric(
          rubric: [
            Rubric.new!(score_range: {6, 10}, expected_outcome: "Good."),
            Rubric.new!(score_range: {0, 5}, expected_outcome: "Bad.")
          ]
        )

      assert Enum.map(metric.rubric, & &1.score_range) == [{0, 5}, {6, 10}]
      assert metric(rubric: []).rubric == nil
    end

    test "raises deepeval's errors for invalid params, criteria and steps" do
      assert_raise ArgumentError, "evaluation_params cannot be an empty list.", fn ->
        metric(evaluation_params: [])
      end

      assert_raise ArgumentError,
                   "Either 'criteria' or 'evaluation_steps' must be provided.",
                   fn ->
                     ConversationalGEval.new(name: "N", evaluation_params: [:content])
                   end

      assert_raise ArgumentError, "Criteria provided cannot be an empty string.", fn ->
        metric(criteria: " ")
      end

      assert_raise ArgumentError, ~r/^'evaluation_steps' must not be an empty list/, fn ->
        metric(criteria: nil, evaluation_steps: [])
      end
    end

    test "rejects params deepeval's conversational G-Eval cannot name, and audio" do
      assert_raise ArgumentError, ~r/cannot evaluate :context/, fn ->
        metric(evaluation_params: [:context])
      end

      assert_raise ArgumentError, ~r/cannot evaluate :input/, fn ->
        metric(evaluation_params: [:input])
      end

      assert_raise ArgumentError, ~r/sends no audio/, fn ->
        metric(evaluation_params: [:content, :audio])
      end
    end
  end

  describe "metric_name/1" do
    test "is deepeval's __name__" do
      assert ConversationalGEval.metric_name(metric()) == "Helpfulness [Conversational GEval]"

      assert ConversationalGEval.metric_name(metric(include_g_eval_suffix: false)) ==
               "Helpfulness"
    end
  end

  describe "measuring" do
    test "generates steps from the criteria, then scores out of 10" do
      Mock.script(
        %{
          "steps" => [%{"steps" => ["Check the refund.", "Check the tone."]}],
          "reason,score" => [%{"reason" => "Refund started.", "score" => 8}]
        },
        model: "judge"
      )

      result = measure(metric(), test_case())

      assert result.score == 0.8
      assert result.success == true
      assert result.reason == "Refund started."
      assert result.threshold == 0.5
      assert result.metric == "Helpfulness [Conversational GEval]"
      assert result.evaluation_model == "judge"

      assert result.verbose_logs ==
               "Criteria:\n#{@criteria} \n \n" <>
                 ~s(Evaluation Steps:\n[\n    "Check the refund.",\n    "Check the tone."\n] \n \n) <>
                 "Rubric:\nNone"

      assert [%{step: "steps", prompt: steps_prompt}, %{step: "reason,score", prompt: prompt}] =
               Mock.scripted_prompts()

      assert steps_prompt =~ "using the Content and Role fields"
      assert prompt =~ "1. Check the refund.\n2. Check the tone.\n"

      assert prompt =~
               "[{'content': 'My order is late, I want a refund.', 'role': 'user'}, " <>
                 "{'content': \"I've started a refund for order 42.\", 'role': 'assistant'}]"
    end

    test "keeps a fractional score and uses given steps without generating any" do
      Mock.script(%{"reason,score" => [%{"reason" => "Partly.", "score" => 2.5}]})

      result =
        measure(metric(criteria: nil, evaluation_steps: ["Check it."]), test_case())

      assert result.score == 0.25
      assert result.success == false
      assert [%{step: "reason,score"}] = Mock.scripted_prompts()
    end

    test "prints the conversation-level params it evaluates" do
      Mock.script(%{"reason,score" => [%{"reason" => "Reached.", "score" => 10}]})

      result =
        measure(
          metric(
            evaluation_steps: ["Check the outcome."],
            evaluation_params: [:expected_outcome]
          ),
          test_case(expected_outcome: "A refund is started.")
        )

      assert result.score == 1.0
      assert [%{prompt: prompt}] = Mock.scripted_prompts()

      assert prompt =~
               "Conversation-level fields:\nExpected Outcome:\nA refund is started. \n\n\n" <>
                 "Parameters to consider during evaluation:\nExpected Outcome, Content, and Role\n"
    end

    test "clamps a score below 1 to the integer 0 in strict mode" do
      Mock.script(%{
        "steps" => [%{"steps" => ["Check it."]}],
        "reason,score" => [%{"reason" => "Almost.", "score" => 9}]
      })

      result = measure(metric(strict_mode: true), test_case())

      assert result.score === 0
      assert result.threshold == 1
      assert result.success == false
      assert result.strict_mode == true
    end

    test "returns deepeval's missing param error for an evaluated case-level param" do
      metric = metric(evaluation_params: [:scenario])

      error =
        assert_raise MissingTestCaseParamsError, fn -> measure(metric, test_case()) end

      assert error.message =~ "'scenario'"
      assert error.message =~ "Helpfulness [Conversational GEval]"
      assert Mock.scripted_prompts() == []
    end

    test "rejects a single-turn test case" do
      test_case = TestCase.new!(input: "Hi", actual_output: "Hello")

      assert {:error, :not_conversational_test_case} =
               ConversationalGEval.measure(test_case, name: "N", criteria: "c")
    end

    test "prints its verbose logs and score in verbose mode" do
      Mock.script(%{"reason,score" => [%{"reason" => "Fine.", "score" => 7}]})

      printed =
        capture_io(fn ->
          measure(metric(evaluation_steps: ["Check it."], verbose_mode: true), test_case())
        end)

      assert printed =~ "Helpfulness [Conversational GEval] Verbose Logs"
      assert printed =~ "Score: 0.7\nReason: Fine."
    end
  end

  describe "logprob-weighted scores" do
    test "weigh the FIRST token equal to the score, unlike GEval's last" do
      tokens = [
        {"7", [{"7", -0.1}, {"6", -2.0}]},
        {" of 8", []},
        {"7", [{"7", -0.3}, {"9", -1.0}]}
      ]

      raw = completion(~s({"reason": "7 of 8 replies resolve it.", "score": 7}), tokens)

      Mock.script(%{"steps" => [%{"steps" => ["Check it."]}], "raw_response" => [raw]})

      result = measure(metric(), test_case())

      p7 = :math.exp(-0.1)
      p6 = :math.exp(-2.0)
      assert result.score == (7 * p7 + 6 * p6) / (p7 + p6) / 10
    end

    test "keep the raw score in strict mode, then clamp it" do
      raw =
        completion(~s({"reason": "Fully.", "score": 10}), [{"10", [{"10", -0.1}, {"9", -1.0}]}])

      Mock.script(%{"steps" => [%{"steps" => ["Check it."]}], "raw_response" => [raw]})

      assert measure(metric(strict_mode: true), test_case()).score == 1.0
    end

    test "error with deepeval's ZeroDivisionError when every top token is dropped" do
      raw = completion(~s({"reason": "Hm.", "score": 7}), [{"7", [{"seven", -0.1}, {"6", -9.0}]}])
      Mock.script(%{"steps" => [%{"steps" => ["Check it."]}], "raw_response" => [raw]})

      result = measure(metric(), test_case(), ignore_errors: true)

      assert result.error == "float division by zero"
    end
  end

  describe "copies" do
    test "copy_metric/1 names the judge as the audio judge too, as deepeval's copy_metrics" do
      copy = ConversationalGEval.copy_metric(metric())

      assert copy.audio_model == :judge

      assert ConversationalGEval.describe_evaluation_model("judge", audio_model: :judge) ==
               "judge (audio: judge)"

      assert ConversationalGEval.describe_evaluation_model("judge", []) == "judge"
    end

    test "the asynchronous Evaluator reports the copy's evaluation model, the synchronous not" do
      script = %{
        "steps" => [%{"steps" => ["Check it."]}],
        "reason,score" => [%{"reason" => "Fine.", "score" => 7}]
      }

      Mock.script(script, model: "judge")
      [[async]] = Evaluator.evaluate([test_case()], [metric()], adapter: :mock)
      assert async.evaluation_model == "judge (audio: judge)"

      Mock.script(script, model: "judge")

      [[sync]] =
        Evaluator.evaluate([test_case()], [metric()], adapter: :mock, run_async: false)

      assert sync.evaluation_model == "judge"
    end
  end
end
