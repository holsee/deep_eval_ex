# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/g_eval/utils.py (Rubric,
# validate_and_sort_rubrics, get_score_range)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.GEval.Rubric do
  @moduledoc """
  One entry of a `DeepEvalEx.Metrics.GEval` rubric, as deepeval 4.3.1's
  `Rubric`: the outcome a judge should expect for scores in a range.

  - `:score_range` - `{start, end}`, integers from 0 to 10 inclusive, with
    `start <= end`; `{5, 5}` is the single score 5
  - `:expected_outcome` - what a response scored in the range looks like

  A GEval rubric is a list of entries whose ranges do not overlap (not even
  at an end, see `validate_and_sort/1`); together they set the score range
  the judge scores in (`score_range/1`).

  ## Examples

      iex> DeepEvalEx.Metrics.GEval.Rubric.new!(score_range: {0, 3}, expected_outcome: "Wrong.")
      %DeepEvalEx.Metrics.GEval.Rubric{score_range: {0, 3}, expected_outcome: "Wrong."}
  """

  @enforce_keys [:score_range, :expected_outcome]
  defstruct [:score_range, :expected_outcome]

  @type t :: %__MODULE__{
          score_range: {0..10, 0..10},
          expected_outcome: String.t()
        }

  @doc """
  Builds a rubric entry from a keyword list or map with `:score_range` (a
  `{start, end}` tuple or a two-element list) and `:expected_outcome`.

  Returns `{:error, message}` for a range deepeval's `Rubric` rejects, with
  deepeval's message.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{score_range: range, expected_outcome: outcome}) when is_binary(outcome) do
    with {:ok, range} <- validate_score_range(range) do
      {:ok, %__MODULE__{score_range: range, expected_outcome: outcome}}
    end
  end

  def new(attrs) when is_map(attrs) do
    {:error,
     "Rubric requires a :score_range and an :expected_outcome string, got: #{inspect(attrs)}"}
  end

  @doc """
  As `new/1`, raising `ArgumentError` with the error's message.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, rubric} -> rubric
      {:error, message} -> raise ArgumentError, message
    end
  end

  # deepeval's Rubric.validate_score_range.
  defp validate_score_range([start, stop]), do: validate_score_range({start, stop})

  defp validate_score_range({start, stop}) when is_integer(start) and is_integer(stop) do
    cond do
      start not in 0..10 or stop not in 0..10 ->
        {:error, "Both Rubric's 'score_range' values must be between 0 and 10 inclusive."}

      start > stop ->
        {:error, "Rubric's 'score_range' start must be less than or equal to end."}

      true ->
        {:ok, {start, stop}}
    end
  end

  defp validate_score_range(range) do
    {:error, "Rubric's 'score_range' must be a pair of integers, got: #{inspect(range)}"}
  end

  @doc """
  Sorts `rubrics` by the start of their range, as deepeval's
  `validate_and_sort_rubrics`; `nil` or an empty list is no rubric (`nil`).

  Raises `ArgumentError` with deepeval's message when two ranges overlap,
  sharing an end included, naming the first overlapping pair in sorted
  order.

  ## Examples

      iex> alias DeepEvalEx.Metrics.GEval.Rubric
      iex> [Rubric.new!(score_range: {5, 10}, expected_outcome: "Right."),
      ...>  Rubric.new!(score_range: {0, 4}, expected_outcome: "Wrong.")]
      ...> |> Rubric.validate_and_sort()
      ...> |> Enum.map(& &1.score_range)
      [{0, 4}, {5, 10}]
  """
  @spec validate_and_sort([t()] | nil) :: [t()] | nil
  def validate_and_sort(nil), do: nil
  def validate_and_sort([]), do: nil

  def validate_and_sort(rubrics) when is_list(rubrics) do
    sorted = Enum.sort_by(rubrics, fn %__MODULE__{score_range: {start, _}} -> start end)

    for {a, i} <- Enum.with_index(sorted), b <- Enum.drop(sorted, i + 1) do
      {_a_start, a_end} = a.score_range
      {b_start, _b_end} = b.score_range

      if a_end >= b_start do
        raise ArgumentError,
              "Overlapping score ranges: #{python_tuple(a.score_range)} and #{python_tuple(b.score_range)}"
      end
    end

    sorted
  end

  @doc """
  Returns the score range of rubrics sorted by `validate_and_sort/1`, as
  deepeval's `get_score_range`: from the first range's start to the last
  range's end, `{0, 10}` without a rubric.

  ## Examples

      iex> DeepEvalEx.Metrics.GEval.Rubric.score_range(nil)
      {0, 10}
  """
  @spec score_range([t()] | nil) :: {integer(), integer()}
  def score_range(nil), do: {0, 10}

  def score_range([%__MODULE__{score_range: {start, _}} | _] = rubrics) do
    {_, stop} = List.last(rubrics).score_range
    {start, stop}
  end

  @doc """
  Formats sorted rubrics for GEval's prompt and verbose logs, as deepeval's
  `format_rubrics`: one `"<start>-<end>: <expected outcome>"` line per
  entry, `"<score>: <expected outcome>"` for a single score. `nil` stays
  `nil`.

  ## Examples

      iex> alias DeepEvalEx.Metrics.GEval.Rubric
      iex> Rubric.format([Rubric.new!(score_range: {0, 3}, expected_outcome: "Wrong."),
      ...>                Rubric.new!(score_range: {5, 5}, expected_outcome: "Right.")])
      "0-3: Wrong.\\n5: Right."
  """
  @spec format([t()] | nil) :: String.t() | nil
  def format(nil), do: nil

  def format(rubrics) when is_list(rubrics) do
    Enum.map_join(rubrics, "\n", fn
      %__MODULE__{score_range: {score, score}, expected_outcome: outcome} ->
        "#{score}: #{outcome}"

      %__MODULE__{score_range: {start, stop}, expected_outcome: outcome} ->
        "#{start}-#{stop}: #{outcome}"
    end)
  end

  defp python_tuple({start, stop}), do: "(#{start}, #{stop})"
end
