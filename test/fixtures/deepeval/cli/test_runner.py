import pytest

from deepeval import assert_test
from deepeval.metrics import ExactMatchMetric
from deepeval.test_case import LLMTestCase
from deepeval.test_run import log_hyperparameters


@log_hyperparameters
def hyperparameters():
    return {"model": "gpt-4.1", "prompt_version": "v3"}


def test_passing():
    test_case = LLMTestCase(name="passing", input="2 + 2?", actual_output="4", expected_output="4")
    assert_test(test_case, [ExactMatchMetric()])


def test_failing():
    test_case = LLMTestCase(name="failing", input="2 + 3?", actual_output="6", expected_output="5")
    assert_test(test_case, [ExactMatchMetric()])


def test_flaky():
    test_case = LLMTestCase(
        name="flaky", input="3 + 3?", actual_output="7", expected_output="6", flaky=True
    )
    assert_test(test_case, [ExactMatchMetric()])


@pytest.mark.rag
def test_unnamed():
    test_case = LLMTestCase(input="Capital of France?", actual_output="Paris", expected_output="Paris")
    assert_test(test_case, [ExactMatchMetric()])


@pytest.mark.skip(reason="not ready")
def test_skipped():
    test_case = LLMTestCase(name="skipped", input="x", actual_output="x", expected_output="x")
    assert_test(test_case, [ExactMatchMetric()])
