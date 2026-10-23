# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/conversational_jev_eval/conversational_jev_eval.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ConversationalJevEval do
  @moduledoc """
  The multi-turn counterpart of `DeepEvalEx.Metrics.JevEval`, a port of
  deepeval 4.3.1's `ConversationalJevEval`
  (`deepeval/metrics/conversational_jev_eval/conversational_jev_eval.py`):
  the same System One-answered `DeepEvalEx.SystemOne.Scored` questions
  (Noul, Score and Choice), about a `DeepEvalEx.ConversationalTestCase`.

  One System One request (`DeepEvalEx.SystemOne.decide/3`) answers them
  all, about the conversation's turns and the conversation-level fields
  named by `:evaluation_params`, deepeval's `construct_multi_turn_state`
  (`DeepEvalEx.SystemOne.State.multi_turn/2`):

      {"turns": [{"content": "...", "role": "user"}, ...],
       "test_case": {"scenario": "...", "chatbot_role": "..."}}

  Each turn carries the params that name a turn field (`:role`,
  `:content`, `:retrieval_context`, `:tools_called`), in the order given;
  `"test_case"` the others that are set, and is left out when none is.
  `:content` and `:role` are always part of the state: they are appended,
  in that order, when missing.

  Scoring, strict mode, the reason, the verbose logs and the usage are
  JevEval's: the weighted mean of the answers that applied, no LLM at any
  point, always decided by System One whatever the `:eval_mode`, a System
  One error raised and never caught, never batched with other metrics.

  ## Usage

      alias DeepEvalEx.{ConversationalTestCase, Metrics.ConversationalJevEval}
      alias DeepEvalEx.SystemOne.Scored

      metric =
        ConversationalJevEval.new(
          name: "Support",
          evaluation_params: [:chatbot_role],
          questions: [
            Scored.Noul.new!(
              statement: "The assistant does what the user asked in the last turn.",
              weight: 2
            ),
            Scored.Score.new!(
              question: "How well do the assistant's turns keep to chatbot_role?",
              levels: ["Not at all", "Partly", "Fully"]
            )
          ]
        )

      test_case =
        ConversationalTestCase.new!(
          chatbot_role: "A courteous order support agent.",
          turns: [
            %{role: :user, content: "Can I change the address to Zürich?"},
            %{role: :assistant, content: "Done: order 42 now ships to Zürich."}
          ]
        )

      {:ok, result} = ConversationalJevEval.evaluate(metric, test_case)

  A metric struct can also be passed to `DeepEvalEx.evaluate/3` like any
  other metric.

  ## Test case checks

  As deepeval's `_check_params`, before asking: a multimodal conversation
  raises `ArgumentError` (Jev has no image input), and the test case is
  checked with `DeepEvalEx.ConversationalTestCase.validate_params/3` for
  the evaluation params, requiring a `:chatbot_role` when it is one of
  them. A failed check returns its error, as a conversational metric's
  (see `DeepEvalEx.Metrics.BaseConversationalMetric`).

  ## Options

  - `:name` - the metric's name (required); results are named
    `"<name> [Conversational JevEval]"`
  - `:evaluation_params` - the `DeepEvalEx.Params.MultiTurn` params the
    questions refer to (required, at least one), `:content` and `:role`
    appended when missing
  - `:questions` - the `DeepEvalEx.SystemOne.Scored` questions (required,
    at least one), asked as `"q_<index>"`
  - `:system_one_model` - the System One model, anything
    `DeepEvalEx.SystemOne.Model.resolve/1` accepts (default: the
    `:system_one_model` application config, else Jev)
  - `:threshold` - pass/fail threshold (default: `0.5`); `nil` for
    score-only
  - `:strict_mode` - forces the threshold to `1`, and scores `1.0` only
    when every applicable question is answered at its best (see JevEval)
    (default: `false`)
  - `:include_reason` - build the reason (default: `true`)
  - `:verbose_mode` - print the verbose logs (default: `false`)
  - `:flaky` - never decide the test case's success (default: `false`)
  - `:include_jev_eval_suffix` - append `" [Conversational JevEval]"` to
    the name (default: `true`)
  """

  use DeepEvalEx.Metrics.BaseConversationalMetric, default_threshold: 0.5

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.Metrics.{BaseMetric, JevEval}
  alias DeepEvalEx.Params.MultiTurn
  alias DeepEvalEx.SystemOne.{Context, Model, Scored, State}

  @enforce_keys [:name, :evaluation_params, :questions, :system_one_model]
  defstruct [
    :name,
    :evaluation_params,
    :questions,
    :system_one_model,
    :verbose_mode,
    threshold: 0.5,
    strict_mode: false,
    include_reason: true,
    flaky: false,
    include_jev_eval_suffix: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          evaluation_params: [MultiTurn.t(), ...],
          questions: [Scored.t(), ...],
          system_one_model: Model.t(),
          verbose_mode: boolean() | nil,
          threshold: number() | nil,
          strict_mode: boolean(),
          include_reason: boolean(),
          flaky: boolean(),
          include_jev_eval_suffix: boolean()
        }

  @doc """
  Creates a ConversationalJevEval metric. See the moduledoc for the
  options.

  The System One model is resolved and initialised here, as deepeval's
  constructor does. Raises `ArgumentError`, as deepeval raises
  `ValueError` or `TypeError`, for no `:evaluation_params`, one that is
  not a multi-turn param, no questions or a question that is not a Noul,
  Score or Choice, and `DeepEvalEx.DeepEvalError` when the System One model
  is not usable.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      evaluation_params: opts |> Keyword.get(:evaluation_params) |> evaluation_params!(),
      questions: opts |> Keyword.get(:questions) |> JevEval.validate_questions!(),
      system_one_model: opts |> Keyword.get(:system_one_model) |> JevEval.jev_model!(),
      threshold: BaseMetric.threshold(opts, default_threshold()),
      strict_mode: Keyword.get(opts, :strict_mode, false),
      include_reason: Keyword.get(opts, :include_reason, true),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky, false),
      include_jev_eval_suffix: Keyword.get(opts, :include_jev_eval_suffix, true)
    }
  end

  # Every question is about the conversation, so the turns' content and
  # roles are always part of the state.
  defp evaluation_params!(params) when params in [nil, []] do
    raise ArgumentError,
          "evaluation_params cannot be empty; list the turn and conversation fields your " <>
            "questions refer to."
  end

  defp evaluation_params!(params) when is_list(params) do
    Enum.each(params, fn param ->
      unless MultiTurn.member?(param) do
        raise ArgumentError, "expected a multi-turn param, got: #{inspect(param)}"
      end
    end)

    params
    |> append_missing(:content)
    |> append_missing(:role)
  end

  defp append_missing(params, param),
    do: if(param in params, do: params, else: params ++ [param])

  @impl true
  def metric_name, do: "Conversational JevEval"

  @doc """
  The name results of this configured metric carry, deepeval's
  `ConversationalJevEval.__name__`: `"<name> [Conversational JevEval]"`,
  or just `"<name>"` when `:include_jev_eval_suffix` is false.
  """
  @impl true
  @spec metric_name(t()) :: String.t()
  def metric_name(%__MODULE__{name: name, include_jev_eval_suffix: true}),
    do: "#{name} [Conversational JevEval]"

  def metric_name(%__MODULE__{name: name}), do: name

  @impl true
  def required_params, do: [:content, :role]

  @doc """
  The System One model's name, deepeval's `evaluation_model`, reported
  even on an errored result.
  """
  @impl true
  def evaluation_model(opts), do: Model.resolve(Keyword.get(opts, :system_one_model)).name

  @doc """
  Measures `test_case` with `metric`, plus `opts` (e.g. `:verbose_mode`).
  Same as `measure/2` with the metric's fields as options.
  """
  @spec evaluate(t(), ConversationalTestCase.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def evaluate(%__MODULE__{} = metric, test_case, opts \\ []) do
    measure(test_case, Keyword.merge(opts, to_opts(metric)))
  end

  defp to_opts(metric) do
    metric
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> is_nil(value) and key != :threshold end)
  end

  @doc """
  Measures `test_case` with the metric configured by `opts` (see the
  moduledoc), as `c:DeepEvalEx.Metrics.BaseConversationalMetric.measure/2`
  does, always on System One.

  The test case is checked first, as deepeval's `_check_params` (see "Test
  case checks").
  """
  @impl true
  def measure(test_case, opts) when is_list(opts) do
    metric = new(opts)

    with :ok <- check_params(metric, test_case) do
      context = %Context{mode: :system_one, model: metric.system_one_model, llm?: false}

      super(
        test_case,
        Keyword.merge(opts,
          evaluation_params: metric.evaluation_params,
          questions: metric.questions,
          system_one_model: metric.system_one_model,
          system_one: context
        )
      )
    end
  end

  # deepeval's _check_params.
  defp check_params(metric, %ConversationalTestCase{} = test_case) do
    if test_case.multimodal do
      raise ArgumentError,
            "#{metric_name(metric)} evaluates text only: Jev has no image input. " <>
              "Pass a text-only ConversationalTestCase."
    end

    ConversationalTestCase.validate_params(test_case, metric.evaluation_params,
      requires_chatbot_role: :chatbot_role in metric.evaluation_params
    )
  end

  defp check_params(_metric, _test_case), do: {:error, :not_conversational_test_case}

  @doc false
  def do_measure(%ConversationalTestCase{} = test_case, opts) do
    opts
    |> Keyword.fetch!(:evaluation_params)
    |> State.multi_turn(test_case)
    |> JevEval.decide(name(opts), opts)
  end

  defp name(opts) do
    name = Keyword.fetch!(opts, :name)

    if Keyword.get(opts, :include_jev_eval_suffix, true),
      do: "#{name} [Conversational JevEval]",
      else: name
  end
end
