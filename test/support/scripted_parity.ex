defmodule DeepEvalEx.Test.ScriptedParity do
  @moduledoc """
  Runs the scripted-judge scenarios of `test/fixtures/deepeval/scripted/`
  through DeepEvalEx and compares the outcome with what deepeval 4.3.1 did
  for the same script.

  Each scenario's `script.json` holds one metric (`kind` and constructor
  `params`), one `test_case` and the judge's `responses`, keyed by metric
  kind, step and call index. `scripts/parity/generate_fixtures.py` ran it
  through deepeval with a scripted judge and recorded `prompts.json`,
  `measure.json` and `test_run.json` next to it; here
  `DeepEvalEx.LLM.Adapters.Mock` replays the same responses (see
  `DeepEvalEx.LLM.Adapters.Mock.script/2`) and `assert_matches_fixture/2`
  compares the results with those files.
  """

  import ExUnit.Assertions

  alias DeepEvalEx.{Evaluator, MetricError}
  alias DeepEvalEx.LLM.Adapters.Mock

  alias DeepEvalEx.Metrics.{
    AnswerRelevancy,
    ContextualPrecision,
    ContextualRecall,
    ExactMatch,
    Faithfulness,
    GEval,
    Hallucination,
    ToolCorrectness
  }

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Test.JSONDiff
  alias DeepEvalEx.TestCase
  alias Jason.OrderedObject

  @fixtures Path.expand("../fixtures/deepeval/scripted", __DIR__)

  @modules %{
    "exact_match" => ExactMatch,
    "faithfulness" => Faithfulness,
    "hallucination" => Hallucination,
    "answer_relevancy" => AnswerRelevancy,
    "contextual_precision" => ContextualPrecision,
    "contextual_recall" => ContextualRecall,
    "tool_correctness" => ToolCorrectness
  }

  # Pairs of steps that need not keep deepeval's relative order, as neither
  # uses the other's answers.
  @independent_steps [MapSet.new(["claims", "truths"])]

  @doc "The directory holding the scripted scenarios."
  @spec fixtures_dir() :: Path.t()
  def fixtures_dir, do: @fixtures

  @doc "The names of the scripted scenarios, sorted."
  @spec scenarios() :: [String.t()]
  def scenarios do
    @fixtures
    |> File.ls!()
    |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "script.json"])))
    |> Enum.sort()
  end

  @doc "The path of a scenario's fixture file, e.g. `\"prompts.json\"`."
  @spec fixture(String.t(), String.t()) :: Path.t()
  def fixture(scenario, file), do: Path.join([@fixtures, scenario, file])

  @doc """
  Measures the scenario's test case with its metric, as deepeval's
  `measure()` did, under the scenario's script.

  Like `measure()`, a metric that errors raises (`ignore_errors: false`);
  the state it leaves is the raised `DeepEvalEx.MetricError`'s `:result`,
  whose `success` is `nil` as deepeval's metric is left with `None`.

  Returns `{measured, prompts}`: the result as `measure.json`'s fields (see
  `measured/1`) and the prompts the metric sent, as
  `DeepEvalEx.LLM.Adapters.Mock.scripted_prompts/0` lists them.
  """
  @spec measure(String.t()) :: {map(), [map()]}
  def measure(scenario) do
    script = load(scenario)
    {metric, opts} = metric(script)
    load_script(script)

    result =
      try do
        Evaluator.evaluate_metric(test_case(script), metric, [ignore_errors: false] ++ opts)
      rescue
        error in [MetricError] -> error.result
      end

    {measured(result), Mock.scripted_prompts()}
  end

  @doc """
  Evaluates the scenario with `DeepEvalEx.evaluate_run/3`, as deepeval's
  `evaluate()` did with `ignore_errors=True`, writing the test run to
  `results_folder`. Returns the file's contents.
  """
  @spec test_run(String.t(), Path.t()) :: binary()
  def test_run(scenario, results_folder) do
    script = load(scenario)
    {metric, opts} = metric(script)
    load_script(script)

    {_results, _test_run, path} =
      ExUnit.CaptureLog.with_log(fn ->
        DeepEvalEx.evaluate_run(
          [test_case(script)],
          [metric],
          [results_folder: results_folder, ignore_errors: true] ++ opts
        )
      end)
      |> elem(0)

    assert is_binary(path), "DeepEvalEx wrote no test run file"
    File.read!(path)
  end

  @doc """
  The fields of `measure.json` for a result: score, success, reason,
  threshold, error, evaluation model, cost, tokens and `verbose_logs`.
  """
  @spec measured(DeepEvalEx.Result.t()) :: map()
  def measured(result) do
    %{
      "score" => result.score,
      "success" => result.success,
      "reason" => result.reason,
      "threshold" => result.threshold,
      "error" => result.error,
      "evaluation_model" => result.evaluation_model,
      "evaluation_cost" => result.evaluation_cost,
      "input_tokens" => result.input_tokens,
      "output_tokens" => result.output_tokens,
      "verbose_logs" => result.verbose_logs
    }
  end

  @doc """
  Asserts that `actual` matches the deepeval fixture file at `path`, which
  is named after what it holds:

  - `prompts.json` - `actual` is a list of `%{step:, prompt:}`. Each step's
    prompts must equal deepeval's byte for byte, in call order. Across
    steps, where deepeval sent every prompt of one step before any of
    another, DeepEvalEx must too, except for steps that are independent of
    each other (Faithfulness's truths and claims), which DeepEvalEx may run
    concurrently.
  - `measure.json` - `actual` is a map of some of its fields (see
    `measured/1`); each must equal deepeval's, integer vs float included.
  - `test_run.json` - `actual` is the test run file DeepEvalEx wrote. It must
    have deepeval's keys, key order, value types and values, then be equal
    byte for byte. Only the run-level `runDuration` is normalised.
  """
  @spec assert_matches_fixture(term(), Path.t()) :: true
  def assert_matches_fixture(actual, path) do
    expected = File.read!(path)

    case Path.basename(path) do
      "prompts.json" -> assert_prompts(actual, Jason.decode!(expected))
      "measure.json" -> assert_measured(actual, Jason.decode!(expected))
      "test_run.json" -> assert_test_run(actual, expected)
    end

    true
  end

  @doc """
  Asserts that `actual`, a list of `%{step:, prompt:}`, are the prompts of
  `expected`, deepeval's decoded `prompts.json` entries: see
  `assert_matches_fixture/2`.
  """
  @spec assert_prompts([map()], [map()]) :: :ok
  def assert_prompts(actual, expected) do
    ours = Enum.group_by(actual, & &1.step, & &1.prompt)
    theirs = Enum.group_by(expected, & &1["step"], & &1["prompt"])

    assert Map.new(ours, fn {step, prompts} -> {step, length(prompts)} end) ==
             Map.new(theirs, fn {step, prompts} -> {step, length(prompts)} end),
           "calls per step differ from deepeval's"

    for {step, prompts} <- theirs,
        {their_prompt, index} <- Enum.with_index(prompts) do
      # Step and index in both sides, so the failure diff names the prompt.
      assert {step, index, Enum.at(ours[step], index)} == {step, index, their_prompt}
    end

    assert_step_order(Enum.map(actual, & &1.step), Enum.map(expected, & &1["step"]))
    :ok
  end

  # Every pair of steps deepeval sent one after the other must keep that
  # order, unless independent.
  defp assert_step_order(ours, theirs) do
    for first <- Enum.uniq(theirs),
        second <- Enum.uniq(theirs),
        first != second,
        MapSet.new([first, second]) not in @independent_steps,
        before?(theirs, first, second) do
      assert before?(ours, first, second),
             "every #{inspect(first)} prompt must come before any #{inspect(second)} " <>
               "prompt, as in deepeval; sent: #{inspect(ours)}"
    end
  end

  # Whether every call of step `first` comes before any call of `second`.
  defp before?(steps, first, second) do
    last_first = length(steps) - 1 - Enum.find_index(Enum.reverse(steps), &(&1 == first))
    last_first < Enum.find_index(steps, &(&1 == second))
  end

  defp assert_measured(actual, expected) do
    unknown = Map.keys(actual) -- Map.keys(expected)
    assert unknown == [], "measure.json has no #{inspect(unknown)}"

    assert JSONDiff.diff(actual, Map.take(expected, Map.keys(actual))) == []
  end

  defp assert_test_run(actual, expected) do
    ours = normalise(actual)
    theirs = normalise(expected)

    assert JSONDiff.diff(decode(ours), decode(theirs)) == []
    assert ours == theirs
  end

  # The run-level runDuration is the only key following testFailed.
  defp normalise(json) do
    String.replace(json, ~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
  end

  defp decode(json), do: Jason.decode!(json, objects: :ordered_objects)

  defp load(scenario) do
    path = fixture(scenario, "script.json")
    # The test case keeps its JSON objects' key order, as the export does.
    script = path |> File.read!() |> Jason.decode!()
    %OrderedObject{} = ordered = path |> File.read!() |> decode()
    Map.put(script, "test_case", ordered["test_case"])
  end

  defp load_script(%{"metric" => %{"kind" => kind}} = script) do
    Mock.script(Map.get(script["responses"], kind, %{}), model: script["judge_model"])
  end

  defp test_case(%{"test_case" => %OrderedObject{values: pairs}}) do
    pairs
    |> Map.new(fn
      {key, tool_calls} when key in ["tools_called", "expected_tools"] ->
        {key, Enum.map(tool_calls, &Map.new(&1.values))}

      pair ->
        pair
    end)
    |> TestCase.new!()
  end

  # The metric and the evaluation options deepeval's constructor params
  # translate to.
  defp metric(%{"metric" => %{"kind" => "g_eval", "params" => params}}) do
    opts = params |> options(GEval) |> Keyword.update(:evaluation_params, [], &atoms/1)
    {GEval.new(opts), [adapter: :mock]}
  end

  defp metric(%{"metric" => %{"kind" => kind, "params" => params}}) do
    module = Map.fetch!(@modules, kind)

    opts =
      params
      |> options(module)
      |> update_present(:evaluation_params, &atoms/1)
      |> update_present(:available_tools, &Enum.map(&1, fn tool -> tool_call(tool) end))

    {module, [adapter: :mock] ++ opts}
  end

  # Option names are atoms the metric's module defines once loaded.
  defp options(params, module) do
    Code.ensure_loaded!(module)
    Enum.map(params, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp tool_call(attrs) do
    {:ok, tool_call} = ToolCall.new(attrs)
    tool_call
  end

  defp update_present(opts, key, fun) do
    if Keyword.has_key?(opts, key), do: Keyword.update!(opts, key, fun), else: opts
  end

  # Evaluation params name test case fields, atoms TestCase defines once
  # loaded; without it a test running first in a fresh VM sees none.
  defp atoms(names) do
    Code.ensure_loaded!(TestCase)
    Enum.map(names, &String.to_existing_atom/1)
  end
end
