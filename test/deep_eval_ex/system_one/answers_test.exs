defmodule DeepEvalEx.SystemOne.AnswersTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.SystemOne.{Answers, Question}
  alias DeepEvalEx.TestRun.JSON

  doctest DeepEvalEx.SystemOne.Answers

  @fixtures Path.expand("../../fixtures/deepeval/system_one", __DIR__)

  describe "confidence/1" do
    test "of a Noul is |2p - 1| with Python's float operations" do
      assert Answers.confidence(%Answers.Noul{probability: 0.6}) == 0.19999999999999996
      assert Answers.confidence(%Answers.Noul{probability: 0.5}) == 0.0
      assert Answers.confidence(%Answers.Noul{probability: 0.0}) == 1.0
      assert Answers.confidence(%Answers.Noul{probability: 1}) == 1.0
    end

    test "of a Choice or Score is the confidence it came with" do
      assert Answers.confidence(%Answers.Choice{choice: "a", confidence: 0.27}) == 0.27
      assert Answers.confidence(%Answers.Score{score: 1.0, confidence: 0.4}) == 0.4
    end
  end

  describe "normalized/1" do
    test "divides the score by the highest level index" do
      score = %Answers.Score{score: 1.6, probabilities: [{0, 0.05}, {1, 0.3}, {2, 0.65}]}
      assert Answers.normalized(score) == 0.8
    end

    test "is 0.0 without levels above 0, as deepeval" do
      assert Answers.normalized(%Answers.Score{score: 1, probabilities: []}) == 0.0
      assert Answers.normalized(%Answers.Score{score: 1, probabilities: [{0, 1.0}]}) == 0.0
    end
  end

  describe "min_confidence/1" do
    test "is the least decisive answer of any type" do
      answers = %Answers{
        nouls: %{"q_0" => %Answers.Noul{probability: 0.88}},
        choices: %{"q_2" => %Answers.Choice{choice: "a", confidence: 0.27}},
        scores: %{"q_1" => %Answers.Score{score: 1.0, confidence: 0.48}}
      }

      assert Answers.min_confidence(answers) == 0.27
    end

    test "is nil without answers" do
      assert Answers.min_confidence(%Answers{}) == nil
    end
  end

  test "take_prefix/2 keeps one batched metric's answers, unprefixed" do
    answers = %Answers{
      nouls: %{
        "m0.q_0" => %Answers.Noul{probability: 0.1},
        "m1.q_0" => %Answers.Noul{probability: 0.9}
      },
      scores: %{"m1.q_2" => %Answers.Score{score: 1.0, confidence: 0.4}},
      choices: %{"m0.label" => %Answers.Choice{choice: "a", confidence: 1.0}}
    }

    assert Answers.take_prefix(answers, "m1.") == %Answers{
             nouls: %{"q_0" => %Answers.Noul{probability: 0.9}},
             scores: %{"q_2" => %Answers.Score{score: 1.0, confidence: 0.4}}
           }
  end

  describe "to_dump/2 and from_dump/1" do
    test "dump as SystemOneAnswers.model_dump, numbers as floats" do
      answers = %Answers{
        nouls: %{"q_0" => %Answers.Noul{probability: 1}},
        scores: %{
          "q_1" => %Answers.Score{score: 2, probabilities: [{0, 0}, {1, 0.5}], confidence: 1}
        }
      }

      assert JSON.encode!(Answers.to_dump(answers)) ==
               ~s({"nouls": {"q_0": {"probability": 1.0}}, "choices": {}, ) <>
                 ~s("scores": {"q_1": {"score": 2.0, "probabilities": {"0": 0.0, "1": 0.5}, "confidence": 1.0}}})
    end

    test "dump keys in the order given, then the rest in natural order" do
      nouls = for key <- ~w(q_10 q_2 q_1 x), into: %{}, do: {key, %Answers.Noul{probability: 0.5}}
      answers = %Answers{nouls: nouls}

      keys = fn dump ->
        dump.values |> hd() |> elem(1) |> Map.get(:values) |> Enum.map(&elem(&1, 0))
      end

      assert keys.(Answers.to_dump(answers)) == ~w(q_1 q_2 q_10 x)
      assert keys.(Answers.to_dump(answers, ~w(x q_10))) == ~w(x q_10 q_1 q_2)

      questions = [{"q_2", %Question.Noul{instructions: "a"}}]
      assert keys.(Answers.to_dump(answers, questions)) == ~w(q_2 q_1 q_10 x)
    end

    test "from_dump/1 reads a dump with string level keys back" do
      dump = %{
        "nouls" => %{"q_0" => %{"probability" => 0.3}},
        "scores" => %{
          "q_2" => %{
            "score" => 1.0,
            "probabilities" => Jason.OrderedObject.new([{"1", 0.6}, {"0", 0.4}]),
            "confidence" => 0.2
          }
        }
      }

      assert Answers.from_dump(dump) == %Answers{
               nouls: %{"q_0" => %Answers.Noul{probability: 0.3}},
               scores: %{
                 "q_2" => %Answers.Score{
                   score: 1.0,
                   probabilities: [{1, 0.6}, {0, 0.4}],
                   confidence: 0.2
                 }
               }
             }
    end
  end

  # Every decide() call the System One fixtures recorded: the questions'
  # wire shape and the answers' dump are rebuilt from DeepEvalEx structs and
  # must encode to the same bytes.
  describe "System One fixtures" do
    for path <- Path.wildcard(Path.join(@fixtures, "*/decide.json")) do
      @external_resource path
      scenario = path |> Path.dirname() |> Path.basename()

      test "#{scenario}: questions and answers round-trip byte for byte" do
        decide =
          unquote(path) |> File.read!() |> Jason.decode!(objects: :ordered_objects)

        calls = Enum.flat_map(decide["measure"], & &1) ++ decide["evaluate"]

        for call <- calls do
          questions = Enum.map(call["questions"], fn {key, wire} -> {key, from_wire(wire)} end)

          assert JSON.encode!(Question.to_wire_map(questions), indent: 2) ==
                   JSON.encode!(call["questions"], indent: 2)

          if answers = call["answers"] do
            assert JSON.encode!(Answers.to_dump(Answers.from_dump(answers), questions), indent: 2) ==
                     JSON.encode!(answers, indent: 2)
          end
        end
      end
    end
  end

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
end
