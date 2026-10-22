defmodule DeepEvalEx.Metrics.JevEvalTest do
  # The cases of deepeval 4.3.1's tests/test_metrics/test_jev_eval.py that
  # concern the metric, against the Mock System One model: no network, API
  # key or LLM. The value mapping itself is DeepEvalEx.SystemOne.Scoring's.
  use ExUnit.Case, async: true

  alias DeepEvalEx.{DeepEvalError, Evaluator, MissingTestCaseParamsError, Result, TestCase}
  alias DeepEvalEx.Metrics.JevEval
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Error, Scored}
  alias DeepEvalEx.TestRun.JSON

  # The worked example from deepeval's docs: Tool Faithfulness.
  @questions [
    Scored.Noul.new!(
      statement:
        "Every fact and figure in actual_output appears in the output of a tool in tools_called.",
      weight: 2
    ),
    Scored.Noul.new!(
      statement: "actual_output reports every value returned in tools_called accurately."
    ),
    Scored.Score.new!(
      question: "How much of actual_output is grounded in the outputs in tools_called?",
      levels: ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
    ),
    Scored.Choice.new!(
      question: "What did actual_output do with information the tools did not return?",
      options: [
        {"left_it_out", 1.0},
        {"flagged_it_as_unknown", 1.0},
        {"hedged_it", 0.5},
        {"stated_it_as_fact", 0.0},
        {"nothing_missing", nil}
      ]
    )
  ]

  @answers %Answers{
    nouls: %{
      "q_0" => %Answers.Noul{probability: 0.30},
      "q_1" => %Answers.Noul{probability: 0.90}
    },
    scores: %{
      "q_2" => %Answers.Score{
        score: 1.7,
        probabilities: [{0, 0.05}, {1, 0.30}, {2, 0.55}, {3, 0.10}],
        confidence: 0.55
      }
    },
    choices: %{
      "q_3" => %Answers.Choice{
        choice: "stated_it_as_fact",
        probabilities: [
          {"left_it_out", 0.05},
          {"flagged_it_as_unknown", 0.05},
          {"hedged_it", 0.25},
          {"stated_it_as_fact", 0.60},
          {"nothing_missing", 0.05}
        ],
        confidence: 0.6
      }
    }
  }

  @not_applicable %Answers.Choice{
    choice: "nothing_missing",
    probabilities: [
      {"left_it_out", 0.04},
      {"flagged_it_as_unknown", 0.02},
      {"hedged_it", 0.02},
      {"stated_it_as_fact", 0.02},
      {"nothing_missing", 0.90}
    ],
    confidence: 0.9
  }

  defp test_case do
    TestCase.new!(%{
      input: "What's the weather in Paris right now?",
      actual_output: "It's 18°C and sunny in Paris, with a light breeze and around 40% humidity.",
      tools_called: [
        %{
          name: "get_weather",
          input_parameters: %{"city" => "Paris"},
          output: %{"temp_c" => 18, "condition" => "sunny"}
        }
      ]
    })
  end

  defp metric(answers \\ @answers, opts \\ []) do
    mock = Mock.new(answers: answers)

    metric =
      [
        name: "Tool Faithfulness",
        evaluation_params: [:input, :actual_output, :tools_called],
        questions: @questions,
        system_one_model: mock,
        include_reason: false
      ]
      |> Keyword.merge(opts)
      |> JevEval.new()

    {metric, mock}
  end

  defp measure!(metric) do
    {:ok, result} = JevEval.evaluate(metric, test_case())
    result
  end

  defp breakdown(%Result{score_breakdown: breakdown}),
    do: Enum.map(breakdown, &(&1 |> JSON.encode!() |> Jason.decode!()))

  describe "scoring" do
    test "is the weighted mean of the answers' values (the worked example)" do
      {metric, _mock} = metric()
      result = measure!(metric)

      expected = (2 * 0.30 + 0.90 + 1.7 / 3 + 0.225 / 0.95) / 5
      assert_in_delta result.score, expected, 1.0e-9
      assert_in_delta result.score, 0.461, 1.0e-3
      assert result.success == false
      assert result.reason == nil
      # The least decisive answer: the first Noul, |2 * 0.30 - 1|.
      assert_in_delta result.confidence, 0.40, 1.0e-9
      assert result.threshold == 0.5
    end

    test "drops a Choice whose not-applicable options carry the mass" do
      {metric, _mock} = metric(put_in(@answers.choices["q_3"], @not_applicable))
      result = measure!(metric)

      assert_in_delta result.score, (2 * 0.30 + 0.90 + 1.7 / 3) / 4, 1.0e-9
      assert %{"applicable" => false, "value" => nil} = Enum.at(breakdown(result), 3)
    end

    test "breaks the score down per question without a strict flag" do
      {metric, _mock} = metric()
      result = measure!(metric)

      assert [noul, _noul, score, choice] = breakdown(result)
      assert noul["type"] == "noul" and noul["weight"] == 2.0
      assert score["probabilities"]["Mostly grounded"] == 0.55
      assert choice["applicable"] == true
      assert Enum.all?(breakdown(result), &(&1["passed"] == nil))
    end
  end

  describe "strict mode" do
    test "forces the threshold to 1 and the score to 1 or 0" do
      {metric, _mock} = metric(@answers, strict_mode: true, threshold: 0.3)
      assert metric.threshold == 1

      result = measure!(metric)

      # q_0 is at 0.30 (< 0.5) and q_3's likeliest option earns 0.0.
      assert result.score === 0.0
      assert result.threshold == 1
      assert result.success == false
      assert Enum.map(breakdown(result), & &1["passed"]) == [false, true, false, false]
    end

    test "scores 1 when every applicable question is answered at its best" do
      answers = %Answers{
        nouls: %{
          "q_0" => %Answers.Noul{probability: 0.9},
          "q_1" => %Answers.Noul{probability: 0.7}
        },
        scores: %{
          "q_2" => %Answers.Score{
            score: 2.8,
            probabilities: [{0, 0.0}, {1, 0.05}, {2, 0.1}, {3, 0.85}],
            confidence: 0.85
          }
        },
        choices: %{
          "q_3" => %Answers.Choice{
            choice: "left_it_out",
            probabilities: [
              {"left_it_out", 0.7},
              {"flagged_it_as_unknown", 0.2},
              {"hedged_it", 0.05},
              {"stated_it_as_fact", 0.03},
              {"nothing_missing", 0.02}
            ],
            confidence: 0.7
          }
        }
      }

      {metric, _mock} = metric(answers, strict_mode: true)
      result = measure!(metric)

      assert result.score === 1.0
      assert result.success == true
      assert Enum.all?(breakdown(result), & &1["passed"])
    end

    test "skips a not-applicable Choice" do
      answers = %Answers{
        nouls: %{
          "q_0" => %Answers.Noul{probability: 0.9},
          "q_1" => %Answers.Noul{probability: 0.9}
        },
        scores: %{
          "q_2" => %Answers.Score{
            score: 2.9,
            probabilities: [{0, 0.0}, {1, 0.0}, {2, 0.1}, {3, 0.9}],
            confidence: 0.9
          }
        },
        choices: %{"q_3" => @not_applicable}
      }

      {metric, _mock} = metric(answers, strict_mode: true)
      result = measure!(metric)

      assert result.score === 1.0
      assert %{"applicable" => false, "passed" => nil} = Enum.at(breakdown(result), 3)
    end
  end

  describe "the request" do
    test "is one decide call about the evaluation params only" do
      {metric, mock} = metric()
      measure!(metric)

      assert [call] = Mock.calls(mock)

      assert call.state |> JSON.encode!() |> Jason.decode!() == %{
               "test_case" => %{
                 "input" => "What's the weather in Paris right now?",
                 "actual_output" =>
                   "It's 18°C and sunny in Paris, with a light breeze and around 40% humidity.",
                 "tools_called" => [
                   %{
                     "name" => "get_weather",
                     "type" => "FUNCTION",
                     "input_parameters" => %{"city" => "Paris"},
                     "output" => %{"temp_c" => 18, "condition" => "sunny"}
                   }
                 ]
               }
             }

      assert call.state |> JSON.encode!() |> String.starts_with?(~s({"test_case": {"input": ))
      assert Enum.map(call.questions, &elem(&1, 0)) == ["q_0", "q_1", "q_2", "q_3"]
    end

    test "sends no weights or credits" do
      {metric, mock} = metric()
      measure!(metric)

      [call] = Mock.calls(mock)
      {"q_3", choice} = List.last(call.questions)

      assert Enum.map(choice.options, &elem(&1, 0)) ==
               Enum.map(List.last(@questions).options, &elem(&1, 0))

      refute Map.has_key?(choice, :weight)
    end

    test "raises a System One error, as nothing falls back" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      mock = Mock.new(raises: error)

      metric =
        JevEval.new(
          name: "Down",
          evaluation_params: [:input],
          questions: [Scored.Noul.new!(statement: "x")],
          system_one_model: mock
        )

      assert_raise Error, "Jev is down", fn -> JevEval.evaluate(metric, test_case()) end
    end
  end

  describe "usage" do
    test "is always System One's, seeded as without an LLM, whatever the eval mode" do
      for mode <- [:llm, :hybrid, :system_one] do
        mock = Mock.new(answers: @answers, cost: {4.2e-05, 1000, 0})

        {:ok, result} =
          JevEval.measure(test_case(),
            name: "Tool Faithfulness",
            evaluation_params: [:input, :actual_output, :tools_called],
            questions: @questions,
            system_one_model: mock,
            eval_mode: mode
          )

        assert result.evaluation_model == "fake-jev"
        assert result.evaluation_cost == 4.2e-05
        assert result.input_tokens == 1000
        assert result.output_tokens == 0
        assert [_call] = Mock.calls(mock)
      end
    end

    test "an unpriced request leaves the cost nil and the tokens at 0" do
      mock = Mock.new(answers: @answers, cost: nil)

      {:ok, result} =
        JevEval.measure(test_case(),
          name: "Tool Faithfulness",
          evaluation_params: [:input],
          questions: @questions,
          system_one_model: mock
        )

      assert result.evaluation_cost == nil
      assert result.input_tokens == 0
      assert result.output_tokens == 0
    end
  end

  describe "the reason" do
    test "is deterministic and covers every question" do
      {metric, _mock} = metric(@answers, include_reason: true)
      reason = measure!(metric).reason

      assert String.starts_with?(reason, "Decided by fake-jev, minimum confidence 0.40.")
      for question <- @questions, do: assert(reason =~ Scored.text(question))
      assert reason =~ "likely fails (P(yes)=0.30, confidence=0.40, weight=2)"
      assert reason =~ "clearly holds (P(yes)=0.90, confidence=0.80)"
      assert reason =~ ~s("Mostly grounded")
      assert reason =~ "expected level=0.57 of 1.00"
      assert reason =~ ~s["stated_it_as_fact" (P=0.60, confidence=0.60)]
      assert String.ends_with?(reason, "Score: 0.46 (weighted mean of 4 applicable questions).")

      {again, _mock} = metric(@answers, include_reason: true)
      assert measure!(again).reason == reason
    end

    test "marks strict results" do
      {metric, _mock} = metric(@answers, include_reason: true, strict_mode: true)
      reason = measure!(metric).reason

      assert reason =~ "strict=fail"
      assert reason =~ "strict=pass"

      assert String.ends_with?(
               reason,
               "Score: 0.00 (strict mode: at least one applicable question failed)."
             )
    end

    test "marks a not-applicable Choice" do
      answers = put_in(@answers.choices["q_3"], @not_applicable)
      {metric, _mock} = metric(answers, include_reason: true)
      reason = measure!(metric).reason

      assert reason =~ "-> not applicable (not applicable"
      assert reason =~ "weighted mean of 3 applicable questions"
    end
  end

  describe "verbose logs" do
    test "list the questions, then the score and confidence" do
      {metric, _mock} = metric(@answers, include_reason: true)
      logs = measure!(metric).verbose_logs

      assert String.starts_with?(logs, "Questions:\n1. [noul, weight=2] Every fact")
      assert logs =~ ~r/ \n \nScore: 0\.46\d+\nConfidence: 0\.4\d*$/
      refute logs =~ "Reason:"
      refute logs =~ "no LLM call was made"
    end
  end

  describe "test case checks" do
    test "rejects a multimodal test case before asking System One" do
      {metric, mock} = metric()

      multimodal = %{
        test_case()
        | input: "what is this? [DEEPEVAL:IMAGE:https://x/y.png]"
      }

      assert_raise ArgumentError,
                   "Tool Faithfulness [JevEval] evaluates text only: Jev has no image input. " <>
                     "Pass a text-only LLMTestCase.",
                   fn -> JevEval.evaluate(metric, multimodal) end

      assert Mock.calls(mock) == []
    end

    test "returns missing evaluation params" do
      {metric, mock} = metric()

      assert {:error, {:missing_params, [:tools_called]}} =
               JevEval.evaluate(metric, %TestCase{
                 input: "hi",
                 actual_output: "there",
                 tools_called: nil
               })

      assert Mock.calls(mock) == []
    end

    test "without evaluation params needs a trace, which no test case carries yet" do
      mock = Mock.new(answers: %Answers{nouls: %{"q_0" => %Answers.Noul{probability: 0.9}}})

      metric =
        JevEval.new(
          name: "Tool Use",
          questions: [
            Scored.Noul.new!(statement: "The agent called order_lookup before answering.")
          ],
          system_one_model: mock
        )

      error =
        assert_raise MissingTestCaseParamsError, fn ->
          JevEval.evaluate(metric, %TestCase{input: "hi", actual_output: "there"})
        end

      assert error.message ==
               "The 'Tool Use [JevEval]' metric has no evaluation_params, so it evaluates the " <>
                 "trace, but this test case has none. Run it on a traced component (`@observe` " <>
                 "or `evals_iterator`), or pass evaluation_params to evaluate a plain LLMTestCase."

      assert Mock.calls(mock) == []
    end

    test "the evaluator skips a test case missing params with skip_on_missing_params" do
      {metric, _mock} = metric()

      result =
        Evaluator.evaluate_metric(
          %TestCase{input: "hi", actual_output: "there", tools_called: nil},
          metric,
          skip_on_missing_params: true
        )

      assert result.skipped
    end
  end

  describe "new/1" do
    test "rejects an empty evaluation_params list" do
      assert_raise ArgumentError,
                   "evaluation_params cannot be an empty list; list the test case fields your " <>
                     "questions refer to, or omit it to evaluate the trace.",
                   fn ->
                     JevEval.new(
                       name: "x",
                       evaluation_params: [],
                       questions: [Scored.Noul.new!(statement: "a")],
                       system_one_model: Mock.new()
                     )
                   end
    end

    test "rejects no questions" do
      for questions <- [nil, []] do
        assert_raise ArgumentError,
                     "JevEval needs at least one question (Noul, Score or Choice).",
                     fn ->
                       JevEval.new(
                         name: "x",
                         evaluation_params: [:input],
                         questions: questions,
                         system_one_model: Mock.new()
                       )
                     end
      end
    end

    test "rejects anything but a Noul, Score or Choice" do
      assert_raise ArgumentError, ~r/^Questions must be Noul, Score or Choice; got /, fn ->
        JevEval.new(
          name: "x",
          evaluation_params: [:input],
          questions: ["not a question"],
          system_one_model: Mock.new()
        )
      end
    end

    test "raises when the System One model is not usable" do
      message =
        assert_raise DeepEvalError, fn ->
          JevEval.new(
            name: "x",
            evaluation_params: [:input],
            questions: [Scored.Noul.new!(statement: "a")],
            system_one_model: {:typesafe, api_key: ""}
          )
        end

      assert message.message =~ ~r/^JevEval needs Jev to score, but it is not usable: /
      assert message.message =~ "Pass a configured `TypeSafeModel` as `system_one_model`"
    end

    test "names the metric '<name> [JevEval]' unless the suffix is off" do
      {metric, _mock} = metric()
      assert JevEval.metric_name(metric) == "Tool Faithfulness [JevEval]"
      assert measure!(metric).metric == "Tool Faithfulness [JevEval]"

      {metric, _mock} = metric(@answers, include_jev_eval_suffix: false)
      assert JevEval.metric_name(metric) == "Tool Faithfulness"
      assert measure!(metric).metric == "Tool Faithfulness"
    end
  end

  describe "with the evaluator" do
    test "reports the configured name and System One model, also on an error" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

      metric =
        JevEval.new(
          name: "Down",
          evaluation_params: [:input],
          questions: [Scored.Noul.new!(statement: "x")],
          system_one_model: Mock.new(raises: error, model: "fake-jev")
        )

      result = Evaluator.evaluate_metric(test_case(), metric, ignore_errors: true)

      assert result.metric == "Down [JevEval]"
      assert result.error == "Jev is down"
      assert result.evaluation_model == "fake-jev"
    end
  end
end
