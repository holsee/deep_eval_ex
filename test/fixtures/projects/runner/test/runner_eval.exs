# The mirror of test/fixtures/deepeval/cli/test_runner.py: the same test
# cases, assertions, mark and skip, in the same order (run with --seed 0).
defmodule Runner.EvalTest do
  use ExUnit.Case, async: false
  use DeepEvalEx.ExUnit

  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.TestCase

  test "passing" do
    test_case =
      TestCase.new!(name: "passing", input: "2 + 2?", actual_output: "4", expected_output: "4")

    assert_test(test_case, [ExactMatch])
  end

  test "failing" do
    test_case =
      TestCase.new!(name: "failing", input: "2 + 3?", actual_output: "6", expected_output: "5")

    assert_test(test_case, [ExactMatch])
  end

  test "flaky" do
    test_case =
      TestCase.new!(
        name: "flaky",
        input: "3 + 3?",
        actual_output: "7",
        expected_output: "6",
        flaky: true
      )

    assert_test(test_case, [ExactMatch])
  end

  @tag :rag
  test "unnamed" do
    test_case =
      TestCase.new!(input: "Capital of France?", actual_output: "Paris", expected_output: "Paris")

    assert_test(test_case, [ExactMatch])
  end

  @tag skip: "not ready"
  test "skipped" do
    test_case =
      TestCase.new!(name: "skipped", input: "x", actual_output: "x", expected_output: "x")

    assert_test(test_case, [ExactMatch])
  end
end
