# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/tool_correctness/tool_correctness.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ToolCorrectness do
  @moduledoc """
  Metric for evaluating tool calling correctness and tool selection quality.

  Compares the tools called by an LLM agent against a set of expected tools
  using deterministic comparison. Optionally evaluates tool selection quality
  via an LLM call when `available_tools` are provided.

  Follows the same logic as the Python `deepeval` library's ToolCorrectnessMetric.

  ## Usage

      metric = DeepEvalEx.Metrics.ToolCorrectness

      test_case = %DeepEvalEx.TestCase{
        input: "Look up Kai Nakamura",
        actual_output: "",
        tools_called: [%ToolCall{name: "oa_find_applicants"}],
        expected_tools: [%ToolCall{name: "oa_find_applicants"}]
      }

      {:ok, result} = metric.measure(test_case)
      # => %DeepEvalEx.Result{score: 1.0, success: true, ...}

  ## Options

  - `:threshold` - Score threshold for pass/fail (default: 0.5)
  - `:should_exact_match` - All-or-nothing positional matching; length mismatch → 0.0 (default: false)
  - `:should_consider_ordering` - Use weighted LCS to enforce tool call order (default: false)
  - `:evaluation_params` - Which additional ToolCall fields to compare beyond name:
    `[:input_parameters]`, `[:output]`, or `[:input_parameters, :output]` (default: `[]`)
  - `:available_tools` - List of available ToolCall structs. When provided, an LLM
    evaluates whether the right tools were selected. Final score = min(calling, selection).
  - `:strict_mode` - When true, threshold is forced to 1.0 and any score below is zeroed (default: false)
  - `:include_reason` - Whether to include reason in results (default: true)
  - `:adapter` - LLM adapter for tool selection scoring
  - `:model` - Model name for tool selection scoring

  ## Scoring Modes

  - **Default mode:** For each expected tool, find the best matching called tool (greedy).
    Score = total matches / |expected|. Extra tools do not penalise.
  - **Exact match mode:** Lists must be the same length. Each position is compared.
    Any mismatch → score 0.0. All match → score 1.0.
  - **Ordering mode:** Uses weighted Longest Common Subsequence (LCS) DP algorithm.
    Score = weighted LCS score / |expected|. Preserves relative order.
  - When `:input_parameters` is in `evaluation_params`, parameter similarity is computed
    via recursive dictionary comparison returning a fractional score (0.0–1.0).
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.Prompts.ToolCorrectness, as: Template
  alias DeepEvalEx.Schemas.MetricOutputs.ToolCorrectness, as: Schema

  @impl true
  def metric_name, do: "Tool Correctness"

  @impl true
  def required_params, do: [:tools_called, :expected_tools]

  @doc """
  Override validate_test_case to allow empty lists.

  Python DeepEval allows empty tools_called/expected_tools and returns
  scores rather than validation errors.
  """
  def validate_test_case(test_case) do
    # Only validate that the fields exist (are not nil)
    missing =
      required_params()
      |> Enum.filter(fn param ->
        Map.get(test_case, param) == nil
      end)

    case missing do
      [] -> :ok
      params -> {:error, {:missing_params, params}}
    end
  end

  def do_measure(test_case, opts) do
    config = parse_config(opts)
    called = test_case.tools_called
    expected = test_case.expected_tools

    tool_calling_score =
      calculate_score(
        called,
        expected,
        config.exact_match?,
        config.consider_ordering?,
        config.eval_params
      )
      |> apply_strict_mode(config)

    {tool_selection_score, tool_selection_reason} =
      evaluate_tool_selection(test_case.input, called, config.available_tools, opts)

    score =
      min(tool_calling_score, tool_selection_score)
      |> apply_strict_mode(config)

    reason =
      build_combined_reason(
        called,
        expected,
        config,
        tool_selection_reason
      )

    {:ok,
     Result.new(
       metric: metric_name(),
       score: score,
       threshold: config.threshold,
       reason: reason,
       success: score >= config.threshold,
       metadata: %{
         tool_calling_score: tool_calling_score,
         tool_selection_score: tool_selection_score,
         tool_selection_reason: tool_selection_reason,
         should_exact_match: config.exact_match?,
         should_consider_ordering: config.consider_ordering?,
         evaluation_params: config.eval_params,
         strict_mode: config.strict_mode?
       }
     )}
  end

  defp parse_config(opts) do
    strict_mode? = Keyword.get(opts, :strict_mode, false)

    %{
      strict_mode?: strict_mode?,
      threshold:
        if(strict_mode?, do: 1.0, else: Keyword.get(opts, :threshold, default_threshold())),
      exact_match?: Keyword.get(opts, :should_exact_match, false),
      consider_ordering?: Keyword.get(opts, :should_consider_ordering, false),
      eval_params: Keyword.get(opts, :evaluation_params, []),
      available_tools: Keyword.get(opts, :available_tools),
      include_reason: Keyword.get(opts, :include_reason, true)
    }
  end

  defp apply_strict_mode(score, %{strict_mode?: true, threshold: threshold})
       when score < threshold, do: 0.0

  defp apply_strict_mode(score, _config), do: score

  defp evaluate_tool_selection(_input, _called, nil, _opts) do
    {1.0, "No available tools were provided to assess tool selection criteria"}
  end

  defp evaluate_tool_selection(_input, _called, [], _opts) do
    {1.0, "No available tools were provided to assess tool selection criteria"}
  end

  defp evaluate_tool_selection(input, called, available_tools, opts) do
    get_tool_selection_score(input, called, available_tools, opts)
  end

  defp build_combined_reason(_called, _expected, %{include_reason: false}, _selection_reason),
    do: nil

  defp build_combined_reason(called, expected, config, selection_reason) do
    calling_reason =
      generate_reason(
        called,
        expected,
        config.exact_match?,
        config.consider_ordering?,
        config.eval_params
      )

    construct_final_reason(calling_reason, selection_reason)
  end

  # --- Score calculation dispatch (matches Python _calculate_score) ---

  defp calculate_score(called, expected, exact_match?, consider_ordering?, eval_params) do
    cond do
      exact_match? ->
        calculate_exact_match_score(called, expected, eval_params)

      consider_ordering? ->
        {_lcs, weighted_length} = compute_weighted_lcs(called, expected, eval_params)
        calculate_ordering_score(called, expected, weighted_length)

      true ->
        calculate_non_exact_match_score(called, expected, eval_params)
    end
  end

  defp calculate_ordering_score(called, expected, weighted_length) do
    cond do
      Enum.empty?(called) and Enum.empty?(expected) -> 1.0
      Enum.empty?(expected) -> 0.0
      true -> weighted_length / length(expected)
    end
  end

  # --- Exact match score (matches Python _calculate_exact_match_score) ---

  defp calculate_exact_match_score([], [], _eval_params), do: 1.0

  defp calculate_exact_match_score(called, expected, _eval_params)
       when length(called) != length(expected) do
    0.0
  end

  defp calculate_exact_match_score(called, expected, eval_params) do
    mismatch? =
      Enum.zip(called, expected)
      |> Enum.any?(fn {c, e} ->
        c.name != e.name or
          (:input_parameters in eval_params and
             c.input_parameters != e.input_parameters) or
          (:output in eval_params and c.output != e.output)
      end)

    if mismatch?, do: 0.0, else: 1.0
  end

  # --- Non-exact match score (matches Python _calculate_non_exact_match_score) ---

  defp calculate_non_exact_match_score(called, expected, eval_params) do
    {total_score, _matched} =
      Enum.reduce(expected, {0.0, MapSet.new()}, fn exp, {score_acc, matched} ->
        {best_score, best_idx} = find_best_match(called, exp, eval_params, matched)

        if best_score > 0 do
          {score_acc + best_score, MapSet.put(matched, best_idx)}
        else
          {score_acc, matched}
        end
      end)

    cond do
      Enum.empty?(expected) and Enum.empty?(called) -> 1.0
      Enum.empty?(expected) -> 0.0
      true -> total_score / length(expected)
    end
  end

  defp find_best_match(called, expected_tool, eval_params, matched) do
    called
    |> Enum.with_index()
    |> Enum.reject(fn {_c, i} -> MapSet.member?(matched, i) end)
    |> Enum.filter(fn {c, _i} -> expected_tool.name == c.name end)
    |> Enum.reduce({0.0, nil}, fn {c, i}, {best, best_i} ->
      match_score = compute_match_score(c, expected_tool, eval_params)
      if match_score > best, do: {match_score, i}, else: {best, best_i}
    end)
  end

  # --- Weighted LCS (matches Python _compute_weighted_lcs) ---
  # Returns {lcs_tools, weighted_length} matching Python's return signature

  defp compute_weighted_lcs(called, expected, eval_params) do
    m = length(expected)
    n = length(called)

    expected_vec = :array.from_list(expected)
    called_vec = :array.from_list(called)

    # Build DP table
    dp =
      for i <- 1..max(m, 1),
          j <- 1..max(n, 1),
          i <= m,
          j <= n,
          reduce: %{} do
        acc ->
          exp = :array.get(i - 1, expected_vec)
          cal = :array.get(j - 1, called_vec)

          if exp.name != cal.name do
            val = max(Map.get(acc, {i - 1, j}, 0.0), Map.get(acc, {i, j - 1}, 0.0))
            Map.put(acc, {i, j}, val)
          else
            score = compute_match_score(cal, exp, eval_params)

            diag = if score > 0, do: Map.get(acc, {i - 1, j - 1}, 0.0) + score, else: 0.0
            up = Map.get(acc, {i - 1, j}, 0.0)
            left = Map.get(acc, {i, j - 1}, 0.0)

            Map.put(acc, {i, j}, max(diag, max(up, left)))
          end
      end

    # Backtrack to recover LCS and total score
    {lcs, total_score} = backtrack_lcs(dp, expected_vec, m, n)

    {lcs, total_score}
  end

  defp backtrack_lcs(dp, expected_vec, m, n) do
    backtrack_lcs(dp, expected_vec, m, n, [], 0.0)
  end

  defp backtrack_lcs(_dp, _expected_vec, 0, _j, lcs, total_score), do: {lcs, total_score}
  defp backtrack_lcs(_dp, _expected_vec, _i, 0, lcs, total_score), do: {lcs, total_score}

  defp backtrack_lcs(dp, expected_vec, i, j, lcs, total_score) do
    current = Map.get(dp, {i, j}, 0.0)
    up = Map.get(dp, {i - 1, j}, 0.0)
    left = Map.get(dp, {i, j - 1}, 0.0)
    diag = Map.get(dp, {i - 1, j - 1}, 0.0)

    cond do
      current == up ->
        backtrack_lcs(dp, expected_vec, i - 1, j, lcs, total_score)

      current == left ->
        backtrack_lcs(dp, expected_vec, i, j - 1, lcs, total_score)

      true ->
        tool = :array.get(i - 1, expected_vec)
        step_score = current - diag
        backtrack_lcs(dp, expected_vec, i - 1, j - 1, [tool | lcs], total_score + step_score)
    end
  end

  # --- Match score computation (shared by non-exact and LCS) ---

  defp compute_match_score(called, expected, eval_params) do
    score = 1.0

    score =
      if :input_parameters in eval_params do
        score * compare_dicts(expected.input_parameters, called.input_parameters, false)
      else
        score
      end

    if :output in eval_params and expected.output != called.output do
      0.0
    else
      score
    end
  end

  # --- Dictionary comparison (matches Python _compare_dicts) ---

  defp compare_dicts(dict1, dict2, _exact_match?) when dict1 == dict2, do: 1.0

  defp compare_dicts(dict1, dict2, _exact_match?)
       when is_map(dict1) and is_map(dict2) do
    keys1 = MapSet.new(Map.keys(dict1))
    keys2 = MapSet.new(Map.keys(dict2))
    matched_keys = MapSet.intersection(keys1, keys2)
    total = MapSet.size(MapSet.union(keys1, keys2))

    if total == 0 do
      1.0
    else
      Enum.reduce(matched_keys, 0.0, fn key, acc ->
        acc + compare_key_values(Map.get(dict1, key), Map.get(dict2, key), total)
      end)
    end
  end

  defp compare_dicts(_dict1, _dict2, _exact_match?), do: 0.0

  defp compare_key_values(v, v, total), do: 1 / total

  defp compare_key_values(v1, v2, total) when is_map(v1) and is_map(v2) do
    compare_dicts(v1, v2, false) / total
  end

  defp compare_key_values(_v1, _v2, _total), do: 0.0

  # --- Tool Selection Score (LLM-based, matches Python _get_tool_selection_score) ---

  defp get_tool_selection_score(user_input, tools_called, available_tools, opts) do
    tools_called_formatted = Template.format_tools(tools_called)
    available_tools_formatted = Template.format_tools(available_tools)

    prompt =
      Template.get_tool_selection_score(
        user_input: user_input,
        tools_called: tools_called_formatted,
        available_tools: available_tools_formatted
      )

    case Adapter.generate_with_schema(prompt, Schema.tool_selection_score_schema(), opts) do
      {:ok, response} ->
        case Schema.parse_tool_selection_score(response) do
          {:ok, %{score: score, reason: reason}} -> {score, reason}
          {:error, _} -> {1.0, "Failed to parse tool selection score"}
        end

      {:error, _} ->
        {1.0, "Failed to generate tool selection score"}
    end
  end

  # --- Reason generation (matches Python _generate_reason) ---

  defp generate_reason(called, expected, exact_match?, consider_ordering?, eval_params) do
    called_names = Enum.map(called, & &1.name)
    expected_names = Enum.map(expected, & &1.name)

    cond do
      exact_match? ->
        generate_exact_match_reason(called, expected, eval_params, called_names, expected_names)

      consider_ordering? ->
        generate_ordering_reason(called, expected, eval_params, called_names, expected_names)

      true ->
        generate_default_reason(called, expected, eval_params, called_names, expected_names)
    end
  end

  defp generate_exact_match_reason(called, expected, eval_params, called_names, expected_names) do
    score = calculate_exact_match_score(called, expected, eval_params)
    label = if score == 1.0, do: "Exact match", else: "Not an exact match"

    "#{label}: expected #{inspect(expected_names)}, called #{inspect(called_names)}. See details above."
  end

  defp generate_ordering_reason(called, expected, eval_params, called_names, expected_names) do
    {lcs, weighted_length} = compute_weighted_lcs(called, expected, eval_params)
    score = calculate_ordering_score(called, expected, weighted_length)

    if score == 1.0 do
      "Correct ordering: all expected tools #{inspect(expected_names)} were called in the correct order."
    else
      format_ordering_issues(lcs, called_names, expected_names)
    end
  end

  defp format_ordering_issues(lcs, called_names, expected_names) do
    expected_set = MapSet.new(expected_names)
    called_set = MapSet.new(called_names)
    lcs_names = MapSet.new(lcs, & &1.name)

    missing = MapSet.difference(expected_set, called_set)
    out_of_order = MapSet.difference(expected_set, lcs_names)

    issues =
      []
      |> maybe_add_issue(missing, "missing tools")
      |> maybe_add_issue(out_of_order, "out-of-order tools")

    "Incorrect tool usage: #{Enum.join(issues, " and ")}; expected #{inspect(expected_names)}, called #{inspect(called_names)}. See more details above."
  end

  defp maybe_add_issue(issues, set, label) do
    if MapSet.size(set) > 0,
      do: issues ++ ["#{label} #{inspect(MapSet.to_list(set))}"],
      else: issues
  end

  defp generate_default_reason(called, expected, eval_params, called_names, expected_names) do
    score = calculate_non_exact_match_score(called, expected, eval_params)

    if score == 1.0 do
      "All expected tools #{inspect(expected_names)} were called (order not considered)."
    else
      missing_list =
        expected
        |> MapSet.new()
        |> MapSet.difference(MapSet.new(called))
        |> Enum.map(& &1.name)

      "Incomplete tool usage: missing tools #{inspect(missing_list)}; expected #{inspect(expected_names)}, called #{inspect(called_names)}. See more details above."
    end
  end

  # --- Final reason construction (matches Python _construct_final_reason) ---

  defp construct_final_reason(tool_calling_reason, tool_selection_reason) do
    "[\n\t Tool Calling Reason: #{tool_calling_reason}\n\t Tool Selection Reason: #{tool_selection_reason}\n]\n"
  end
end
