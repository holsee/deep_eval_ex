defmodule DeepEvalEx.TestCaseTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.TestCase

  describe "new/1" do
    test "creates a valid test case with required fields" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "What is the capital of France?",
                 actual_output: "Paris"
               )

      assert test_case.input == "What is the capital of France?"
      assert test_case.actual_output == "Paris"
    end

    test "creates test case with all fields" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "Question",
                 actual_output: "Answer",
                 expected_output: "Expected",
                 retrieval_context: ["context 1", "context 2"],
                 metadata: %{key: "value"},
                 name: "test-1",
                 tags: ["rag", "qa"]
               )

      assert test_case.expected_output == "Expected"
      assert test_case.retrieval_context == ["context 1", "context 2"]
      assert test_case.metadata == %{key: "value"}
      assert test_case.name == "test-1"
      assert test_case.tags == ["rag", "qa"]
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = TestCase.new(%{})
      assert "can't be blank" in errors_on(changeset).input
    end

    test "normalizes context to retrieval_context" do
      assert {:ok, test_case} =
               TestCase.new(
                 input: "Question",
                 context: ["context 1"]
               )

      assert test_case.retrieval_context == ["context 1"]
    end
  end

  describe "new!/1" do
    test "creates test case and returns struct directly" do
      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer"
        )

      assert %TestCase{} = test_case
      assert test_case.input == "Question"
    end

    test "raises on invalid input" do
      assert_raise RuntimeError, ~r/Invalid test case/, fn ->
        TestCase.new!(%{})
      end
    end
  end

  describe "validate_params/2" do
    test "returns :ok when all params present" do
      test_case =
        TestCase.new!(
          input: "Question",
          actual_output: "Answer",
          expected_output: "Expected"
        )

      assert :ok = TestCase.validate_params(test_case, [:input, :actual_output, :expected_output])
    end

    test "returns error with missing params" do
      test_case = TestCase.new!(input: "Question")

      assert {:error, {:missing_params, missing}} =
               TestCase.validate_params(test_case, [:input, :actual_output, :expected_output])

      assert :actual_output in missing
      assert :expected_output in missing
      refute :input in missing
    end
  end

  describe "get_retrieval_context/1" do
    test "returns retrieval_context when set" do
      test_case = TestCase.new!(input: "Q", retrieval_context: ["ctx"])
      assert TestCase.get_retrieval_context(test_case) == ["ctx"]
    end

    test "falls back to context when retrieval_context is nil" do
      test_case = %TestCase{input: "Q", context: ["ctx"], retrieval_context: nil}
      assert TestCase.get_retrieval_context(test_case) == ["ctx"]
    end

    test "returns nil when both are nil" do
      test_case = TestCase.new!(input: "Q")
      assert TestCase.get_retrieval_context(test_case) == nil
    end
  end

  # Helper to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
