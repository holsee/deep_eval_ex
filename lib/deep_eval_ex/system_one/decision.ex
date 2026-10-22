defmodule DeepEvalEx.SystemOne.Decision do
  @moduledoc """
  The `:hybrid` decision points of a metric: where a metric that still
  extracts with its LLM asks a System One model for its decisions instead.
  A port of the System One helpers of deepeval 4.3.1's
  `deepeval/metrics/utils/decision.py` and of the System One section of
  `deepeval/metrics/utils/qag.py`.

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
  - `verdicts/3` - one QAG verdict per item of a
    `DeepEvalEx.SystemOne.Spec.Verdicts`, the System One branch of
    deepeval's `generate_qag_verdicts`

  `verdict_from_probability/2` thresholds a P(yes) into a QAG vocabulary,
  and `split_sentences/1` splits a text into the sentences a metric asks
  verdicts about when its LLM prompt would split and judge in one step.

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
  one request through `DeepEvalEx.SystemOne.decide/3`; `verdicts/3` asks one
  question per item in one request, and none for no items. The request's usage
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
  alias DeepEvalEx.Metrics.QAG
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.{Answers, Context, Error, Ledger, Model, Question, Spec}
  alias Jason.OrderedObject

  # The key of a decision's one question.
  @key "verdict"

  # deepeval's SYSTEM_ONE_YES_THRESHOLD and SYSTEM_ONE_BORDERLINE_LOW/HIGH.
  @yes_threshold 0.5
  @borderline_low 0.35
  @borderline_high 0.65

  # deepeval's _SENTENCE_END.
  @sentence_end ~r/(?<=[.!?])\s+/u

  @doc """
  P(yes) of a yes/no decision, from `0.0` to `1.0`, or `:llm`. Asks one
  Noul with the spec's instructions.
  """
  @spec probability(Spec.Binary.t() | nil, keyword()) :: {:ok, number()} | :llm
  def probability(spec, opts) do
    with {:ok, answers} <- ask(spec, opts, :nouls),
         %Answers.Noul{probability: probability} <- Map.fetch!(answers, @key),
         do: {:ok, probability}
  end

  @doc """
  The answer to a decision between the spec's options (the chosen option,
  every option's probability and the confidence), or `:llm`. Asks one
  Choice whose options have no descriptions.
  """
  @spec choice(Spec.Choice.t() | nil, keyword()) :: {:ok, Answers.Choice.t()} | :llm
  def choice(spec, opts) do
    with {:ok, answers} <- ask(spec, opts, :choices), do: {:ok, Map.fetch!(answers, @key)}
  end

  @doc """
  A graded decision on `0..1` (the chosen level index over the highest,
  `DeepEvalEx.SystemOne.Answers.normalized/1`), or `:llm`. Asks one Score
  over the spec's levels.
  """
  @spec score(Spec.Score.t() | nil, keyword()) :: {:ok, float()} | :llm
  def score(spec, opts) do
    with {:ok, answers} <- ask(spec, opts, :scores),
         %Answers.Score{} = answer <- Map.fetch!(answers, @key),
         do: {:ok, Answers.normalized(answer)}
  end

  @doc """
  One QAG verdict per item of the spec, in order, or `:llm`: the System One
  branch of deepeval's `generate_qag_verdicts`.

  Asks one Noul per item, keyed `"<item_key>_<i>"`, whose instructions are
  `{item_key: item, "question": instructions}`, about the spec's state plus
  `"<item_key>s"`: the items (replacing a state key of that name in place).
  No items is `{:ok, []}`, with no request. Each P(yes) becomes a verdict in
  `allowed` (`verdict_from_probability/2`), and each verdict is
  `%{verdict: verdict, reason: "P(yes)=0.91"}` unless the spec's
  `build_verdict` builds it.

  An item with no answer raises deepeval's "System One model returned no
  answer for claim 1." `DeepEvalEx.DeepEvalError`, never a fallback.

  ## Examples

      spec = %DeepEvalEx.SystemOne.Spec.Verdicts{
        instructions: "Is `claim` supported by the facts in `retrieval_context`?",
        items: claims,
        item_key: "claim",
        state: [retrieval_context: truths]
      }

      case DeepEvalEx.SystemOne.Decision.verdicts(spec, QAG.yes_no_borderline(), opts) do
        {:ok, verdicts} -> {:ok, verdicts}
        :llm -> llm_verdicts(claims, truths, opts)
      end
  """
  @spec verdicts(Spec.Verdicts.t() | nil, [QAG.verdict()], keyword()) :: {:ok, [term()]} | :llm
  def verdicts(spec, allowed, opts) when is_list(allowed) do
    with {:ok, answers} <- ask(spec, opts, :nouls) do
      %Spec.Verdicts{items: items, item_key: item_key, build_verdict: build} = spec

      verdicts =
        for {item, i} <- Enum.with_index(items) do
          probability =
            case Map.fetch(answers, "#{item_key}_#{i}") do
              {:ok, %Answers.Noul{probability: probability}} ->
                probability

              :error ->
                raise DeepEvalError,
                  message: "System One model returned no answer for #{item_key} #{i}."
            end

          verdict = verdict_from_probability(probability, allowed)

          if build,
            do: build.(item, verdict, probability),
            else: %{verdict: verdict, reason: "P(yes)=#{Python.format_fixed(probability, 2)}"}
        end

      {:ok, verdicts}
    end
  end

  @doc """
  Thresholds a P(yes) into a verdict of `allowed`, deepeval's
  `verdict_from_probability`. With `:borderline` in `allowed`, above `0.65`
  is `:yes`, below `0.35` is `:no` and anything between is `:borderline`;
  without it, `0.5` and above is `:yes`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Decision.verdict_from_probability(0.5, [:yes, :no, :borderline])
      :borderline

      iex> DeepEvalEx.SystemOne.Decision.verdict_from_probability(0.5, [:yes, :no])
      :yes
  """
  @spec verdict_from_probability(number(), [QAG.verdict()]) :: QAG.verdict()
  def verdict_from_probability(probability, allowed \\ QAG.yes_no())
      when is_number(probability) and is_list(allowed) do
    cond do
      :borderline not in allowed -> if probability >= @yes_threshold, do: :yes, else: :no
      probability > @borderline_high -> :yes
      probability < @borderline_low -> :no
      true -> :borderline
    end
  end

  @doc """
  Splits a text into sentences after `.`, `!` or `?` and whitespace,
  deepeval's `split_sentences`: each sentence trimmed, empty ones dropped.
  Under `:hybrid` a metric whose LLM prompt splits and judges in one step
  splits with this instead, so the System One model judges each sentence.

  ## Examples

      iex> DeepEvalEx.SystemOne.Decision.split_sentences("Pi is 3.14. It never ends!  Right?")
      ["Pi is 3.14.", "It never ends!", "Right?"]
  """
  @spec split_sentences(String.t() | nil) :: [String.t()]
  def split_sentences(text) do
    for sentence <- Regex.split(@sentence_end, text || ""),
        sentence = String.trim(sentence),
        sentence != "",
        do: sentence
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

  # The answers of one kind to the spec's questions, {:ok, %{key => answer}},
  # or :llm. deepeval's _system_one_active, then its request, booking and
  # failure handling.
  defp ask(spec, opts, kind) do
    if active?(spec, opts), do: call(spec, opts, kind), else: :llm
  end

  defp call(%Spec.Verdicts{items: []}, _opts, _kind), do: {:ok, %{}}

  defp call(spec, opts, kind) do
    %Context{mode: mode, model: model} = context(opts)
    {state, questions} = request(spec)

    decided =
      SystemOne.decide(state, questions,
        system_one_model: model,
        mode: mode,
        metrics: List.wrap(Keyword.get(opts, :metric_name))
      )

    case decided do
      {:ok, answers, usage} ->
        answers = Map.fetch!(answers, kind)
        book(usage)
        Ledger.record_confidence(answers)
        {:ok, answers}

      {:error, error} ->
        handle_failure(error, opts)
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
    do: {state(state), [{@key, %Question.Noul{instructions: instructions}}]}

  defp request(%Spec.Choice{instructions: instructions, options: options, state: state}),
    do:
      {state(state),
       [
         {@key,
          %Question.Choice{instructions: instructions, options: Enum.map(options, &{&1, nil})}}
       ]}

  defp request(%Spec.Score{instructions: instructions, levels: levels, state: state}),
    do: {state(state), [{@key, %Question.Score{instructions: instructions, levels: levels}}]}

  # deepeval's _system_one_request.
  defp request(%Spec.Verdicts{item_key: item_key} = spec) do
    item_key = to_string(item_key)
    {yes, no} = spec.criteria || {nil, nil}

    questions =
      for {item, i} <- Enum.with_index(spec.items) do
        instructions = OrderedObject.new([{item_key, item}, {"question", spec.instructions}])
        {"#{item_key}_#{i}", %Question.Noul{instructions: instructions, true: yes, false: no}}
      end

    {put_state(state(spec.state), item_key <> "s", spec.items), questions}
  end

  defp state(state) when is_map(state), do: state

  defp state(pairs) when is_list(pairs),
    do: OrderedObject.new(for {key, value} <- pairs, do: {to_string(key), value})

  # Python's {**state, key: value}: an existing key keeps its place.
  defp put_state(%OrderedObject{values: values}, key, value) do
    values =
      if List.keymember?(values, key, 0),
        do: List.keyreplace(values, key, 0, {key, value}),
        else: values ++ [{key, value}]

    OrderedObject.new(values)
  end

  defp put_state(state, key, value) when is_map(state), do: Map.put(state, key, value)

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
