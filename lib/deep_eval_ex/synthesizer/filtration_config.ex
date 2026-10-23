# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/config.py (FiltrationConfig)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer.FiltrationConfig do
  @moduledoc """
  How `DeepEvalEx.Synthesizer` filters the inputs it generates from
  contexts, deepeval 4.3.1's `FiltrationConfig`.

  A critic model scores each input's clarity and answerability from 0 to 1
  (`DeepEvalEx.Synthesizer.FilterTemplate`). An input scoring below
  `:synthetic_input_quality_threshold` is rewritten from the critic's
  feedback and scored again, up to `:max_quality_retries` times; the last
  rewrite is kept whatever its score, and the last score is recorded as
  the golden's `additional_metadata["synthetic_input_quality"]` (`0.0`
  when `:max_quality_retries` is `0`, which skips the critic).

  ## Fields

  - `:synthetic_input_quality_threshold` - the passing score (default: `0.5`)
  - `:max_quality_retries` - the critic's calls per input (default: `3`)
  - `:critic_model`, `:critic_adapter` - the critic, as a metric's
    `:model` and `:adapter`. Both `nil` (the default) is the configured
    default model, as deepeval's `initialize_model(None)`. A
    `DeepEvalEx.Synthesizer` built without a filtration config uses its
    own model as the critic, as deepeval does.

  ## Examples

      iex> DeepEvalEx.Synthesizer.FiltrationConfig.new(max_quality_retries: 1)
      %DeepEvalEx.Synthesizer.FiltrationConfig{synthetic_input_quality_threshold: 0.5, max_quality_retries: 1, critic_model: nil, critic_adapter: nil}
  """

  @type t :: %__MODULE__{
          synthetic_input_quality_threshold: number(),
          max_quality_retries: non_neg_integer(),
          critic_model: term(),
          critic_adapter: term()
        }

  defstruct synthetic_input_quality_threshold: 0.5,
            max_quality_retries: 3,
            critic_model: nil,
            critic_adapter: nil

  @doc """
  Builds a filtration config from a keyword list or map of its fields
  (atom keys), or returns a `FiltrationConfig` as it is. Raises
  `ArgumentError` for an unknown field, a threshold that is not a number
  or a retry count that is not a non-negative integer.
  """
  @spec new(t() | keyword() | map()) :: t()
  def new(%__MODULE__{} = config), do: config

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    config = struct!(__MODULE__, Map.new(attrs))

    unless is_number(config.synthetic_input_quality_threshold) do
      raise ArgumentError,
            "synthetic_input_quality_threshold must be a number, got: " <>
              inspect(config.synthetic_input_quality_threshold)
    end

    unless is_integer(config.max_quality_retries) and config.max_quality_retries >= 0 do
      raise ArgumentError,
            "max_quality_retries must be a non-negative integer, got: " <>
              inspect(config.max_quality_retries)
    end

    config
  end
end
