defmodule DeepEvalEx.Dataset.ExpectationsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Expectations

  doctest DeepEvalEx.Dataset.Expectations

  describe "cast/1" do
    test "fills deepeval's defaults and strips each condition" do
      assert Expectations.cast(%{"must" => [" Cite a source "], "mustNot" => ["Guess"]}) ==
               {:ok, %{model: nil, eval_mode: nil, must: ["Cite a source"], must_not: ["Guess"]}}

      assert Expectations.cast(%{}) ==
               {:ok, %{model: nil, eval_mode: nil, must: [], must_not: []}}
    end

    test "accepts atom keys, keyword lists, a model name and an eval mode" do
      assert Expectations.cast(must_not: ["Guess"], model: "gpt-4.1", eval_mode: "system_one") ==
               {:ok, %{model: "gpt-4.1", eval_mode: :system_one, must: [], must_not: ["Guess"]}}

      assert {:ok, %{eval_mode: :llm}} = Expectations.cast(%{eval_mode: :llm})
    end

    test "rejects what deepeval's Expectations rejects" do
      # Expectations is extra="forbid", and must_not shadows its mustNot alias
      for bad <- [
            %{"must" => ["  "]},
            %{"must" => "Cite a source"},
            %{"must" => [1]},
            %{"must" => nil},
            %{"model" => 3},
            %{"eval_mode" => "hybrid"},
            %{"eval_mode" => "LLM"},
            %{"bogus" => 1},
            %{"must_not" => ["a"], "mustNot" => ["b"]},
            "must cite"
          ] do
        assert {:error, message, _} = Expectations.cast(bad), "accepted #{inspect(bad)}"
        assert is_binary(message)
      end
    end
  end
end
