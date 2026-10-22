defmodule DeepEvalEx.Metrics.SystemOneParityTest do
  @moduledoc """
  Measures the System One scenarios of `test/fixtures/deepeval/system_one/`
  with the real DeepEvalEx metrics and compares each with what deepeval
  4.3.1 did (see `DeepEvalEx.Test.SystemOneParity` and the fixtures'
  README), in five facets:

  - `decide` - every System One request (state and questions) and what it
    answered, byte for byte
  - `measure` - score, success, reason, threshold, error, evaluation model,
    cost, tokens, verbose logs, confidence, fallback reason and score
    breakdown after measuring
  - `prompts` - every prompt the LLM judge got, byte for byte
  - `test_run` - the exported test run, byte for byte
  - `evaluate decide` - the System One requests of the `evaluate()` run

  Batched scenarios (`batch_*`) measure several metrics: each is measured
  alone (`decide`, `measure`), and `evaluate()` batches them into one
  request (`DeepEvalEx.SystemOne.Batch`, `test_run` and `evaluate decide`).
  """

  use ExUnit.Case, async: true

  import DeepEvalEx.Test.SystemOneParity

  @moduletag :parity
  @moduletag :tmp_dir
  # evaluate_run/3 logs where it saved the test run.
  @moduletag :capture_log

  @scenarios ~w(
    faithfulness_system_one faithfulness_system_one_strict faithfulness_hybrid
    faithfulness_hybrid_fallback
    answer_relevancy_system_one answer_relevancy_hybrid answer_relevancy_hybrid_fallback
    contextual_precision_system_one contextual_precision_hybrid
    contextual_precision_hybrid_fallback
    contextual_recall_system_one contextual_recall_hybrid contextual_recall_hybrid_fallback
    contextual_relevancy_system_one contextual_relevancy_hybrid
    contextual_relevancy_hybrid_fallback
    hallucination_system_one hallucination_hybrid hallucination_hybrid_fallback
    bias_system_one bias_hybrid bias_hybrid_fallback
    toxicity_system_one toxicity_hybrid toxicity_hybrid_fallback
    pii_leakage_system_one pii_leakage_hybrid pii_leakage_hybrid_fallback
    prompt_alignment_system_one prompt_alignment_hybrid prompt_alignment_hybrid_fallback
    summarization_system_one summarization_hybrid summarization_hybrid_fallback
    argument_correctness_system_one argument_correctness_hybrid
    argument_correctness_hybrid_fallback
    tool_correctness_system_one tool_correctness_hybrid tool_correctness_hybrid_fallback
    json_correctness_system_one json_correctness_hybrid
    jev_eval jev_eval_strict_not_applicable
  )

  @batched_scenarios ~w(
    batch_system_one batch_system_one_retrieval batch_system_one_safety
    batch_system_one_pii_alignment batch_system_one_agent batch_system_one_json
    batch_system_one_summarization
    batch_system_one_down
  )

  for scenario <- @scenarios ++ @batched_scenarios,
      file <- ~w(input.json decide.json measure.json prompts.json test_run.json),
      File.regular?(fixture(scenario, file)) do
    @external_resource fixture(scenario, file)
  end

  for scenario <- @scenarios do
    describe scenario do
      test "asks System One what deepeval asked" do
        {_measured, calls, _prompts} = measure(unquote(scenario))
        assert_calls(calls, unquote(scenario))
      end

      test "measures what deepeval measured" do
        {measured, _calls, _prompts} = measure(unquote(scenario))
        assert_measured(measured, unquote(scenario))
      end

      test "prompts the LLM judge as deepeval did" do
        {_measured, _calls, prompts} = measure(unquote(scenario))
        assert_prompts(prompts, unquote(scenario))
      end

      test "exports deepeval's test run", %{tmp_dir: tmp_dir} do
        {test_run, calls} = test_run(unquote(scenario), tmp_dir)
        assert_test_run(test_run, unquote(scenario))
        assert_calls(calls, unquote(scenario), :evaluate)
      end
    end
  end

  for scenario <- @batched_scenarios do
    describe scenario do
      for index <- 0..(metric_count(scenario) - 1) do
        test "asks System One what deepeval asked metric #{index} alone" do
          {_measured, calls, _prompts} = measure(unquote(scenario), unquote(index))
          assert_calls(calls, unquote(scenario), :measure, unquote(index))
        end

        test "measures metric #{index} alone as deepeval did" do
          {measured, _calls, _prompts} = measure(unquote(scenario), unquote(index))
          assert_measured(measured, unquote(scenario), unquote(index))
        end
      end

      test "exports deepeval's test run from one batched request", %{tmp_dir: tmp_dir} do
        {test_run, calls} = test_run(unquote(scenario), tmp_dir)
        assert_calls(calls, unquote(scenario), :evaluate)
        assert_test_run(test_run, unquote(scenario))
      end
    end
  end
end
