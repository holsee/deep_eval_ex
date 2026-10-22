defmodule DeepEvalEx.SystemOne.AdapterCase.MockTest do
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.Error

  use DeepEvalEx.SystemOne.AdapterCase,
    async: true,
    model: Mock.new(answer_fn: Mock.answer_everything()),
    failing_model:
      Mock.new(
        raises: %Error{
          reason: :connection,
          type: "ConnectionError",
          message: "Jev is down"
        },
        raise?: true
      )
end

defmodule DeepEvalEx.SystemOne.AdapterCase.ToyProviderTest do
  alias DeepEvalEx.Test.SystemOneToy

  use DeepEvalEx.SystemOne.AdapterCase,
    async: true,
    model: {SystemOneToy, api_key: "k"},
    failing_model: {SystemOneToy, api_key: "k", down: true},
    init_failure: SystemOneToy
end

defmodule DeepEvalEx.SystemOne.AdapterCase.ContextModelTest do
  # The model comes from the test context, as a provider stubbing its
  # transport per test (Req.Test) sets it up.
  use DeepEvalEx.SystemOne.AdapterCase, async: true

  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.SystemOneStub

  setup do
    answer = Mock.answer_everything(0.4, 0.6)

    %{
      system_one_model:
        {SystemOneStub, decide: fn _state, questions, _opts -> {:ok, answer.(questions), nil} end}
    }
  end
end

defmodule DeepEvalEx.SystemOne.AdapterCaseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{AdapterCase, Answers, Error, Question}

  @questions [
    {"n", %Question.Noul{instructions: "?"}},
    {"c", %Question.Choice{instructions: "?", options: [{"a", nil}, {"b", nil}]}},
    {"s", %Question.Score{instructions: "?", levels: ["lo", "mid", "hi"]}}
  ]

  @good %Answers{
    nouls: %{"n" => %Answers.Noul{probability: 0.7}},
    choices: %{
      "c" => %Answers.Choice{
        choice: "a",
        probabilities: [{"a", 0.8}, {"b", 0.2}],
        confidence: 0.6
      }
    },
    scores: %{
      "s" => %Answers.Score{
        score: 1.5,
        probabilities: [{0, 0.1}, {1, 0.3}, {2, 0.6}],
        confidence: 0.4
      }
    }
  }

  defp fails(fun, message) do
    error = assert_raise ExUnit.AssertionError, fun
    assert error.message =~ message
  end

  describe "assert_answers/2" do
    test "accepts every key answered under its own type" do
      assert AdapterCase.assert_answers(@questions, @good) == :ok
    end

    test "rejects a key left unanswered, answered under another type or not asked" do
      fails(fn -> AdapterCase.assert_answers(@questions, %{@good | nouls: %{}}) end, ~s("n"))

      moved = %{@good | nouls: %{}, scores: Map.put(@good.scores, "n", @good.scores["s"])}
      fails(fn -> AdapterCase.assert_answers(@questions, moved) end, ~s("n"))

      extra = %{@good | nouls: Map.put(@good.nouls, "x", %Answers.Noul{probability: 0.1})}
      fails(fn -> AdapterCase.assert_answers(@questions, extra) end, ~s("x"))
    end

    test "rejects probabilities outside 0..1" do
      bad = put_in(@good.nouls["n"].probability, 1.2)
      fails(fn -> AdapterCase.assert_answers(@questions, bad) end, "probability")

      bad = put_in(@good.choices["c"].probabilities, [{"a", -0.1}])
      fails(fn -> AdapterCase.assert_answers(@questions, bad) end, "probabilit")
    end

    test "rejects a choice or probability that is not one of the options" do
      fails(
        fn -> AdapterCase.assert_answers(@questions, put_in(@good.choices["c"].choice, "z")) end,
        ~s("z")
      )

      bad = put_in(@good.choices["c"].probabilities, [{"z", 0.5}])
      fails(fn -> AdapterCase.assert_answers(@questions, bad) end, ~s("z"))
    end

    test "rejects Score levels that are not integers in range, and a score out of range" do
      for probabilities <- [[{3, 0.5}], [{"1", 0.5}], [{1.0, 0.5}]] do
        bad = put_in(@good.scores["s"].probabilities, probabilities)
        fails(fn -> AdapterCase.assert_answers(@questions, bad) end, "level")
      end

      fails(
        fn -> AdapterCase.assert_answers(@questions, put_in(@good.scores["s"].score, 2.5)) end,
        "score"
      )
    end

    test "rejects Choice and Score confidences outside [0, 1]" do
      fails(
        fn ->
          AdapterCase.assert_answers(@questions, put_in(@good.choices["c"].confidence, 1.5))
        end,
        "confidence"
      )

      fails(
        fn ->
          AdapterCase.assert_answers(@questions, put_in(@good.scores["s"].confidence, nil))
        end,
        "confidence"
      )
    end
  end

  test "assert_reply/2 checks the decide/3 reply shape and its usage" do
    assert AdapterCase.assert_reply(@questions, {:ok, @good, nil}) == :ok

    assert AdapterCase.assert_reply(@questions, {:ok, @good, %Usage{cost: 0.0, input_tokens: 3}}) ==
             :ok

    fails(fn -> AdapterCase.assert_reply(@questions, {:ok, @good, %{cost: 1.0}}) end, "usage")

    fails(
      fn -> AdapterCase.assert_reply(@questions, {:ok, @good, %Usage{input_tokens: -1}}) end,
      "usage"
    )

    fails(fn -> AdapterCase.assert_reply(@questions, {:ok, %{}, nil}) end, "Answers")
    fails(fn -> AdapterCase.assert_reply(@questions, :ok) end, "decide/3")
  end

  test "assert_error/1 checks an error is well formed" do
    assert AdapterCase.assert_error(%Error{
             reason: :connection,
             type: "ConnectionError",
             message: "x"
           }) == :ok

    assert AdapterCase.assert_error(%DeepEvalEx.DeepEvalError{message: "x"}) == :ok

    fails(
      fn -> AdapterCase.assert_error(%Error{reason: :oops, type: "X", message: "x"}) end,
      "reason"
    )

    fails(
      fn -> AdapterCase.assert_error(%Error{reason: :http, type: :x, message: "x"}) end,
      "type"
    )

    fails(
      fn ->
        AdapterCase.assert_error(%Error{reason: :http, type: "X", message: "x", permanent?: nil})
      end,
      "permanent?"
    )

    fails(
      fn ->
        AdapterCase.assert_error(%Error{reason: :context_limit, type: "X", estimated_tokens: -1})
      end,
      "tokens"
    )

    fails(fn -> AdapterCase.assert_error(:timeout) end, "exception")
  end

  test "assert_budget/1 takes positive {state, request} with state <= request, or :unbounded" do
    assert AdapterCase.assert_budget({32_000, 64_000}) == :ok
    assert AdapterCase.assert_budget(:unbounded) == :ok
    fails(fn -> AdapterCase.assert_budget({0, 1}) end, "budget")
    fails(fn -> AdapterCase.assert_budget({2, 1}) end, "budget")
  end
end
