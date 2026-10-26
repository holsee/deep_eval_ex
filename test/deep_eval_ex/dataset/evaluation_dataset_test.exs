defmodule DeepEvalEx.Dataset.EvaluationDatasetTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.TestCase

  doctest DeepEvalEx.Dataset.EvaluationDataset

  defp golden(input), do: Golden.new!(input: input)

  defp test_case(input),
    do: TestCase.new!(input: input, actual_output: input, expected_output: input)

  describe "new/2" do
    test "starts empty, without dataset properties" do
      assert %EvaluationDataset{
               goldens: [],
               test_cases: [],
               alias: nil,
               id: nil,
               version: nil
             } = EvaluationDataset.new()
    end

    test "keeps the goldens in order" do
      goldens = [golden("a"), golden("b")]
      assert EvaluationDataset.new(goldens).goldens == goldens
    end

    test "takes the dataset's alias, id and version" do
      dataset = EvaluationDataset.new([], alias: "qa", id: "ds-1", version: "v2")
      assert {dataset.alias, dataset.id, dataset.version} == {"qa", "ds-1", "v2"}
    end

    test "rejects anything but goldens, as deepeval's TypeError" do
      assert_raise ArgumentError, ~r/must be instances of DeepEvalEx.Dataset.Golden/, fn ->
        EvaluationDataset.new([golden("a"), test_case("b")])
      end

      assert_raise ArgumentError, ~r/must be instances of DeepEvalEx.Dataset.Golden/, fn ->
        EvaluationDataset.new([%{input: "a"}])
      end
    end
  end

  describe "add_golden/2" do
    test "appends the golden and leaves the original dataset unchanged" do
      dataset = EvaluationDataset.new([golden("a")])
      added = EvaluationDataset.add_golden(dataset, golden("b"))

      assert Enum.map(added.goldens, & &1.input) == ["a", "b"]
      assert Enum.map(dataset.goldens, & &1.input) == ["a"]
    end

    test "rejects a test case" do
      assert_raise ArgumentError, ~r/must be instances of DeepEvalEx.Dataset.Golden/, fn ->
        EvaluationDataset.add_golden(EvaluationDataset.new(), test_case("a"))
      end
    end
  end

  describe "put_goldens/2" do
    test "replaces the goldens" do
      dataset = EvaluationDataset.new([golden("a")])

      assert EvaluationDataset.put_goldens(dataset, [golden("x"), golden("y")]).goldens == [
               golden("x"),
               golden("y")
             ]
    end

    test "rejects the whole list when one item is not a golden" do
      assert_raise ArgumentError, fn ->
        EvaluationDataset.put_goldens(EvaluationDataset.new(), [golden("a"), "b"])
      end
    end
  end

  describe "add_test_case/2" do
    test "ranks each test case by its position, as deepeval's _dataset_rank" do
      dataset =
        EvaluationDataset.new()
        |> EvaluationDataset.add_test_case(test_case("a"))
        |> EvaluationDataset.add_test_case(test_case("b"))
        |> EvaluationDataset.add_test_case(test_case("c"))

      assert Enum.map(dataset.test_cases, &{&1.input, &1.dataset_rank}) ==
               [{"a", 0}, {"b", 1}, {"c", 2}]
    end

    test "replaces a rank the test case brought from another dataset" do
      ranked = %{test_case("a") | dataset_rank: 7}

      assert [%TestCase{dataset_rank: 0}] =
               EvaluationDataset.new()
               |> EvaluationDataset.add_test_case(ranked)
               |> Map.get(:test_cases)
    end

    test "rejects a golden" do
      assert_raise ArgumentError, ~r/must be instances of DeepEvalEx.TestCase/, fn ->
        EvaluationDataset.add_test_case(EvaluationDataset.new(), golden("a"))
      end
    end
  end

  describe "put_test_cases/2" do
    test "replaces the test cases, ranking them from 0" do
      dataset =
        EvaluationDataset.new()
        |> EvaluationDataset.add_test_case(test_case("old"))
        |> EvaluationDataset.put_test_cases([test_case("x"), test_case("y")])

      assert Enum.map(dataset.test_cases, &{&1.input, &1.dataset_rank}) == [{"x", 0}, {"y", 1}]
    end

    test "skips anything that is not a test case, as deepeval's setter" do
      dataset =
        EvaluationDataset.put_test_cases(EvaluationDataset.new(), [
          test_case("x"),
          "junk",
          golden("g"),
          test_case("y")
        ])

      assert Enum.map(dataset.test_cases, &{&1.input, &1.dataset_rank}) == [{"x", 0}, {"y", 1}]
    end
  end

  describe "Enumerable" do
    setup do
      %{dataset: EvaluationDataset.new([golden("a"), golden("b"), golden("c")])}
    end

    test "enumerates the goldens in order", %{dataset: dataset} do
      assert Enum.map(dataset, & &1.input) == ["a", "b", "c"]
      assert Enum.count(dataset) == 3
      assert Enum.member?(dataset, golden("b"))
      refute Enum.member?(dataset, golden("z"))
      assert Enum.at(dataset, 1) == golden("b")
      assert dataset |> Enum.slice(1..2) |> Enum.map(& &1.input) == ["b", "c"]
      assert Enum.take(dataset, 1) == [golden("a")]
    end

    test "an empty dataset enumerates nothing" do
      assert Enum.to_list(EvaluationDataset.new()) == []
      assert Enum.empty?(EvaluationDataset.new())
    end
  end

  describe "dataset rank in evaluation" do
    # deepeval 4.3.1: evaluate(test_cases=[ds.test_cases[2], ds.test_cases[0]])
    # names the test results test_case_2 and test_case_0, in the order given,
    # and writes the run's testCases sorted by order: test_case_0 (order 0),
    # then test_case_2 (order 2).
    test "names test cases after their dataset rank and sorts the run by it" do
      dataset =
        Enum.reduce(~w(a b c d), EvaluationDataset.new(), fn input, acc ->
          EvaluationDataset.add_test_case(acc, test_case(input))
        end)

      [a, _b, c, _d] = dataset.test_cases

      {:ok, result} = DeepEvalEx.evaluate([c, a], [ExactMatch])

      assert Enum.map(result.test_results, &{&1.name, &1.index}) == [
               {"test_case_2", 2},
               {"test_case_0", 0}
             ]

      {_results, test_run, nil} = DeepEvalEx.evaluate_run([c, a], [ExactMatch])

      assert Enum.map(test_run.test_cases, &{&1.name, &1.order, &1.input}) ==
               [{"test_case_0", 0, "a"}, {"test_case_2", 2, "c"}]
    end
  end
end
