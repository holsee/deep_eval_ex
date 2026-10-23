defmodule DeepEvalEx.Metrics.Utils.SequenceMatcherTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.Utils.SequenceMatcher

  doctest SequenceMatcher

  @table Path.expand("../../../fixtures/deepeval/loop_detection/sequence_matcher.json", __DIR__)
  @external_resource @table

  # The isjunk functions a table row may name, as the generator's
  # SEQUENCE_MATCHER_JUNK.
  defp isjunk(nil), do: nil
  defp isjunk("space"), do: &(&1 == ?\s)

  describe "ratio/3 and matching_blocks/3 against difflib (sequence_matcher.json)" do
    rows = @table |> File.read!() |> Jason.decode!()

    test "the table covers autojunk, junk and empty inputs" do
      rows = @table |> File.read!() |> Jason.decode!()

      assert Enum.any?(rows, &(String.length(&1["b"]) >= 200 and &1["autojunk"]))
      assert Enum.any?(rows, &(String.length(&1["b"]) >= 200 and not &1["autojunk"]))
      assert Enum.any?(rows, &(&1["isjunk"] == "space"))
      assert Enum.any?(rows, &(&1["a"] == "" and &1["b"] == ""))
    end

    for {row, index} <- Enum.with_index(rows) do
      @row row

      test "row #{index}: ratio #{row["ratio"]}" do
        opts = [isjunk: isjunk(@row["isjunk"]), autojunk: @row["autojunk"]]

        assert SequenceMatcher.ratio(@row["a"], @row["b"], opts) === @row["ratio"]

        assert SequenceMatcher.matching_blocks(@row["a"], @row["b"], opts) ==
                 Enum.map(@row["matching_blocks"], &List.to_tuple/1)
      end
    end
  end

  describe "ratio/3" do
    test "takes lists as well as strings" do
      assert SequenceMatcher.ratio([1, 2, 3], [1, 2, 4]) == 2 * 2 / 6
      assert SequenceMatcher.ratio(~w(a b c), ~w(a b c)) == 1.0
    end

    test "compares code points, not bytes or graphemes" do
      # "é" as one code point against "e" and a combining acute accent.
      assert SequenceMatcher.ratio("\u00e9", "e\u0301") == 0.0
      assert SequenceMatcher.ratio("e\u0301", "e") == 2 / 3
    end

    test "is 1.0 for two empty sequences, as difflib's _calculate_ratio" do
      assert SequenceMatcher.ratio("", "") == 1.0
      assert SequenceMatcher.ratio("", "a") == 0.0
    end
  end
end
