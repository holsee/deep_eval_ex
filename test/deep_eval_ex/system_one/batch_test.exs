defmodule DeepEvalEx.SystemOne.BatchTest do
  use ExUnit.Case, async: true

  doctest DeepEvalEx.SystemOne.Batch

  alias DeepEvalEx.{ContextWindowExceededError, TestCase}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Batch, Context, Error, EvalSpec, Scored}
  alias DeepEvalEx.Test.SystemOneStub
  alias DeepEvalEx.TestRun.JSON

  defmodule Judged do
    @moduledoc false
    # A whole-chain metric whose spec comes from opts[:test_spec].
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "Judged"

    @impl true
    def required_params, do: [:actual_output]

    @impl true
    def system_one_eval_spec(_test_case, opts), do: Keyword.get(opts, :test_spec)
  end

  defmodule NeedsContext do
    @moduledoc false
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "Needs Context"

    @impl true
    def required_params, do: [:actual_output, :retrieval_context]

    @impl true
    def system_one_eval_spec(_test_case, opts), do: Keyword.get(opts, :test_spec)
  end

  defmodule ConversationalJudged do
    @moduledoc false
    # A whole-chain conversational metric whose spec comes from
    # opts[:test_spec].
    use DeepEvalEx.Metrics.BaseConversationalMetric

    @impl true
    def metric_name, do: "Conversational Judged"

    @impl true
    def required_params, do: [:content]

    @impl true
    def system_one_eval_spec(_test_case, opts), do: Keyword.get(opts, :test_spec)
  end

  @test_case %TestCase{input: "Q?", actual_output: "A."}

  defp spec(params, statement, extra_state \\ []) do
    %EvalSpec{
      evaluation_params: params,
      questions: [%Scored.Noul{statement: statement}],
      extra_state: extra_state
    }
  end

  defp entry(module, mode, model, spec, extra \\ []) do
    opts = [eval_mode: mode, system_one_model: model, test_spec: spec] ++ extra
    {module, Keyword.put(opts, :system_one, Context.resolve!(module, opts))}
  end

  defp encode(term), do: JSON.encode!(term)

  describe "prefetch/3" do
    test "asks one request for every :system_one metric and hands each its answers" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8), cost: {0.0003, 300, 0})

      outcomes =
        Batch.prefetch(@test_case, [
          entry(Judged, :system_one, mock, spec([:input], "`input` is a question.")),
          entry(Judged, :system_one, mock, spec([:actual_output], "`actual_output` answers."))
        ])

      assert [%Mock.Call{state: state, questions: questions}] = Mock.calls(mock)
      assert encode(state) == ~s({"test_case": {"input": "Q?", "actual_output": "A."}})
      assert Enum.map(questions, &elem(&1, 0)) == ["m0.q_0", "m1.q_0"]

      assert [
               {:answers, %Answers{nouls: %{"q_0" => %Answers.Noul{probability: 0.8}}},
                %Usage{cost: 0.00015, input_tokens: 150, output_tokens: 0}},
               {:answers, %Answers{nouls: %{"q_0" => _}}, %Usage{input_tokens: 150}}
             ] = outcomes
    end

    test "batches the conversational metrics of a conversational test case, merging each turn" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8), cost: {0.0002, 200, 0})

      conversation =
        DeepEvalEx.ConversationalTestCase.new!(
          scenario: "Greeting",
          turns: [%{role: :user, content: "Hi"}, %{role: :assistant, content: "Hello!"}]
        )

      outcomes =
        Batch.prefetch(conversation, [
          entry(ConversationalJudged, :system_one, mock, spec([:content], "Polite.")),
          entry(Judged, :system_one, mock, spec([:input], "S")),
          entry(ConversationalJudged, :system_one, mock, spec([:role, :scenario], "On topic."))
        ])

      assert [%Mock.Call{state: state, questions: questions}] = Mock.calls(mock)

      assert encode(state) ==
               ~s({"turns": [{"content": "Hi", "role": "user"}, ) <>
                 ~s({"content": "Hello!", "role": "assistant"}], "test_case": {"scenario": "Greeting"}})

      assert Enum.map(questions, &elem(&1, 0)) == ["m0.q_0", "m1.q_0"]
      assert [{:answers, _, %Usage{input_tokens: 100}}, nil, {:answers, _, _}] = outcomes
    end

    test "batches nothing on a multimodal conversational test case" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      conversation =
        DeepEvalEx.ConversationalTestCase.new!(
          turns: [%{role: :user, content: "What is this? [DEEPEVAL:IMAGE:img-1]"}]
        )

      assert Batch.prefetch(conversation, [
               entry(ConversationalJudged, :system_one, mock, spec([:content], "S")),
               entry(ConversationalJudged, :system_one, mock, spec([:content], "S"))
             ]) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "batches nothing on a multimodal single-turn test case" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))
      test_case = DeepEvalEx.TestCase.new!(input: "What is this? [DEEPEVAL:IMAGE:img-1]")

      assert Batch.prefetch(test_case, [
               entry(Judged, :system_one, mock, spec([:input], "S")),
               entry(Judged, :system_one, mock, spec([:input], "S"))
             ]) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "batches no conversational metric on a single-turn test case" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      assert Batch.prefetch(@test_case, [
               entry(ConversationalJudged, :system_one, mock, spec([:content], "S")),
               entry(ConversationalJudged, :system_one, mock, spec([:content], "S"))
             ]) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "batches no single-turn metric on a conversational test case, leaving each its own measure" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      conversation =
        DeepEvalEx.ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}])

      assert Batch.prefetch(conversation, [
               entry(Judged, :system_one, mock, spec([:input], "S")),
               entry(Judged, :system_one, mock, spec([:input], "S"))
             ]) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "batches nothing with fewer than two :system_one metrics" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      assert Batch.prefetch(@test_case, [
               entry(Judged, :system_one, mock, spec([:input], "S")),
               entry(Judged, :hybrid, mock, spec([:input], "S"))
             ]) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "counts a metric without a spec for the test case, then leaves it to its own measure" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))
      # As ToolCorrectness, whose spec is always nil.
      spec_less = entry(Judged, :system_one, mock, nil)

      assert [nil, {:answers, _answers, _usage}] =
               Batch.prefetch(@test_case, [
                 spec_less,
                 entry(Judged, :system_one, mock, spec([:input], "S"))
               ])

      # Alone in its request, the metric's keys are still prefixed.
      assert [%Mock.Call{questions: [{"m0.q_0", _}]}] = Mock.calls(mock)
    end

    test "leaves out a metric reusing a cached result; the others keep m<j>. by their place" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      assert [nil, {:answers, _, _}, {:answers, _, _}] =
               Batch.prefetch(
                 @test_case,
                 [
                   entry(Judged, :system_one, mock, spec([:input], "S")),
                   entry(Judged, :system_one, mock, spec([:input], "T")),
                   entry(Judged, :system_one, mock, spec([:actual_output], "U"))
                 ],
                 cached: MapSet.new([0])
               )

      assert [%Mock.Call{questions: [{"m0.q_0", %{instructions: "T"}}, {"m1.q_0", _}]}] =
               Mock.calls(mock)
    end

    test "batches nothing when a cached result leaves one :system_one metric" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      assert Batch.prefetch(
               @test_case,
               [
                 entry(Judged, :system_one, mock, spec([:input], "S")),
                 entry(Judged, :system_one, mock, spec([:input], "T"))
               ],
               cached: MapSet.new([1])
             ) == [nil, nil]

      assert Mock.calls(mock) == []
    end

    test "sends one request per model name" do
      a = Mock.new(answer_fn: Mock.noul_answers(0.8), model: "jev-a")
      b = Mock.new(answer_fn: Mock.noul_answers(0.8), model: "jev-b")

      Batch.prefetch(@test_case, [
        entry(Judged, :system_one, a, spec([:input], "S")),
        entry(Judged, :system_one, b, spec([:input], "S")),
        entry(Judged, :system_one, a, spec([:actual_output], "T"))
      ])

      assert [%Mock.Call{questions: [{"m0.q_0", _}, {"m1.q_0", _}]}] = Mock.calls(a)
      assert [%Mock.Call{questions: [{"m0.q_0", _}]}] = Mock.calls(b)
    end

    test "starts a new request for a state that conflicts with the request's" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      Batch.prefetch(@test_case, [
        entry(Judged, :system_one, mock, spec([:input], "S", topics: ["a"])),
        entry(Judged, :system_one, mock, spec([:input], "S", topics: ["b"])),
        entry(Judged, :system_one, mock, spec([:input], "S", topics: ["a"]))
      ])

      # The two requests run concurrently, so the Mock may record either first.
      calls = Mock.calls(mock)
      assert length(calls) == 2
      {[merged], [conflicting]} = Enum.split_with(calls, &(length(&1.questions) == 2))
      assert Enum.map(merged.questions, &elem(&1, 0)) == ["m0.q_0", "m1.q_0"]
      assert encode(merged.state) =~ ~s("topics": ["a"])
      assert encode(conflicting.state) =~ ~s("topics": ["b"])
    end

    test "starts a new request when the merged request would exceed the context budget" do
      parent = self()

      model =
        {SystemOneStub,
         budget: {1_000, 40},
         decide: fn _state, questions, _opts ->
           send(parent, {:asked, Enum.map(questions, &elem(&1, 0))})
           {:ok, %Answers{}, nil}
         end}

      statement = String.duplicate("x", 30)

      Batch.prefetch(@test_case, [
        entry(Judged, :system_one, model, spec([:input], statement)),
        entry(Judged, :system_one, model, spec([:input], statement))
      ])

      assert_received {:asked, ["m0.q_0"]}
      assert_received {:asked, ["m0.q_0"]}
    end

    test "fails every metric of a failed request with deepeval's error text" do
      down = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      mock = Mock.new(raises: down)

      assert [{:error, error}, {:error, error}] =
               Batch.prefetch(@test_case, [
                 entry(Judged, :system_one, mock, spec([:input], "S")),
                 entry(Judged, :system_one, mock, spec([:input], "T"))
               ])

      assert %Batch.Error{message: "ConnectionError: Jev is down", original: ^down} = error
    end

    test "reports a lone metric's context overflow as its own" do
      model = {SystemOneStub, budget: {1_000, 10}, decide: fn _, _, _ -> flunk("sent") end}
      fits = {SystemOneStub, decide: fn _, _, _ -> {:ok, %Answers{}, nil} end, name: "other"}

      assert [{:error, %Batch.Error{original: %ContextWindowExceededError{} = error}}, _fits] =
               Batch.prefetch(@test_case, [
                 entry(Judged, :system_one, model, spec([:input], String.duplicate("x", 60))),
                 entry(Judged, :system_one, fits, spec([:input], "S"))
               ])

      assert Exception.message(error) =~ "Judged could not run on System One: "
    end

    test "fails a metric whose test case lacks its params without asking for it" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.8))

      assert [{:setup_failed, error}, {:answers, _, _}, {:answers, _, _}] =
               Batch.prefetch(@test_case, [
                 entry(NeedsContext, :system_one, mock, spec([:input], "S")),
                 entry(Judged, :system_one, mock, spec([:input], "S")),
                 entry(Judged, :system_one, mock, spec([:input], "T"))
               ])

      assert error == %Batch.Error{
               message:
                 "MissingTestCaseParamsError: 'retrieval_context' cannot be None for the " <>
                   "'Needs Context' metric",
               original: {:missing_params, [:retrieval_context]}
             }

      assert [%Mock.Call{questions: [{"m0.q_0", _}, {"m1.q_0", _}]}] = Mock.calls(mock)
    end
  end

  describe "apportion/2" do
    test "rounds each running share half to even, as Python's round" do
      # 1.5 rounds to 2, 2.5 to 2.
      assert Batch.apportion(3, [1, 1]) == [2, 1]
      assert Batch.apportion(5, [1, 1]) == [2, 3]
      assert Batch.apportion(0, [2, 1]) == [0, 0]
    end

    test "parts always add up to the total" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..500 do
        weights = for _ <- 1..:rand.uniform(6), do: :rand.uniform(12)
        total = :rand.uniform(100_000) - 1
        parts = Batch.apportion(total, weights)

        assert Enum.sum(parts) == total
        assert Enum.all?(parts, &(&1 >= 0))
      end
    end
  end

  describe "split_usage/2" do
    test "gives nil shares of an unpriced request" do
      assert Batch.split_usage(nil, [1, 2]) == [nil, nil]
    end

    test "splits a cost without token counts" do
      usage = %Usage{cost: 0.3, source: :system_one, model: "fake-jev"}

      assert [
               %Usage{cost: 0.09999999999999999, input_tokens: nil, model: "fake-jev"},
               %Usage{cost: 0.19999999999999998, input_tokens: nil}
             ] = Batch.split_usage(usage, [1, 2])
    end
  end
end
