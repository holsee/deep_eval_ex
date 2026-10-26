defmodule DeepEvalEx.Params.SingleTurnTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Params.SingleTurn
  alias DeepEvalEx.Prompts.GEval, as: Template

  doctest DeepEvalEx.Params.SingleTurn

  describe "all/0" do
    test "lists deepeval 4.3.1's SingleTurnParams members in order" do
      assert SingleTurn.all() == [
               :input,
               :actual_output,
               :expected_output,
               :context,
               :retrieval_context,
               :metadata,
               :tags,
               :tools_called,
               :expected_tools,
               :mcp_servers,
               :mcp_tools_called,
               :mcp_resources_called,
               :mcp_prompts_called
             ]
    end
  end

  describe "member?/1" do
    test "is true for SingleTurnParams members only" do
      assert SingleTurn.member?(:tags)
      assert SingleTurn.member?(:mcp_servers)
      refute SingleTurn.member?(:name)
      refute SingleTurn.member?("input")
    end
  end

  describe "display_name/1" do
    test "uses deepeval's G_EVAL_PARAMS names" do
      assert Enum.map(
               [
                 :input,
                 :actual_output,
                 :expected_output,
                 :context,
                 :retrieval_context,
                 :metadata,
                 :tags,
                 :expected_tools,
                 :tools_called
               ],
               &SingleTurn.display_name/1
             ) == [
               "Input",
               "Actual Output",
               "Expected Output",
               "Context",
               "Retrieval Context",
               "Metadata",
               "Tags",
               "Expected Tools",
               "Tools Called"
             ]
    end

    test "is nil for params deepeval gives no display name" do
      assert SingleTurn.display_name(:mcp_servers) == nil
      assert SingleTurn.display_name(:name) == nil
    end
  end

  describe "GEval prompts" do
    test "name evaluation params with deepeval's display names" do
      assert Template.format_params([:tools_called, :expected_tools, :tags]) ==
               "Tools Called, Expected Tools, and Tags"

      assert Template.format_test_case_content(%{tags: ["a", "b"]}, [:tags]) ==
               "Tags:\n['a', 'b'] \n\n"
    end
  end
end
