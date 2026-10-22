defmodule DeepEvalEx.SystemOne.RunnerTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError, Result, TestCase}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Context, Error, EvalSpec, Model, Runner, Scored}
  alias DeepEvalEx.TestRun.JSON

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  defmodule WholeChain do
    @moduledoc false
    # A metric with a whole-chain form: its spec comes from opts[:test_spec],
    # and its own chain returns a fixed result.
    use DeepEvalEx.Metrics.BaseMetric

    alias DeepEvalEx.SystemOne.Runner

    @impl true
    def metric_name, do: "Whole Chain"

    @impl true
    def required_params, do: []

    @impl true
    def system_one_eval_spec(_test_case, opts), do: Keyword.get(opts, :test_spec)

    def do_measure(test_case, opts) do
      case Runner.run(__MODULE__, test_case, opts) do
        {:ok, result} -> {:ok, result}
        :continue -> {:ok, Result.new(metric: metric_name(), score: 0.5, reason: "LLM chain")}
      end
    end
  end

  defmodule NoForm do
    @moduledoc false
    use DeepEvalEx.Metrics.BaseMetric

    @impl true
    def metric_name, do: "No Form"

    @impl true
    def required_params, do: []
  end

  @test_case %TestCase{
    input: "What is the capital of France?",
    actual_output: "Paris.",
    retrieval_context: ["Paris is the capital of France."]
  }

  @spec_ %EvalSpec{
    evaluation_params: [:actual_output, :retrieval_context, :expected_output],
    questions: [
      %Scored.Noul{statement: "`actual_output` is grounded.", weight: 2.0},
      %Scored.Score{question: "How grounded?", levels: ["Low", "Mid", "High"]}
    ]
  }

  @answers %Answers{
    nouls: %{"q_0" => %Answers.Noul{probability: 0.9}},
    scores: %{
      "q_1" => %Answers.Score{
        score: 2.0,
        probabilities: [{0, 0.1}, {1, 0.2}, {2, 0.7}],
        confidence: 0.6
      }
    }
  }

  defp opts(mode, mock, extra \\ []) do
    Keyword.merge([eval_mode: mode, system_one_model: mock, test_spec: @spec_], extra)
  end

  describe "run/3" do
    test "decides the whole measure in one request about the test case" do
      mock = Mock.new(answers: @answers, cost: {4.2e-05, 1000, 0})

      {:ok, result} = WholeChain.measure(@test_case, opts(:system_one, mock))

      [call] = Mock.calls(mock)

      assert JSON.encode!(call.state) ==
               ~s({"test_case": {"actual_output": "Paris.", ) <>
                 ~s("retrieval_context": ["Paris is the capital of France."]}})

      assert Enum.map(call.questions, &elem(&1, 0)) == ["q_0", "q_1"]

      # (2 * 0.9 + 1 * 1.0) / 3
      assert result.score == 0.9333333333333332
      assert result.success
      assert result.confidence == 0.6
      assert result.evaluation_model == "fake-jev"
      assert result.evaluation_cost == 4.2e-05
      assert result.input_tokens == 1000
      assert result.strict_applied

      assert result.reason ==
               """
               Decided by fake-jev, minimum confidence 0.60.
               1. `actual_output` is grounded. -> clearly holds (P(yes)=0.90, confidence=0.80, weight=2)
               2. How grounded? -> "High" (expected level=1.00 of 1.00, confidence=0.60)
               Score: 0.93 (weighted mean of 2 applicable questions).\
               """

      assert result.verbose_logs ==
               """
               Decided by System One (fake-jev); no LLM call was made. \n \nQuestions:
               1. [noul, weight=2] `actual_output` is grounded.
                  value=0.900 applicable=True probabilities={'true': 0.9, 'false': 0.1} confidence=0.800
               2. [score, weight=1] How grounded?
                  value=1.000 applicable=True probabilities={'Low': 0.1, 'Mid': 0.2, 'High': 0.7} confidence=0.600\
               """

      assert [first, _second] = result.score_breakdown

      assert JSON.encode!(first) =~
               ~s({"question": "`actual_output` is grounded.", "type": "noul")
    end

    test "is :continue unless the eval mode is system_one" do
      mock = Mock.new(answers: @answers)

      for mode <- [:llm, :hybrid] do
        assert {:ok, %Result{reason: "LLM chain"}} =
                 WholeChain.measure(@test_case, opts(mode, mock))
      end

      assert Mock.calls(mock) == []
    end

    test "is :continue for a metric without a whole-chain form, which runs as hybrid" do
      assert :continue =
               Runner.run(NoForm, @test_case, eval_mode: :system_one, system_one_model: :mock)
    end

    test "raises deepeval's error for a nil spec when the metric has no LLM" do
      mock = Mock.new(answers: @answers)

      message =
        "DEEPEVAL_EVAL_MODE=system_one runs Whole Chain on System One, which cannot judge " <>
          "this test case. Switch it back to the LLM with `eval_mode=\"llm\"` or " <>
          "`deepeval set-eval-mode llm`."

      assert_raise DeepEvalError, message, fn ->
        WholeChain.measure(@test_case, opts(:system_one, mock, test_spec: nil))
      end
    end

    test "is :continue for a nil spec when the metric has an LLM" do
      context = %Context{mode: :system_one, model: Model.resolve(Mock.new()), llm?: true}

      assert :continue =
               Runner.run(WholeChain, @test_case, system_one: context, test_spec: nil)
    end

    test "raises when the context has no System One model" do
      context = %Context{mode: :system_one, model: nil, llm?: false}

      assert_raise DeepEvalError, ~r/^DEEPEVAL_EVAL_MODE=system_one runs WholeChain on a/, fn ->
        Runner.run(WholeChain, @test_case, system_one: context, test_spec: @spec_)
      end
    end

    test "checks the context budget before sending and raises the switch-to-llm error" do
      mock = Mock.new(answers: @answers)
      # Over Jev's 32,000-token state budget at 3 characters a token.
      big = %TestCase{input: "Q", actual_output: String.duplicate("x", 100_000)}

      error =
        assert_raise ContextWindowExceededError, fn ->
          WholeChain.measure(big, opts(:system_one, mock))
        end

      assert error.message =~ ~r/^Whole Chain could not run on System One: System One state/
      assert error.message =~ "exceeds the 32000-token state budget"
      assert error.message =~ "Switch this metric back to the LLM"
      assert Mock.calls(mock) == []
    end

    test "rewraps a context limit the model reports as the switch-to-llm error" do
      mock =
        Mock.new(
          raises: %Error{
            reason: :context_limit,
            message: "Jev rejected the request as too large."
          }
        )

      error =
        assert_raise ContextWindowExceededError, fn ->
          WholeChain.measure(@test_case, opts(:system_one, mock))
        end

      assert error.message =~
               "Whole Chain could not run on System One: Jev rejected the request as too large."
    end

    test "raises any other System One error unchanged: nothing falls back" do
      down = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      mock = Mock.new(raises: down)

      assert_raise Error, "Jev is down", fn ->
        WholeChain.measure(@test_case, opts(:system_one, mock))
      end
    end

    test "raises deepeval's error when an answer is missing" do
      mock = Mock.new(answers: %Answers{nouls: @answers.nouls})

      assert_raise DeepEvalError, "Jev returned no Score answer for q_1.", fn ->
        WholeChain.measure(@test_case, opts(:system_one, mock))
      end
    end

    test "scores strictly under strict_mode and keeps the float score" do
      mock = Mock.new(answers: put_in(@answers.nouls["q_0"].probability, 0.4))

      {:ok, result} = WholeChain.measure(@test_case, opts(:system_one, mock, strict_mode: true))

      assert result.score === 0.0
      assert result.threshold == 1
      refute result.success
      assert result.reason =~ "-> unclear (P(yes)=0.40, confidence=0.20, weight=2) strict=fail"

      assert result.reason =~
               "Score: 0.00 (strict mode: at least one applicable question failed)."
    end

    test "leaves the reason out with include_reason: false" do
      mock = Mock.new(answers: @answers)

      {:ok, result} =
        WholeChain.measure(@test_case, opts(:system_one, mock, include_reason: false))

      assert result.reason == nil
      assert result.verbose_logs =~ "Decided by System One (fake-jev)"
    end

    test "uses a batch prefetch's answers and usage share instead of a request" do
      mock = Mock.new(answers: @answers)
      share = %Usage{cost: 1.0e-05, input_tokens: 250, output_tokens: 0, source: :system_one}

      {:ok, result} =
        WholeChain.measure(
          @test_case,
          opts(:system_one, mock, system_one_prefetched: {:answers, @answers, share})
        )

      assert Mock.calls(mock) == []
      assert result.score == 0.9333333333333332
      assert result.evaluation_cost == 1.0e-05
      assert result.input_tokens == 250
    end

    test "raises a batch prefetch's error" do
      mock = Mock.new(answers: @answers)
      down = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

      assert_raise Error, "Jev is down", fn ->
        WholeChain.measure(
          @test_case,
          opts(:system_one, mock, system_one_prefetched: {:error, down})
        )
      end

      assert Mock.calls(mock) == []
    end
  end

  # deepeval's whole-chain metrics and JevEval run through the same
  # populate: replaying each fixture's questions through the runner must
  # send the same request and reach the same measure, byte for byte.
  describe "System One fixtures" do
    for scenario <-
          ~w(faithfulness_system_one faithfulness_system_one_strict hallucination_system_one
             answer_relevancy_system_one contextual_precision_system_one
             contextual_recall_system_one jev_eval jev_eval_strict_not_applicable) do
      test "#{scenario} is decided as deepeval decides it" do
        fixture = fixture(unquote(scenario))
        mock = Mock.from_fixture(fixture.input["system_one"])
        [metric] = fixture.input["metrics"]

        {:ok, result} =
          WholeChain.measure(
            TestCase.new!(fixture.input["test_case"]),
            [
              eval_mode: :system_one,
              system_one_model: mock,
              test_spec: fixture.spec
            ] ++ metric_opts(metric["params"])
          )

        assert dump(Mock.dump_calls(mock)) == dump(hd(fixture.decide["measure"]))

        [measured] = fixture.measure

        for key <- ~w(score success reason threshold evaluation_model confidence) do
          assert {key, Map.fetch!(Map.from_struct(result), String.to_atom(key))} ==
                   {key, measured[key]}
        end

        assert dump(result.score_breakdown) == dump(measured["score_breakdown"])
        assert is_float(result.score)

        # JevEval writes its own verbose logs (P4-6).
        if metric["kind"] != "jev_eval" do
          assert result.verbose_logs == measured["verbose_logs"]
        end

        # Without token counts from the model, the seed (P3-11) sets them.
        if is_map(fixture.input["system_one"]["cost"]) do
          assert result.evaluation_cost == measured["evaluation_cost"]
          assert result.input_tokens == measured["input_tokens"]
          assert result.output_tokens == measured["output_tokens"]
        end
      end
    end
  end

  defp metric_opts(params) do
    for {key, value} <- params, key in ~w(threshold strict_mode), do: {String.to_atom(key), value}
  end

  defp fixture(scenario) do
    load = fn file ->
      [@fixtures, scenario, file]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)
    end

    input = load.("input.json")
    decide = load.("decide.json")
    measure = load.("measure.json") |> Enum.map(&ordered_to_map/1)

    %{input: input, decide: decide, measure: measure, spec: spec(input, decide, measure)}
  end

  # JevEval's own questions, or a built-in metric's from its recorded
  # request and score breakdown (weights are not sent).
  defp spec(input, decide, [measured]) do
    [metric] = input["metrics"]
    [[call]] = decide["measure"]

    questions =
      case metric["kind"] do
        "jev_eval" ->
          metric["params"]["questions"] |> JSON.encode!() |> Scored.parse!()

        _kind ->
          for {{_key, question}, outcome} <-
                Enum.zip(call["questions"].values, measured["score_breakdown"]),
              do: scored(question, outcome["weight"])
      end

    %EvalSpec{
      evaluation_params: Enum.map(call["state"]["test_case"].values, &elem(&1, 0)),
      questions: questions
    }
  end

  defp scored(question, weight), do: scored(question["type"], question, weight)

  defp scored("noul", question, weight) do
    {yes, no} =
      case question["criteria"] do
        nil -> {nil, nil}
        criteria -> {criteria["true"], criteria["false"]}
      end

    Scored.Noul.new!(statement: question["instructions"], weight: weight, true: yes, false: no)
  end

  defp scored("score", question, weight),
    do:
      Scored.Score.new!(
        question: question["instructions"],
        levels: question["criteria"],
        weight: weight
      )

  # The measure's top-level keys as a map; nested objects stay ordered.
  defp ordered_to_map(%Jason.OrderedObject{values: values}), do: Map.new(values)

  defp dump(term), do: JSON.encode!(term, indent: 2, ensure_ascii: false)
end
