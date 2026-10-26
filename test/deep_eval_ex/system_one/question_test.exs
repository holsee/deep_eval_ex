defmodule DeepEvalEx.SystemOne.QuestionTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.SystemOne.Question
  alias DeepEvalEx.TestRun.JSON

  doctest DeepEvalEx.SystemOne.Question

  defp encode(term), do: JSON.encode!(term)

  describe "to_wire/1" do
    test "a Noul without criteria sends only its type and instructions" do
      wire = Question.to_wire(%Question.Noul{instructions: "`input` is a question."})

      assert encode(wire) == ~s({"type": "noul", "instructions": "`input` is a question."})
    end

    test "a Noul with either criterion sends both, true first" do
      wire = Question.to_wire(%Question.Noul{instructions: "x", false: "it is not"})

      assert encode(wire) ==
               ~s({"type": "noul", "instructions": "x", "criteria": {"true": null, "false": "it is not"}})
    end

    test "a Choice sends its options in order, descriptions or null" do
      wire =
        Question.to_wire(%Question.Choice{
          instructions: "tone?",
          options: [{"rude", nil}, {"friendly", "warm and polite"}]
        })

      assert encode(wire) ==
               ~s({"type": "choice", "instructions": "tone?", "criteria": {"rude": null, "friendly": "warm and polite"}})
    end

    test "a Score sends its levels" do
      wire = Question.to_wire(%Question.Score{instructions: "how?", levels: ["Low", "High"]})

      assert encode(wire) ==
               ~s({"type": "score", "instructions": "how?", "criteria": ["Low", "High"]})
    end

    test "instructions may be any JSON term, sent as given" do
      instructions = Jason.OrderedObject.new([{"claim", "Paris"}, {"question", "Supported?"}])
      wire = Question.to_wire(%Question.Noul{instructions: instructions})

      assert encode(wire) ==
               ~s({"type": "noul", "instructions": {"claim": "Paris", "question": "Supported?"}})
    end
  end

  test "to_wire_map/1 keys each wire question, in order" do
    wire =
      Question.to_wire_map([
        {"q_1", %Question.Noul{instructions: "b"}},
        {"q_0", %Question.Noul{instructions: "a"}}
      ])

    assert encode(wire) ==
             ~s({"q_1": {"type": "noul", "instructions": "b"}, "q_0": {"type": "noul", "instructions": "a"}})
  end
end
