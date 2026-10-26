defmodule DeepEvalEx.Schemas.RetrievedContextDataTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Schemas.RetrievedContextData
  alias DeepEvalEx.SystemOne.State

  doctest DeepEvalEx.Schemas.RetrievedContextData

  @data %RetrievedContextData{context: "Paris is in France.", source: "wiki"}

  describe "new/1" do
    test "builds the struct from atom or string keys" do
      assert {:ok, @data} =
               RetrievedContextData.new(context: "Paris is in France.", source: "wiki")

      assert {:ok, @data} =
               RetrievedContextData.new(%{"context" => "Paris is in France.", "source" => "wiki"})
    end

    test "requires both context and source, as deepeval's pydantic model" do
      assert {:error, _} = RetrievedContextData.new(context: "Paris is in France.")
      assert {:error, _} = RetrievedContextData.new(source: "wiki")
      assert {:error, _} = RetrievedContextData.new(context: 1, source: "wiki")
    end
  end

  describe "String.Chars" do
    test "renders deepeval's model_serializer, source then context" do
      assert to_string(@data) == "wiki: Paris is in France."
    end
  end

  describe "context/1" do
    test "returns the context of a RetrievedContextData and a string as it is" do
      assert RetrievedContextData.context(@data) == "Paris is in France."
      assert RetrievedContextData.context("plain chunk") == "plain chunk"
    end
  end

  describe "Python formatting" do
    test "repr/1 prints pydantic's repr, fields in declaration order" do
      assert Python.repr([@data, "it's"]) ==
               ~S{[RetrievedContextData(context='Paris is in France.', source='wiki'), "it's"]}
    end

    test "str/1 prints pydantic's str for a model and a string as it is" do
      assert Python.str(@data) == "context='Paris is in France.' source='wiki'"
      assert Python.str("plain chunk") == "plain chunk"
    end
  end

  describe "System One state" do
    test "is sent as deepeval's model_dump, the serialised 'source: context' string" do
      test_case = %DeepEvalEx.TestCase{input: "Q", retrieval_context: [@data, "plain chunk"]}

      assert [:retrieval_context] |> State.single_turn(test_case) |> Jason.encode!() ==
               ~s({"test_case":{"retrieval_context":["wiki: Paris is in France.","plain chunk"]}})
    end
  end
end
