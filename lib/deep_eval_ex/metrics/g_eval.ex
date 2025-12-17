# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/g_eval/g_eval.py
# Original: https://github.com/confident-ai/deepeval
# Based on the G-Eval framework: https://arxiv.org/pdf/2303.16634.pdf

defmodule DeepEvalEx.Metrics.GEval do
  @moduledoc """
  G-Eval metric for flexible LLM-as-judge evaluation.

  G-Eval uses an LLM to evaluate outputs based on custom criteria,
  following the framework from https://arxiv.org/pdf/2303.16634.pdf

  ## How It Works

  1. **Define criteria** - What you want to evaluate (e.g., "accuracy", "helpfulness")
  2. **Generate evaluation steps** - LLM creates concrete steps from criteria
  3. **Score the output** - LLM evaluates the test case using the steps
  4. **Get result** - Score (0-1) with reasoning

  ## Usage

  ```elixir
  # Create a GEval metric instance
  metric = DeepEvalEx.Metrics.GEval.new(
    name: "Helpfulness",
    criteria: "Determine if the response is helpful and addresses the user's question",
    evaluation_params: [:input, :actual_output]
  )

  test_case = DeepEvalEx.TestCase.new!(
    input: "How do I make pasta?",
    actual_output: "Boil water, add pasta, cook for 8-10 minutes, drain and serve."
  )

  {:ok, result} = DeepEvalEx.Metrics.GEval.measure(metric, test_case)
  result.score   # => 0.8
  result.reason  # => "The response provides clear, actionable steps..."
  ```

  ## With Custom Evaluation Steps

  ```elixir
  metric = DeepEvalEx.Metrics.GEval.new(
    name: "Accuracy",
    evaluation_params: [:input, :actual_output, :expected_output],
    evaluation_steps: [
      "Compare the actual output with the expected output",
      "Check if key facts are correctly stated",
      "Verify no contradictions exist"
    ]
  )
  ```

  ## With Rubric

  ```elixir
  metric = DeepEvalEx.Metrics.GEval.new(
    name: "Quality",
    criteria: "Evaluate overall response quality",
    evaluation_params: [:input, :actual_output],
    rubric: [
      {10, "Perfect response, comprehensive and accurate"},
      {7, "Good response with minor issues"},
      {4, "Acceptable but missing key information"},
      {1, "Poor response, mostly incorrect or unhelpful"}
    ]
  )
  ```

  ## Options

  - `:name` - Name of this metric (required)
  - `:criteria` - Evaluation criteria description (required unless evaluation_steps provided)
  - `:evaluation_params` - Test case parameters to evaluate (required)
  - `:evaluation_steps` - Pre-defined evaluation steps (optional)
  - `:rubric` - Scoring rubric as list of {score, description} (optional)
  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:score_range` - Min/max score range (default: {0, 10})
  - `:strict_mode` - Binary 0/1 scoring (default: false)
  - `:model` - LLM model to use for evaluation
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Result}
  alias DeepEvalEx.Prompts.GEval, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.GEval, as: Schema

  @enforce_keys [:name, :evaluation_params]
  defstruct [
    :name,
    :criteria,
    :evaluation_params,
    :evaluation_steps,
    :rubric,
    :threshold,
    :score_range,
    :strict_mode,
    :model
  ]

  @type rubric_entry :: {integer(), String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          criteria: String.t() | nil,
          evaluation_params: [atom()],
          evaluation_steps: [String.t()] | nil,
          rubric: [rubric_entry()] | nil,
          threshold: float(),
          score_range: {integer(), integer()},
          strict_mode: boolean(),
          model: tuple() | nil
        }

  @doc """
  Creates a new GEval metric configuration.

  ## Options

  - `:name` - Name of this metric (required)
  - `:criteria` - Evaluation criteria (required unless evaluation_steps provided)
  - `:evaluation_params` - Parameters to evaluate (required)
  - `:evaluation_steps` - Pre-defined steps (optional)
  - `:rubric` - Scoring rubric (optional)
  - `:threshold` - Pass/fail threshold (default: 0.5)
  - `:score_range` - Score range (default: {0, 10})
  - `:strict_mode` - Binary scoring (default: false)
  - `:model` - LLM model (optional, uses default)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    evaluation_params = Keyword.fetch!(opts, :evaluation_params)
    criteria = Keyword.get(opts, :criteria)
    evaluation_steps = Keyword.get(opts, :evaluation_steps)

    # Validate: need either criteria or evaluation_steps
    if is_nil(criteria) and is_nil(evaluation_steps) do
      raise ArgumentError,
            "GEval requires either :criteria or :evaluation_steps to be provided"
    end

    %__MODULE__{
      name: name,
      criteria: criteria,
      evaluation_params: evaluation_params,
      evaluation_steps: evaluation_steps,
      rubric: Keyword.get(opts, :rubric),
      threshold: Keyword.get(opts, :threshold, 0.5),
      score_range: Keyword.get(opts, :score_range, {0, 10}),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      model: Keyword.get(opts, :model)
    }
  end

  @impl true
  def metric_name, do: "GEval"

  @impl true
  def required_params, do: []

  @doc """
  Measures a test case using the GEval metric configuration.

  ## With a metric struct (recommended):

  ```elixir
  metric = GEval.new(name: "Test", ...)
  GEval.evaluate(metric, test_case)
  ```

  ## With inline config:

  ```elixir
  GEval.evaluate(test_case,
    name: "Test",
    criteria: "...",
    evaluation_params: [:input, :actual_output]
  )
  ```
  """
  @spec evaluate(t(), map()) :: {:ok, Result.t()} | {:error, term()}
  @spec evaluate(map(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = metric, test_case) do
    do_measure_with_config(metric, test_case, [])
  end

  def evaluate(test_case, opts) when is_map(test_case) and is_list(opts) do
    # Build metric from opts if not a struct
    if Keyword.has_key?(opts, :name) do
      metric = new(opts)
      do_measure_with_config(metric, test_case, opts)
    else
      {:error, :missing_metric_configuration}
    end
  end

  @spec evaluate(t(), map(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = metric, test_case, opts) do
    do_measure_with_config(metric, test_case, opts)
  end

  # Implement the BaseMetric behaviour - measure expects (test_case, opts)
  # For GEval, we need configuration, so this delegates to evaluate/2
  def do_measure(test_case, opts) do
    if Keyword.has_key?(opts, :name) do
      evaluate(test_case, opts)
    else
      {:error, {:missing_config, "GEval requires :name, :criteria, and :evaluation_params options"}}
    end
  end

  defp do_measure_with_config(metric, test_case, opts) do
    start_time = System.monotonic_time(:millisecond)

    # Validate required params from the metric config
    with :ok <- validate_params(test_case, metric.evaluation_params) do
      adapter_opts = build_adapter_opts(metric, opts)

      result =
        with {:ok, steps} <- get_or_generate_steps(metric, adapter_opts),
             {:ok, {score, reason}} <- evaluate(metric, test_case, steps, adapter_opts) do
          # Normalize score to 0-1 range
          {min_score, max_score} = metric.score_range
          normalized_score = (score - min_score) / (max_score - min_score)
          threshold = Keyword.get(opts, :threshold, metric.threshold)

          latency = System.monotonic_time(:millisecond) - start_time

          {:ok,
           Result.new(
             metric: "#{metric.name} [GEval]",
             score: normalized_score,
             threshold: threshold,
             reason: reason,
             latency_ms: latency,
             metadata: %{
               raw_score: score,
               score_range: metric.score_range,
               evaluation_steps: steps,
               criteria: metric.criteria
             }
           )}
        end

      result
    end
  end

  defp validate_params(test_case, params) do
    missing =
      params
      |> Enum.filter(fn param ->
        value = Map.get(test_case, param)
        is_nil(value) or value == ""
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_params, missing}}
    end
  end

  defp build_adapter_opts(metric, opts) do
    base_opts = Keyword.take(opts, [:adapter, :api_key, :timeout])

    case metric.model do
      nil -> base_opts
      {provider, model} -> Keyword.merge(base_opts, adapter: provider, model: model)
      model when is_binary(model) -> Keyword.put(base_opts, :model, model)
    end
  end

  defp get_or_generate_steps(%{evaluation_steps: steps}, _opts) when is_list(steps) do
    {:ok, steps}
  end

  defp get_or_generate_steps(metric, opts) do
    params_string = Template.format_params(metric.evaluation_params)

    prompt =
      Template.generate_evaluation_steps(
        criteria: metric.criteria,
        parameters: params_string
      )

    case Adapter.generate_with_schema(prompt, Schema.steps_schema(), opts) do
      {:ok, response} -> Schema.parse_steps(response)
      {:error, _} = error -> error
    end
  end

  defp evaluate(metric, test_case, steps, opts) do
    params_string = Template.format_params(metric.evaluation_params)
    test_case_content = Template.format_test_case_content(test_case, metric.evaluation_params)

    prompt =
      if metric.strict_mode do
        Template.generate_strict_evaluation_results(
          evaluation_steps: steps,
          test_case_content: test_case_content,
          parameters: params_string
        )
      else
        Template.generate_evaluation_results(
          evaluation_steps: steps,
          test_case_content: test_case_content,
          parameters: params_string,
          rubric: format_rubric(metric.rubric),
          score_range: metric.score_range
        )
      end

    case Adapter.generate_with_schema(prompt, Schema.reason_score_schema(), opts) do
      {:ok, response} -> Schema.parse_reason_score(response)
      {:error, _} = error -> error
    end
  end

  defp format_rubric(nil), do: nil

  defp format_rubric(rubric) when is_list(rubric) do
    rubric
    |> Enum.sort_by(fn {score, _} -> -score end)
    |> Enum.map_join("\n", fn {score, description} -> "- Score #{score}: #{description}" end)
  end
end
