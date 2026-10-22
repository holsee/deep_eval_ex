defmodule DeepEvalEx.TestRun do
  @moduledoc """
  A completed evaluation run in deepeval's `TestRun` export format.

  deepeval saves every `evaluate()` call as a `test_run_<timestamp>.json`
  file (see `DeepEvalEx.TestRun.LocalStore`). This module builds the same
  structure from DeepEvalEx results, so tools that read deepeval's exports
  can read DeepEvalEx's too.

      results = DeepEvalEx.evaluate_batch(test_cases, metrics)
      test_run = DeepEvalEx.TestRun.from_results(test_cases, results)

      test_run
      |> DeepEvalEx.TestRun.to_map()
      |> DeepEvalEx.TestRun.JSON.encode!()

  `DeepEvalEx.evaluate_run/3` does all of this, including the timing, and
  writes the file when a results folder is configured.

  ## Fields

  Fields mirror deepeval's `TestRun` (snake_case here, camelCase in the
  export):

  - `:test_cases` - One `DeepEvalEx.TestRun.TestCase` per evaluated test case
  - `:metrics_scores` - Per metric: every score, plus pass, fail and error
    counts, in the order metrics first appear
  - `:identifier` - Optional name for the run
  - `:hyperparameters` - `{name, value}` pairs with values stringified as
    deepeval does (see `process_hyperparameters/1`), or `nil`
  - `:test_passed` / `:test_failed` - Number of passing and failing test cases
  - `:run_duration` - Wall-clock time of the whole run, in seconds
  - `:evaluation_cost` - Sum of the test cases' costs; `nil` when no metric
    reported a cost

  deepeval's conversational test cases and prompts are always empty, and
  `official` is always `false`.
  """

  alias DeepEvalEx.{Result, TestRun}
  alias DeepEvalEx.TestCase, as: EvalTestCase
  alias DeepEvalEx.TestRun.JSON
  alias Jason.OrderedObject

  @type metric_scores :: %{
          metric: String.t(),
          scores: [float()],
          passes: non_neg_integer(),
          fails: non_neg_integer(),
          errors: non_neg_integer()
        }

  @type t :: %__MODULE__{
          test_cases: [TestRun.TestCase.t()],
          metrics_scores: [metric_scores()],
          identifier: String.t() | nil,
          hyperparameters: [{String.t(), String.t()}] | nil,
          test_passed: non_neg_integer(),
          test_failed: non_neg_integer(),
          run_duration: float(),
          evaluation_cost: float() | nil
        }

  defstruct test_cases: [],
            metrics_scores: [],
            identifier: nil,
            hyperparameters: nil,
            test_passed: 0,
            test_failed: 0,
            run_duration: 0.0,
            evaluation_cost: nil

  defmodule MetricData do
    @moduledoc """
    One metric's result on one test case, as deepeval's `MetricData`.

    Built from a `DeepEvalEx.Result` by `from_result/2`. An errored result
    keeps its threshold, error and cost but has no score or reason, as in
    deepeval. DeepEvalEx metrics are never flaky, so `:flaky` is always
    `false`.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            threshold: float() | nil,
            success: boolean(),
            score: float() | nil,
            reason: String.t() | nil,
            strict_mode: boolean(),
            flaky: boolean(),
            evaluation_model: String.t() | nil,
            error: String.t() | nil,
            evaluation_cost: float() | nil,
            input_tokens: non_neg_integer() | nil,
            output_tokens: non_neg_integer() | nil
          }

    defstruct [
      :name,
      :threshold,
      :success,
      :score,
      :reason,
      :evaluation_model,
      :error,
      :evaluation_cost,
      :input_tokens,
      :output_tokens,
      strict_mode: false,
      flaky: false
    ]

    @doc """
    Converts a result into metric data.

    ## Options

    - `:strict_mode` - Whether the metric ran in strict mode (default: `false`)
    """
    @spec from_result(Result.t(), keyword()) :: t()
    def from_result(%Result{} = result, opts \\ []) do
      errored? = Result.errored?(result)

      %__MODULE__{
        name: result.metric,
        threshold: result.threshold,
        success: result.success,
        score: if(errored?, do: nil, else: result.score),
        reason: if(errored?, do: nil, else: result.reason),
        strict_mode: Keyword.get(opts, :strict_mode, false),
        evaluation_model: result.evaluation_model,
        error: result.error,
        evaluation_cost: result.evaluation_cost,
        input_tokens: result.input_tokens,
        output_tokens: result.output_tokens
      }
    end
  end

  defmodule TestCase do
    @moduledoc """
    One evaluated test case, as deepeval's `LLMApiTestCase`.

    Carries the test case's fields, the metric data of each of its results,
    whether every metric passed (`:success`), its summed `:evaluation_cost`
    (`nil` when no metric reported one) and its `:run_duration` in seconds.
    `:name` defaults to `"test_case_<order>"` as in deepeval.
    """

    alias DeepEvalEx.Schemas.ToolCall

    @type t :: %__MODULE__{
            name: String.t(),
            input: String.t() | nil,
            actual_output: String.t() | nil,
            expected_output: String.t() | nil,
            context: [String.t()] | nil,
            retrieval_context: [String.t()] | nil,
            tools_called: [ToolCall.t()] | nil,
            expected_tools: [ToolCall.t()] | nil,
            token_cost: float() | nil,
            input_token_count: non_neg_integer() | nil,
            output_token_count: non_neg_integer() | nil,
            completion_time: float() | nil,
            tags: [String.t()] | nil,
            flaky: boolean(),
            success: boolean(),
            metrics_data: [MetricData.t()],
            run_duration: float(),
            evaluation_cost: float() | nil,
            order: non_neg_integer(),
            metadata: map() | nil,
            comments: String.t() | nil
          }

    defstruct [
      :name,
      :input,
      :actual_output,
      :expected_output,
      :context,
      :retrieval_context,
      :tools_called,
      :expected_tools,
      :token_cost,
      :input_token_count,
      :output_token_count,
      :completion_time,
      :tags,
      :evaluation_cost,
      :order,
      :metadata,
      :comments,
      flaky: false,
      success: true,
      metrics_data: [],
      run_duration: 0.0
    ]
  end

  @doc """
  Builds a test run from test cases and their results.

  `results` holds one result list per test case, as returned by
  `DeepEvalEx.evaluate_batch/3`. Test cases without results are left out,
  as deepeval leaves out test cases no metric ran on; the others keep their
  position in `test_cases` as their `order`.

  ## Options

  - `:metrics` - The metrics that produced each result list, used to record
    each metric's strict mode
  - `:strict_mode` - Strict mode of metrics that do not set their own
    (default: `false`)
  - `:run_durations` - Seconds each test case took, in `test_cases` order.
    As in deepeval, a test case that took under one second is recorded as
    `0.0` (default: all `0.0`)
  - `:run_duration` - Seconds the whole run took (default: `0.0`)
  - `:identifier` - Name for the run
  - `:hyperparameters` - Keyword list or map of hyperparameters, see
    `process_hyperparameters/1`
  """
  @spec from_results([EvalTestCase.t()], [[Result.t()]], keyword()) :: t()
  def from_results(test_cases, results, opts \\ []) do
    strict_modes = strict_modes(opts)

    durations =
      Keyword.get_lazy(opts, :run_durations, fn -> Enum.map(test_cases, fn _ -> 0.0 end) end)

    api_test_cases =
      [test_cases, results, durations]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.reject(fn {{_test_case, case_results, _duration}, _order} -> case_results == [] end)
      |> Enum.map(fn {{test_case, case_results, duration}, order} ->
        api_test_case(test_case, case_results, duration, order, strict_modes)
      end)

    %__MODULE__{
      test_cases: api_test_cases,
      metrics_scores: metrics_scores(api_test_cases),
      identifier: Keyword.get(opts, :identifier),
      hyperparameters: process_hyperparameters(Keyword.get(opts, :hyperparameters)),
      test_passed: Enum.count(api_test_cases, & &1.success),
      test_failed: Enum.count(api_test_cases, &(not &1.success)),
      run_duration: to_float(Keyword.get(opts, :run_duration, 0.0)),
      evaluation_cost: sum_costs(api_test_cases)
    }
  end

  @doc """
  Normalises hyperparameters as deepeval's `process_hyperparameters` does.

  Takes a keyword list or a map with atom or string keys and returns
  `{name, value}` pairs, keeping the order of a keyword list. `nil` values
  are dropped and the rest are stringified like Python's `str()`: strings
  and atoms as they are, integers in decimal, floats as in
  `DeepEvalEx.TestRun.JSON.float_repr/1` and booleans as `"True"` or
  `"False"`. Returns `nil` for `nil`.

  Raises `ArgumentError` for any other value, as deepeval raises a
  `TypeError`.

  ## Examples

      iex> DeepEvalEx.TestRun.process_hyperparameters(model: "gpt-4o", temperature: 0.7, k: 5)
      [{"model", "gpt-4o"}, {"temperature", "0.7"}, {"k", "5"}]
  """
  @spec process_hyperparameters(keyword() | map() | nil) :: [{String.t(), String.t()}] | nil
  def process_hyperparameters(nil), do: nil

  def process_hyperparameters(hyperparameters)
      when is_list(hyperparameters) or is_map(hyperparameters) do
    for {key, value} <- hyperparameters, not is_nil(value) do
      {hyperparameter_key(key), hyperparameter_value(key, value)}
    end
  end

  defp hyperparameter_key(key) when is_binary(key), do: key
  defp hyperparameter_key(key) when is_atom(key), do: Atom.to_string(key)

  defp hyperparameter_key(key) do
    raise ArgumentError, "hyperparameter key #{inspect(key)} must be a string or an atom"
  end

  defp hyperparameter_value(_key, value) when is_binary(value), do: value
  defp hyperparameter_value(_key, true), do: "True"
  defp hyperparameter_value(_key, false), do: "False"
  defp hyperparameter_value(_key, value) when is_atom(value), do: Atom.to_string(value)
  defp hyperparameter_value(_key, value) when is_integer(value), do: Integer.to_string(value)
  defp hyperparameter_value(_key, value) when is_float(value), do: JSON.float_repr(value)

  defp hyperparameter_value(key, value) do
    raise ArgumentError,
          "hyperparameter #{inspect(to_string(key))} must be a string, number, boolean " <>
            "or atom, got: #{inspect(value)}"
  end

  @doc """
  Converts a test run into deepeval's export structure.

  Returns nested `Jason.OrderedObject`s with deepeval's camelCase keys in
  the declaration order of deepeval's pydantic models, leaving out `nil`
  values as `model_dump(by_alias=True, exclude_none=True)` does (`false`,
  `0` and empty lists are kept). Encode it with
  `DeepEvalEx.TestRun.JSON.encode!/1` for deepeval's exact bytes, or with
  `Jason` for ordinary JSON.

  Empty `tools_called`, `expected_tools` and `retrieval_context` lists are
  left out, as deepeval does for test cases that do not set them.
  """
  @spec to_map(t()) :: OrderedObject.t()
  def to_map(%__MODULE__{} = test_run) do
    ordered(
      testCases: Enum.map(test_run.test_cases, &test_case_map/1),
      conversationalTestCases: [],
      metricsScores: Enum.map(test_run.metrics_scores, &metric_scores_map/1),
      identifier: test_run.identifier,
      hyperparameters: test_run.hyperparameters && OrderedObject.new(test_run.hyperparameters),
      prompts: [],
      testPassed: test_run.test_passed,
      testFailed: test_run.test_failed,
      runDuration: to_float(test_run.run_duration),
      evaluationCost: to_float(test_run.evaluation_cost),
      official: false
    )
  end

  defp api_test_case(test_case, results, duration, order, strict_modes) do
    metrics_data =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, index} ->
        MetricData.from_result(result, strict_mode: strict_modes.(index))
      end)

    %TestCase{
      name: test_case.name || "test_case_#{order}",
      input: test_case.input,
      actual_output: test_case.actual_output,
      expected_output: test_case.expected_output,
      context: test_case.context,
      retrieval_context: non_empty(test_case.retrieval_context),
      tools_called: non_empty(test_case.tools_called),
      expected_tools: non_empty(test_case.expected_tools),
      token_cost: test_case.token_cost,
      input_token_count: test_case.input_token_count,
      output_token_count: test_case.output_token_count,
      completion_time: test_case.completion_time,
      tags: test_case.tags,
      flaky: test_case.flaky || false,
      success: Enum.all?(metrics_data, &(&1.flaky or &1.success)),
      metrics_data: metrics_data,
      run_duration: case_duration(duration),
      evaluation_cost: sum_costs(metrics_data),
      order: order,
      metadata: test_case.metadata,
      comments: test_case.comments
    }
  end

  # deepeval's async executor records a test case that finished in under a
  # second as 0 ("all metrics were from cache").
  defp case_duration(duration) when is_number(duration) and duration >= 1, do: duration / 1
  defp case_duration(_duration), do: 0.0

  defp strict_modes(opts) do
    default = Keyword.get(opts, :strict_mode, false)

    modes =
      opts
      |> Keyword.get(:metrics, [])
      |> Enum.map(fn
        %{strict_mode: mode} when is_boolean(mode) -> mode
        _metric -> default
      end)
      |> List.to_tuple()

    fn index -> if index < tuple_size(modes), do: elem(modes, index), else: default end
  end

  defp metrics_scores(test_cases) do
    {order, scores} =
      for %TestCase{metrics_data: metrics_data} <- test_cases,
          data <- metrics_data,
          reduce: {[], %{}} do
        {order, scores} ->
          order = if Map.has_key?(scores, data.name), do: order, else: [data.name | order]

          entry =
            Map.get(scores, data.name, %{
              metric: data.name,
              scores: [],
              passes: 0,
              fails: 0,
              errors: 0
            })

          {order, Map.put(scores, data.name, add_score(entry, data))}
      end

    order
    |> Enum.reverse()
    |> Enum.map(fn name -> Map.update!(scores[name], :scores, &Enum.reverse/1) end)
  end

  defp add_score(entry, %MetricData{score: nil}), do: Map.update!(entry, :errors, &(&1 + 1))

  defp add_score(entry, %MetricData{score: score, success: success}) do
    entry = Map.update!(entry, :scores, &[to_float(score) | &1])

    if success,
      do: Map.update!(entry, :passes, &(&1 + 1)),
      else: Map.update!(entry, :fails, &(&1 + 1))
  end

  # Summed in order, skipping unknown costs; nil when there are none.
  defp sum_costs(items) do
    Enum.reduce(items, nil, fn
      %{evaluation_cost: nil}, total -> total
      %{evaluation_cost: cost}, nil -> cost
      %{evaluation_cost: cost}, total -> total + cost
    end)
  end

  defp test_case_map(%TestCase{} = test_case) do
    ordered(
      name: test_case.name,
      input: test_case.input,
      actualOutput: test_case.actual_output,
      expectedOutput: test_case.expected_output,
      context: test_case.context,
      retrievalContext: test_case.retrieval_context,
      toolsCalled: tool_calls_map(test_case.tools_called),
      expectedTools: tool_calls_map(test_case.expected_tools),
      tokenCost: to_float(test_case.token_cost),
      inputTokenCount: test_case.input_token_count,
      outputTokenCount: test_case.output_token_count,
      completionTime: to_float(test_case.completion_time),
      tags: test_case.tags,
      flaky: test_case.flaky,
      success: test_case.success,
      metricsData: Enum.map(test_case.metrics_data, &metric_data_map/1),
      runDuration: to_float(test_case.run_duration),
      evaluationCost: to_float(test_case.evaluation_cost),
      order: test_case.order,
      metadata: test_case.metadata,
      comments: test_case.comments
    )
  end

  defp metric_data_map(%MetricData{} = data) do
    ordered(
      name: data.name,
      threshold: to_float(data.threshold),
      success: data.success,
      score: to_float(data.score),
      reason: data.reason,
      strictMode: data.strict_mode,
      flaky: data.flaky,
      evaluationModel: data.evaluation_model,
      error: data.error,
      evaluationCost: to_float(data.evaluation_cost),
      inputTokenCount: data.input_tokens,
      outputTokenCount: data.output_tokens
    )
  end

  defp metric_scores_map(scores) do
    ordered(
      metric: scores.metric,
      scores: scores.scores,
      passes: scores.passes,
      fails: scores.fails,
      errors: scores.errors
    )
  end

  defp tool_calls_map(nil), do: nil

  defp tool_calls_map(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      ordered(
        name: tool_call.name,
        type: tool_call.type |> to_string() |> String.upcase(),
        description: tool_call.description,
        reasoning: tool_call.reasoning,
        output: tool_call.output,
        inputParameters: tool_call.input_parameters
      )
    end)
  end

  # An ordered object of the non-nil pairs, with string keys.
  defp ordered(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> OrderedObject.new()
  end

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp to_float(nil), do: nil
  defp to_float(number), do: number / 1
end
