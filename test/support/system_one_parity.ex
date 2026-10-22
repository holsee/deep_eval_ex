defmodule DeepEvalEx.Test.SystemOneParity do
  @moduledoc """
  Runs the System One scenarios of `test/fixtures/deepeval/system_one/`
  through the real DeepEvalEx metrics and compares the outcome with what
  deepeval 4.3.1 did for the same scenario (see the fixtures' README).

  A scenario's `input.json` holds its metrics (`kind`, `eval_mode` and
  constructor `params`; a `jev_eval` has no `eval_mode` and is built as a
  `DeepEvalEx.Metrics.JevEval` struct): one, or several for a `batched`
  scenario, whose `evaluate()` asked one batched request (see
  `DeepEvalEx.SystemOne.Batch`). It also holds one `test_case`, the fake System One model
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
    ArgumentCorrectness,
    Bias,
    ContextualPrecision,
    ContextualRecall,
    ContextualRelevancy,
    Faithfulness,
    Hallucination,
    JevEval,
    JsonCorrectness,
    PIILeakage,
    PromptAlignment,
    Summarization,
    ToolCorrectness,
    Toxicity
  }

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.SystemOne.Adapters.Mock
  alias DeepEvalEx.SystemOne.Scored
  alias DeepEvalEx.Test.{JSONDiff, ScriptedParity}
  alias DeepEvalEx.TestRun.JSON

  @fixtures Path.expand("../fixtures/deepeval/system_one", __DIR__)

  @modules %{
    "faithfulness" => Faithfulness,
    "answer_relevancy" => AnswerRelevancy,
    "contextual_precision" => ContextualPrecision,
    "contextual_recall" => ContextualRecall,
    "contextual_relevancy" => ContextualRelevancy,
    "hallucination" => Hallucination,
    "bias" => Bias,
    "toxicity" => Toxicity,
    "pii_leakage" => PIILeakage,
    "prompt_alignment" => PromptAlignment,
    "summarization" => Summarization,
    "argument_correctness" => ArgumentCorrectness,
    "tool_correctness" => ToolCorrectness,
    "json_correctness" => JsonCorrectness
  }

  @eval_modes %{"llm" => :llm, "hybrid" => :hybrid, "system_one" => :system_one}

  @doc "The path of a scenario's fixture file, e.g. `\"measure.json\"`."
  @spec fixture(String.t(), String.t()) :: Path.t()
  def fixture(scenario, file), do: Path.join([@fixtures, scenario, file])

  @doc """
  The number of metrics the scenario measures.
  """
  @spec metric_count(String.t()) :: pos_integer()
  def metric_count(scenario), do: length(load(scenario, "input.json")["metrics"])

  @doc """
  Measures the scenario's test case with its metric number `index`, alone,
  as deepeval's `measure()` did, with `ignore_errors: false`. A batched
  scenario's fake answers metric `index` from the batch's answers for its
  `m<index>.` keys.

  Returns `{measured, calls, prompts}`: the result as `measure.json`'s
  fields (`raised` holding the error `measure()` raised, if any), the
  System One calls as `decide.json` records them and the judge's prompts.
  """
  @spec measure(String.t(), non_neg_integer()) :: {map(), [map()], [map()]}
  def measure(scenario, index \\ 0) do
    input = load(scenario, "input.json")
    prefix = if input["batched"], do: "m#{index}.", else: ""
    mock = Mock.from_fixture(input["system_one"], prefix: prefix)
    {metric, opts} = input |> metrics(mock) |> Enum.at(index)

    measured =
      try do
        input
        |> test_case()
        |> Evaluator.evaluate_metric(metric, [ignore_errors: false] ++ opts)
        |> measured(nil)
      rescue
        error in [MetricError] -> measured(error.result, nil)
        error -> measured(raised_state(input, index), error)
      end

    {measured, Mock.dump_calls(mock), LLMMock.scripted_prompts()}
  end

  # The metric as deepeval's measure() left it when it raised: its
  # threshold, models and seeded cost, but neither success nor error (only
  # ignore_errors sets those). DeepEvalEx raises without a result, so the
  # metric is measured again, against a fresh fake, with ignore_errors: true.
  # deepeval seeds the cost with the int 0, DeepEvalEx with 0.0; both export
  # as 0.0.
  defp raised_state(input, index) do
    prefix = if input["batched"], do: "m#{index}.", else: ""
    mock = Mock.from_fixture(input["system_one"], prefix: prefix)
    {metric, opts} = input |> metrics(mock) |> Enum.at(index)

    result =
      input
      |> test_case()
      |> Evaluator.evaluate_metric(metric, [ignore_errors: true] ++ opts)

    cost = if result.evaluation_cost === 0.0, do: 0, else: result.evaluation_cost
    %{result | success: nil, error: nil, evaluation_cost: cost}
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
    mock = Mock.from_fixture(input["system_one"])
    {metrics, opts} = input |> metrics(mock) |> Enum.unzip()
    # The run's options: a batched scenario's metrics share theirs.
    [opts] = Enum.uniq(opts)

    {_results, _test_run, path} =
      DeepEvalEx.evaluate_run(
        [test_case(input)],
        metrics,
        [results_folder: results_folder, ignore_errors: true] ++ opts
      )

    assert is_binary(path), "DeepEvalEx wrote no test run file"
    {File.read!(path), Mock.dump_calls(mock)}
  end

  @doc """
  Asserts that `measured` (see `measure/2`) is the scenario's
  `measure.json` entry for metric `index`, every field, integer vs float
  included.
  """
  @spec assert_measured(map(), String.t(), non_neg_integer()) :: :ok
  def assert_measured(measured, scenario, index \\ 0) do
    expected = scenario |> fixture("measure.json") |> File.read!() |> Jason.decode!()
    assert JSONDiff.diff(roundtrip(measured), Enum.at(expected, index)) == []
    :ok
  end

  @doc """
  Asserts that `calls` are the scenario's recorded `decide()` calls:
  `decide.json`'s `"measure"` calls of metric `index`, or its `"evaluate"`
  calls with `:evaluate`, byte for byte.
  """
  @spec assert_calls([map()], String.t(), :measure | :evaluate, non_neg_integer()) :: :ok
  def assert_calls(calls, scenario, run \\ :measure, index \\ 0) do
    decide = load(scenario, "decide.json")

    expected =
      case run do
        :measure -> Enum.at(decide["measure"], index)
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

  # Each metric (a module, or a JevEval struct) with its options (deepeval's
  # constructor params, the eval mode, the fake System One model and the
  # scripted judge).
  defp metrics(input, mock) do
    specs = Enum.map(input["metrics"], &Map.new(&1.values))

    # A scenario without responses had deepeval's exploding LLM: no call.
    # Only single-metric scenarios script a judge.
    responses = (input["responses"] || %{}) |> plain()
    [%{"kind" => first} | _] = specs
    LLMMock.script(Map.get(responses, first, %{}), model: input["judge_model"] || "exploding-llm")

    Enum.map(specs, fn
      %{"kind" => "jev_eval", "params" => params} ->
        {jev_eval(params, mock), [adapter: :mock]}

      %{"kind" => kind, "params" => params} = spec ->
        metric(kind, spec["eval_mode"], params, mock)
    end)
  end

  defp metric(kind, eval_mode, params, mock) do
    module = Map.fetch!(@modules, kind)
    Code.ensure_loaded!(module)

    opts =
      [
        adapter: :mock,
        eval_mode: Map.fetch!(@eval_modes, eval_mode),
        system_one_model: mock
      ] ++
        Enum.map(params.values, fn
          # JsonCorrectness prints its schema in its key order.
          {"expected_schema", schema} -> {:expected_schema, schema}
          {key, value} -> option(key, plain(value))
        end)

    configured(module, opts)
  end

  # PromptAlignment's instructions are its own, as deepeval's constructor
  # param: a struct, so a batched scenario's metrics share the other options.
  defp configured(PromptAlignment, opts) do
    {instructions, opts} = Keyword.pop!(opts, :prompt_instructions)
    {PromptAlignment.new(prompt_instructions: instructions), opts}
  end

  # JsonCorrectness's schema is its own, as deepeval's constructor param.
  defp configured(JsonCorrectness, opts) do
    {schema, opts} = Keyword.pop!(opts, :expected_schema)
    {JsonCorrectness.new(expected_schema: schema), opts}
  end

  defp configured(module, opts), do: {module, opts}

  # deepeval's JevEval(**params): the questions as Scored structs, the
  # evaluation params as atoms.
  defp jev_eval(params, mock) do
    # Its evaluation params are the test case's field names.
    Code.ensure_loaded!(TestCase)

    params.values
    |> Enum.map(fn
      {"questions", questions} ->
        {:questions, questions |> JSON.encode!() |> Scored.parse!()}

      {"evaluation_params", names} ->
        {:evaluation_params, Enum.map(names, &String.to_existing_atom/1)}

      {"_include_jev_eval_suffix", suffix?} ->
        {:include_jev_eval_suffix, suffix?}

      {key, value} ->
        option(key, plain(value))
    end)
    |> Keyword.put(:system_one_model, mock)
    |> JevEval.new()
  end

  # deepeval's fixture generator builds ToolCalls from available_tools.
  defp option("available_tools", tools),
    do: {:available_tools, Enum.map(tools, &(&1 |> ToolCall.new() |> elem(1)))}

  defp option(key, value), do: {String.to_existing_atom(key), value}

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
      "evaluation_cost" => seeded_cost(result),
      "input_tokens" => result[:input_tokens],
      "output_tokens" => result[:output_tokens],
      "verbose_logs" => result[:verbose_logs],
      "confidence" => result[:confidence],
      "system_one_fallback_reason" => result[:system_one_fallback_reason],
      "score_breakdown" => result[:score_breakdown],
      "raised" => raised && %{"type" => type(raised), "message" => Exception.message(raised)}
    }
  end

  # Likewise for a metric with neither an LLM nor a System One model
  # (JsonCorrectness under system_one): nothing adds to its seed.
  defp seeded_cost(%{evaluation_cost: cost, evaluation_model: nil}) when cost === 0.0, do: 0

  defp seeded_cost(result), do: result[:evaluation_cost]

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
