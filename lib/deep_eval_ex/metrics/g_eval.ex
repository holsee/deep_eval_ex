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

  ## Logprob-Weighted Scores

  As in deepeval, a judge that returns log probabilities (see
  `DeepEvalEx.LLM.Adapter.supports_log_probs?/1`; OpenAI's `gpt-4o`,
  `gpt-4.1`, ... but not its reasoning models) is asked for a raw response
  instead of a structured one, and the score it gives is replaced by the
  average of the scores it considered, weighted by their probabilities
  (`calculate_weighted_summed_score/2`): a judge torn between 7 and 8 scores
  about 7.5 rather than either. Strict mode keeps the judge's score. Any
  other judge (Anthropic, Ollama, custom adapters without
  `generate_raw_response/2`) is asked with the score schema and its score is
  kept.

  ## Scores

  The judge scores in the metric's score range: the range its rubric spans
  (see `DeepEvalEx.Metrics.GEval.Rubric.score_range/1`), 0-10 without one.
  As in deepeval, the score is the judge's score normalised over that range,
  `(score - min) / (max - min)`, and in strict mode the judge's 0 or 1
  itself, truncated to an integer as deepeval's `int(g_score)`.

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
      Rubric.new!(score_range: {0, 2}, expected_outcome: "Poor response, mostly incorrect or unhelpful"),
      Rubric.new!(score_range: {3, 5}, expected_outcome: "Acceptable but missing key information"),
      Rubric.new!(score_range: {6, 8}, expected_outcome: "Good response with minor issues"),
      Rubric.new!(score_range: {9, 10}, expected_outcome: "Perfect response, comprehensive and accurate")
    ]
  )
  ```

  (with `alias DeepEvalEx.Metrics.GEval.Rubric`). Ranges must not overlap,
  not even at an end, and are sorted by their start; the judge then scores
  from the first range's start to the last range's end, here 0-10.

  Rubric entries given as `{score, description}`, the shape before
  deepeval's `Rubric`, are deprecated: each is taken as the single-score
  range `{score, score}`, with a warning. They will be removed in the next
  release.

  ## Options

  - `:name` - Name of this metric (required)
  - `:criteria` - Evaluation criteria description (required unless evaluation_steps provided)
  - `:evaluation_params` - Test case parameters to evaluate (required)
  - `:evaluation_steps` - Pre-defined evaluation steps (optional)
  - `:rubric` - Scoring rubric, a list of `DeepEvalEx.Metrics.GEval.Rubric`
    entries; sets the score range (optional)
  - `:threshold` - Pass/fail threshold (default: 0.5); `nil` for score-only
    evaluation
  - `:score_range` - Deprecated: `{min, max}` score range without a rubric
    (default: `{0, 10}`); use a rubric
  - `:strict_mode` - Binary 0/1 scoring; forces the threshold to `1`
    (default: false)
  - `:flaky` - Report the result without letting it decide its test case's
    success (default: false)
  - `:model` - LLM model to use for evaluation
  - `:top_logprobs` - Most likely score tokens a judge with logprobs returns
    for weighting (default: 20, as in deepeval)
  - `:verbose_mode` - Print the result's `:verbose_logs` (criteria,
    evaluation steps, rubric and score) after measuring (default: false)
  - `:include_g_eval_suffix` - Name results `"<name> [GEval]"` rather than
    just `"<name>"` (default: true, as in deepeval)
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` (default: `nil`, deepeval's
    templates)

  ## Eval Modes

  GEval is always judged by its LLM, as deepeval's: it has no System One
  form, so under the `:hybrid` and `:system_one` eval modes (see
  `DeepEvalEx.SystemOne.Mode`) it still builds and calls its LLM, and
  builds and calls no System One model.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.{LLM.Adapter, Metrics.BaseMetric, Result, TestCase}
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Metrics.Utils.{Generation, Verbose}
  alias DeepEvalEx.Prompts.EvaluationTemplate
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
    :model,
    :verbose_mode,
    :evaluation_template,
    top_logprobs: 20,
    flaky: false,
    include_g_eval_suffix: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          criteria: String.t() | nil,
          evaluation_params: [atom()],
          evaluation_steps: [String.t()] | nil,
          rubric: [Rubric.t()] | nil,
          threshold: number() | nil,
          score_range: {integer(), integer()},
          strict_mode: boolean(),
          verbose_mode: boolean() | nil,
          flaky: boolean(),
          model: tuple() | nil,
          top_logprobs: pos_integer(),
          include_g_eval_suffix: boolean(),
          evaluation_template: module() | nil
        }

  @doc """
  Creates a new GEval metric configuration.

  ## Options

  - `:name` - Name of this metric (required)
  - `:criteria` - Evaluation criteria (required unless evaluation_steps provided)
  - `:evaluation_params` - Parameters to evaluate (required)
  - `:evaluation_steps` - Pre-defined steps (optional)
  - `:rubric` - `DeepEvalEx.Metrics.GEval.Rubric` entries (optional); the
    deprecated `{score, description}` entries are converted with a warning
  - `:threshold` - Pass/fail threshold (default: 0.5); `nil` for score-only
  - `:score_range` - Deprecated, see the moduledoc (default: {0, 10})
  - `:strict_mode` - Binary scoring; the threshold is then the integer `1`,
    as deepeval's constructor forces it (default: false)
  - `:flaky` - Never decide a test case's success (default: false)
  - `:model` - LLM model (optional, uses default)
  - `:top_logprobs` - Score tokens to weight by, for judges with logprobs
    (default: 20)
  - `:verbose_mode` - Print the verbose logs (default: false)
  - `:include_g_eval_suffix` - Append `" [GEval]"` to the name (default: true)
  - `:evaluation_template` - A `DeepEvalEx.Prompts.GEval` override (default: `nil`)

  Raises `ArgumentError`, as deepeval's constructor raises `ValueError`,
  for an empty `:evaluation_params` list, a blank `:criteria`, an empty
  `:evaluation_steps` list, or rubric ranges that overlap.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    evaluation_params = Keyword.fetch!(opts, :evaluation_params)
    criteria = Keyword.get(opts, :criteria)
    evaluation_steps = Keyword.get(opts, :evaluation_steps)

    validate_evaluation_params!(evaluation_params)
    validate_criteria_and_evaluation_steps!(criteria, evaluation_steps)

    rubric = opts |> Keyword.get(:rubric) |> rubric!()

    %__MODULE__{
      name: name,
      criteria: criteria,
      evaluation_params: evaluation_params,
      evaluation_steps: evaluation_steps,
      rubric: rubric,
      threshold: BaseMetric.threshold(opts, default_threshold()),
      score_range: score_range!(rubric, opts),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      top_logprobs: Keyword.get(opts, :top_logprobs, 20),
      include_g_eval_suffix: Keyword.get(opts, :include_g_eval_suffix, true),
      evaluation_template: Keyword.get(opts, :evaluation_template)
    }
  end

  defp validate_evaluation_params!([]),
    do: raise(ArgumentError, "evaluation_params cannot be an empty list.")

  defp validate_evaluation_params!(_params), do: :ok

  # deepeval's validate_criteria_and_evaluation_steps.
  defp validate_criteria_and_evaluation_steps!(nil, nil) do
    raise ArgumentError, "GEval requires either :criteria or :evaluation_steps to be provided"
  end

  defp validate_criteria_and_evaluation_steps!(criteria, steps) do
    if is_binary(criteria) and String.trim(criteria) == "" do
      raise ArgumentError, "Criteria provided cannot be an empty string."
    end

    if steps == [] do
      raise ArgumentError,
            "'evaluation_steps' must not be an empty list. Either omit evaluation " <>
              "steps or include a non-empty list of steps."
    end

    :ok
  end

  # deepeval's validate_and_sort_rubrics, converting deprecated
  # {score, description} entries to single-score Rubric ranges.
  defp rubric!(nil), do: nil

  defp rubric!(entries) when is_list(entries) do
    if Enum.any?(entries, &match?({_, _}, &1)) do
      IO.warn(
        "{score, description} GEval rubric entries are deprecated and will be removed " <>
          "in the next release; use DeepEvalEx.Metrics.GEval.Rubric entries, " <>
          "e.g. Rubric.new!(score_range: {score, score}, expected_outcome: description)"
      )
    end

    entries
    |> Enum.map(fn
      %Rubric{} = rubric -> rubric
      {score, outcome} -> Rubric.new!(score_range: {score, score}, expected_outcome: outcome)
      other -> raise ArgumentError, "invalid GEval rubric entry: #{inspect(other)}"
    end)
    |> Rubric.validate_and_sort()
  end

  # deepeval's get_score_range, honouring the deprecated :score_range
  # without a rubric. A :score_range equal to the derived one is accepted
  # silently: the evaluator rebuilds a metric from its struct's fields.
  defp score_range!(rubric, opts) do
    derived = Rubric.score_range(rubric)

    case {Keyword.get(opts, :score_range, derived), rubric} do
      {^derived, _rubric} ->
        derived

      {range, nil} ->
        IO.warn(
          "GEval's :score_range option is deprecated and will be removed in the next " <>
            "release; give a :rubric, whose ranges set the score range, as in deepeval"
        )

        range

      {_range, _rubric} ->
        raise ArgumentError,
              "GEval takes its score range from its :rubric; do not also give :score_range"
    end
  end

  @impl true
  def metric_name, do: "GEval"

  @doc """
  `false`: GEval takes no part in System One (see "Eval Modes").
  """
  @impl true
  def system_one?, do: false

  @doc """
  Returns the name results of this configured metric carry.

  Mirrors deepeval's `GEval.__name__`: `"<name> [GEval]"`, or just
  `"<name>"` when `:include_g_eval_suffix` is false.
  """
  @impl true
  @spec metric_name(t()) :: String.t()
  def metric_name(%__MODULE__{name: name, include_g_eval_suffix: true}), do: "#{name} [GEval]"
  def metric_name(%__MODULE__{name: name}), do: name

  @impl true
  def required_params, do: []

  @doc """
  Returns the judge model this metric calls with `opts`, honouring a
  `:model` given as `{provider, model}`.
  """
  @impl true
  def evaluation_model(opts) do
    opts
    |> Keyword.get(:model)
    |> adapter_opts(opts)
    |> Adapter.model_name()
  end

  @doc """
  GEval's test-run cache settings, as deepeval's `GEval` attributes: its
  criteria, its evaluation steps (the generated ones once measured) and
  its evaluation params; GEval takes no `include_reason`.
  """
  @impl true
  def cache_configuration(opts, result) do
    steps =
      Keyword.get(opts, :evaluation_steps) ||
        (result && Map.get(result.metadata || %{}, :evaluation_steps))

    %{
      criteria: Keyword.get(opts, :criteria),
      evaluation_steps: steps,
      evaluation_params: opts |> Keyword.get(:evaluation_params) |> param_names(),
      include_reason: false
    }
  end

  defp param_names(nil), do: nil
  defp param_names(params), do: Enum.map(params, &Atom.to_string/1)

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
      {:error,
       {:missing_config, "GEval requires :name, :criteria, and :evaluation_params options"}}
    end
  end

  defp do_measure_with_config(metric, test_case, opts) do
    start_time = System.monotonic_time(:millisecond)

    # Validate required params from the metric config
    with :ok <- TestCase.validate_params(test_case, metric.evaluation_params) do
      adapter_opts = build_adapter_opts(metric, opts)

      result =
        with {:ok, steps} <- get_or_generate_steps(metric, adapter_opts),
             {:ok, {score, reason}} <- evaluate(metric, test_case, steps, adapter_opts) do
          strict_opts = Keyword.put_new(opts, :strict_mode, metric.strict_mode || false)
          threshold = BaseMetric.threshold(strict_opts, metric.threshold)
          final_score = g_eval_score(score, metric)

          verbose_logs =
            Verbose.construct_verbose_logs(
              metric_name(metric),
              [
                "Criteria:\n#{Verbose.to_str(metric.criteria)}",
                "Evaluation Steps:\n#{Verbose.prettify_list(steps)}",
                "Rubric:\n#{metric.rubric |> Template.format_rubric() |> Verbose.to_str()}",
                "Score: #{Verbose.to_str(final_score)}",
                "Reason: #{Verbose.to_str(reason)}"
              ],
              verbose_mode: Keyword.get(opts, :verbose_mode, metric.verbose_mode)
            )

          latency = System.monotonic_time(:millisecond) - start_time

          {:ok,
           Result.new(
             metric: metric_name(metric),
             score: final_score,
             threshold: threshold,
             reason: reason,
             verbose_logs: verbose_logs,
             strict_mode: strict_opts[:strict_mode],
             flaky: Keyword.get(opts, :flaky, metric.flaky),
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

  # deepeval's GEval score: the judge's score normalised over the score
  # range, or in strict mode its int(g_score), the 0 or 1 asked for.
  defp g_eval_score(score, %{strict_mode: true}), do: trunc(score)

  defp g_eval_score(score, %{score_range: {min_score, max_score}}),
    do: (score - min_score) / (max_score - min_score)

  defp template_opts(metric), do: [evaluation_template: metric.evaluation_template]

  defp build_adapter_opts(metric, opts), do: adapter_opts(metric.model, opts)

  defp adapter_opts(model, opts) do
    base_opts = Keyword.take(opts, [:adapter, :api_key, :timeout])

    case model do
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
      EvaluationTemplate.render(template_opts(metric), Template, :generate_evaluation_steps,
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
        EvaluationTemplate.render(
          template_opts(metric),
          Template,
          :generate_strict_evaluation_results,
          evaluation_steps: steps,
          test_case_content: test_case_content,
          parameters: params_string
        )
      else
        EvaluationTemplate.render(template_opts(metric), Template, :generate_evaluation_results,
          evaluation_steps: steps,
          test_case_content: test_case_content,
          parameters: params_string,
          rubric: Template.format_rubric(metric.rubric),
          score_range: metric.score_range
        )
      end

    rubric_score(metric, prompt, opts)
  end

  defp rubric_score(metric, prompt, opts) do
    generate_rubric_score(prompt, opts,
      strict_mode: metric.strict_mode,
      top_logprobs: metric.top_logprobs,
      schema: Schema.reason_score_schema(),
      parse: &Schema.parse_reason_score/1,
      weighted_score: &calculate_weighted_summed_score/2
    )
  end

  @doc false
  # deepeval's generate_rubric_score (metrics/utils/decision.py), shared
  # with ConversationalGEval: a judge with logprobs answers a raw response
  # whose score is weighted by `:weighted_score` (except in strict mode);
  # any other is asked for the `:schema`, as deepeval falls back on the
  # AttributeError of a judge without generate_raw_response. `:parse` reads
  # `{score, reason}` from either answer.
  @spec generate_rubric_score(String.t(), keyword(), keyword()) ::
          {:ok, {number(), String.t()}} | {:error, term()}
  def generate_rubric_score(prompt, opts, scoring) do
    parse = Keyword.fetch!(scoring, :parse)

    if Adapter.supports_log_probs?(opts) do
      raw_opts = Keyword.put(opts, :top_logprobs, Keyword.fetch!(scoring, :top_logprobs))

      with {:ok, raw_response} <- Adapter.generate_raw_response(prompt, raw_opts),
           {:ok, {score, reason}} <- score_from_raw_response(raw_response, parse) do
        if Keyword.fetch!(scoring, :strict_mode),
          do: {:ok, {score, reason}},
          else: {:ok, {Keyword.fetch!(scoring, :weighted_score).(score, raw_response), reason}}
      end
    else
      case Adapter.generate_with_schema(prompt, Keyword.fetch!(scoring, :schema), opts) do
        {:ok, response} -> parse.(response)
        {:error, _} = error -> error
      end
    end
  end

  # deepeval's _score_from_raw_response: the message is loaded with
  # trimAndLoadJson whatever the judge's structured output support.
  defp score_from_raw_response(
         %{"choices" => [%{"message" => %{"content" => content}} | _]},
         parse
       ) do
    with {:ok, data} <- Generation.trim_and_load_json(content) do
      parse.(data)
    end
  end

  defp score_from_raw_response(raw_response, _parse),
    do: {:error, {:unexpected_response, raw_response}}

  # Tokens under 1% probability are dropped.
  @min_logprob :math.log(0.01)

  @doc """
  Weights `raw_score` by the log probabilities of the judge's `raw_response`
  (an OpenAI chat completion, see
  `DeepEvalEx.LLM.Adapter.c:generate_raw_response/2`), deepeval's
  `calculate_weighted_summed_score`.

  The score's token is the last one of the completion equal to the raw
  score (the reasoning may name the same number earlier). Of its top
  logprobs, tokens under 1% probability and tokens that are not decimal
  numbers are dropped; the rest, as integer scores (`"08"` counts for 8),
  are averaged weighted by their probabilities, normalised to sum to 1.

  Returns `raw_score` when no token is left, and where deepeval's caller
  falls back to the raw score on an error: a completion without logprobs or
  without a token for the score.

  ## Examples

      iex> top = [%{"token" => "7", "logprob" => -0.1}, %{"token" => "8", "logprob" => -2.5}]
      iex> raw_response = %{"choices" => [%{"logprobs" => %{"content" => [
      ...>   %{"token" => "7", "logprob" => -0.1, "top_logprobs" => top}]}}]}
      iex> DeepEvalEx.Metrics.GEval.calculate_weighted_summed_score(7, raw_response)
      7.083172696493922

      iex> DeepEvalEx.Metrics.GEval.calculate_weighted_summed_score(7, %{"choices" => []})
      7
  """
  @spec calculate_weighted_summed_score(number(), map()) :: number()
  def calculate_weighted_summed_score(raw_score, raw_response),
    do: calculate_weighted_summed_score(raw_score, raw_response, [])

  @doc false
  # calculate_weighted_summed_score/2 with ConversationalGEval's variant of
  # it: `score_token: :first` weights the first token equal to the score
  # rather than the last (default: `:last`), and `no_tokens: :raise` raises
  # deepeval's ZeroDivisionError, as an ArithmeticError, when every top
  # token is dropped rather than returning the raw score (default:
  # `:raw_score`).
  @spec calculate_weighted_summed_score(number(), map(), keyword()) :: number()
  def calculate_weighted_summed_score(raw_score, raw_response, opts) do
    with {:ok, top_logprobs} <-
           score_top_logprobs(raw_score, raw_response, Keyword.get(opts, :score_token, :last)),
         {:ok, {scores, sum}} <- linear_probabilities(top_logprobs) do
      weighted_summed_score(scores, sum, raw_score, Keyword.get(opts, :no_tokens, :raw_score))
    else
      :error -> raw_score
    end
  end

  # The top logprobs of the last (or first) token equal to the score, as
  # Python's str(raw_score).
  defp score_top_logprobs(
         raw_score,
         %{"choices" => [%{"logprobs" => %{"content" => tokens}} | _]},
         score_token
       )
       when is_list(tokens) do
    token = Verbose.to_str(raw_score)
    tokens = if score_token == :last, do: Enum.reverse(tokens), else: tokens

    case Enum.find(tokens, &match?(%{"token" => ^token}, &1)) do
      %{"top_logprobs" => top_logprobs} when is_list(top_logprobs) -> {:ok, top_logprobs}
      _ -> :error
    end
  end

  defp score_top_logprobs(_raw_score, _raw_response, _score_token), do: :error

  # Each kept score with its summed linear probability, in first-seen order
  # as deepeval's dict, and the running sum of every kept probability in
  # token order, so the floats add up as in deepeval.
  defp linear_probabilities(top_logprobs) do
    Enum.reduce_while(top_logprobs, {:ok, {[], 0}}, fn
      %{"token" => token, "logprob" => logprob}, {:ok, acc}
      when is_binary(token) and is_number(logprob) ->
        {:cont, {:ok, add_probability(acc, token, logprob)}}

      _malformed, _acc ->
        {:halt, :error}
    end)
  end

  defp add_probability({scores, sum} = acc, token, logprob) do
    if logprob < @min_logprob or not decimal?(token) do
      acc
    else
      score = String.to_integer(token)
      probability = :math.exp(logprob)

      scores =
        case List.keyfind(scores, score, 0) do
          nil -> scores ++ [{score, probability}]
          {^score, prob} -> List.keyreplace(scores, score, 0, {score, prob + probability})
        end

      {scores, sum + probability}
    end
  end

  # Python's str.isdecimal, for ASCII digits.
  defp decimal?(token), do: token =~ ~r/\A[0-9]+\z/

  # Every token filtered out: the raw score, or deepeval's ZeroDivisionError
  # (0.0 / 0) where its sum is left unchecked.
  defp weighted_summed_score([], _sum, raw_score, :raw_score), do: raw_score

  defp weighted_summed_score([], _sum, _raw_score, :raise),
    do: raise(ArithmeticError, message: "float division by zero")

  defp weighted_summed_score(scores, sum_linear_probability, _raw_score, _no_tokens) do
    sum_of_weighted_scores = Enum.reduce(scores, 0.0, fn {s, p}, sum -> sum + s * p end)
    sum_of_weighted_scores / sum_linear_probability
  end
end
