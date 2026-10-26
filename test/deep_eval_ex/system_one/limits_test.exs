defmodule DeepEvalEx.SystemOne.LimitsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.SystemOne.{Error, Limits, Question}
  alias DeepEvalEx.SystemOne.Question.{Choice, Noul, Score}
  alias Jason.OrderedObject

  doctest Limits

  # Every expected value below was produced by CPython running deepeval
  # 4.3.1's `deepeval.models.system_one.limits` on the same input.

  describe "estimate_tokens/1" do
    test "is 0 for nil" do
      assert Limits.estimate_tokens(nil) == 0
    end

    test "counts a bare string as is, without JSON-encoding it" do
      # 23 code points; json.dumps would add two quotes (25 -> 9 tokens)
      assert Limits.estimate_tokens("It is 18°C at the café.") == 8
      assert Limits.estimate_tokens("") == 0
    end

    test "counts code points, not graphemes or bytes" do
      # "é" as e + U+0301: 6 code points, 3 graphemes, 9 bytes
      assert Limits.estimate_tokens(String.duplicate("é", 3)) == 2
      # astral characters are one code point each (no surrogate pairs)
      assert Limits.estimate_tokens("😀😀😀😀") == 2
    end

    test "dumps any other value as json.dumps(ensure_ascii=False) with Python's separators" do
      state =
        OrderedObject.new([
          {"test_case",
           OrderedObject.new([
             {"actual_output", "It is 18°C at the café."},
             {"n", 1},
             {"f", 0.5},
             {"tiny", 1.0e-5},
             {"sum", 0.1 + 0.2},
             {"ok", true},
             {"none", nil},
             {"list", [1, 2]},
             {"quote", "say \"hi\"\n\tbye"}
           ])}
        ])

      # 192 characters
      assert Limits.estimate_tokens(state) == 64
      assert Limits.estimate_tokens(["café", 1, nil]) == 6
      assert Limits.estimate_tokens(12_345) == 2
    end

    test "falls back to inspect/1 for a term JSON cannot encode" do
      pid = self()
      assert Limits.estimate_tokens(pid) == ceil(String.length(inspect(pid)) / 3)
    end
  end

  describe "question_tokens/1" do
    test "estimates a question struct as deepeval's pydantic model_dump" do
      # {"instructions": "x", "true": null, "false": null}
      assert Limits.question_tokens(%Noul{instructions: "x"}) == 17

      assert Limits.question_tokens(%Noul{
               instructions: %{"claim" => "café"},
               true: "yes",
               false: "no"
             }) == 22

      # {"instructions": "Pick", "options": {"a": null, "b": "Bé"}}
      assert Limits.question_tokens(%Choice{
               instructions: "Pick",
               options: [{"a", nil}, {"b", "Bé"}]
             }) ==
               20

      assert Limits.question_tokens(%Score{instructions: "How?", levels: ["Low", "High"]}) == 17
    end

    test "estimates any other question (e.g. the SDK's wire shape) as is" do
      wire = Question.to_wire(%Noul{instructions: "x"})
      # {"type": "noul", "instructions": "x"}
      assert Limits.question_tokens(wire) == 13
    end
  end

  describe "check/3 state budget" do
    setup do
      # 17 tokens; (32_000 - 17) * 3 = 95_949 characters of state fill the budget
      %{questions: [{"q_0", %Noul{instructions: "x"}}]}
    end

    test "passes at exactly 32,000 tokens", %{questions: questions} do
      assert Limits.check(String.duplicate("é", 95_949), questions) == :ok
    end

    test "fails one token over with deepeval's message", %{questions: questions} do
      assert {:error, %Error{} = error} =
               Limits.check(String.duplicate("é", 95_950), questions)

      assert error.reason == :context_limit
      assert error.type == "SystemOneContextLimitError"
      assert error.estimated_tokens == 32_001
      assert error.limit_tokens == 32_000
      refute error.permanent?

      assert error.message ==
               "System One state (31984 est. tokens) plus the longest question (17) " <>
                 "exceeds the 32000-token state budget. Send less state or judge this " <>
                 "test case with the LLM."

      assert Error.describe(error) == "context limit (32001 est. tokens > 32000)"
    end
  end

  describe "check/3 request budget" do
    setup do
      # each question is exactly 20,000 tokens: 3 * 20_000 + 12_000 / 3 = 64_000
      padding = byte_size(~s({"instructions": "", "true": null, "false": null}))
      instructions = String.duplicate("ü", 60_000 - padding)
      %{questions: for(i <- 0..2, do: {"q_#{i}", %Noul{instructions: instructions}})}
    end

    test "passes at exactly 64,000 tokens", %{questions: questions} do
      assert Limits.check(String.duplicate("s", 12_000), questions) == :ok
    end

    test "fails one token over with deepeval's message", %{questions: questions} do
      assert {:error, %Error{} = error} =
               Limits.check(String.duplicate("s", 12_001), questions)

      assert error.reason == :context_limit
      assert error.type == "SystemOneContextLimitError"
      assert error.estimated_tokens == 64_001
      assert error.limit_tokens == 64_000

      assert error.message ==
               "System One request (64001 est. tokens across 3 questions) exceeds the " <>
                 "64000-token request budget. Ask fewer questions per request or judge " <>
                 "this test case with the LLM."
    end
  end

  describe "check/3" do
    test "passes an empty request" do
      assert Limits.check(nil, []) == :ok
    end

    test "accepts the questions as a wire map" do
      questions = Question.to_wire_map([{"q_0", %Noul{instructions: "x"}}])
      # 13 tokens of question: 31_987 tokens of state fit, 31_988 do not
      assert Limits.check(String.duplicate("a", 31_987 * 3), questions) == :ok

      assert {:error, %Error{estimated_tokens: 32_001}} =
               Limits.check(String.duplicate("a", 31_988 * 3), questions)
    end

    test "checks the budget it is given" do
      questions = [{"q_0", %Noul{instructions: "x"}}]

      # 1 token of state plus 17 of question
      assert {:error, %Error{limit_tokens: 17, message: "System One state " <> _}} =
               Limits.check("abc", questions, {17, 100})

      assert {:error, %Error{limit_tokens: 17, message: "System One request " <> _}} =
               Limits.check("abc", questions, {18, 17})

      assert Limits.check("abc", questions, {18, 18}) == :ok
    end

    test "never fails an :unbounded budget" do
      assert Limits.check(String.duplicate("a", 1_000_000), [], :unbounded) == :ok
    end
  end
end
