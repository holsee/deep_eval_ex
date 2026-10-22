defmodule DeepEvalEx.SystemOne.Decision do
  @moduledoc """
  The `:hybrid` decision points of a metric: where a metric that still
  extracts with its LLM asks a System One model for one decision instead.
  A port of the System One helpers of deepeval 4.3.1's
  `deepeval/metrics/utils/decision.py`.

  Each helper takes a `DeepEvalEx.SystemOne.Spec` (or `nil`, for a
  decision with no System One form) and the options `do_measure/2` got,
  and returns `{:ok, value}` when the System One model decided, or `:llm`
  when the metric should run its unchanged LLM branch:

  - `probability/2` - P(yes) of a `DeepEvalEx.SystemOne.Spec.Binary`,
    deepeval's `system_one_probability`
  - `choice/2` - the `DeepEvalEx.SystemOne.Answers.Choice` of a
    `DeepEvalEx.SystemOne.Spec.Choice`
  - `score/2` - a `DeepEvalEx.SystemOne.Spec.Score` on `0..1`, deepeval's
    `system_one_score`

  `format_reason/3` writes the reason that stands in for the LLM's when
  the model made a decision the LLM would have explained.

  A G-Eval rubric score is LLM-as-a-judge by definition and has no System
  One decision point; `DeepEvalEx.Metrics.GEval` never asks one.

  ## When System One decides

  A helper asks the System One model only when the spec is not `nil`, the
  metric's eval mode (`opts[:system_one]`, a `DeepEvalEx.SystemOne.Context`)
  uses System One, and no permanent failure disabled System One earlier in
  the measure (`DeepEvalEx.SystemOne.Ledger.disabled?/0`). Without a
  context it is `:llm`. A mode that uses System One with no model raises
  `DeepEvalEx.DeepEvalError`, as deepeval does.

  A decision asks one question keyed `"verdict"` about the spec's state, in
  one request through `DeepEvalEx.SystemOne.decide/3`. The request's usage
  is booked in the measure's usage scope and its confidence folded into the
  measure's (the minimum, see `DeepEvalEx.SystemOne.Ledger`). As in
  deepeval, these helpers do not pre-check the context budget: a request
  too large for the model fails like any other, and the failure is handled
  as below.

  ## Failures

  A failed request is handled by `handle_failure/2`: under `:hybrid` the
  decision falls back to the LLM (`:llm`) and the measure's
  `system_one_fallback_reason` says why; a permanent failure also keeps the
  rest of the measure on the LLM. A missing answer is a bug and raises
  `KeyError`, never a fallback.

  ## Options

  - `:system_one` - the metric's resolved `DeepEvalEx.SystemOne.Context`,
    which `c:DeepEvalEx.Metrics.BaseMetric.measure/2` sets
  - `:metric_name` - the metric's name, for error messages and telemetry

  ## Examples

      spec = %DeepEvalEx.SystemOne.Spec.Score{
        instructions: "How well do the tools in `tools_called` match what `input` asks for?",
        levels: ["Misaligned", "Poor selection", "Mixed selection", "Mostly appropriate",
                 "Fully appropriate"],
        state: [input: test_case.input, tools_called: tools_called]
      }

      case DeepEvalEx.SystemOne.Decision.score(spec, opts) do
        {:ok, score} ->
          {score, DeepEvalEx.SystemOne.Decision.format_reason(opts, "tool selection", score)}

        :llm ->
          llm_tool_selection(test_case, opts)
      end
  """

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError, SystemOne}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.{Answers, Context, Error, Ledger, Model, Question, Spec}
  alias Jason.OrderedObject

  # The key of a decision's one question.
  @key "verdict"

  @doc """
  P(yes) of a yes/no decision, from `0.0` to `1.0`, or `:llm`. Asks one
  Noul with the spec's instructions.
  """
  @spec probability(Spec.Binary.t() | nil, keyword()) :: {:ok, number()} | :llm
  def probability(spec, opts) do
    with {:ok, %Answers.Noul{probability: probability}} <- ask(spec, opts, :nouls),
         do: {:ok, probability}
  end

  @doc """
  The answer to a decision between the spec's options (the chosen option,
  every option's probability and the confidence), or `:llm`. Asks one
  Choice whose options have no descriptions.
  """
  @spec choice(Spec.Choice.t() | nil, keyword()) :: {:ok, Answers.Choice.t()} | :llm
  def choice(spec, opts), do: ask(spec, opts, :choices)

  @doc """
  A graded decision on `0..1` (the chosen level index over the highest,
  `DeepEvalEx.SystemOne.Answers.normalized/1`), or `:llm`. Asks one Score
  over the spec's levels.
  """
  @spec score(Spec.Score.t() | nil, keyword()) :: {:ok, float()} | :llm
  def score(spec, opts) do
    with {:ok, %Answers.Score{} = answer} <- ask(spec, opts, :scores),
         do: {:ok, Answers.normalized(answer)}
  end

  @doc """
  Decides what a failed System One request means for the metric, deepeval's
  `handle_system_one_failure`.

  - under `:hybrid` the failure is noted in the measure's ledger
    (`DeepEvalEx.SystemOne.Error.describe/1`, joined with `"; "`) and the
    decision falls back to the LLM: it returns `:llm`. A permanent failure
    (`permanent?: true`, or a `DeepEvalEx.DeepEvalError` about a missing API
    key or TypeSafe SDK) also disables System One for the rest of the
    measure
  - in any other mode it raises: a context overflow
    (`reason: :context_limit`) as `context_limit_error/2`, anything else
    unchanged

  Only System One errors are handled (`DeepEvalEx.SystemOne.Error`,
  `DeepEvalEx.DeepEvalError` and `DeepEvalEx.ContextWindowExceededError`);
  any other exception is raised in every mode.
  """
  @spec handle_failure(Exception.t(), keyword()) :: :llm
  def handle_failure(error, opts) when is_exception(error) do
    if not system_one_error?(error), do: raise(error)

    case mode(opts) do
      :hybrid ->
        Ledger.note_fallback(Error.describe(error))
        if permanent?(error), do: Ledger.disable()
        :llm

      _mode ->
        case error do
          %Error{reason: :context_limit} ->
            raise context_limit_error(Keyword.get(opts, :metric_name), error)

          _ ->
            raise error
        end
    end
  end

  @doc """
  The error a metric under `:system_one` raises when its test case does not
  fit in the System One model's context, deepeval's `context_limit_error`:
  the model cannot judge it, the LLM can.

  ## Examples

      iex> error = %DeepEvalEx.SystemOne.Error{reason: :context_limit, message: "Too large."}
      iex> DeepEvalEx.SystemOne.Decision.context_limit_error("Faithfulness", error).message
      "Faithfulness could not run on System One: Too large. This test case is too large for Jev to judge in one request. Switch this metric back to the LLM with `eval_mode=\\"llm\\"` or `deepeval set-eval-mode llm`."
  """
  @spec context_limit_error(String.t() | nil, Exception.t()) :: ContextWindowExceededError.t()
  def context_limit_error(metric_name, error) when is_exception(error) do
    %ContextWindowExceededError{
      message:
        "#{metric_name || "The metric"} could not run on System One: " <>
          "#{Exception.message(error)} This test case is too large for Jev to judge " <>
          "in one request. Switch this metric back to the LLM with " <>
          "`eval_mode=\"llm\"` or `deepeval set-eval-mode llm`."
    }
  end

  @doc """
  The reason that stands in for the LLM's when the System One model made a
  decision the LLM would have explained in the same response, deepeval's
  `format_decision_reason`: the model's name, `what` was decided, its
  `value` and the measure's confidence so far, to two decimals.

  ## Examples

      iex> DeepEvalEx.SystemOne.Decision.format_reason([], "score", 0.5)
      "Decided by System One: score 0.50."
  """
  @spec format_reason(keyword(), String.t(), number()) :: String.t()
  def format_reason(opts, what, value) when is_binary(what) and is_number(value) do
    name =
      case context(opts) do
        %Context{model: %Model{name: name}} -> name
        _ -> "System One"
      end

    text = "Decided by #{name}: #{what} #{Python.format_fixed(value, 2)}"

    case Ledger.confidence() do
      nil -> text <> "."
      confidence -> text <> ", confidence #{Python.format_fixed(confidence, 2)}."
    end
  end

  defp ask(spec, opts, kind) do
    if active?(spec, opts) do
      %Context{mode: mode, model: model} = context(opts)
      {state, question} = request(spec)

      decided =
        SystemOne.decide(state, [{@key, question}],
          system_one_model: model,
          mode: mode,
          metrics: List.wrap(Keyword.get(opts, :metric_name))
        )

      case decided do
        {:ok, answers, usage} ->
          answers = Map.fetch!(answers, kind)
          book(usage)
          Ledger.record_confidence(answers)
          {:ok, Map.fetch!(answers, @key)}

        {:error, error} ->
          handle_failure(error, opts)
      end
    else
      :llm
    end
  end

  # deepeval's _system_one_active.
  defp active?(nil, _opts), do: false

  defp active?(_spec, opts) do
    case context(opts) do
      %Context{mode: :llm} ->
        false

      %Context{mode: mode, model: model} ->
        cond do
          Ledger.disabled?() -> false
          model == nil -> raise DeepEvalError, message: not_configured(mode, opts)
          true -> true
        end

      nil ->
        false
    end
  end

  defp not_configured(mode, opts) do
    "DEEPEVAL_EVAL_MODE=#{mode} routes decisions to a System One model, but " <>
      "#{Keyword.get(opts, :metric_name) || "the metric"} has none configured. " <>
      "Set TYPESAFE_API_KEY or switch back with `deepeval set-eval-mode llm`."
  end

  defp request(%Spec.Binary{instructions: instructions, state: state}),
    do: {state(state), %Question.Noul{instructions: instructions}}

  defp request(%Spec.Choice{instructions: instructions, options: options, state: state}),
    do:
      {state(state),
       %Question.Choice{instructions: instructions, options: Enum.map(options, &{&1, nil})}}

  defp request(%Spec.Score{instructions: instructions, levels: levels, state: state}),
    do: {state(state), %Question.Score{instructions: instructions, levels: levels}}

  defp state(state) when is_map(state), do: state

  defp state(pairs) when is_list(pairs),
    do: OrderedObject.new(for {key, value} <- pairs, do: {to_string(key), value})

  # An unpriced request (nil) voids the measure's summed cost, as deepeval's
  # _accrue_cost(None).
  defp book(nil), do: Usage.record(%Usage{source: :system_one})
  defp book(%Usage{} = usage), do: Usage.record(usage)

  defp context(opts) do
    case Keyword.get(opts, :system_one) do
      %Context{} = context -> context
      _ -> nil
    end
  end

  defp mode(opts) do
    case context(opts) do
      %Context{mode: mode} -> mode
      nil -> :llm
    end
  end

  defp system_one_error?(error) do
    is_struct(error, Error) or is_struct(error, DeepEvalError) or
      is_struct(error, ContextWindowExceededError)
  end

  # deepeval's _is_permanent: failures that will not get better on the next
  # request of the measure (no SDK, no key, a rejected key).
  defp permanent?(%Error{permanent?: true}), do: true

  defp permanent?(%module{message: message})
       when module in [DeepEvalError, ContextWindowExceededError] do
    text = String.downcase(message || "")
    Enum.any?(["api key", "typesafe_sdk", "typesafe-sdk"], &String.contains?(text, &1))
  end

  defp permanent?(_error), do: false
end
