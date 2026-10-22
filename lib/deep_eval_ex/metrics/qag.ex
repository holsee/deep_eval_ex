# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/utils/qag.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.QAG do
  @moduledoc """
  Shared QAG (question-answer generation) verdict handling.

  Every yes/no-style metric follows the same loop: ask the judge to classify
  a list of items, get back `%{"verdicts" => [%{"verdict" => ..., "reason" =>
  ...}]}`, and score the fraction that land in a "passing" bucket. This module
  is the single implementation of that loop, as deepeval 4.3.1's
  `metrics/utils/qag.py` is. Metrics only choose:

  - the vocabulary: `yes_no/0` or `yes_no_borderline/0`
  - the polarity: which verdicts count as passing when scoring

  ## Verdicts

  Verdicts are the atoms `:yes`, `:no` and `:borderline`. Judges that saw an
  older prompt may reply `idk`, which is read as `:borderline`. A reply
  outside the metric's vocabulary is dropped rather than miscounted.

  ## Scores

  `score_qag_verdicts/2` keeps deepeval's number types, because they show in
  `measure()` results: a fraction is a float, while the empty-list score and
  the `strict_mode` clamp are the integers `1` (or the metric's
  `:empty_score`) and `0`.
  """

  @typedoc "A normalised QAG verdict."
  @type verdict :: :yes | :no | :borderline

  @typedoc "A parsed verdict, as metrics keep it in their result's metadata."
  @type parsed_verdict :: %{verdict: verdict(), reason: String.t() | nil}

  @verdicts %{"yes" => :yes, "no" => :no, "borderline" => :borderline}

  # Older prompts used `idk` for the borderline bucket. Judges that saw a
  # cached or third-party copy of those prompts may still reply with it.
  @legacy_aliases %{"idk" => :borderline}

  @doc """
  The yes/no vocabulary, deepeval's `YES_NO`.
  """
  @spec yes_no() :: [verdict()]
  def yes_no, do: [:yes, :no]

  @doc """
  The yes/no/borderline vocabulary, deepeval's `YES_NO_BORDERLINE`.
  """
  @spec yes_no_borderline() :: [verdict()]
  def yes_no_borderline, do: [:yes, :no, :borderline]

  @doc """
  Coerces a judge's verdict into a verdict within `allowed`.

  Judges don't always honour a strict instruction: a model may reply
  `"No, it's off-topic"`. This strips, lower-cases and keeps only the leading
  word, maps the legacy alias `idk` to `:borderline`, and returns `nil` for
  anything still outside `allowed` so the caller can drop it from scoring.
  A verdict atom is kept when it is in `allowed`.

  ## Examples

      iex> DeepEvalEx.Metrics.QAG.normalize_qag_verdict("No, it's off-topic")
      :no

      iex> DeepEvalEx.Metrics.QAG.normalize_qag_verdict("idk", [:yes, :no, :borderline])
      :borderline

      iex> DeepEvalEx.Metrics.QAG.normalize_qag_verdict("maybe")
      nil
  """
  @spec normalize_qag_verdict(term(), [verdict()]) :: verdict() | nil
  def normalize_qag_verdict(raw, allowed \\ yes_no())

  def normalize_qag_verdict(raw, allowed) when raw in [:yes, :no, :borderline] do
    if raw in allowed, do: raw
  end

  def normalize_qag_verdict(raw, allowed) when is_binary(raw) do
    leading =
      case Regex.run(~r/\A[a-z]+/, raw |> String.trim() |> String.downcase()) do
        [word] -> word
        nil -> ""
      end

    verdict = Map.get(@legacy_aliases, leading) || Map.get(@verdicts, leading)

    if verdict in allowed, do: verdict
  end

  def normalize_qag_verdict(_raw, _allowed), do: nil

  @doc """
  Parses a judge's verdicts response into verdicts within `allowed`.

  Each item becomes `%{verdict: verdict, reason: reason}`, its verdict
  normalised with `normalize_qag_verdict/2`. Items whose verdict is outside
  `allowed` are dropped, as deepeval drops them.
  """
  @spec parse_verdicts(term(), [verdict()]) ::
          {:ok, [parsed_verdict()]} | {:error, {:invalid_verdicts_response, term()}}
  def parse_verdicts(%{"verdicts" => verdicts}, allowed) when is_list(verdicts) do
    {:ok, Enum.flat_map(verdicts, &parse_verdict(&1, allowed))}
  end

  def parse_verdicts(other, _allowed), do: {:error, {:invalid_verdicts_response, other}}

  defp parse_verdict(%{} = item, allowed) do
    case normalize_qag_verdict(item["verdict"], allowed) do
      nil -> []
      verdict -> [%{verdict: verdict, reason: item["reason"]}]
    end
  end

  defp parse_verdict(_item, _allowed), do: []

  @doc """
  Scores the fraction of `verdicts` whose `:verdict` is in `:passing`.

  `nil` entries (dropped verdicts) are ignored, and each verdict is
  normalised against `:passing`, so raw strings count too.

  ## Options

  - `:passing` - the verdicts that pass (required). It sets the polarity:
    `[:yes]` for "yes is good" metrics such as contextual recall, `[:no]` for
    "yes is bad" metrics, `[:yes, :borderline]` to let borderline items pass
  - `:empty_score` - the score of an empty list (default: the integer `1`)
  - `:strict_mode` - clamp a score below `:threshold` to the integer `0`
    (default: `false`)
  - `:threshold` - the metric's threshold; required with `strict_mode: true`

  ## Examples

      iex> verdicts = [%{verdict: :yes}, %{verdict: :no}, %{verdict: :borderline}]
      iex> DeepEvalEx.Metrics.QAG.score_qag_verdicts(verdicts, passing: [:yes, :borderline])
      0.6666666666666666

      iex> DeepEvalEx.Metrics.QAG.score_qag_verdicts([], passing: [:yes])
      1
  """
  @spec score_qag_verdicts([map() | nil], keyword()) :: number()
  def score_qag_verdicts(verdicts, opts) do
    passing = Keyword.fetch!(opts, :passing)

    case Enum.reject(verdicts, &is_nil/1) do
      [] ->
        Keyword.get(opts, :empty_score, 1)

      verdicts ->
        passed = Enum.count(verdicts, &(normalize_qag_verdict(&1.verdict, passing) != nil))
        clamp_strict(passed / length(verdicts), opts)
    end
  end

  defp clamp_strict(score, opts) do
    if Keyword.get(opts, :strict_mode, false) and score < Keyword.fetch!(opts, :threshold) do
      0
    else
      score
    end
  end
end
