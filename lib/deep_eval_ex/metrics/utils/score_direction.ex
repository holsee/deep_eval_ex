# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/utils/metrics.py (warn_score_direction_flipped)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.ScoreDirection do
  @moduledoc """
  Warns that a metric's score direction was inverted.

  deepeval 4.3.1 flipped the metrics that used to score the proportion of
  violations (Hallucination among them) so that, like every other metric, 1
  is a pass and `threshold` is the minimum passing score. Each flipped metric
  warns once per node, the way deepeval warns once per process, so a run that
  measures many test cases doesn't repeat itself.
  """

  require Logger

  @doc """
  Logs the score direction warning for `metric_name`, the first time it is
  called for that name on this node.
  """
  @spec warn_flipped(String.t()) :: :ok
  def warn_flipped(metric_name) do
    key = {__MODULE__, metric_name}

    if :persistent_term.get(key, false) do
      :ok
    else
      :persistent_term.put(key, true)

      Logger.warning(
        "'#{metric_name}' now scores in the same direction as every other " <>
          "metric: 1 is a pass, 0 is a failure, and 'threshold' is the " <>
          "MINIMUM passing score. It previously scored the proportion of " <>
          "violations, where 'threshold' was a maximum. Review any 'threshold' " <>
          "you pass and any code reading '.score' - a threshold of 0.2 that " <>
          "used to mean 'at most 20% violations' should now be 0.8. This notice " <>
          "will be removed in a future release."
      )
    end
  end
end
