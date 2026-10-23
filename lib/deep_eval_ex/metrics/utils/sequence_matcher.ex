# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from CPython's Lib/difflib.py (SequenceMatcher), as deepeval's
# AgentLoopDetectionMetric uses it.

defmodule DeepEvalEx.Metrics.Utils.SequenceMatcher do
  @moduledoc """
  Python's `difflib.SequenceMatcher`, for `ratio/3` and `matching_blocks/3`:
  deepeval 4.3.1's `AgentLoopDetectionMetric` compares consecutive LLM
  outputs with `SequenceMatcher(None, a, b).ratio()`, so a faithful port
  is what makes its stagnation scores match.

  The algorithm is difflib's (Ratcliff/Obershelp "gestalt pattern
  matching"): find the longest contiguous matching block, the leftmost in
  `a` and then in `b` on ties, and recurse on the pieces to its left and
  right. `ratio/3` is `2.0 * M / T`, where `M` is the number of matched
  elements and `T` the total length of both sequences, and `1.0` when both
  are empty.

  Strings are compared code point by code point, as Python's `str`
  indexes them (not by byte or grapheme); lists element by element.

  ## Options

  - `:isjunk` - a one-arity predicate marking elements of `b` as junk
    (difflib's `isjunk`): a match never starts or ends inside junk,
    although junk next to a match is absorbed into it (default: `nil`, no
    junk)
  - `:autojunk` - difflib's popularity heuristic: when `b` has 200
    elements or more, every element occurring more than `div(n, 100) + 1`
    times is treated as popular and never starts a match (default: `true`)

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.SequenceMatcher.ratio("abcd", "bcde")
      0.75

      iex> DeepEvalEx.Metrics.Utils.SequenceMatcher.matching_blocks("abxcd", "abcd")
      [{0, 0, 2}, {3, 2, 2}, {5, 4, 0}]
  """

  @typedoc "A string (compared by code point) or a list of elements."
  @type sequence :: String.t() | list()

  @typedoc """
  A matching block, difflib's `Match(a, b, size)`: `a[i:i+n] == b[j:j+n]`.
  """
  @type block :: {i :: non_neg_integer(), j :: non_neg_integer(), n :: non_neg_integer()}

  @doc """
  A measure of the sequences' similarity in `[0.0, 1.0]`, difflib's
  `SequenceMatcher(isjunk, a, b, autojunk).ratio()`. See the moduledoc
  for the options.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.SequenceMatcher.ratio("", "")
      1.0

      iex> DeepEvalEx.Metrics.Utils.SequenceMatcher.ratio(" abcd", "abcd abcd", isjunk: &(&1 == ?\\s))
      0.5714285714285714
  """
  @spec ratio(sequence(), sequence(), keyword()) :: float()
  def ratio(a, b, opts \\ []) do
    a = to_tuple(a)
    b = to_tuple(b)
    matches = a |> blocks(b, opts) |> Enum.reduce(0, fn {_i, _j, n}, acc -> acc + n end)

    # difflib's _calculate_ratio.
    case tuple_size(a) + tuple_size(b) do
      0 -> 1.0
      length -> 2.0 * matches / length
    end
  end

  @doc """
  The matching blocks of `a` and `b`, difflib's `get_matching_blocks()`:
  `{i, j, n}` triples increasing in `i` and `j`, adjacent blocks merged,
  ending with the dummy `{len(a), len(b), 0}`.
  """
  @spec matching_blocks(sequence(), sequence(), keyword()) :: [block()]
  def matching_blocks(a, b, opts \\ []) do
    a = to_tuple(a)
    b = to_tuple(b)

    a
    |> blocks(b, opts)
    |> Enum.sort()
    |> collapse()
    |> Kernel.++([{tuple_size(a), tuple_size(b), 0}])
  end

  defp to_tuple(string) when is_binary(string),
    do: string |> String.to_charlist() |> List.to_tuple()

  defp to_tuple(list) when is_list(list), do: List.to_tuple(list)

  # The matching blocks, unsorted and unmerged: get_matching_blocks's queue,
  # whose processing order does not change the blocks it finds.
  defp blocks(a, b, opts) do
    matcher = chain_b(b, Keyword.get(opts, :isjunk), Keyword.get(opts, :autojunk, true))
    matcher = Map.put(matcher, :a, a)
    find_blocks(matcher, [{0, tuple_size(a), 0, tuple_size(b)}], [])
  end

  defp find_blocks(_matcher, [], found), do: found

  defp find_blocks(matcher, [{alo, ahi, blo, bhi} | queue], found) do
    case find_longest_match(matcher, alo, ahi, blo, bhi) do
      {_i, _j, 0} ->
        find_blocks(matcher, queue, found)

      {i, j, k} = block ->
        queue = if alo < i and blo < j, do: [{alo, i, blo, j} | queue], else: queue

        queue =
          if i + k < ahi and j + k < bhi, do: [{i + k, ahi, j + k, bhi} | queue], else: queue

        find_blocks(matcher, queue, [block | found])
    end
  end

  # difflib's __chain_b: b2j maps each element of b to its indices,
  # ascending, without junk and popular elements.
  defp chain_b(b, isjunk, autojunk) do
    n = tuple_size(b)

    b2j =
      b
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {elt, i}, acc -> Map.update(acc, elt, [i], &[i | &1]) end)
      |> Map.new(fn {elt, indices} -> {elt, Enum.reverse(indices)} end)

    junk =
      if isjunk,
        do: for({elt, _indices} <- b2j, isjunk.(elt), into: MapSet.new(), do: elt),
        else: MapSet.new()

    b2j = Map.drop(b2j, MapSet.to_list(junk))

    popular =
      if autojunk and n >= 200 do
        ntest = div(n, 100) + 1
        for {elt, indices} <- b2j, length(indices) > ntest, do: elt
      else
        []
      end

    %{b: b, b2j: Map.drop(b2j, popular), junk: junk}
  end

  # difflib's find_longest_match: the longest block of a[alo:ahi] and
  # b[blo:bhi] free of junk, the earliest in a and then in b, extended
  # first by equal non-junk elements on both sides (popular ones included),
  # then by equal junk.
  defp find_longest_match(%{a: a, b: b, b2j: b2j, junk: junk}, alo, ahi, blo, bhi) do
    {best, _j2len} =
      Enum.reduce(alo..(ahi - 1)//1, {{alo, blo, 0}, %{}}, fn i, {best, j2len} ->
        b2j |> Map.get(elem(a, i), []) |> scan_row(i, blo, bhi, j2len, best)
      end)

    junk? = &MapSet.member?(junk, &1)
    bounds = {a, b, alo, ahi, blo, bhi}

    best
    |> extend(bounds, &(not junk?.(&1)))
    |> extend(bounds, junk?)
  end

  # One row of find_longest_match's loop: a[i] against its indices in b
  # within [blo, bhi), extending the runs ending at j - 1 (j2len) into the
  # row's runs (newj2len). Returns the best block and the row's runs.
  defp scan_row(indices, i, blo, bhi, j2len, best) do
    Enum.reduce_while(indices, {best, %{}}, fn
      j, acc when j < blo ->
        {:cont, acc}

      j, acc when j >= bhi ->
        {:halt, acc}

      j, {{_besti, _bestj, bestsize} = best, new_j2len} ->
        k = Map.get(j2len, j - 1, 0) + 1
        best = if k > bestsize, do: {i - k + 1, j - k + 1, k}, else: best
        {:cont, {best, Map.put(new_j2len, j, k)}}
    end)
  end

  # Grows a block backwards, then forwards, over equal elements of b that
  # satisfy `keep?`.
  defp extend(block, bounds, keep?),
    do: block |> extend_back(bounds, keep?) |> extend_forward(bounds, keep?)

  defp extend_back({i, j, k} = block, {a, b, alo, _ahi, blo, _bhi} = bounds, keep?) do
    if i > alo and j > blo and keep?.(elem(b, j - 1)) and elem(a, i - 1) == elem(b, j - 1),
      do: extend_back({i - 1, j - 1, k + 1}, bounds, keep?),
      else: block
  end

  defp extend_forward({i, j, k} = block, {a, b, _alo, ahi, _blo, bhi} = bounds, keep?) do
    if i + k < ahi and j + k < bhi and keep?.(elem(b, j + k)) and elem(a, i + k) == elem(b, j + k),
      do: extend_forward({i, j, k + 1}, bounds, keep?),
      else: block
  end

  # Merges adjacent blocks, as get_matching_blocks does after sorting.
  defp collapse([{i1, j1, k1}, {i2, j2, k2} | rest]) when i1 + k1 == i2 and j1 + k1 == j2,
    do: collapse([{i1, j1, k1 + k2} | rest])

  defp collapse([block | rest]), do: [block | collapse(rest)]
  defp collapse([]), do: []
end
