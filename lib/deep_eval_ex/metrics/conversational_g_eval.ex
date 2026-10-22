# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/conversational_g_eval/conversational_g_eval.py
# Original: https://github.com/confident-ai/deepeval
# Based on the G-Eval framework: https://arxiv.org/pdf/2303.16634.pdf

defmodule DeepEvalEx.Metrics.ConversationalGEval do
  @moduledoc """
  G-Eval for conversations, deepeval 4.3.1's `ConversationalGEval`: an LLM
  judges a whole `DeepEvalEx.ConversationalTestCase` against custom
  criteria.

  ## How It Works

  1. **Generate evaluation steps** - the judge turns the criteria into 3-4
     steps, unless `:evaluation_steps` are given
  2. **Score the conversation** - the judge scores it from 0 to 10 with the
     steps (and the rubric, if any), seeing each turn's evaluated fields
     ("Per-turn fields") and the evaluated case-level fields
     ("Conversation-level fields")
  3. **Get result** - the score divided by 10, with the judge's reason

  As in deepeval, `:content` and `:role` are always evaluated: they are
  appended to `:evaluation_params` when missing (`[:scenario]` becomes
  `[:scenario, :content, :role]`). The case-level params evaluated
  (`:scenario`, `:expected_outcome`, `:metadata`, `:tags`) must be set on the
  test case (see `DeepEvalEx.ConversationalTestCase.validate_params/3`).

  ## Usage

  ```elixir
  metric =
    DeepEvalEx.Metrics.ConversationalGEval.new(
      name: "Helpfulness",
      criteria: "Determine whether the assistant resolves the user's request.",
      evaluation_params: [:content]
    )

  test_case =
    DeepEvalEx.ConversationalTestCase.new!(
      turns: [
        %{role: :user, content: "My order is late, I want a refund."},
        %{role: :assistant, content: "I've started a refund for order 42."}
      ]
    )

  [[result]] = DeepEvalEx.Evaluator.evaluate([test_case], [metric])
  result.metric  # => "Helpfulness [Conversational GEval]"
  ```

  ## Scores

  Unlike GEval's, the judge always scores from 0 to 10, rubric or not, and
  the score is the judge's divided by 10, a fractional score included. In
  strict mode the threshold is `1` and the judge is asked the same
  question; a score below `1` is then the integer `0`.

  A judge that returns log probabilities (see
  `DeepEvalEx.LLM.Adapter.supports_log_probs?/1`) is asked for a raw
  response, and its score is weighted by them (except in strict mode), as
  GEval's: see `calculate_weighted_summed_score/2` for how deepeval's
  conversational variant differs.

  ## Options

  - `:name` - Name of this metric (required)
  - `:evaluation_params` - The `DeepEvalEx.Params.MultiTurn` params to
    evaluate (required): `:content`, `:role`, `:retrieval_context`,
    `:tools_called` (per turn), `:scenario`, `:expected_outcome`,
    `:metadata` and `:tags` (per conversation)
  - `:criteria` - Evaluation criteria (required unless `:evaluation_steps`
    are given)
  - `:evaluation_steps` - Pre-defined evaluation steps
  - `:rubric` - `DeepEvalEx.Metrics.GEval.Rubric` entries the judge scores
    by
  - `:threshold` - Pass/fail threshold (default: 0.5); `nil` for score-only
  - `:strict_mode` - Binary 0/1 scoring; forces the threshold to `1`
    (default: false)
  - `:flaky` - Never decide a test case's success (default: false)
  - `:model` - LLM model to use for evaluation
  - `:top_logprobs` - Most likely score tokens a judge with logprobs returns
    for weighting (default: 20)
  - `:verbose_mode` - Print the verbose logs after measuring (default: false)
  - `:include_g_eval_suffix` - Name results `"<name> [Conversational GEval]"`
    rather than just `"<name>"` (default: true)
  - `:evaluation_template` - A module overriding some of the prompts, see
    `DeepEvalEx.Prompts.EvaluationTemplate` and
    `DeepEvalEx.Prompts.ConversationalGEval` (default: `nil`)

  deepeval's `:audio` param, which sends each turn's audio to the judge,
  is not supported: DeepEvalEx's judges take text only. Params deepeval's
  conversational G-Eval cannot name (`:context`, `:user_description`,
  `:chatbot_role`, `:provider_transcript` and the MCP params), on which
  deepeval's `measure()` fails, are rejected by `new/1`. deepeval's
  `upload()` and `pull()` (Confident AI) are not ported, so
  `:evaluation_params` is required.

  ## Copies

  deepeval's asynchronous `evaluate()` measures copies of its metrics
  (`copy_metrics`), and a copy of a `ConversationalGEval` names its judge
  as its audio judge too, so its results report the evaluation model
  `"<judge> (audio: <judge>)"`. The `DeepEvalEx.Evaluator` copies the
  metric likewise with `copy_metric/1` unless `run_async: false`, so the
  same evaluation model is exported.

  ## Eval Modes

  ConversationalGEval is always judged by its LLM, as deepeval's: it has no
  System One form, so under the `:hybrid` and `:system_one` eval modes (see
  `DeepEvalEx.SystemOne.Mode`) it still builds and calls its LLM, and
  builds and calls no System One model.
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.{ConversationalTestCase, LLM.Adapter, Metrics.BaseMetric, Result}
  alias DeepEvalEx.Metrics.GEval
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Metrics.Utils.{Turns, Verbose}
  alias DeepEvalEx.Params.MultiTurn
  alias DeepEvalEx.Prompts.ConversationalGEval, as: Template
  alias DeepEvalEx.Prompts.EvaluationTemplate
  alias DeepEvalEx.Schemas.MetricOutputs.ConversationalGEval, as: Schema

  @enforce_keys [:name, :evaluation_params]
  defstruct [
    :name,
    :criteria,
    :evaluation_params,
    :evaluation_steps,
    :rubric,
    :threshold,
    :strict_mode,
    :model,
    :verbose_mode,
    :evaluation_template,
    :audio_model,
    top_logprobs: 20,
    flaky: false,
    include_g_eval_suffix: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          criteria: String.t() | nil,
          evaluation_params: [MultiTurn.t()],
          evaluation_steps: [String.t()] | nil,
          rubric: [Rubric.t()] | nil,
          threshold: number() | nil,
          strict_mode: boolean(),
          verbose_mode: boolean() | nil,
          flaky: boolean(),
          model: tuple() | String.t() | nil,
          top_logprobs: pos_integer(),
          include_g_eval_suffix: boolean(),
          evaluation_template: module() | nil,
          audio_model: :judge | nil
        }

  @doc """
  Creates a new ConversationalGEval metric configuration (see "Options").

  Raises `ArgumentError`, as deepeval raises `ValueError`, for an empty
  `:evaluation_params` list, neither `:criteria` nor `:evaluation_steps`, a
  blank `:criteria`, an empty `:evaluation_steps` list, or rubric ranges
  that overlap; and for params it cannot evaluate (see "Options").
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    name = Keyword.fetch!(opts, :name)
    criteria = Keyword.get(opts, :criteria)
    evaluation_steps = Keyword.get(opts, :evaluation_steps)

    evaluation_params = opts |> Keyword.fetch!(:evaluation_params) |> evaluation_params!()
    validate_criteria_and_evaluation_steps!(criteria, evaluation_steps)

    %__MODULE__{
      name: name,
      criteria: criteria,
      evaluation_params: evaluation_params,
      evaluation_steps: evaluation_steps,
      rubric: opts |> Keyword.get(:rubric) |> rubric!(),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      flaky: Keyword.get(opts, :flaky, false),
      model: Keyword.get(opts, :model),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      top_logprobs: Keyword.get(opts, :top_logprobs, 20),
      include_g_eval_suffix: Keyword.get(opts, :include_g_eval_suffix, true),
      evaluation_template: Keyword.get(opts, :evaluation_template),
      audio_model: Keyword.get(opts, :audio_model)
    }
  end

  # deepeval appends CONTENT, then ROLE, when missing.
  defp evaluation_params!([]),
    do: raise(ArgumentError, "evaluation_params cannot be an empty list.")

  defp evaluation_params!(params) when is_list(params) do
    Enum.each(params, &check_param!/1)

    params
    |> append_missing(:content)
    |> append_missing(:role)
  end

  defp append_missing(params, param),
    do: if(param in params, do: params, else: params ++ [param])

  defp check_param!(:audio) do
    raise ArgumentError,
          "ConversationalGEval cannot evaluate :audio: DeepEvalEx sends no audio to judges"
  end

  defp check_param!(param) do
    unless MultiTurn.display_name(param) do
      raise ArgumentError,
            "ConversationalGEval cannot evaluate #{inspect(param)}; it evaluates " <>
              ":content, :role, :retrieval_context, :tools_called, :scenario, " <>
              ":expected_outcome, :metadata and :tags"
    end
  end

  # deepeval's validate_criteria_and_evaluation_steps, which its
  # ensure_required_params runs before measuring.
  defp validate_criteria_and_evaluation_steps!(nil, nil),
    do: raise(ArgumentError, "Either 'criteria' or 'evaluation_steps' must be provided.")

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

  # deepeval's validate_and_sort_rubrics.
  defp rubric!(nil), do: nil

  defp rubric!(entries) when is_list(entries) do
    entries
    |> Enum.map(fn
      %Rubric{} = rubric -> rubric
      other -> raise ArgumentError, "invalid ConversationalGEval rubric entry: #{inspect(other)}"
    end)
    |> Rubric.validate_and_sort()
  end

  @impl true
  def metric_name, do: "Conversational GEval"

  @doc """
  `false`: ConversationalGEval takes no part in System One (see "Eval
  Modes").
  """
  @impl true
  def system_one?, do: false

  @doc """
  Returns the name results of this configured metric carry, deepeval's
  `__name__`: `"<name> [Conversational GEval]"`, or just `"<name>"` when
  `:include_g_eval_suffix` is false.
  """
  @impl true
  @spec metric_name(t()) :: String.t()
  def metric_name(%__MODULE__{name: name, include_g_eval_suffix: true}),
    do: "#{name} [Conversational GEval]"

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
  The evaluation model a result reports for the judge `model`: deepeval's
  `"<judge> (audio: <judge>)"` for a copy (`audio_model: :judge`, see
  "Copies"), else `model`.
  """
  @impl true
  @spec describe_evaluation_model(String.t(), keyword()) :: String.t()
  def describe_evaluation_model(model, opts) do
    case Keyword.get(opts, :audio_model) do
      :judge -> "#{model} (audio: #{model})"
      _none -> model
    end
  end

  @doc """
  The copy deepeval's asynchronous `evaluate()` measures, as its
  `copy_metrics` rebuilds it: the judge is named as the audio judge too
  (see "Copies").
  """
  @impl true
  @spec copy_metric(t()) :: t()
  def copy_metric(%__MODULE__{} = metric), do: %{metric | audio_model: :judge}

  @doc """
  Measures a conversational test case with a metric struct, as the
  `DeepEvalEx.Evaluator` does, `opts` giving run-level defaults (such as
  `:adapter`) that the metric's own fields override.
  """
  @spec evaluate(t(), ConversationalTestCase.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = metric, test_case, opts \\ []) do
    struct_opts =
      metric
      |> Map.from_struct()
      |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)

    measure(test_case, Keyword.merge(opts, struct_opts))
  end

  @doc false
  def do_measure(test_case, opts) do
    if Keyword.has_key?(opts, :name) do
      metric = new(opts)

      with :ok <- ConversationalTestCase.validate_params(test_case, metric.evaluation_params) do
        measure_with(metric, test_case, opts)
      end
    else
      {:error,
       {:missing_config,
        "ConversationalGEval requires :name, :evaluation_params and :criteria or " <>
          ":evaluation_steps options"}}
    end
  end

  defp measure_with(metric, test_case, opts) do
    adapter_opts = adapter_opts(metric.model, opts)

    with {:ok, steps} <- evaluation_steps(metric, adapter_opts),
         {:ok, {g_score, reason}} <- evaluate_steps(metric, test_case, steps, adapter_opts) do
      threshold = BaseMetric.threshold(opts, metric.threshold)
      score = g_score / 10

      strict_score =
        BaseMetric.strict_score(score, strict_mode: metric.strict_mode, threshold: threshold)

      verbose_logs =
        Verbose.construct_verbose_logs(
          metric_name(metric),
          [
            "Criteria:\n#{Verbose.to_str(metric.criteria)}",
            "Evaluation Steps:\n#{Verbose.prettify_list(steps)}",
            "Rubric:\n#{metric.rubric |> Template.format_rubric() |> Verbose.to_str()}",
            "Score: #{Verbose.to_str(strict_score)}\nReason: #{Verbose.to_str(reason)}"
          ],
          verbose_mode: Keyword.get(opts, :verbose_mode, metric.verbose_mode)
        )

      {:ok,
       Result.new(
         metric: metric_name(metric),
         score: score,
         threshold: threshold,
         reason: reason,
         verbose_logs: verbose_logs,
         metadata: %{raw_score: g_score, evaluation_steps: steps, criteria: metric.criteria}
       )}
    end
  end

  defp template_opts(metric), do: [evaluation_template: metric.evaluation_template]

  defp adapter_opts(model, opts) do
    base_opts = Keyword.take(opts, [:adapter, :api_key, :timeout])

    case model do
      nil -> base_opts
      {provider, model} -> Keyword.merge(base_opts, adapter: provider, model: model)
      model when is_binary(model) -> Keyword.put(base_opts, :model, model)
    end
  end

  # deepeval's _generate_evaluation_steps.
  defp evaluation_steps(%{evaluation_steps: steps}, _opts) when is_list(steps), do: {:ok, steps}

  defp evaluation_steps(metric, opts) do
    prompt =
      EvaluationTemplate.render(template_opts(metric), Template, :generate_evaluation_steps,
        criteria: metric.criteria,
        parameters: Template.format_params(metric.evaluation_params)
      )

    with {:ok, response} <- Adapter.generate_with_schema(prompt, Schema.steps_schema(), opts) do
      Schema.parse_steps(response)
    end
  end

  # deepeval's _evaluation_prompt and evaluate.
  defp evaluate_steps(metric, test_case, steps, opts) do
    params = metric.evaluation_params

    prompt =
      EvaluationTemplate.render(template_opts(metric), Template, :generate_evaluation_results,
        evaluation_steps: steps,
        test_case_content: Template.format_test_case_content(test_case, params),
        turns: Enum.map(test_case.turns, &Turns.convert_turn_to_dict(&1, params)),
        parameters: Template.format_params(params),
        rubric: Template.format_rubric(metric.rubric)
      )

    GEval.generate_rubric_score(prompt, opts,
      strict_mode: metric.strict_mode,
      top_logprobs: metric.top_logprobs,
      schema: Schema.reason_score_schema(),
      parse: &Schema.parse_reason_score/1,
      weighted_score: &calculate_weighted_summed_score/2
    )
  end

  @doc """
  Weights `raw_score` by the log probabilities of the judge's
  `raw_response`, deepeval's `ConversationalGEval.generate_weighted_summed_score`:
  `DeepEvalEx.Metrics.GEval.calculate_weighted_summed_score/2`, except
  that, as in deepeval:

  - the score's token is the **first** token of the completion equal to the
    raw score, even one in the reason, not the last;
  - when every top token is dropped, it raises deepeval's
    `ZeroDivisionError` as an `ArithmeticError` (`"float division by
    zero"`), which errors the metric, rather than returning the raw score.

  A completion without logprobs or without a token for the score still
  gives the raw score.

  ## Examples

      iex> top = [%{"token" => "7", "logprob" => -0.1}, %{"token" => "8", "logprob" => -2.5}]
      iex> raw_response = %{"choices" => [%{"logprobs" => %{"content" => [
      ...>   %{"token" => "7", "logprob" => -0.1, "top_logprobs" => top},
      ...>   %{"token" => "7", "logprob" => -0.1, "top_logprobs" => []}]}}]}
      iex> DeepEvalEx.Metrics.ConversationalGEval.calculate_weighted_summed_score(7, raw_response)
      7.083172696493922
  """
  @spec calculate_weighted_summed_score(number(), map()) :: number()
  def calculate_weighted_summed_score(raw_score, raw_response) do
    GEval.calculate_weighted_summed_score(raw_score, raw_response,
      score_token: :first,
      no_tokens: :raise
    )
  end
end
