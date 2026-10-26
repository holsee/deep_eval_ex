defmodule DeepEvalEx.Params.MultiTurnTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Params.MultiTurn

  doctest DeepEvalEx.Params.MultiTurn

  describe "all/0" do
    test "lists deepeval 4.3.1's MultiTurnParams members in order" do
      assert MultiTurn.all() == [
               :role,
               :content,
               :provider_transcript,
               :audio,
               :metadata,
               :tags,
               :scenario,
               :expected_outcome,
               :context,
               :user_description,
               :retrieval_context,
               :chatbot_role,
               :tools_called,
               :mcp_tools_called,
               :mcp_resources_called,
               :mcp_prompts_called
             ]
    end
  end

  describe "member?/1" do
    test "is true for MultiTurnParams members only" do
      assert MultiTurn.member?(:chatbot_role)
      assert MultiTurn.member?(:provider_transcript)
      refute MultiTurn.member?(:input)
      refute MultiTurn.member?("role")
    end
  end

  describe "display_name/1" do
    test "uses deepeval's CONVERSATIONAL_G_EVAL_PARAMS names" do
      assert Map.new(MultiTurn.all(), &{&1, MultiTurn.display_name(&1)}) == %{
               role: "Role",
               content: "Content",
               provider_transcript: nil,
               audio: "Audio",
               metadata: "Metadata",
               tags: "Tags",
               scenario: "Scenario",
               expected_outcome: "Expected Outcome",
               context: nil,
               user_description: nil,
               retrieval_context: "Retrieval Context",
               chatbot_role: nil,
               tools_called: "Tools Called",
               mcp_tools_called: nil,
               mcp_resources_called: nil,
               mcp_prompts_called: nil
             }
    end
  end
end
