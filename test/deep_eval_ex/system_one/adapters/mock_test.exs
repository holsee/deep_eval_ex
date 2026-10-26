defmodule DeepEvalEx.SystemOne.Adapters.MockTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.{Answers, Error, Model, Question}
  alias DeepEvalEx.TestRun.JSON

  doctest DeepEvalEx.SystemOne.Adapters.Mock

  @fixtures Path.expand("../../../fixtures/deepeval/system_one", __DIR__)

  @state %{"input" => "Q", "actual_output" => "A"}
  @noul {"q_0", %Question.Noul{instructions: "`actual_output` answers `input`."}}
  @score {"q_1", %Question.Score{instructions: "How well?", levels: ["Low", "Mid", "High"]}}
  @choice {"q_2",
           %Question.Choice{
             instructions: "Tone?",
             options: [{"friendly", nil}, {"rude", "Hostile"}]
           }}

  defp nouls(pairs),
    do: %Answers{nouls: Map.new(pairs, fn {k, p} -> {k, %Answers.Noul{probability: p}} end)}

  describe "new/1" do
    test "returns a {Mock, opts} handle the :mock alias and Model.resolve/1 accept" do
      assert {Mock, opts} = handle = Mock.new()
      assert is_pid(opts[:log])
      assert %Model{adapter: Mock, name: "fake-jev"} = Model.resolve(handle)
      assert Model.resolve({:mock, model: "jev-x"}).name == "jev-x"
    end

    test "names an exploding mock exploding-jev, as deepeval's fake" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "down"}
      assert Model.resolve(Mock.new(raises: error)).name == "exploding-jev"
      assert Model.resolve(Mock.new(raises: error, model: "x")).name == "x"
    end
  end

  describe "decide/3" do
    test "returns the canned answers on every call, priced 0.0 by default" do
      answers = nouls([{"q_0", 0.9}])
      handle = Mock.new(answers: answers)

      for _ <- 1..2 do
        assert {:ok, ^answers, %Usage{cost: +0.0, input_tokens: nil, source: :system_one}} =
                 SystemOne.decide(@state, [@noul], system_one_model: handle)
      end
    end

    test "consumes an answers list one per call" do
      first = nouls([{"q_0", 0.1}])
      second = nouls([{"q_0", 0.2}])
      handle = Mock.new(answers: [first, second])

      assert {:ok, ^first, _} = SystemOne.decide(@state, [@noul], system_one_model: handle)
      assert {:ok, ^second, _} = SystemOne.decide(@state, [@noul], system_one_model: handle)

      assert_raise RuntimeError, ~r/no canned answers left/, fn ->
        SystemOne.decide(@state, [@noul], system_one_model: handle)
      end
    end

    test "asks answer_fn with the questions" do
      handle =
        Mock.new(answer_fn: fn questions -> nouls(for {k, _} <- questions, do: {k, 0.5}) end)

      assert {:ok, %Answers{nouls: %{"q_0" => %Answers.Noul{probability: 0.5}}}, _} =
               SystemOne.decide(@state, [@noul], system_one_model: handle)
    end

    test "reports the cost as nil, a float, a Usage or {value, input, output}" do
      for {cost, usage} <- [
            {nil, nil},
            {0.5, %Usage{cost: 0.5}},
            {1, %Usage{cost: 1.0}},
            {{4.2e-5, 1000, 0}, %Usage{cost: 4.2e-5, input_tokens: 1000, output_tokens: 0}},
            {%Usage{model: "m", cost: 0.1}, %Usage{model: "m", cost: 0.1}}
          ] do
        handle = Mock.new(answers: %Answers{}, cost: cost)
        assert {:ok, _, reported} = SystemOne.decide(@state, [], system_one_model: handle)
        assert strip(reported) == strip(usage)
      end
    end

    test "returns or raises the error it is given, logging the call either way" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}

      for handle <- [Mock.new(raises: error), Mock.new(raises: error, raise?: true)] do
        assert {:error, ^error} = SystemOne.decide(@state, [@noul], system_one_model: handle)
        assert [%Mock.Call{state: @state, questions: [@noul], error: ^error}] = Mock.calls(handle)
      end
    end

    test "a non-System One exception it raises propagates" do
      handle = Mock.new(raises: %KeyError{key: :x}, raise?: true)
      assert_raise KeyError, fn -> SystemOne.decide(@state, [@noul], system_one_model: handle) end
    end

    test "works without new/1 for fixed answers" do
      assert {:ok, %Answers{}, %Usage{cost: +0.0}} =
               SystemOne.decide(@state, [@noul], system_one_model: :mock)

      assert_raise ArgumentError, ~r/Mock.new/, fn ->
        SystemOne.decide(@state, [@noul], system_one_model: {:mock, answers: [%Answers{}]})
      end
    end
  end

  describe "calls/1" do
    test "logs state, questions, answers and usage in call order" do
      handle = Mock.new(answers: [nouls([{"q_0", 0.1}]), nouls([{"q_0", 0.2}])], cost: 0.5)
      SystemOne.decide(%{"n" => 1}, [@noul], system_one_model: handle)
      SystemOne.decide(%{"n" => 2}, [@noul], system_one_model: handle)

      assert [
               %Mock.Call{
                 state: %{"n" => 1},
                 answers: %Answers{nouls: %{"q_0" => %{probability: 0.1}}}
               },
               %Mock.Call{state: %{"n" => 2}, usage: %Usage{cost: 0.5}, error: nil}
             ] = Mock.calls(handle)
    end

    test "keeps each handle's log apart, also across concurrent callers" do
      handles = for _ <- 1..4, do: Mock.new(answers: %Answers{})

      handles
      |> Enum.with_index()
      |> Task.async_stream(fn {handle, i} ->
        for n <- 1..10, do: SystemOne.decide(%{"h" => i, "n" => n}, [], system_one_model: handle)
      end)
      |> Stream.run()

      for {handle, i} <- Enum.with_index(handles) do
        assert Enum.map(Mock.calls(handle), & &1.state) ==
                 for(n <- 1..10, do: %{"h" => i, "n" => n})
      end
    end

    test "logs a call whose answer_fn raised, without answers" do
      handle = Mock.new(answer_fn: fn _ -> raise "boom" end)

      assert_raise RuntimeError, fn ->
        SystemOne.decide(@state, [@noul], system_one_model: handle)
      end

      assert [%Mock.Call{state: @state, answers: nil, error: nil}] = Mock.calls(handle)
    end

    test "needs a handle from new/1" do
      assert_raise ArgumentError, ~r/Mock.new/, fn -> Mock.calls({Mock, []}) end
    end
  end

  describe "answer helpers" do
    test "noul_answers/1 answers every key as a Noul with one probability" do
      answers = Mock.noul_answers(0.7).([@noul, {"claim_0", %Question.Noul{instructions: "x"}}])

      assert answers == nouls([{"q_0", 0.7}, {"claim_0", 0.7}])
    end

    test "answer_everything/2 answers any mix: Nouls, top Score level, first Choice option" do
      answers = Mock.answer_everything().([@noul, @score, @choice])

      assert answers == %Answers{
               nouls: %{"q_0" => %Answers.Noul{probability: 0.9}},
               scores: %{
                 "q_1" => %Answers.Score{
                   score: 2,
                   probabilities: [{0, 0.0}, {1, 0.0}, {2, 1.0}],
                   confidence: 0.8
                 }
               },
               choices: %{
                 "q_2" => %Answers.Choice{
                   choice: "friendly",
                   probabilities: [{"friendly", 1.0}],
                   confidence: 0.8
                 }
               }
             }

      assert Mock.answer_everything(0.2, 0.3).([@noul]).nouls["q_0"].probability == 0.2
    end
  end

  describe "from_fixture/2" do
    test "answers each question from the canned answers of its type and key" do
      spec = %{
        "model" => "fake-jev",
        "cost" => %{"value" => 4.2e-5, "input_tokens" => 1000, "output_tokens" => 0},
        "answers" => %{
          "nouls" => %{"m1.q_0" => %{"probability" => 0.6}},
          "scores" => %{
            "m1.q_1" => %{
              "score" => 1,
              "probabilities" => %{"0" => 0.2, "1" => 0.8},
              "confidence" => 0.6
            }
          }
        }
      }

      handle = Mock.from_fixture(spec, prefix: "m1.")
      score = {"q_1", %Question.Score{instructions: "?", levels: ["a", "b"]}}

      assert {:ok, answers, %Usage{cost: 4.2e-5, input_tokens: 1000, output_tokens: 0}} =
               SystemOne.decide(@state, [@noul, score], system_one_model: handle)

      assert answers.nouls == %{"q_0" => %Answers.Noul{probability: 0.6}}
      assert %Answers.Score{score: 1, probabilities: [{0, 0.2}, {1, 0.8}]} = answers.scores["q_1"]

      assert_raise RuntimeError, ~r/no canned nouls answer for "m1.q_9"/, fn ->
        SystemOne.decide(@state, [{"q_9", %Question.Noul{instructions: "?"}}],
          system_one_model: handle
        )
      end
    end

    test "a cost left out is nil, as the fixture generator passes it" do
      handle = Mock.from_fixture(%{"model" => "fake-jev", "answers" => %{}})
      assert {:ok, _, nil} = SystemOne.decide(@state, [], system_one_model: handle)
    end

    test "raises: becomes a raised System One error" do
      for {type, reason} <- [{"ConnectionError", :connection}, {"TimeoutError", :timeout}] do
        handle =
          Mock.from_fixture(%{
            "model" => "exploding-jev",
            "raises" => %{"type" => type, "message" => "m"}
          })

        assert {:error, %Error{reason: ^reason, type: ^type, message: "m"}} =
                 SystemOne.decide(@state, [@noul], system_one_model: handle)
      end

      assert_raise ArgumentError, ~r/KeyError/, fn ->
        Mock.from_fixture(%{
          "model" => "x",
          "raises" => %{"type" => "KeyError", "message" => "m"}
        })
      end
    end
  end

  # Replays every decide() call the System One fixtures recorded through a
  # handle built from the scenario's input.json: dumping the log must give
  # decide.json's bytes (state, wire questions, answers, cost or error).
  describe "System One fixtures" do
    for dir <- Path.wildcard(Path.join(@fixtures, "*")), File.dir?(dir) do
      @external_resource Path.join(dir, "input.json")
      @external_resource Path.join(dir, "decide.json")
      scenario = Path.basename(dir)

      test "#{scenario}: the replayed call log dumps to decide.json byte for byte" do
        dir = unquote(dir)
        input = load(dir, "input.json")
        expected = File.read!(Path.join(dir, "decide.json"))
        decide = Jason.decode!(expected, objects: :ordered_objects)

        measure =
          decide["measure"]
          |> Enum.with_index()
          |> Enum.map(fn {calls, j} ->
            prefix = if input["batched"], do: "m#{j}.", else: ""
            replay(Mock.from_fixture(input["system_one"], prefix: prefix), calls)
          end)

        evaluate = replay(Mock.from_fixture(input["system_one"]), decide["evaluate"])

        dumped = Jason.OrderedObject.new([{"measure", measure}, {"evaluate", evaluate}])
        assert JSON.encode!(dumped, indent: 2, ensure_ascii: false) <> "\n" == expected
      end
    end
  end

  defp replay(handle, calls) do
    for call <- calls do
      questions = Enum.map(call["questions"], fn {key, wire} -> {key, from_wire(wire)} end)
      SystemOne.decide(call["state"], questions, system_one_model: handle)
    end

    Mock.dump_calls(handle)
  end

  defp load(dir, file),
    do: dir |> Path.join(file) |> File.read!() |> Jason.decode!(objects: :ordered_objects)

  defp from_wire(wire) do
    criteria = wire["criteria"]

    case wire["type"] do
      "noul" ->
        criteria = criteria || %{}

        %Question.Noul{
          instructions: wire["instructions"],
          true: criteria["true"],
          false: criteria["false"]
        }

      "choice" ->
        %Question.Choice{instructions: wire["instructions"], options: Enum.to_list(criteria)}

      "score" ->
        %Question.Score{instructions: wire["instructions"], levels: criteria}
    end
  end

  defp strip(nil), do: nil
  defp strip(%Usage{} = usage), do: %{usage | source: nil, model: nil}
end
