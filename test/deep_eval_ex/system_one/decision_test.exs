defmodule DeepEvalEx.SystemOne.DecisionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Context, Decision, Error, Ledger, Model, Question, Spec}
  alias DeepEvalEx.TestRun.JSON
  alias Jason.OrderedObject

  doctest Decision

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  @jev_down %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

  @binary %Spec.Binary{
    instructions: "`actual_output` answers `input`.",
    state: [input: "Q", actual_output: "A"]
  }

  @choice %Spec.Choice{
    instructions: "Which tone does `actual_output` take?",
    options: ["formal", "casual"],
    state: [actual_output: "Hey there!"]
  }

  @score %Spec.Score{
    instructions: "How relevant is `actual_output`?",
    levels: ["Low", "Medium", "High"],
    state: %{"actual_output" => "A"}
  }

  # The options do_measure/2 gets: the resolved System One context.
  defp opts(mode, model, extra \\ []) do
    model = if model, do: Model.resolve(model)
    [{:system_one, %Context{mode: mode, model: model, llm?: mode != :system_one}} | extra]
  end

  # Runs `fun` as a measure does: in a usage scope and a fresh ledger.
  defp measure(fun) do
    {{result, usages}, ledger} = Ledger.track(fn -> Usage.track(fun) end)
    {result, usages, ledger}
  end

  defp choice_answers(_questions) do
    %Answers{
      choices: %{
        "verdict" => %Answers.Choice{
          choice: "casual",
          probabilities: [{"formal", 0.2}, {"casual", 0.8}],
          confidence: 0.6
        }
      }
    }
  end

  defp score_answers(_questions) do
    %Answers{
      scores: %{
        "verdict" => %Answers.Score{
          score: 1,
          probabilities: [{0, 0.2}, {1, 0.5}, {2, 0.3}],
          confidence: 0.4
        }
      }
    }
  end

  describe "probability/2" do
    test "asks one Noul keyed \"verdict\" about the spec's state" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.9))

      assert {{:ok, 0.9}, _usages, _ledger} =
               measure(fn -> Decision.probability(@binary, opts(:hybrid, mock)) end)

      assert [call] = Mock.calls(mock)

      assert call.state ==
               OrderedObject.new([{"input", "Q"}, {"actual_output", "A"}])

      assert call.questions == [
               {"verdict", %Question.Noul{instructions: "`actual_output` answers `input`."}}
             ]
    end

    test "books the request's usage and folds its confidence into the ledger" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.9), cost: {4.2e-05, 1000, 0})

      {_result, usages, ledger} =
        measure(fn -> Decision.probability(@binary, opts(:hybrid, mock)) end)

      assert [
               %Usage{
                 source: :system_one,
                 model: "fake-jev",
                 cost: 4.2e-05,
                 input_tokens: 1000,
                 output_tokens: 0
               }
             ] = usages

      assert ledger.confidence == 0.8
      assert ledger.fallback_reasons == []
    end

    test "books an unpriced request as a nil cost, which voids the summed cost" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.9), cost: nil)

      {_result, usages, _ledger} =
        measure(fn -> Decision.probability(@binary, opts(:hybrid, mock)) end)

      assert [%Usage{source: :system_one, cost: nil, input_tokens: nil}] = usages
      assert Usage.summarize(usages).evaluation_cost == nil
    end

    test "keeps the lowest confidence of the measure" do
      low = Mock.new(answer_fn: Mock.noul_answers(0.6))
      high = Mock.new(answer_fn: Mock.noul_answers(0.95))

      {_result, _usages, ledger} =
        measure(fn ->
          Decision.probability(@binary, opts(:hybrid, high))
          Decision.probability(@binary, opts(:hybrid, low))
          Decision.probability(@binary, opts(:hybrid, high))
        end)

      assert ledger.confidence == 0.19999999999999996
    end

    test "is :llm under the llm mode, with no request" do
      assert {:llm, [], %Ledger{confidence: nil}} =
               measure(fn -> Decision.probability(@binary, opts(:llm, nil)) end)
    end

    test "is :llm without a spec or a System One context" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.9))

      assert Decision.probability(nil, opts(:hybrid, mock)) == :llm
      assert Decision.probability(@binary, []) == :llm
      assert Mock.calls(mock) == []
    end

    test "is :llm with no request once the measure disabled System One" do
      mock = Mock.new(answer_fn: Mock.noul_answers(0.9))

      {result, _usages, _ledger} =
        measure(fn ->
          Ledger.disable()
          Decision.probability(@binary, opts(:hybrid, mock))
        end)

      assert result == :llm
      assert Mock.calls(mock) == []
    end

    test "raises when the mode uses System One but no model is configured" do
      message =
        "DEEPEVAL_EVAL_MODE=hybrid routes decisions to a System One model, but " <>
          "Faithfulness has none configured. Set TYPESAFE_API_KEY or switch back " <>
          "with `deepeval set-eval-mode llm`."

      assert_raise DeepEvalError, message, fn ->
        Decision.probability(@binary, opts(:hybrid, nil, metric_name: "Faithfulness"))
      end
    end

    test "lets a missing answer crash rather than fall back" do
      mock = Mock.new(answers: %Answers{})

      assert_raise KeyError, fn ->
        measure(fn -> Decision.probability(@binary, opts(:hybrid, mock)) end)
      end
    end
  end

  describe "probability/2 when the request fails under hybrid" do
    test "hands the decision to the LLM and records why" do
      mock = Mock.new(raises: @jev_down)

      {result, usages, ledger} =
        measure(fn -> Decision.probability(@binary, opts(:hybrid, mock)) end)

      assert result == :llm
      assert usages == []
      assert ledger.confidence == nil
      assert Ledger.fallback_reason(ledger) == "ConnectionError: Jev is down"
    end

    test "joins the reasons of several failed decisions with \"; \"" do
      down = Mock.new(raises: @jev_down)
      slow = Mock.new(raises: %Error{reason: :timeout, type: "TimeoutError", message: "slow"})

      {_result, _usages, ledger} =
        measure(fn ->
          Decision.probability(@binary, opts(:hybrid, down))
          Decision.score(@score, opts(:hybrid, slow))
        end)

      assert Ledger.fallback_reason(ledger) == "ConnectionError: Jev is down; timeout (slow)"
      refute ledger.disabled?
    end

    test "keeps the rest of the measure on the LLM after a permanent failure" do
      auth =
        Mock.new(
          raises: %Error{
            reason: :auth,
            type: "TypeSafeAuthenticationError",
            message: "bad key",
            permanent?: true
          }
        )

      {results, _usages, ledger} =
        measure(fn ->
          [
            Decision.probability(@binary, opts(:hybrid, auth)),
            Decision.probability(@binary, opts(:hybrid, auth))
          ]
        end)

      assert results == [:llm, :llm]
      assert ledger.disabled?
      assert length(Mock.calls(auth)) == 1
      assert Ledger.fallback_reason(ledger) == "TypeSafeAuthenticationError: bad key"
    end

    test "describes a context overflow" do
      overflow =
        Mock.new(
          raises: %Error{
            reason: :context_limit,
            type: "SystemOneContextLimitError",
            message: "too big",
            estimated_tokens: 32_001,
            limit_tokens: 32_000
          }
        )

      {:llm, _usages, ledger} =
        measure(fn -> Decision.probability(@binary, opts(:hybrid, overflow)) end)

      assert Ledger.fallback_reason(ledger) == "context limit (32001 est. tokens > 32000)"
    end
  end

  describe "handle_failure/2" do
    test "under hybrid notes the failure and returns :llm" do
      {result, _usages, ledger} =
        measure(fn -> Decision.handle_failure(@jev_down, opts(:hybrid, Mock.new())) end)

      assert result == :llm
      assert Ledger.fallback_reason(ledger) == "ConnectionError: Jev is down"
      refute ledger.disabled?
    end

    test "under hybrid disables System One for a missing API key or SDK, as deepeval" do
      for message <- ["TYPESAFE_API_KEY is not set: no API key", "typesafe_sdk is missing"] do
        {:llm, _usages, ledger} =
          measure(fn ->
            Decision.handle_failure(
              %DeepEvalError{message: message},
              opts(:hybrid, Mock.new())
            )
          end)

        assert ledger.disabled?, message
        assert Ledger.fallback_reason(ledger) == "DeepEvalError: #{message}"
      end
    end

    test "under hybrid keeps System One on for any other DeepEvalError" do
      {:llm, _usages, ledger} =
        measure(fn ->
          Decision.handle_failure(%DeepEvalError{message: "bad JSON"}, opts(:hybrid, Mock.new()))
        end)

      refute ledger.disabled?
    end

    test "under system_one raises a context overflow as the switch-back-to-llm error" do
      overflow = %Error{
        reason: :context_limit,
        type: "SystemOneContextLimitError",
        message: "System One state is too large.",
        estimated_tokens: 40_000,
        limit_tokens: 32_000
      }

      message =
        "Tool Correctness could not run on System One: System One state is too large. " <>
          "This test case is too large for Jev to judge in one request. Switch this " <>
          "metric back to the LLM with `eval_mode=\"llm\"` or `deepeval set-eval-mode llm`."

      assert_raise ContextWindowExceededError, message, fn ->
        Decision.handle_failure(
          overflow,
          opts(:system_one, Mock.new(), metric_name: "Tool Correctness")
        )
      end
    end

    test "under system_one re-raises any other System One error unchanged" do
      assert_raise Error, "Jev is down", fn ->
        Decision.handle_failure(@jev_down, opts(:system_one, Mock.new()))
      end
    end

    test "re-raises an error that is not a System One error, even under hybrid" do
      assert_raise ArgumentError, "bug", fn ->
        Decision.handle_failure(%ArgumentError{message: "bug"}, opts(:hybrid, Mock.new()))
      end
    end
  end

  describe "choice/2" do
    test "asks one Choice over the spec's options and returns its answer" do
      mock = Mock.new(answer_fn: &choice_answers/1)

      {result, _usages, ledger} =
        measure(fn -> Decision.choice(@choice, opts(:hybrid, mock)) end)

      assert {:ok, %Answers.Choice{choice: "casual", confidence: 0.6}} = result
      assert ledger.confidence == 0.6

      assert [%{questions: [{"verdict", question}]}] = Mock.calls(mock)

      assert question == %Question.Choice{
               instructions: "Which tone does `actual_output` take?",
               options: [{"formal", nil}, {"casual", nil}]
             }
    end

    test "falls back to the LLM when the request fails under hybrid" do
      {result, _usages, ledger} =
        measure(fn -> Decision.choice(@choice, opts(:hybrid, Mock.new(raises: @jev_down))) end)

      assert result == :llm
      assert Ledger.fallback_reason(ledger) == "ConnectionError: Jev is down"
    end

    test "is :llm under the llm mode" do
      assert Decision.choice(@choice, opts(:llm, nil)) == :llm
    end
  end

  describe "score/2" do
    test "asks one Score over the spec's levels and returns it on 0..1" do
      mock = Mock.new(answer_fn: &score_answers/1)

      {result, _usages, ledger} = measure(fn -> Decision.score(@score, opts(:hybrid, mock)) end)

      assert result == {:ok, 0.5}
      assert ledger.confidence == 0.4

      assert [%{state: %{"actual_output" => "A"}, questions: [{"verdict", question}]}] =
               Mock.calls(mock)

      assert question == %Question.Score{
               instructions: "How relevant is `actual_output`?",
               levels: ["Low", "Medium", "High"]
             }
    end

    test "is :llm under the llm mode" do
      assert Decision.score(@score, opts(:llm, nil)) == :llm
    end
  end

  describe "format_reason/3" do
    test "names the model and the measure's confidence" do
      mock = Mock.new(model: "fake-jev")

      {reason, _usages, _ledger} =
        measure(fn ->
          Ledger.record_confidence(0.25)
          Decision.format_reason(opts(:hybrid, mock), "tool selection", 0.75)
        end)

      assert reason == "Decided by fake-jev: tool selection 0.75, confidence 0.25."
    end

    test "leaves the confidence out when no System One answer fed the measure" do
      assert Decision.format_reason(opts(:hybrid, Mock.new(model: "jev-x")), "verdict", 1) ==
               "Decided by jev-x: verdict 1.00."
    end

    test "says System One when the context has no model" do
      assert Decision.format_reason([], "score", 0.125) == "Decided by System One: score 0.12."
    end
  end

  # deepeval's ToolCorrectness asks its tool-selection Score through
  # system_one_score: replaying the fixture's recorded request through
  # score/2 must ask the same question and decide the same way.
  describe "tool_correctness hybrid fixtures" do
    setup do
      %{
        hybrid: fixture("tool_correctness_hybrid"),
        fallback: fixture("tool_correctness_hybrid_fallback")
      }
    end

    test "scores tool selection with Jev and explains it as deepeval does", %{hybrid: fixture} do
      mock = Mock.from_fixture(fixture.input["system_one"])
      opts = opts(:hybrid, mock)

      {{result, reason}, _usages, ledger} =
        measure(fn ->
          {:ok, score} = Decision.score(fixture.spec, opts)
          {score, Decision.format_reason(opts, "tool selection", score)}
        end)

      [measured] = fixture.measure
      assert result == measured["score"]
      assert ledger.confidence == measured["confidence"]
      assert String.contains?(measured["reason"], "Tool Selection Reason: #{reason}\n")
      assert dump(Mock.dump_calls(mock)) == dump(hd(fixture.decide["measure"]))
    end

    test "records deepeval's fallback reason when Jev is down", %{fallback: fixture} do
      mock = Mock.from_fixture(fixture.input["system_one"])

      {result, _usages, ledger} =
        measure(fn -> Decision.score(fixture.spec, opts(:hybrid, mock)) end)

      [measured] = fixture.measure
      assert result == :llm
      assert Ledger.fallback_reason(ledger) == measured["system_one_fallback_reason"]
      assert dump(Mock.dump_calls(mock)) == dump(hd(fixture.decide["measure"]))
    end
  end

  defp fixture(scenario) do
    load = fn file ->
      [@fixtures, scenario, file]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)
    end

    decide = load.("decide.json")
    [[call]] = decide["measure"]
    question = call["questions"]["verdict"]

    %{
      input: load.("input.json"),
      decide: decide,
      measure: load.("measure.json"),
      spec: %Spec.Score{
        instructions: question["instructions"],
        levels: question["criteria"],
        state: call["state"]
      }
    }
  end

  defp dump(calls), do: JSON.encode!(calls, indent: 2, ensure_ascii: false)
end
