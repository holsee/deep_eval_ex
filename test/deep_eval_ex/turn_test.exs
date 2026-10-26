defmodule DeepEvalEx.TurnTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn

  doctest DeepEvalEx.Turn

  describe "new/1" do
    test "builds a turn from a role and content" do
      assert {:ok, %Turn{role: :user, content: "Hi"} = turn} =
               Turn.new(role: :user, content: "Hi")

      assert turn.user_id == nil
      assert turn.audio == nil
      assert turn.latency_ms == nil
      assert turn.interrupted == nil
      assert turn.provider_transcript == nil
      assert turn.retrieval_context == nil
      assert turn.tools_called == nil
      assert turn.metadata == nil
    end

    test "accepts the roles as strings" do
      assert {:ok, %Turn{role: :assistant}} = Turn.new(%{"role" => "assistant", "content" => "x"})
      assert {:ok, %Turn{role: :user}} = Turn.new(%{"role" => "user", "content" => "x"})
    end

    test ~s(rejects any other role, as deepeval's Literal["user", "assistant"]) do
      assert {:error, _} = Turn.new(role: "bot", content: "x")
      assert {:error, _} = Turn.new(role: :system, content: "x")
    end

    test "requires role and content" do
      assert {:error, _} = Turn.new(content: "x")
      assert {:error, _} = Turn.new(role: :user)
      assert {:error, _} = Turn.new(role: :user, content: 1)
    end

    test "keeps the voice fields as plain data, casting an integer latency to a float" do
      audio = %{"url" => "https://example.com/a.wav", "mimeType" => "audio/wav"}

      assert {:ok, turn} =
               Turn.new(
                 role: :assistant,
                 content: "Hello",
                 audio: audio,
                 latency_ms: 120,
                 interrupted: true,
                 provider_transcript: "Hallo"
               )

      assert turn.audio == audio
      assert turn.latency_ms == 120.0
      assert turn.interrupted == true
      assert turn.provider_transcript == "Hallo"
    end

    test "rejects voice fields of the wrong type" do
      assert {:error, _} = Turn.new(role: :user, content: "x", latency_ms: "fast")
      assert {:error, _} = Turn.new(role: :user, content: "x", interrupted: "yes")
      assert {:error, _} = Turn.new(role: :user, content: "x", provider_transcript: 1)
    end

    test "accepts retrieval context strings and RetrievedContextData, and tool calls" do
      assert {:ok, turn} =
               Turn.new(
                 role: :assistant,
                 content: "Paris",
                 retrieval_context: ["chunk", %{"context" => "c", "source" => "s"}],
                 tools_called: [%{"name" => "search", "inputParameters" => %{"q" => "x"}}]
               )

      assert turn.retrieval_context == ["chunk", %RetrievedContextData{context: "c", source: "s"}]

      assert turn.tools_called == [
               %ToolCall{name: "search", type: :function, input_parameters: %{"q" => "x"}}
             ]
    end

    test "accepts deepeval's camelCase aliases, the first listed winning" do
      assert {:ok, turn} =
               Turn.new(%{
                 "role" => "user",
                 "content" => "x",
                 "userId" => "u1",
                 "user_id" => "ignored",
                 "latencyMs" => 5.5,
                 "providerTranscript" => "pt",
                 "retrievalContext" => ["r"],
                 "toolsCalled" => [%{"name" => "t"}],
                 "additionalMetadata" => %{"k" => 1},
                 "unknown" => "dropped"
               })

      assert turn.user_id == "u1"
      assert turn.latency_ms == 5.5
      assert turn.provider_transcript == "pt"
      assert turn.retrieval_context == ["r"]
      assert [%ToolCall{name: "t"}] = turn.tools_called
      assert turn.metadata == %{"k" => 1}
    end

    test "prefers metadata over additional_metadata" do
      assert {:ok, turn} =
               Turn.new(
                 role: :user,
                 content: "x",
                 metadata: %{"a" => 1},
                 additional_metadata: %{"b" => 2}
               )

      assert turn.metadata == %{"a" => 1}
    end
  end

  describe "new!/1" do
    test "raises on an invalid turn" do
      assert_raise RuntimeError, ~r/Invalid turn/, fn -> Turn.new!(role: "bot", content: "x") end
    end
  end

  describe "model_dump/1" do
    test "dumps every field of deepeval's model_dump(), audio and provider transcript included" do
      turn =
        Turn.new!(
          role: :user,
          content: "hi",
          audio: %{"url" => "a.wav"},
          provider_transcript: "hy"
        )

      assert JSON.encode!(Turn.model_dump(turn)) ==
               ~s({"role": "user", "content": "hi", "user_id": null, "audio": {"url": "a.wav"}, ) <>
                 ~s("latency_ms": null, "interrupted": null, "provider_transcript": "hy", ) <>
                 ~s("retrieval_context": null, "tools_called": null, "mcp_tools_called": null, ) <>
                 ~s("mcp_resources_called": null, "mcp_prompts_called": null, "metadata": null})
    end
  end

  describe "model_dump_for_prompt/1" do
    test "dumps deepeval's fields in order, without audio or provider transcript" do
      turn =
        Turn.new!(
          role: :assistant,
          content: "hi",
          user_id: "u",
          audio: %{"url" => "a.wav"},
          latency_ms: 12,
          interrupted: true,
          provider_transcript: "hy",
          retrieval_context: ["a", %RetrievedContextData{context: "c", source: "s"}],
          tools_called: [%ToolCall{name: "x", input_parameters: %{"a" => 1}}],
          metadata: %{"k" => 1}
        )

      # deepeval 4.3.1: Turn(...).model_dump_for_prompt(), serialised as
      # serialize_turns_for_prompt does (json.dumps(indent=4))
      assert JSON.encode!(Turn.model_dump_for_prompt(turn), indent: 4, ensure_ascii: false) ==
               String.trim_trailing("""
               {
                   "role": "assistant",
                   "content": "hi",
                   "user_id": "u",
                   "latency_ms": 12.0,
                   "interrupted": true,
                   "retrieval_context": [
                       "a",
                       "s: c"
                   ],
                   "tools_called": [
                       {
                           "name": "x",
                           "type": "FUNCTION",
                           "description": null,
                           "reasoning": null,
                           "output": null,
                           "input_parameters": {
                               "a": 1
                           }
                       }
                   ],
                   "mcp_tools_called": null,
                   "mcp_resources_called": null,
                   "mcp_prompts_called": null,
                   "metadata": {
                       "k": 1
                   }
               }
               """)
    end

    test "keeps unset fields as null" do
      dump = Turn.model_dump_for_prompt(Turn.new!(role: :user, content: "x"))

      assert Enum.map(dump.values, &elem(&1, 0)) == [
               "role",
               "content",
               "user_id",
               "latency_ms",
               "interrupted",
               "retrieval_context",
               "tools_called",
               "mcp_tools_called",
               "mcp_resources_called",
               "mcp_prompts_called",
               "metadata"
             ]

      assert dump["role"] == "user"
      assert dump["user_id"] == nil
      assert dump["metadata"] == nil
    end
  end
end
