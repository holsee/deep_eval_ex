defmodule DeepEvalEx.SystemOneTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError, SystemOne}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Answers, Error, Question}
  alias DeepEvalEx.Test.SystemOneStub

  @questions [
    {"q_0", %Question.Noul{instructions: "`actual_output` answers `input`."}},
    {"q_1", %Question.Score{instructions: "How complete?", levels: ~w(No Partly Fully)}},
    {"q_2", %Question.Choice{instructions: "Tone?", options: [{"rude", nil}, {"kind", nil}]}}
  ]

  @answers %Answers{
    nouls: %{"q_0" => %Answers.Noul{probability: 0.88}},
    scores: %{
      "q_1" => %Answers.Score{
        score: 1.6,
        probabilities: [{0, 0.05}, {1, 0.3}, {2, 0.65}],
        confidence: 0.48
      }
    },
    choices: %{
      "q_2" => %Answers.Choice{
        choice: "kind",
        probabilities: [{"rude", 0.2}, {"kind", 0.8}],
        confidence: 0.6
      }
    }
  }

  defp model(decide, opts \\ []), do: {SystemOneStub, Keyword.put(opts, :decide, decide)}

  defp answering(answers, usage),
    do: model(fn _state, _questions, _opts -> {:ok, answers, usage} end)

  describe "decide/3" do
    test "asks the adapter with its own options and returns the answers and usage" do
      test_pid = self()

      decide = fn state, questions, opts ->
        send(test_pid, {:asked, state, questions, opts})

        {:ok, @answers,
         %Usage{model: "stub-jev", input_tokens: 1000, output_tokens: 0, cost: 4.2e-05}}
      end

      state = %{"test_case" => %{"input" => "Q"}}

      assert {:ok, @answers, usage} =
               SystemOne.decide(state, @questions,
                 system_one_model: model(decide, name: "fake-jev")
               )

      assert_received {:asked, ^state, @questions, opts}
      assert opts[:name] == "fake-jev"

      assert %Usage{input_tokens: 1000, output_tokens: 0, cost: 4.2e-05, source: :system_one} =
               usage
    end

    test "stamps the usage as System One's, naming the model when the adapter did not" do
      usage = %Usage{input_tokens: 3, output_tokens: 0, cost: 0.0}

      assert {:ok, _, %Usage{model: "stub-jev", source: :system_one}} =
               SystemOne.decide("state", @questions, system_one_model: answering(@answers, usage))
    end

    test "keeps nil usage, an unpriced call" do
      assert {:ok, @answers, nil} =
               SystemOne.decide("state", @questions, system_one_model: answering(@answers, nil))
    end

    test "never records the usage itself" do
      {_result, usages} =
        Usage.track(fn ->
          SystemOne.decide("s", @questions,
            system_one_model: answering(@answers, %Usage{cost: 1.0})
          )
        end)

      assert usages == []
    end
  end

  describe "decide/3 failures" do
    test "a returned System One error is returned" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

      assert SystemOne.decide("s", @questions,
               system_one_model: model(fn _, _, _ -> {:error, error} end)
             ) ==
               {:error, error}
    end

    test "a raised System One error is returned" do
      for exception <- [
            %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"},
            %DeepEvalError{message: "set TYPESAFE_API_KEY"},
            %ContextWindowExceededError{message: "too large"}
          ] do
        decide = fn _, _, _ -> raise exception end

        assert SystemOne.decide("s", @questions, system_one_model: model(decide)) ==
                 {:error, exception}
      end
    end

    test "a transport error is a ConnectionError, a transport timeout a TimeoutError" do
      for {returned_or_raised, result} <- [
            {{:error, %Req.TransportError{reason: :econnrefused}},
             {:connection, "ConnectionError"}},
            {%Req.TransportError{reason: :closed}, {:connection, "ConnectionError"}},
            {{:error, %Req.TransportError{reason: :timeout}}, {:timeout, "TimeoutError"}}
          ] do
        decide =
          case returned_or_raised do
            {:error, _} = error -> fn _, _, _ -> error end
            exception -> fn _, _, _ -> raise exception end
          end

        {reason, type} = result

        assert {:error, %Error{reason: ^reason, type: ^type, message: message}} =
                 SystemOne.decide("s", @questions, system_one_model: model(decide))

        assert message =~ ~r/connection refused|socket closed|timeout/
      end
    end

    test "an exit on timeout is a TimeoutError" do
      decide = fn _, _, _ -> exit({:timeout, {Task, :await, [:task, 5_000]}}) end

      assert {:error, %Error{reason: :timeout, type: "TimeoutError"}} =
               SystemOne.decide("s", @questions, system_one_model: model(decide))
    end

    test "any other exception propagates, raised or returned" do
      raising = fn _, _, _ -> raise KeyError, key: "q_0", term: %{} end

      assert_raise KeyError, fn ->
        SystemOne.decide("s", @questions, system_one_model: model(raising))
      end

      returning = fn _, _, _ -> {:error, %RuntimeError{message: "bug"}} end

      assert_raise RuntimeError, "bug", fn ->
        SystemOne.decide("s", @questions, system_one_model: model(returning))
      end
    end

    test "a reply outside the contract raises ArgumentError" do
      for reply <- [{:ok, %{}, nil}, {:error, :down}, :ok, {:ok, @answers, %{cost: 1.0}}] do
        assert_raise ArgumentError, ~r/System One adapter DeepEvalEx.Test.SystemOneStub/, fn ->
          SystemOne.decide("s", @questions, system_one_model: model(fn _, _, _ -> reply end))
        end
      end
    end
  end

  describe "noul/3, choice/3 and score/3" do
    test "return the answers of their own type" do
      opts = [system_one_model: answering(@answers, nil)]

      assert SystemOne.noul("s", @questions, opts) == {:ok, @answers.nouls, nil}
      assert SystemOne.choice("s", @questions, opts) == {:ok, @answers.choices, nil}
      assert SystemOne.score("s", @questions, opts) == {:ok, @answers.scores, nil}
    end

    test "return errors as decide/3 does" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "down"}
      opts = [system_one_model: model(fn _, _, _ -> {:error, error} end)]

      assert SystemOne.noul("s", @questions, opts) == {:error, error}
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler_id,
        [
          [:deep_eval_ex, :system_one, :request, :start],
          [:deep_eval_ex, :system_one, :request, :stop],
          [:deep_eval_ex, :system_one, :request, :exception]
        ],
        fn event, measurements, metadata, _config ->
          if metadata[:metrics] == ["Telemetry Metric"],
            do: send(test_pid, {List.last(event), measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "spans each request with its model, mode, metrics and usage" do
      usage = %Usage{input_tokens: 1000, output_tokens: 0, cost: 4.2e-05}

      opts = [
        system_one_model: answering(@answers, usage),
        mode: :system_one,
        metrics: ["Telemetry Metric"]
      ]

      assert {:ok, _, _} = SystemOne.decide("s", @questions, opts)

      assert_received {:start, _, start_meta}

      assert %{model: "stub-jev", mode: :system_one, question_count: 3, batched?: false} =
               start_meta

      assert_received {:stop, measurements, stop_meta}
      assert %{duration: _, input_tokens: 1000, output_tokens: 0, cost: 4.2e-05} = measurements
      assert stop_meta.model == "stub-jev"
      assert stop_meta.batched? == false
    end

    test "leaves out usage the request did not report, and stops on a handled error" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "down"}

      opts = [
        system_one_model: model(fn _, _, _ -> {:error, error} end),
        metrics: ["Telemetry Metric"]
      ]

      assert {:error, ^error} =
               SystemOne.decide("s", @questions, Keyword.put(opts, :batched?, true))

      assert_received {:stop, measurements, %{batched?: true, error: ^error}}
      assert Map.keys(measurements) |> Enum.sort() == [:duration, :monotonic_time]
    end

    test "reports an exception for an error that propagates" do
      opts = [
        system_one_model: model(fn _, _, _ -> raise KeyError, key: "q_0" end),
        metrics: ["Telemetry Metric"]
      ]

      assert_raise KeyError, fn -> SystemOne.decide("s", @questions, opts) end
      assert_received {:exception, _, %{kind: :error, reason: %KeyError{}}}
    end
  end
end
