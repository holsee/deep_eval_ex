defmodule DeepEvalEx.Dataset.UtilsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Utils
  alias DeepEvalEx.Schemas.RetrievedContextData

  doctest DeepEvalEx.Dataset.Utils

  @data %RetrievedContextData{source: "policy.md", context: "Refunds: 30 days"}

  test "delimiters are deepeval's" do
    assert Utils.delimiter() == "|"
    assert Utils.tools_delimiter() == ";"
  end

  describe "serialize_retrieval_context/1" do
    test "writes RetrievedContextData as deepeval's marker, leaving strings" do
      assert Utils.serialize_retrieval_context(["plain", @data]) ==
               ["plain", "deepeval_source=policy.md,deepeval_context=Refunds: 30 days"]
    end

    test "keeps nil" do
      assert Utils.serialize_retrieval_context(nil) == nil
    end
  end

  describe "join_retrieval_context/2 and join_context/2" do
    test "join serialised items on the delimiter" do
      assert Utils.join_retrieval_context(["a", @data]) ==
               "a|deepeval_source=policy.md,deepeval_context=Refunds: 30 days"

      assert Utils.join_retrieval_context(["a", "b"], ";") == "a;b"
      assert Utils.join_context(["a", "b"]) == "a|b"
      assert Utils.join_context(["a", "b"], ";") == "a;b"
      assert Utils.join_context([]) == ""
    end

    test "keep nil" do
      assert Utils.join_retrieval_context(nil) == nil
      assert Utils.join_context(nil) == nil
    end
  end

  describe "reconstruct_retrieval_context/1" do
    test "rebuilds RetrievedContextData from markers, leaving other strings" do
      assert Utils.reconstruct_retrieval_context([
               "plain",
               "deepeval_source=policy.md,deepeval_context=Refunds: 30 days"
             ]) == ["plain", @data]
    end

    test "inverts serialize_retrieval_context/1" do
      items = ["x", @data, %RetrievedContextData{source: "", context: ""}]

      assert items |> Utils.serialize_retrieval_context() |> Utils.reconstruct_retrieval_context() ==
               items
    end

    test "splits at the first ',deepeval_context=' and needs the marker at the start" do
      assert Utils.reconstruct_retrieval_context([
               "deepeval_source=a,b,deepeval_context=c,deepeval_context=d",
               " deepeval_source=a,deepeval_context=b"
             ]) == [
               %RetrievedContextData{source: "a,b", context: "c,deepeval_context=d"},
               " deepeval_source=a,deepeval_context=b"
             ]
    end

    test "drops a newline ending the context, as Python's $" do
      assert Utils.reconstruct_retrieval_context(["deepeval_source=a,deepeval_context=b\n"]) ==
               [%RetrievedContextData{source: "a", context: "b"}]
    end

    test "does not match across lines, as Python's re" do
      assert Utils.reconstruct_retrieval_context(["deepeval_source=a\n,deepeval_context=b"]) ==
               ["deepeval_source=a\n,deepeval_context=b"]
    end

    test "keeps nil and items that are not strings" do
      assert Utils.reconstruct_retrieval_context(nil) == nil
      assert Utils.reconstruct_retrieval_context([@data]) == [@data]
    end
  end

  describe "trim_and_load_json/1" do
    test "decodes JSON with surrounding whitespace" do
      assert Utils.trim_and_load_json("  {\"a\": [1, 2.5, null, true]}\n") ==
               {:ok, %{"a" => [1, 2.5, nil, true]}}
    end

    test "drops trailing commas when the JSON does not decode as it is" do
      assert Utils.trim_and_load_json(~s([{"name": "t", "x": {"q": 1},},])) ==
               {:ok, [%{"name" => "t", "x" => %{"q" => 1}}]}
    end

    test "leaves ', ]' inside valid JSON strings alone" do
      assert Utils.trim_and_load_json(~s(["a, ]"])) == {:ok, ["a, ]"]}
    end

    test "returns deepeval's error message otherwise" do
      assert {:error, "Invalid JSON: {nope. Error: " <> _} = Utils.trim_and_load_json("{nope")
    end
  end
end
