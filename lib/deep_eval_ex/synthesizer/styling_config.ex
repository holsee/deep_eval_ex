# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/config.py (StylingConfig)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer.StylingConfig do
  @moduledoc """
  The style of the goldens `DeepEvalEx.Synthesizer` generates, deepeval
  4.3.1's `StylingConfig`.

  ## Fields

  - `:scenario` - who submits the inputs, and why
  - `:task` - what the application under test does with them
  - `:input_format` - the form the inputs take
  - `:expected_output_format` - the form the expected outputs take

  Every field is optional (`nil`). Generating from contexts, a set
  `:scenario`, `:task` or `:input_format` steers the generated inputs and
  restyles each evolved input; generating from scratch needs all three.

  ## Examples

      iex> DeepEvalEx.Synthesizer.StylingConfig.new(scenario: "Tourists planning a trip", task: "Travel assistant")
      %DeepEvalEx.Synthesizer.StylingConfig{scenario: "Tourists planning a trip", task: "Travel assistant", input_format: nil, expected_output_format: nil}
  """

  @type t :: %__MODULE__{
          scenario: String.t() | nil,
          task: String.t() | nil,
          input_format: String.t() | nil,
          expected_output_format: String.t() | nil
        }

  defstruct [:scenario, :task, :input_format, :expected_output_format]

  @doc """
  Builds a styling config from a keyword list or map of its fields (atom
  keys), or returns a `StylingConfig` as it is. Raises `ArgumentError` for
  an unknown field or a value that is not a string or `nil`.
  """
  @spec new(t() | keyword() | map()) :: t()
  def new(%__MODULE__{} = config), do: config

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    config = struct!(__MODULE__, Map.new(attrs))

    for {field, value} <- Map.from_struct(config), not (is_nil(value) or is_binary(value)) do
      raise ArgumentError, "styling config #{field} must be a string, got: #{inspect(value)}"
    end

    config
  end

  @doc """
  Whether the inputs are restyled after their evolutions: a `:scenario`,
  `:task` or `:input_format` is set (and not empty), as deepeval's
  `should_style`.
  """
  @spec style?(t()) :: boolean()
  def style?(%__MODULE__{} = config) do
    Enum.any?([config.scenario, config.task, config.input_format], &(&1 not in [nil, ""]))
  end
end
