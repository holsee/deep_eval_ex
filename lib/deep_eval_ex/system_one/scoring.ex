defmodule DeepEvalEx.SystemOne.Scoring do
  @moduledoc """
  How a whole-metric System One request becomes a score and a reason, with
  no LLM and no network. Ports of deepeval 4.3.1's
  `deepeval/metrics/jev_eval/utils.py` (answers to values, aggregation,
  strict mode, verbalised outcomes) and of the deterministic reasons of
  `deepeval/metrics/utils/system_one.py`.

  The score is one equation over the questions' outcomes:

      score = sum(w_i * v_i) / sum(w_i)   over applicable questions

  where `v_i` is the value each answer maps onto in `0..1`
  (`outcome/3`):

  - a Noul is valued P(true)
  - a Score is valued `score / (levels - 1)`, clamped to `0..1`
  - a Choice is valued the credit-weighted mean over its credited options;
    it does not apply when its not-applicable options collect at least
    `0.5` of the probability mass, or its credited options none

  When no question applies the score is `1.0`: there was nothing to fail.
  Under strict mode the score is `1.0` when every applicable question met
  its strict bar (`mark_strict/2`) and `0.0` otherwise.

  `reason/3` writes the deterministic reason: who decided, how confident
  the least decisive answer was, and each answer in words and numbers.
  `classification_reason/2` does the same for a classifier's label.
  """

  alias DeepEvalEx.DeepEvalError
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.SystemOne.{Answers, Question, Scored}
  alias DeepEvalEx.SystemOne.Scored.Outcome
  alias Jason.OrderedObject

  # deepeval's NOT_APPLICABLE_THRESHOLD: a Choice whose not-applicable
  # options collect at least this much mass does not apply.
  @not_applicable_threshold 0.5

  # deepeval's EMPTY_SCORE: the score when nothing applied.
  @empty_score 1.0

  # deepeval's STRICT_NOUL_THRESHOLD.
  @strict_noul_threshold 0.5

  # deepeval's _RUNNER_UP_MARGIN: a runner-up this close to the top answer
  # is named as what the answer leans towards.
  @runner_up_margin 0.15

  @doc """
  The key of the question at `index` (from `0`), deepeval's `question_key`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Scoring.question_key(2)
      "q_2"
  """
  @spec question_key(non_neg_integer()) :: String.t()
  def question_key(index) when is_integer(index) and index >= 0, do: "q_#{index}"

  @doc """
  The wire questions of a request for `questions`, keyed `"q_<i>"` in
  order, deepeval's `build_questions`.
  """
  @spec questions([Scored.t()]) :: Question.questions()
  def questions(questions) when is_list(questions) do
    for {question, i} <- Enum.with_index(questions),
        do: {question_key(i), Scored.to_question(question)}
  end

  @doc """
  The outcome of each question from the request's answers, in order,
  deepeval's `outcomes_from_answers`. See `outcome/3`.
  """
  @spec outcomes([Scored.t()], Answers.t()) :: [Outcome.t()]
  def outcomes(questions, %Answers{} = answers) when is_list(questions) do
    for {question, i} <- Enum.with_index(questions),
        do: outcome(question, answers, question_key(i))
  end

  @doc """
  How `question` was answered under `key`, deepeval's `value_from_answer`:
  its value in `0..1` (see the moduledoc), whether it applies, the
  probability of each outcome (`"true"` / `"false"`, the levels or the
  options, in the question's order) and the answer's confidence.

  Raises `DeepEvalEx.DeepEvalError` with deepeval's message when the
  answers have no answer of the question's type under `key`, e.g. "Jev
  returned no Noul answer for q_0."
  """
  @spec outcome(Scored.t(), Answers.t(), String.t()) :: Outcome.t()
  def outcome(%Scored.Noul{} = question, %Answers{} = answers, key) do
    answer = fetch_answer!(answers.nouls, key, "Noul")
    p = answer.probability * 1.0

    %Outcome{
      question: question.statement,
      type: :noul,
      weight: question.weight,
      value: p,
      applicable: true,
      probabilities: [{"true", p}, {"false", 1.0 - p}],
      confidence: Answers.confidence(answer)
    }
  end

  def outcome(%Scored.Score{levels: levels} = question, %Answers{} = answers, key) do
    answer = fetch_answer!(answers.scores, key, "Score")
    top = length(levels) - 1

    probabilities =
      for {level, p} <- answer.probabilities,
          level >= 0 and level <= top,
          do: {Enum.at(levels, level), p * 1.0}

    %Outcome{
      question: question.question,
      type: :score,
      weight: question.weight,
      value: (answer.score / top) |> max(0.0) |> min(1.0),
      applicable: true,
      probabilities: probabilities,
      confidence: answer.confidence
    }
  end

  def outcome(%Scored.Choice{} = question, %Answers{} = answers, key) do
    answer = fetch_answer!(answers.choices, key, "Choice")

    probabilities =
      for {name, _credit} <- question.options,
          do: {name, probability(answer.probabilities, name) * 1.0}

    not_applicable_mass =
      question
      |> Scored.Choice.not_applicable_options()
      |> sum(&probability(probabilities, &1))

    {applicable, value} =
      if not_applicable_mass < @not_applicable_threshold,
        do: credited_value(Scored.Choice.applicable_options(question), probabilities),
        else: {false, nil}

    %Outcome{
      question: question.question,
      type: :choice,
      weight: question.weight,
      value: value,
      applicable: applicable,
      probabilities: probabilities,
      confidence: answer.confidence
    }
  end

  defp credited_value(credits, probabilities) do
    mass = sum(credits, fn {name, _credit} -> probability(probabilities, name) end)

    if mass > 0,
      do:
        {true,
         sum(credits, fn {name, credit} -> probability(probabilities, name) * credit end) / mass},
      else: {false, nil}
  end

  defp fetch_answer!(answers, key, type) do
    case Map.fetch(answers, key) do
      {:ok, answer} -> answer
      :error -> raise DeepEvalError, message: "Jev returned no #{type} answer for #{key}."
    end
  end

  @doc """
  The weighted mean of the applicable outcomes' values, deepeval's
  `aggregate`; `1.0` when none applies.

  ## Examples

      iex> alias DeepEvalEx.SystemOne.Scored.Outcome
      iex> DeepEvalEx.SystemOne.Scoring.aggregate([
      ...>   %Outcome{weight: 2.0, value: 0.5, applicable: true},
      ...>   %Outcome{weight: 1.0, value: 1.0, applicable: true},
      ...>   %Outcome{weight: 1.0, value: nil, applicable: false}
      ...> ])
      0.6666666666666666
  """
  @spec aggregate([Outcome.t()]) :: float()
  def aggregate(outcomes) when is_list(outcomes) do
    case Enum.filter(outcomes, &(&1.applicable and &1.value != nil)) do
      [] ->
        @empty_score

      applicable ->
        sum(applicable, &(&1.weight * &1.value)) / sum(applicable, & &1.weight)
    end
  end

  @doc """
  Records on each applicable outcome whether its question met the strict
  bar (`:passed`), deepeval's `mark_strict`; an outcome that does not apply
  gets `nil`. The bar is P(true) of at least `0.5` for a Noul, the top
  level as the most likely for a Score, and a full-credit option as the
  most likely credited option for a Choice.
  """
  @spec mark_strict([Scored.t()], [Outcome.t()]) :: [Outcome.t()]
  def mark_strict(questions, outcomes) when is_list(questions) and is_list(outcomes) do
    for {question, outcome} <- Enum.zip(questions, outcomes) do
      %{outcome | passed: if(outcome.applicable, do: passes_strictly?(question, outcome))}
    end
  end

  defp passes_strictly?(%Scored.Noul{}, outcome),
    do: probability(outcome.probabilities, "true") >= @strict_noul_threshold

  defp passes_strictly?(%Scored.Score{levels: levels}, outcome),
    do: argmax(outcome.probabilities) == List.last(levels)

  defp passes_strictly?(%Scored.Choice{} = question, outcome) do
    credits = Scored.Choice.applicable_options(question)

    chosen =
      credits
      |> Enum.map(fn {name, _credit} -> {name, probability(outcome.probabilities, name)} end)
      |> argmax()

    case List.keyfind(credits, chosen, 0) do
      {_name, credit} -> credit >= 1.0
      nil -> false
    end
  end

  @doc """
  The strict score of outcomes marked by `mark_strict/2`, deepeval's
  `aggregate_strict`: `1.0` when every applicable outcome passed (or none
  applies), else `0.0`.
  """
  @spec aggregate_strict([Outcome.t()]) :: float()
  def aggregate_strict(outcomes) when is_list(outcomes) do
    if Enum.all?(outcomes, &(not &1.applicable or &1.passed)), do: @empty_score, else: 0.0
  end

  @doc """
  The least decisive outcome's confidence, deepeval's `min_confidence`, or
  `nil` when no outcome has one.
  """
  @spec min_confidence([Outcome.t()]) :: number() | nil
  def min_confidence(outcomes) when is_list(outcomes) do
    outcomes
    |> Enum.map(& &1.confidence)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  @doc """
  An outcome in words, deepeval's `verbalise_outcome`. A Noul by its
  P(true): `"clearly holds"` from `0.85`, `"likely holds"` from `0.65`,
  `"unclear"` from `0.35`, `"likely fails"` from `0.15`, else
  `"clearly fails"`. A Score or Choice by its most likely outcome, quoted,
  `leaning` the runner-up when that is within `0.15` of it; a Choice that
  does not apply is `"not applicable"`.

  ## Examples

      iex> alias DeepEvalEx.SystemOne.Scored.Outcome
      iex> DeepEvalEx.SystemOne.Scoring.verbalise(%Outcome{type: :noul, probabilities: [{"true", 0.7}, {"false", 0.3}]})
      "likely holds"
      iex> DeepEvalEx.SystemOne.Scoring.verbalise(%Outcome{type: :choice, applicable: true,
      ...>   probabilities: [{"friendly", 0.35}, {"neutral", 0.45}, {"rude", 0.2}]})
      ~s("neutral", leaning "friendly")
  """
  @spec verbalise(Outcome.t()) :: String.t()
  def verbalise(%Outcome{type: :noul, probabilities: probabilities}),
    do: probabilities |> probability("true") |> verbalise_noul()

  def verbalise(%Outcome{applicable: false}), do: "not applicable"
  def verbalise(%Outcome{probabilities: probabilities}), do: verbalise_ranked(probabilities)

  defp verbalise_noul(p) when p >= 0.85, do: "clearly holds"
  defp verbalise_noul(p) when p >= 0.65, do: "likely holds"
  defp verbalise_noul(p) when p >= 0.35, do: "unclear"
  defp verbalise_noul(p) when p >= 0.15, do: "likely fails"
  defp verbalise_noul(_p), do: "clearly fails"

  # Python's sorted(reverse=True) is stable, as Enum.sort_by/3 with :desc.
  defp verbalise_ranked(probabilities) do
    case Enum.sort_by(probabilities, &elem(&1, 1), :desc) do
      [] ->
        "no answer"

      [{top, top_p}, {runner, runner_p} | _] when top_p - runner_p <= @runner_up_margin ->
        ~s("#{top}", leaning "#{runner}")

      [{top, _top_p} | _] ->
        ~s("#{top}")
    end
  end

  @doc """
  The reason for a measure a System One model decided, deepeval's
  `format_system_one_reason`: the judge and the minimum confidence, one
  line per question, then how the score follows from them.

  ## Options

  - `:score` - the measure's score
  - `:strict_mode` - whether the score is strict (default: `false`)

  ## Examples

      iex> alias DeepEvalEx.SystemOne.Scored.Outcome
      iex> outcome = %Outcome{question: "`actual_output` answers `input`.", type: :noul, weight: 2.0,
      ...>   value: 0.88, applicable: true, probabilities: [{"true", 0.88}, {"false", 0.12}],
      ...>   confidence: 0.76}
      iex> DeepEvalEx.SystemOne.Scoring.reason("fake-jev", [outcome], score: 0.88)
      "Decided by fake-jev, minimum confidence 0.76.\\n1. `actual_output` answers `input`. -> clearly holds (P(yes)=0.88, confidence=0.76, weight=2)\\nScore: 0.88 (weighted mean of 1 applicable question)."
  """
  @spec reason(String.t() | nil, [Outcome.t()], keyword()) :: String.t()
  def reason(judge, outcomes, opts \\ []) when is_list(outcomes) do
    confidence = min_confidence(outcomes)
    score = Keyword.get(opts, :score)

    header =
      "Decided by #{judge || "System One"}" <>
        if(confidence, do: ", minimum confidence #{Python.format_fixed(confidence, 2)}", else: "") <>
        "."

    lines = for {outcome, i} <- Enum.with_index(outcomes, 1), do: outcome_line(i, outcome)
    applicable = Enum.filter(outcomes, & &1.applicable)

    summary =
      cond do
        Keyword.get(opts, :strict_mode, false) ->
          verdict =
            if Enum.all?(applicable, & &1.passed),
              do: "every applicable question passed",
              else: "at least one applicable question failed"

          "Score: #{fmt(score)} (strict mode: #{verdict})."

        applicable == [] ->
          "Score: #{fmt(score)} (no question applied to this test case)."

        true ->
          count = length(applicable)
          plural = if count == 1, do: "", else: "s"
          "Score: #{fmt(score)} (weighted mean of #{count} applicable question#{plural})."
      end

    Enum.join([header | lines] ++ [summary], "\n")
  end

  # deepeval's _outcome_line.
  defp outcome_line(index, %Outcome{} = outcome) do
    "#{index}. #{outcome.question} -> #{verbalise(outcome)} " <>
      "(#{numbers(outcome)}#{confidence_note(outcome)}#{weight_note(outcome)})" <>
      strict_note(outcome.passed)
  end

  defp numbers(%Outcome{type: :noul, probabilities: probabilities}),
    do: "P(yes)=#{fmt(probability(probabilities, "true"))}"

  defp numbers(%Outcome{type: :score, value: value}), do: "expected level=#{fmt(value)} of 1.00"
  defp numbers(%Outcome{applicable: false}), do: "not applicable"
  defp numbers(%Outcome{probabilities: probabilities}), do: top_probability(probabilities)

  defp confidence_note(%Outcome{confidence: nil}), do: ""
  defp confidence_note(%Outcome{confidence: confidence}), do: ", confidence=#{fmt(confidence)}"

  defp weight_note(%Outcome{weight: weight}) when weight == 1.0, do: ""
  defp weight_note(%Outcome{weight: weight}), do: ", weight=#{Python.format_g(weight)}"

  defp strict_note(nil), do: ""
  defp strict_note(true), do: " strict=pass"
  defp strict_note(false), do: " strict=fail"

  defp top_probability(probabilities) do
    case Enum.max_by(probabilities, &elem(&1, 1), fn -> nil end) do
      nil -> "P=n/a"
      {_name, p} -> "P=#{fmt(p)}"
    end
  end

  @doc """
  The outcomes as deepeval's verbose logs list them,
  `format_outcomes_for_logs`: per question its type, weight and text, then
  its value, whether it applies, its probabilities rounded to 3 decimals,
  its confidence and, under strict mode, whether it passed.
  """
  @spec format_for_logs([Outcome.t()]) :: String.t()
  def format_for_logs(outcomes) when is_list(outcomes) do
    outcomes
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {outcome, i} -> log_line(i, outcome) end)
  end

  defp log_line(index, %Outcome{} = outcome) do
    value = if outcome.value == nil, do: "n/a", else: Python.format_fixed(outcome.value, 3)

    probabilities =
      outcome.probabilities
      |> Enum.map(fn {name, p} -> {name, Python.round(p, 3)} end)
      |> OrderedObject.new()
      |> Python.repr()

    confidence =
      if outcome.confidence,
        do: " confidence=#{Python.format_fixed(outcome.confidence, 3)}",
        else: ""

    strict = if outcome.passed == nil, do: "", else: " strict_pass=#{Python.repr(outcome.passed)}"

    "#{index}. [#{outcome.type}, weight=#{Python.format_g(outcome.weight)}] " <>
      "#{outcome.question}\n   value=#{value} applicable=#{Python.repr(outcome.applicable)} " <>
      "probabilities=#{probabilities}#{confidence}#{strict}"
  end

  @doc """
  The reason for a label a System One model chose, deepeval's
  `format_classification_reason`: the label with its probability and the
  answer's confidence, then every other label, most likely first.

  ## Examples

      iex> answer = %DeepEvalEx.SystemOne.Answers.Choice{choice: "partial_refusal", confidence: 0.48,
      ...>   probabilities: [{"refused", 0.3}, {"partial_refusal", 0.65}, {"complied", 0.05}]}
      iex> DeepEvalEx.SystemOne.Scoring.classification_reason("fake-jev", answer)
      ~s|Decided by fake-jev. Label "partial_refusal" (P=0.65, confidence=0.48). Alternatives: refused 0.30, complied 0.05.|
  """
  @spec classification_reason(String.t() | nil, Answers.Choice.t()) :: String.t()
  def classification_reason(judge, %Answers.Choice{} = answer) do
    chosen = answer.choice

    text =
      ~s(Decided by #{judge || "System One"}. Label "#{chosen}" ) <>
        "(P=#{fmt(probability(answer.probabilities, chosen))}, " <>
        "confidence=#{fmt(answer.confidence)})."

    alternatives =
      answer.probabilities
      |> Enum.reject(fn {name, _p} -> name == chosen end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case alternatives do
      [] ->
        text

      _ ->
        text <>
          " Alternatives: " <>
          Enum.map_join(alternatives, ", ", fn {name, p} -> "#{name} #{fmt(p)}" end) <> "."
    end
  end

  # deepeval's _fmt.
  defp fmt(nil), do: "n/a"
  defp fmt(value), do: Python.format_fixed(value, 2)

  # dict.get(name, 0.0) over ordered pairs.
  defp probability(probabilities, name) do
    case List.keyfind(probabilities, name, 0) do
      {_name, p} -> p
      nil -> 0.0
    end
  end

  # deepeval's _argmax: the first most likely outcome, or nil.
  defp argmax([]), do: nil
  defp argmax(probabilities), do: probabilities |> Enum.max_by(&elem(&1, 1)) |> elem(0)

  # Python's sum(), which starts from the integer 0.
  defp sum(enumerable, fun), do: Enum.reduce(enumerable, 0, &(fun.(&1) + &2))
end
