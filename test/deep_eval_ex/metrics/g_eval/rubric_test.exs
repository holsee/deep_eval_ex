defmodule DeepEvalEx.Metrics.GEval.RubricTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.GEval.Rubric

  doctest Rubric

  # Expected values and error messages are deepeval 4.3.1's, from
  # deepeval.metrics.g_eval.utils on the same rubrics.

  describe "new/1 and new!/1" do
    test "builds a rubric from a keyword list or a map" do
      assert {:ok, %Rubric{score_range: {0, 3}, expected_outcome: "Bad."}} =
               Rubric.new(score_range: {0, 3}, expected_outcome: "Bad.")

      assert %Rubric{score_range: {5, 5}, expected_outcome: "Mid."} =
               Rubric.new!(%{score_range: {5, 5}, expected_outcome: "Mid."})
    end

    test "accepts a score range as a two-element list, as deepeval's tuple" do
      assert %Rubric{score_range: {7, 10}} =
               Rubric.new!(score_range: [7, 10], expected_outcome: "Good.")
    end

    test "rejects a score range outside 0-10 with deepeval's message" do
      message = "Both Rubric's 'score_range' values must be between 0 and 10 inclusive."

      for range <- [{-1, 3}, {0, 11}] do
        assert {:error, ^message} = Rubric.new(score_range: range, expected_outcome: "x")

        assert_raise ArgumentError, message, fn ->
          Rubric.new!(score_range: range, expected_outcome: "x")
        end
      end
    end

    test "rejects a score range that starts after it ends with deepeval's message" do
      assert {:error, "Rubric's 'score_range' start must be less than or equal to end."} =
               Rubric.new(score_range: {5, 2}, expected_outcome: "x")
    end

    test "rejects non-integer scores and a missing expected outcome" do
      assert {:error, _} = Rubric.new(score_range: {0.5, 2}, expected_outcome: "x")
      assert {:error, _} = Rubric.new(score_range: {0, 2})
      assert {:error, _} = Rubric.new(expected_outcome: "x")
    end
  end

  describe "validate_and_sort/1" do
    test "sorts rubrics by the start of their range" do
      rubrics = [
        Rubric.new!(score_range: {7, 10}, expected_outcome: "Good."),
        Rubric.new!(score_range: {0, 3}, expected_outcome: "Bad."),
        Rubric.new!(score_range: {5, 5}, expected_outcome: "Mid.")
      ]

      assert [{0, 3}, {5, 5}, {7, 10}] ==
               rubrics |> Rubric.validate_and_sort() |> Enum.map(& &1.score_range)
    end

    test "returns nil for no rubric" do
      assert Rubric.validate_and_sort(nil) == nil
      assert Rubric.validate_and_sort([]) == nil
    end

    test "rejects overlapping ranges with deepeval's message, sharing an end too" do
      cases = [
        {[{0, 5}, {5, 8}], "Overlapping score ranges: (0, 5) and (5, 8)"},
        {[{0, 10}, {2, 3}, {4, 4}], "Overlapping score ranges: (0, 10) and (2, 3)"},
        {[{3, 3}, {3, 5}], "Overlapping score ranges: (3, 3) and (3, 5)"}
      ]

      for {ranges, message} <- cases do
        rubrics = Enum.map(ranges, &Rubric.new!(score_range: &1, expected_outcome: "x"))

        assert_raise ArgumentError, message, fn -> Rubric.validate_and_sort(rubrics) end
      end
    end
  end

  describe "score_range/1" do
    test "spans the sorted rubrics, 0-10 without one, as deepeval's get_score_range" do
      rubrics =
        Rubric.validate_and_sort([
          Rubric.new!(score_range: {4, 5}, expected_outcome: "Good."),
          Rubric.new!(score_range: {1, 2}, expected_outcome: "Bad.")
        ])

      assert Rubric.score_range(rubrics) == {1, 5}
      assert Rubric.score_range(nil) == {0, 10}
    end
  end
end
