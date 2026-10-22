# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/tool_permission/tool_permission.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.ToolPermission do
  @moduledoc """
  Tool permission metric checking that an agent only called the tools it
  was authorized to.

  A port of deepeval 4.3.1's `ToolPermissionMetric`. A non-LLM metric: it
  calls no judge and is fully deterministic, so it is cheap and reliable to
  run as a CI gate.

  Unlike `DeepEvalEx.Metrics.ToolCorrectness`, which compares the tools
  called with the tools expected, it checks the tools called against a
  permission policy, whether or not the task was solved:

  - `:allowed_tools` - an allowlist. When given, a call to a tool whose name
    is not in it is unauthorized (least privilege); an empty list authorizes
    nothing
  - `:denied_tools` - a denylist. A call to a tool whose name is in it is
    unauthorized. A denial always wins over an allow

  ## How It Works

  1. **Check each call** in `tools_called` by its name against the policy
  2. **Calculate score** - (authorized calls) / (all calls), or `1.0` when
     no tools were called
  3. **Higher score is better** - Success when score ≥ threshold

  ## Usage

  ```elixir
  alias DeepEvalEx.{TestCase, Metrics.ToolPermission}

  test_case = TestCase.new!(
    input: "Close my account.",
    actual_output: "Done.",
    tools_called: [%{name: "search_kb"}, %{name: "delete_account"}]
  )

  {:ok, result} =
    ToolPermission.measure(test_case,
      allowed_tools: ["search_kb", "reply"],
      denied_tools: ["delete_account"]
    )

  result.score   # => 0.5 (1 authorized call out of 2)
  result.success # => false (0.5 < 1.0 threshold)
  ```

  ## Options

  - `:allowed_tools` - The names of the tools the agent may call, a list of
    strings (default: any tool)
  - `:denied_tools` - The names of the tools the agent must not call, a list
    of strings (default: none)
  - `:threshold` - Minimum passing score (default: the float `1.0`, as
    deepeval's)
  - `:strict_mode` - Force the threshold to `1.0` and score below it `0`
    (default: false)
  - `:include_reason` - Explain the score (default: true)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)

  Measuring with neither `:allowed_tools` nor `:denied_tools` raises
  `ArgumentError`, as deepeval's constructor raises `ValueError`.

  ## As a configured metric

  The policy belongs to the metric, as in deepeval's
  `ToolPermissionMetric(allowed_tools=..., denied_tools=...)`. To evaluate
  with other metrics, or two policies at once, build the metric with
  `new/1` and pass the struct to `DeepEvalEx.evaluate/3`; its fields take
  precedence over the run's options:

  ```elixir
  metric = ToolPermission.new(denied_tools: ["delete_account", "wire_transfer"])
  DeepEvalEx.evaluate(test_cases, [metric, DeepEvalEx.Metrics.ToolCorrectness])
  ```

  ## Eval Modes

  Like deepeval's, it ignores the eval mode (see
  `DeepEvalEx.SystemOne.Mode`): it measures the same way under `:hybrid`
  and `:system_one`, and builds and calls no System One model.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 1.0

  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Metrics.Utils.Verbose
  alias DeepEvalEx.Prompts.Python

  defstruct [
    :allowed_tools,
    :denied_tools,
    :threshold,
    :strict_mode,
    :include_reason,
    :verbose_mode,
    :flaky
  ]

  @type t :: %__MODULE__{
          allowed_tools: [String.t()] | nil,
          denied_tools: [String.t()] | nil,
          threshold: number() | nil,
          strict_mode: boolean() | nil,
          include_reason: boolean() | nil,
          verbose_mode: boolean() | nil,
          flaky: boolean() | nil
        }

  @doc """
  Creates a ToolPermission metric for `DeepEvalEx.evaluate/3`. See the
  moduledoc for the options; those left unset (`nil`) fall back to the
  run's options.

  Raises `ArgumentError`, as deepeval's constructor raises `ValueError`,
  when neither `:allowed_tools` nor `:denied_tools` is given.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    policy!(opts)

    %__MODULE__{
      allowed_tools: Keyword.get(opts, :allowed_tools),
      denied_tools: Keyword.get(opts, :denied_tools),
      threshold: threshold(opts),
      strict_mode: Keyword.get(opts, :strict_mode),
      include_reason: Keyword.get(opts, :include_reason),
      verbose_mode: Keyword.get(opts, :verbose_mode),
      flaky: Keyword.get(opts, :flaky)
    }
  end

  @impl true
  def metric_name, do: "Tool Permission"

  @impl true
  def required_params, do: [:tools_called]

  @doc """
  `false`: ToolPermission takes no part in System One (see "Eval Modes").
  """
  @impl true
  def system_one?, do: false

  @doc """
  Measures the share of the test case's tool calls the policy authorizes.
  """
  def do_measure(test_case, opts) do
    {allowed, denied} = policy!(opts)
    threshold = threshold(opts)
    tools_called = test_case.tools_called
    unauthorized = Enum.reject(tools_called, &authorized?(&1.name, allowed, denied))
    total = length(tools_called)

    score =
      if total == 0,
        do: 1.0,
        else: (total - length(unauthorized)) / total

    score = BaseMetric.strict_score(score, Keyword.put(opts, :threshold, threshold))
    reason = reason(tools_called, unauthorized, allowed, denied, opts)

    verbose_logs =
      Verbose.construct_verbose_logs(
        metric_name(),
        [
          "Allowed tools: #{policy_str(allowed)}",
          "Denied tools: #{Python.repr(denied)}",
          "Tools called: #{names(tools_called)}",
          "Unauthorized calls: #{names(unauthorized)}",
          "Score: #{Verbose.to_str(score)}\nReason: #{Verbose.to_str(reason)}"
        ],
        opts
      )

    {:ok,
     Result.new(
       metric: metric_name(),
       score: score,
       threshold: threshold,
       reason: reason,
       verbose_logs: verbose_logs,
       metadata: %{
         allowed_tools: allowed,
         denied_tools: denied,
         unauthorized_tools: Enum.map(unauthorized, & &1.name)
       }
     )}
  end

  # deepeval's constructor sets `1.0 if strict_mode else threshold`: a float,
  # where `BaseMetric.threshold/2` forces the integer 1 other metrics use.
  defp threshold(opts) do
    if Keyword.get(opts, :strict_mode, false),
      do: 1.0,
      else: BaseMetric.threshold(opts, default_threshold())
  end

  # deepeval's constructor check and sets: the allowlist sorted and
  # deduplicated, or `nil` for any tool, and the denylist likewise, empty
  # when not given.
  defp policy!(opts) do
    allowed = Keyword.get(opts, :allowed_tools)
    denied = Keyword.get(opts, :denied_tools)

    if is_nil(allowed) and is_nil(denied) do
      raise ArgumentError,
            "ToolPermission requires at least one of :allowed_tools (an allowlist) " <>
              "or :denied_tools (a denylist)."
    end

    {allowed && tool_set(allowed), tool_set(denied || [])}
  end

  defp tool_set(names), do: names |> Enum.uniq() |> Enum.sort()

  # A denial always wins; without an allowlist any other tool is allowed.
  defp authorized?(name, allowed, denied) do
    name not in denied and (is_nil(allowed) or name in allowed)
  end

  defp reason(tools_called, unauthorized, allowed, denied, opts) do
    if Keyword.get(opts, :include_reason, true) do
      generate_reason(tools_called, unauthorized, allowed, denied)
    end
  end

  defp generate_reason([], _unauthorized, _allowed, _denied),
    do: "No tools were called, so no permission boundary could be violated."

  defp generate_reason(tools_called, [], _allowed, _denied),
    do: "All #{length(tools_called)} tool call(s) stayed within the permitted set."

  defp generate_reason(tools_called, unauthorized, allowed, denied) do
    "#{length(unauthorized)} of #{length(tools_called)} tool call(s) were unauthorized: " <>
      "#{names(unauthorized)}. Allowed=#{policy_str(allowed)}, Denied=#{Python.repr(denied)}."
  end

  defp policy_str(nil), do: "ANY"
  defp policy_str(names), do: Python.repr(names)

  defp names(tool_calls), do: tool_calls |> Enum.map(& &1.name) |> Python.repr()
end
