defmodule DeepEvalEx.EvaluatorCacheTest do
  @moduledoc """
  The test-run cache through `DeepEvalEx.evaluate_run/3` (see "Cache" in
  `DeepEvalEx.Evaluator`); `DeepEvalEx.TestRun.CacheParityTest` checks the
  files against deepeval's.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{ConversationalTestCase, Evaluator, Result, TestCase}
  alias DeepEvalEx.Metrics.Faithfulness
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.ParityMetrics.{CacheStub, ConversationalStub}
  alias DeepEvalEx.TestRun.Cache

  @moduletag :tmp_dir

  @test_case %TestCase{input: "What is the capital of France?", actual_output: "Paris."}

  @stub %CacheStub{
    name: "Relevance",
    score: 0.8,
    reason: "Relevant.",
    threshold: 0.5,
    evaluation_model: "gpt-4o-mini",
    evaluation_cost: 0.25,
    input_tokens: 120,
    output_tokens: 12
  }

  defp evaluate(dir, opts \\ []) do
    {[results], _test_run, _path} =
      DeepEvalEx.evaluate_run([@test_case], [@stub], [cache_folder: dir] ++ opts)

    results
  end

  defp measured do
    receive do
      {:measured, name} -> [name | measured()]
    after
      0 -> []
    end
  end

  test "a warm run with use_cache reuses the result at cost 0 without measuring", %{tmp_dir: dir} do
    assert [%Result{evaluation_cost: 0.25, input_tokens: 120}] = evaluate(dir)
    assert measured() == ["Relevance"]

    ref = :telemetry_test.attach_event_handlers(self(), [[:deep_eval_ex, :metric, :cache_hit]])

    assert [%Result{score: 0.8, success: true, evaluation_cost: +0.0, input_tokens: nil}] =
             evaluate(dir, use_cache: true)

    assert measured() == []

    assert_received {[:deep_eval_ex, :metric, :cache_hit], ^ref, _measurements,
                     %{metric: "Relevance", test_case: nil}}
  end

  test "reads nothing without use_cache, as deepeval's evaluate()", %{tmp_dir: dir} do
    evaluate(dir)
    assert measured() == ["Relevance"]

    assert [%Result{evaluation_cost: 0.25}] = evaluate(dir)
    assert measured() == ["Relevance"]
  end

  test "measures again a metric whose configuration changed", %{tmp_dir: dir} do
    evaluate(dir)
    measured()

    {[[result]], _test_run, _path} =
      DeepEvalEx.evaluate_run([@test_case], [%{@stub | threshold: 0.7}],
        cache_folder: dir,
        use_cache: true
      )

    assert result.evaluation_cost == 0.25
    assert measured() == ["Relevance"]
  end

  test "write_cache: false never reads the cache and deletes it", %{tmp_dir: dir} do
    evaluate(dir)
    assert File.exists?(Path.join(dir, Cache.cache_file()))

    assert [%Result{evaluation_cost: 0.25}] = evaluate(dir, use_cache: true, write_cache: false)
    refute File.exists?(Path.join(dir, Cache.cache_file()))
  end

  test "never caches a conversational test case", %{tmp_dir: dir} do
    conversation =
      ConversationalTestCase.new!(turns: [%{role: :user, content: "Hi"}])

    stub = %ConversationalStub{
      name: "Turns",
      score: 1.0,
      reason: "R",
      threshold: 0.5,
      evaluation_model: "m",
      evaluation_cost: 0.1,
      input_tokens: 1,
      output_tokens: 1
    }

    DeepEvalEx.evaluate_run([conversation], [stub], cache_folder: dir)

    assert File.read!(Path.join(dir, Cache.cache_file())) == ~s({"test_cases_lookup_map": {}})
  end

  test "Evaluator.run/3 caches nothing without a store", %{tmp_dir: dir} do
    File.cd!(dir, fn -> Evaluator.run([@test_case], [@stub], use_cache: true) end)
    assert File.ls!(dir) == []
  end

  test "a System One result never serves the same metric judged by the LLM" do
    jev = Mock.new(answer_fn: Mock.noul_answers(0.8), model: "fake-jev")

    system_one =
      Evaluator.metric_configuration(Faithfulness, eval_mode: :system_one, system_one_model: jev)

    llm = Evaluator.metric_configuration(Faithfulness, eval_mode: :llm, adapter: :mock)

    assert system_one.evaluation_model == "fake-jev"
    refute Cache.same_metric_config?(llm, system_one)
  end
end
