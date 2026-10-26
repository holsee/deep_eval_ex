defmodule DeepEvalEx.ArenaTestCaseTest do
  @moduledoc """
  `DeepEvalEx.ArenaTestCase` and `DeepEvalEx.Contestant`, ports of deepeval
  4.3.1's `test_case/arena_test_case.py`. The error messages are deepeval's,
  as its `ArenaTestCase.__post_init__` raises them.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{ArenaTestCase, Contestant, MLLMImage, TestCase}

  doctest DeepEvalEx.ArenaTestCase
  doctest DeepEvalEx.Contestant

  defp test_case(attrs \\ []) do
    TestCase.new!(Keyword.merge([input: "What is 2 + 2?", actual_output: "4"], attrs))
  end

  defp contestant(name, attrs \\ []) do
    Contestant.new!(name: name, test_case: test_case(attrs))
  end

  describe "Contestant.new/1" do
    test "builds a contestant from a name and a test case" do
      tc = test_case()

      assert {:ok, %Contestant{name: "gpt-4o", test_case: ^tc, hyperparameters: nil}} =
               Contestant.new(name: "gpt-4o", test_case: tc)
    end

    test "takes string keys and builds the test case from its attributes" do
      assert {:ok, %Contestant{name: "a", test_case: %TestCase{input: "q", actual_output: "a"}}} =
               Contestant.new(%{
                 "name" => "a",
                 "test_case" => %{"input" => "q", "actual_output" => "a"},
                 "ignored" => true
               })
    end

    test "keeps string, integer and float hyperparameters under string keys" do
      {:ok, contestant} =
        Contestant.new(
          name: "a",
          test_case: test_case(),
          hyperparameters: [model: "gpt-4o", max_tokens: 256, temperature: 0.7]
        )

      assert contestant.hyperparameters == %{
               "model" => "gpt-4o",
               "max_tokens" => 256,
               "temperature" => 0.7
             }
    end

    test "casts a boolean hyperparameter to an integer, as pydantic's union does" do
      {:ok, contestant} =
        Contestant.new(name: "a", test_case: test_case(), hyperparameters: %{"stream" => true})

      assert contestant.hyperparameters == %{"stream" => 1}
    end

    test "rejects a hyperparameter that is not a string or a number" do
      assert {:error, message} =
               Contestant.new(name: "a", test_case: test_case(), hyperparameters: %{"x" => [1]})

      assert message =~ "'hyperparameters'"

      assert {:error, _} =
               Contestant.new(name: "a", test_case: test_case(), hyperparameters: %{"x" => nil})

      assert {:error, _} =
               Contestant.new(name: "a", test_case: test_case(), hyperparameters: %{1 => "x"})

      assert {:error, _} = Contestant.new(name: "a", test_case: test_case(), hyperparameters: 1)
    end

    test "requires a string name" do
      assert {:error, "'name' must be a string, got 1"} =
               Contestant.new(name: 1, test_case: test_case())

      assert {:error, "'name' must be a string, got nil"} = Contestant.new(test_case: test_case())
    end

    test "requires a valid test case" do
      assert {:error, "'test_case' must be a DeepEvalEx.TestCase" <> _} =
               Contestant.new(name: "a")

      assert {:error, "'test_case' is invalid: " <> _} =
               Contestant.new(name: "a", test_case: %{actual_output: "no input"})
    end

    test "rejects attributes that are not a keyword list or a map" do
      assert {:error, _} = Contestant.new("a")
    end

    test "new!/1 raises ArgumentError on error" do
      assert_raise ArgumentError, "Invalid contestant: 'name' must be a string, got 1", fn ->
        Contestant.new!(name: 1, test_case: test_case())
      end
    end
  end

  describe "ArenaTestCase.new/1" do
    test "builds an arena test case from contestants" do
      a = contestant("a")
      b = contestant("b", actual_output: "four")

      assert {:ok, %ArenaTestCase{contestants: [^a, ^b], multimodal: false}} =
               ArenaTestCase.new(contestants: [a, b])
    end

    test "builds contestants from their attributes" do
      assert {:ok, %ArenaTestCase{contestants: [%Contestant{name: "a"}, %Contestant{name: "b"}]}} =
               ArenaTestCase.new(%{
                 "contestants" => [
                   %{"name" => "a", "test_case" => %{"input" => "q", "actual_output" => "x"}},
                   [name: "b", test_case: [input: "q", actual_output: "y"]]
                 ]
               })
    end

    test "requires unique contestant names" do
      assert {:error, "All contestant names must be unique."} =
               ArenaTestCase.new(contestants: [contestant("a"), contestant("a")])
    end

    test "checks names before inputs, as deepeval does" do
      assert {:error, "All contestant names must be unique."} =
               ArenaTestCase.new(contestants: [contestant("a"), contestant("a", input: "other")])
    end

    test "requires every contestant to share the input" do
      assert {:error, "All contestants must have the same 'input'."} =
               ArenaTestCase.new(contestants: [contestant("a"), contestant("b", input: "other")])
    end

    test "requires every contestant to share the expected output" do
      assert {:error, "All contestants must have the same 'expected_output'."} =
               ArenaTestCase.new(
                 contestants: [contestant("a", expected_output: "4"), contestant("b")]
               )

      assert {:ok, _} =
               ArenaTestCase.new(
                 contestants: [
                   contestant("a", expected_output: "4"),
                   contestant("b", expected_output: "4")
                 ]
               )
    end

    test "requires at least one contestant" do
      assert {:error, "'contestants' must not be empty"} = ArenaTestCase.new(contestants: [])
      assert {:error, "'contestants' must be a list" <> _} = ArenaTestCase.new([])
    end

    test "returns a contestant's error" do
      assert {:error, "'name' must be a string, got nil"} =
               ArenaTestCase.new(contestants: [[test_case: test_case()]])
    end

    test "is multimodal when any contestant's test case is" do
      image = MLLMImage.new!(url: "https://example.com/chart.png")

      multimodal =
        Contestant.new!(
          name: "b",
          test_case: test_case(actual_output: "See #{image}", images: [image])
        )

      assert {:ok, %ArenaTestCase{multimodal: true}} =
               ArenaTestCase.new(contestants: [contestant("a"), multimodal])
    end

    test "keeps multimodal: true when given" do
      assert {:ok, %ArenaTestCase{multimodal: true}} =
               ArenaTestCase.new(contestants: [contestant("a")], multimodal: true)
    end

    test "new!/1 raises ArgumentError on error" do
      assert_raise ArgumentError,
                   "Invalid arena test case: All contestant names must be unique.",
                   fn -> ArenaTestCase.new!(contestants: [contestant("a"), contestant("a")]) end
    end
  end
end
