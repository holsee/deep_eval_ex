defmodule DeepEvalEx.ConversationalTestCaseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.Turn

  doctest DeepEvalEx.ConversationalTestCase

  @turns [%{role: "user", content: "Hi"}, %{role: "assistant", content: "Hello!"}]

  describe "new/1" do
    test "builds turns from maps and keeps Turn structs" do
      turn = Turn.new!(role: :assistant, content: "Hello!")

      assert {:ok, test_case} =
               ConversationalTestCase.new(turns: [%{"role" => "user", "content" => "Hi"}, turn])

      assert test_case.turns == [%Turn{role: :user, content: "Hi"}, turn]
    end

    test "defaults the optional fields as deepeval does" do
      test_case = ConversationalTestCase.new!(turns: @turns)

      assert test_case.scenario == nil
      assert test_case.context == nil
      assert test_case.name == nil
      assert test_case.user_description == nil
      assert test_case.expected_outcome == nil
      assert test_case.chatbot_role == nil
      assert test_case.metadata == nil
      assert test_case.comments == nil
      assert test_case.tags == nil
      assert test_case.flaky == false
      assert test_case.expectations == nil
      assert test_case.expected_labels == nil
      assert test_case.call_recording_path == nil
      assert test_case.multimodal == false
      assert test_case.voice == false
      assert test_case.dataset_rank == nil
    end

    test "accepts every field" do
      assert {:ok, test_case} =
               ConversationalTestCase.new(
                 turns: @turns,
                 scenario: "A user greets the bot",
                 context: ["ctx"],
                 name: "greeting",
                 user_description: "A friendly user",
                 expected_outcome: "The bot greets back",
                 chatbot_role: "A helpful assistant",
                 metadata: %{"k" => "v"},
                 comments: "note",
                 tags: ["smoke"],
                 flaky: true,
                 expectations: %{must: ["greet"]},
                 expected_labels: %{"tone" => "friendly"},
                 call_recording_path: "/tmp/call.wav"
               )

      assert test_case.scenario == "A user greets the bot"
      assert test_case.context == ["ctx"]
      assert test_case.name == "greeting"
      assert test_case.user_description == "A friendly user"
      assert test_case.expected_outcome == "The bot greets back"
      assert test_case.chatbot_role == "A helpful assistant"
      assert test_case.metadata == %{"k" => "v"}
      assert test_case.comments == "note"
      assert test_case.tags == ["smoke"]
      assert test_case.flaky

      assert test_case.expectations == %{
               must: ["greet"],
               must_not: [],
               model: nil,
               eval_mode: nil
             }

      assert test_case.expected_labels == %{"tone" => "friendly"}
      assert test_case.call_recording_path == "/tmp/call.wav"
    end

    test "accepts deepeval's camelCase aliases and drops unknown keys" do
      assert {:ok, test_case} =
               ConversationalTestCase.new(%{
                 "turns" => @turns,
                 "userDescription" => "ud",
                 "user_description" => "ignored",
                 "expectedOutcome" => "eo",
                 "chatbotRole" => "cr",
                 "additionalMetadata" => %{"m" => 1},
                 "expectedLabels" => %{"a" => "b"},
                 "unknown" => 1
               })

      assert test_case.user_description == "ud"
      assert test_case.expected_outcome == "eo"
      assert test_case.chatbot_role == "cr"
      assert test_case.metadata == %{"m" => 1}
      assert test_case.expected_labels == %{"a" => "b"}
    end

    test "rejects empty turns, as deepeval's validate_input" do
      assert {:error, errors} = ConversationalTestCase.new(turns: [])
      assert inspect(errors) =~ "'turns' must not be empty"
    end

    test "requires turns" do
      assert {:error, _} = ConversationalTestCase.new(scenario: "x")
    end

    test "rejects a turn that is neither a Turn nor a valid map" do
      assert {:error, errors} = ConversationalTestCase.new(turns: ["x"])
      assert inspect(errors) =~ "'turns' must be a list of Turn or dict"

      assert {:error, errors} = ConversationalTestCase.new(turns: [%{role: "bot", content: "x"}])
      assert inspect(errors) =~ "Invalid dict for Turn"
    end

    test "keeps context a list of strings" do
      assert {:error, _} = ConversationalTestCase.new(turns: @turns, context: "x")
      assert {:error, _} = ConversationalTestCase.new(turns: @turns, context: [1])
    end

    test "rejects values of the wrong type" do
      assert {:error, _} = ConversationalTestCase.new(turns: @turns, scenario: 1)
      assert {:error, _} = ConversationalTestCase.new(turns: @turns, flaky: "yes")
      assert {:error, _} = ConversationalTestCase.new(turns: @turns, tags: "a")
    end
  end

  describe "voice" do
    test "is set when a turn has audio" do
      turns = [%{role: "user", content: "Hi", audio: %{"url" => "a.wav"}}]

      assert ConversationalTestCase.new!(turns: turns).voice
    end

    test "is kept when given" do
      assert ConversationalTestCase.new!(turns: @turns, voice: true).voice
      refute ConversationalTestCase.new!(turns: @turns).voice
    end
  end

  describe "multimodal" do
    @image "[DEEPEVAL:IMAGE:abc]"

    test "is set by an image placeholder in the scenario, outcome, user description or a turn" do
      for attrs <- [
            [scenario: "see #{@image}"],
            [expected_outcome: @image],
            [user_description: "[DEEPEVAL:PDF:doc]"],
            [turns: [%{role: "user", content: "look #{@image}"}]],
            [turns: [%{role: "assistant", content: "x", retrieval_context: [@image]}]],
            [
              turns: [
                %{
                  role: "assistant",
                  content: "x",
                  retrieval_context: [%RetrievedContextData{context: @image, source: "s"}]
                }
              ]
            ]
          ] do
        attrs = Keyword.put_new(attrs, :turns, @turns)
        assert ConversationalTestCase.new!(attrs).multimodal, inspect(attrs)
      end
    end

    test "is not set by context or chatbot role, as deepeval's set_is_multimodal" do
      refute ConversationalTestCase.new!(turns: @turns, context: [@image]).multimodal
      refute ConversationalTestCase.new!(turns: @turns, chatbot_role: @image).multimodal
    end

    test "is kept when given" do
      assert ConversationalTestCase.new!(turns: @turns, multimodal: true).multimodal
    end
  end

  describe "new!/1" do
    test "raises on an invalid test case" do
      assert_raise RuntimeError, ~r/Invalid conversational test case/, fn ->
        ConversationalTestCase.new!(turns: [])
      end
    end
  end
end
