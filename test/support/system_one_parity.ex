defmodule DeepEvalEx.Test.SystemOneParity do
  @moduledoc """
  Runs the System One scenarios of `test/fixtures/deepeval/system_one/`
  through the real DeepEvalEx metrics and compares the outcome with what
  deepeval 4.3.1 did for the same scenario (see the fixtures' README).

  A scenario's `input.json` holds one metric (`kind`, `eval_mode` and
  constructor `params`), one `test_case`, the fake System One model
  (`system_one`: canned answers or the error it raises) and, when an LLM is
  involved, the scripted judge's `responses`. Here
  `DeepEvalEx.SystemOne.Adapters.Mock.from_fixture/2` stands in for the
  fake and `DeepEvalEx.LLM.Adapters.Mock.script/2` for the judge, so each
  side is asked exactly what deepeval asked, and answers the same.
  """

  import ExUnit.Assertions

  alias DeepEvalEx.{Evaluator, MetricError, TestCase}
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock

  alias DeepEvalEx.Metrics.{
    AnswerRelevancy,
    ContextualPrecision,
    ContextualRecall,
    Faithfulness,
    Hallucination
  }

  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.Test.{JSONDiff, ScriptedParity}
  alias DeepEvalEx.TestRun.JSON

  @fixtures Path.expand("../fixtures/deepeval/system_one", __DIR__)

  @modules %{
    "faithfulness" => Faithfulness,
    "answer_relevancy" => AnswerRelevancy,
    "contextual_precision" => ContextualPrecision,
    "contextual_recall" => ContextualRecall,
    "hallucination" => Hallucination
  }

  @eval_modes %{"llm" => :llm, "hybrid" => :hybrid, "system_one" => :system_one}

  @doc "The path of a scenario's fixture file, e.g. `\"measure.json\"`."
  @spec fixture(String.t(), String.t()) :: Path.t()
  def fixture(scenario, file), do: Path.join([@fixtures, scenario, file])

  @doc """
  Measures the scenario's test case with its metric, as deepeval's
  `measure()` did, with `ignore_errors: false`.

  Returns `{measured, calls, prompts}`: the result as `measure.json`'s
  fields (`raised` holding the error `measure()` raised, if any), the
  System One calls as `decide.json` records them and the judge's prompts.
  """
  @spec measure(String.t()) :: {map(), [map()], [map()]}
  def measure(scenario) do
    input = load(scenario, "input.json")
    {module, opts, mock} = metric(input)

    measured =
      try do
        input
        |> test_case()
        |> Evaluator.evaluate_metric(module, [ignore_errors: false] ++ opts)
        |> measured(nil)
      rescue
        error in [MetricError] -> measured(error.result, nil)
        error -> measured(nil, error)
      end

    {measured, Mock.dump_calls(mock), LLMMock.scripted_prompts()}
  end

  @doc """
  Evaluates the scenario with `DeepEvalEx.evaluate_run/3`, as deepeval's
  `evaluate()` did with `ignore_errors=True`, writing the test run to
  `results_folder`. Returns `{test_run, calls}`: the file's contents and the
  System One calls of the run.
  """
  @spec test_run(String.t(), Path.t()) :: {binary(), [map()]}
  def test_run(scenario, results_folder) do
    input = load(scenario, "input.json")
    {module, opts, mock} = metric(input)

    {_results, _test_run, path} =
      DeepEvalEx.evaluate_run(
        [test_case(input)],
        [module],
        [results_folder: results_folder, ignore_errors: true] ++ opts
      )

    assert is_binary(path), "DeepEvalEx wrote no test run file"
    {File.read!(path), Mock.dump_calls(mock)}
  end

  @doc """
  Asserts that `measured` (see `measure/1`) is the scenario's
  `measure.json`, every field, integer vs float included.
  """
  @spec assert_measured(map(), String.t()) :: :ok
  def assert_measured(measured, scenario) do
    [expected] = scenario |> fixture("measure.json") |> File.read!() |> Jason.decode!()
    assert JSONDiff.diff(roundtrip(measured), expected) == []
    :ok
  end

  @doc """
  Asserts that `calls` are the scenario's recorded `decide()` calls:
  `decide.json`'s `"measure"` calls, or its `"evaluate"` calls with
  `:evaluate`, byte for byte.
  """
  @spec assert_calls([map()], String.t(), :measure | :evaluate) :: :ok
  def assert_calls(calls, scenario, run \\ :measure) do
    decide = load(scenario, "decide.json")

    expected =
      case run do
        :measure -> hd(decide["measure"])
        :evaluate -> decide["evaluate"]
      end

    assert encode(calls) == encode(expected)
    :ok
  end

  @doc """
  Asserts that `prompts` are the prompts the scenario's judge received
  (`prompts.json`), as `DeepEvalEx.Test.ScriptedParity.assert_prompts/2`
  compares them. A scenario without a judge must send none.
  """
  @spec assert_prompts([map()], String.t()) :: :ok
  def assert_prompts(prompts, scenario) do
    path = fixture(scenario, "prompts.json")

    if File.regular?(path) do
      [expected] = path |> File.read!() |> Jason.decode!()
      ScriptedParity.assert_prompts(prompts, expected)
    else
      assert prompts == []
      :ok
    end
  end

  @doc """
  Asserts that `test_run` is the scenario's `test_run.json`, byte for byte
  but for the run-level `runDuration`.
  """
  @spec assert_test_run(binary(), String.t()) :: :ok
  def assert_test_run(test_run, scenario) do
    theirs = scenario |> fixture("test_run.json") |> File.read!() |> normalise()
    ours = normalise(test_run)

    assert JSONDiff.diff(decode(ours), decode(theirs)) == []
    assert ours == theirs
    :ok
  end

  # The metric module, its options (deepeval's constructor params, the eval
  # mode, the fake System One model and the scripted judge) and the fake.
  defp metric(input) do
    [%{"kind" => kind, "eval_mode" => eval_mode, "params" => params}] =
      Enum.map(input["metrics"], &Map.new(&1.values))

    module = Map.fetch!(@modules, kind)
    Code.ensure_loaded!(module)
    mock = Mock.from_fixture(input["system_one"])

    # A scenario without responses had deepeval's exploding LLM: no call.
    responses = (input["responses"] || %{}) |> plain() |> Map.get(kind, %{})
    LLMMock.script(responses, model: input["judge_model"] || "exploding-llm")

    opts =
      [
        adapter: :mock,
        eval_mode: Map.fetch!(@eval_modes, eval_mode),
        system_one_model: mock
      ] ++ Enum.map(params.values, fn {key, value} -> {String.to_existing_atom(key), value} end)

    {module, opts, mock}
  end

  defp measured(result, raised) do
    result = result || %{}

    result = if is_struct(result), do: Map.from_struct(result), else: result

    %{
      "score" => result[:score],
      "success" => result[:success],
      "reason" => result[:reason],
      "threshold" => result[:threshold],
      "error" => result[:error],
      "evaluation_model" => result[:evaluation_model],
      "evaluation_cost" => result[:evaluation_cost],
      "input_tokens" => result[:input_tokens],
      "output_tokens" => result[:output_tokens],
      "verbose_logs" => result[:verbose_logs],
      "confidence" => result[:confidence],
      "system_one_fallback_reason" => result[:system_one_fallback_reason],
      "score_breakdown" => result[:score_breakdown],
      "raised" => raised && %{"type" => type(raised), "message" => Exception.message(raised)}
    }
  end

  defp type(%DeepEvalEx.SystemOne.Error{type: type}) when is_binary(type), do: type
  defp type(%module{}), do: module |> Module.split() |> List.last()

  defp test_case(input), do: input["test_case"] |> plain() |> TestCase.new!()

  # Encoded as deepeval's json.dumps and decoded again, so Python floats
  # (2.0) and ordered dumps compare with the fixture's decoded JSON.
  defp roundtrip(term), do: term |> JSON.encode!() |> Jason.decode!()

  defp encode(term), do: JSON.encode!(term, indent: 2, ensure_ascii: false)

  defp load(scenario, file),
    do: scenario |> fixture(file) |> File.read!() |> decode()

  defp decode(json), do: Jason.decode!(json, objects: :ordered_objects)

  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {key, value} -> {key, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(term), do: term

  # The run-level runDuration is the only key following testFailed.
  defp normalise(json) do
    String.replace(json, ~r/("testFailed": \d+, "runDuration": )[^,}]+/, "\\1\"<normalised>\"")
  end
end
