defmodule DeepEvalEx.Metrics.ConversationalJevEvalTest do
  # deepeval 4.3.1's ConversationalJevEval
  # (deepeval/metrics/conversational_jev_eval/), against the Mock System One
  # model: no network, API key or LLM. The value mapping and the reason are
  # DeepEvalEx.SystemOne.Scoring's, shared with JevEval.
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, DeepEvalError, Evaluator, Result, TestCase}
  alias DeepEvalEx.Metrics.ConversationalJevEval
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Error, Scored}
  alias DeepEvalEx.TestRun.JSON

  @questions [
    Scored.Noul.new!(
      statement: "The assistant changes the delivery address the user asked for.",
      weight: 2
    ),
    Scored.Score.new!(
      question: "How well does the assistant stay on topic across the turns?",
      levels: ["Off topic", "Partly", "On topic"]
    ),
    Scored.Choice.new!(
      question: "How does the assistant handle the chatbot_role?",
      options: [
        {"keeps_it", 1.0},
        {"drifts", 0.5},
        {"breaks_it", 0.0},
        {"no_role", nil}
      ]
    )
  ]

  @answers %Answers{
    nouls: %{"q_0" => %Answers.Noul{probability: 0.80}},
    scores: %{
      "q_1" => %Answers.Score{
        score: 1.2,
        probabilities: [{0, 0.1}, {1, 0.6}, {2, 0.3}],
        confidence: 0.4
      }
    },
    choices: %{
      "q_2" => %Answers.Choice{
        choice: "keeps_it",
        probabilities: [
          {"keeps_it", 0.6},
          {"drifts", 0.3},
          {"breaks_it", 0.05},
          {"no_role", 0.05}
        ],
        confidence: 0.5
      }
    }
  }

  defp test_case(overrides \\ []) do
    [
      chatbot_role: "A courteous order support agent.",
      scenario: "An address change",
      turns: [
        %{role: :user, content: "Can I change the address to Zürich?"},
        %{role: :assistant, content: "Done: order 42 now ships to Zürich."}
      ]
    ]
    |> Keyword.merge(overrides)
    |> ConversationalTestCase.new!()
  end

  defp metric(answers \\ @answers, opts \\ []) do
    mock = Mock.new(answers: answers)

    metric =
      [
        name: "Support",
        evaluation_params: [:chatbot_role],
        questions: @questions,
        system_one_model: mock,
        include_reason: false
      ]
      |> Keyword.merge(opts)
      |> ConversationalJevEval.new()

    {metric, mock}
  end

  defp measure!(metric, test_case \\ test_case()) do
    {:ok, result} = ConversationalJevEval.evaluate(metric, test_case)
    result
  end

  defp breakdown(%Result{score_breakdown: breakdown}),
    do: Enum.map(breakdown, &(&1 |> JSON.encode!() |> Jason.decode!()))

  describe "new/1" do
    test "appends :content then :role to the evaluation params" do
      {metric, _mock} = metric()
      assert metric.evaluation_params == [:chatbot_role, :content, :role]

      {metric, _mock} = metric(@answers, evaluation_params: [:role, :scenario])
      assert metric.evaluation_params == [:role, :scenario, :content]
    end

    test "requires evaluation params" do
      for params <- [nil, []] do
        assert_raise ArgumentError,
                     "evaluation_params cannot be empty; list the turn and conversation " <>
                       "fields your questions refer to.",
                     fn -> metric(@answers, evaluation_params: params) end
      end
    end

    test "rejects a param that is not a multi-turn param" do
      assert_raise ArgumentError, "expected a multi-turn param, got: :input", fn ->
        metric(@answers, evaluation_params: [:input])
      end
    end

    test "rejects no questions, or one that is not a Noul, Score or Choice" do
      assert_raise ArgumentError,
                   "JevEval needs at least one question (Noul, Score or Choice).",
                   fn -> metric(@answers, questions: []) end

      assert_raise ArgumentError, ~r/^Questions must be Noul, Score or Choice; got /, fn ->
        metric(@answers, questions: ["not a question"])
      end
    end

    test "raises when the System One model is not usable" do
      error =
        assert_raise DeepEvalError, fn ->
          ConversationalJevEval.new(
            name: "x",
            evaluation_params: [:content],
            questions: [Scored.Noul.new!(statement: "a")],
            system_one_model: {:typesafe, api_key: ""}
          )
        end

      assert error.message =~ ~r/^JevEval needs Jev to score, but it is not usable: /
    end

    test "forces the threshold to 1 in strict mode" do
      {metric, _mock} = metric(@answers, strict_mode: true, threshold: 0.3)
      assert metric.threshold == 1
    end

    test "names the metric '<name> [Conversational JevEval]' unless the suffix is off" do
      {metric, _mock} = metric()
      assert ConversationalJevEval.metric_name(metric) == "Support [Conversational JevEval]"
      assert measure!(metric).metric == "Support [Conversational JevEval]"

      {metric, _mock} = metric(@answers, include_jev_eval_suffix: false)
      assert ConversationalJevEval.metric_name(metric) == "Support"
      assert measure!(metric).metric == "Support"
    end
  end

  describe "the request" do
    test "is one decide call about the turns and the conversation-level params" do
      {metric, mock} =
        metric(@answers, evaluation_params: [:scenario, :chatbot_role, :user_description])

      measure!(metric)

      assert [call] = Mock.calls(mock)

      assert JSON.encode!(call.state, ensure_ascii: false) ==
               ~s({"turns": [{"content": "Can I change the address to Zürich?", "role": "user"}, ) <>
                 ~s({"content": "Done: order 42 now ships to Zürich.", "role": "assistant"}], ) <>
                 ~s("test_case": {"scenario": "An address change", ) <>
                 ~s("chatbot_role": "A courteous order support agent."}})

      assert Enum.map(call.questions, &elem(&1, 0)) == ["q_0", "q_1", "q_2"]
    end

    test "sends turn fields in the order of the params, without test_case when none is set" do
      test_case =
        test_case(
          turns: [
            %{role: :user, content: "Where is order 42?"},
            %{role: :assistant, content: "It shipped.", retrieval_context: ["Order 42 shipped."]}
          ]
        )

      {metric, mock} = metric(@answers, evaluation_params: [:role, :retrieval_context])
      measure!(metric, test_case)

      [call] = Mock.calls(mock)

      assert JSON.encode!(call.state) ==
               ~s({"turns": [{"role": "user", "content": "Where is order 42?"}, ) <>
                 ~s({"role": "assistant", "retrieval_context": ["Order 42 shipped."], ) <>
                 ~s("content": "It shipped."}]})
    end

    test "raises a System One error, as nothing falls back" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      {metric, _mock} = metric(@answers, system_one_model: Mock.new(raises: error))

      assert_raise Error, "Jev is down", fn -> measure!(metric) end
    end
  end

  describe "scoring" do
    test "is the weighted mean of the answers' values" do
      {metric, _mock} = metric()
      result = measure!(metric)

      expected = (2 * 0.80 + 1.2 / 2 + (0.6 + 0.3 * 0.5) / 0.95) / 4
      assert_in_delta result.score, expected, 1.0e-9
      assert result.success == true
      assert result.threshold == 0.5
      assert result.reason == nil
      # The least decisive answer: the Score's 0.4.
      assert_in_delta result.confidence, 0.4, 1.0e-9

      assert [%{"type" => "noul"}, %{"type" => "score"}, %{"type" => "choice"}] =
               breakdown(result)
    end

    test "in strict mode is 1 only when every applicable question is answered at its best" do
      {metric, _mock} = metric(@answers, strict_mode: true)
      result = measure!(metric)

      # The Score's likeliest level is "Partly", not the top one.
      assert result.score === 0.0
      assert result.threshold == 1
      assert result.success == false
      assert Enum.map(breakdown(result), & &1["passed"]) == [true, false, true]
    end
  end

  describe "the reason and verbose logs" do
    test "are deterministic text built from the answers" do
      {metric, _mock} = metric(@answers, include_reason: true)
      result = measure!(metric)

      assert String.starts_with?(result.reason, "Decided by fake-jev, minimum confidence 0.40.")
      for question <- @questions, do: assert(result.reason =~ Scored.text(question))
      assert result.reason =~ "Score: 0.7"

      assert String.starts_with?(
               result.verbose_logs,
               "Questions:\n1. [noul, weight=2] The assistant changes"
             )

      assert result.verbose_logs =~ ~r/ \n \nScore: 0\.747\d+\nConfidence: 0\.4$/
    end
  end

  describe "usage" do
    test "is always System One's, seeded as without an LLM, whatever the eval mode" do
      for mode <- [:llm, :hybrid, :system_one] do
        mock = Mock.new(answers: @answers, cost: {4.2e-05, 1000, 0})

        {:ok, result} =
          ConversationalJevEval.measure(test_case(),
            name: "Support",
            evaluation_params: [:chatbot_role],
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
  end

  describe "test case checks" do
    test "rejects a multimodal conversation before asking System One" do
      {metric, mock} = metric()

      multimodal =
        test_case(
          turns: [
            %{role: :user, content: "What is this? [DEEPEVAL:IMAGE:https://x/y.png]"},
            %{role: :assistant, content: "A cat."}
          ]
        )

      assert_raise ArgumentError,
                   "Support [Conversational JevEval] evaluates text only: Jev has no image " <>
                     "input. Pass a text-only ConversationalTestCase.",
                   fn -> measure!(metric, multimodal) end

      assert Mock.calls(mock) == []
    end

    test "requires the conversation-level params it names" do
      {metric, mock} = metric(@answers, evaluation_params: [:expected_outcome])

      assert {:error, {:missing_conversational_param, :expected_outcome}} =
               ConversationalJevEval.evaluate(metric, test_case())

      assert Mock.calls(mock) == []
    end

    test "requires a chatbot_role when :chatbot_role is a param" do
      {metric, mock} = metric()

      assert {:error, {:missing_conversational_param, :chatbot_role}} =
               ConversationalJevEval.evaluate(metric, test_case(chatbot_role: nil))

      assert Mock.calls(mock) == []
    end

    test "takes only a conversational test case" do
      {metric, mock} = metric()

      assert {:error, :not_conversational_test_case} =
               ConversationalJevEval.evaluate(metric, %TestCase{input: "hi", actual_output: "x"})

      assert Mock.calls(mock) == []
    end
  end

  describe "with the evaluator" do
    test "measures the struct and names the result" do
      {metric, _mock} = metric()
      result = Evaluator.evaluate_metric(test_case(), metric, [])

      assert result.metric == "Support [Conversational JevEval]"
      assert result.success == true
      assert result.evaluation_model == "fake-jev"
    end

    test "reports the configured name and System One model on an error" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

      {metric, _mock} =
        metric(@answers, system_one_model: Mock.new(raises: error, model: "fake-jev"))

      result = Evaluator.evaluate_metric(test_case(), metric, ignore_errors: true)

      assert result.metric == "Support [Conversational JevEval]"
      assert result.error == "Jev is down"
      assert result.evaluation_model == "fake-jev"
    end
  end
end
