# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/config.py (EvolutionConfig) and the
# weighted pick of deepeval/synthesizer/synthesizer.py (_evolve_input)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer.EvolutionConfig do
  @moduledoc """
  How `DeepEvalEx.Synthesizer` evolves each synthetic input, deepeval
  4.3.1's `EvolutionConfig`.

  Each input is evolved `:num_evolutions` times in a row, every time with
  an evolution drawn at random from `:evolutions`, a distribution of
  `DeepEvalEx.Synthesizer.Evolution`s to weights (relative, as Python's
  `random.choices` takes them). The evolutions drawn are recorded, in
  order, as the golden's `additional_metadata["evolutions"]`.

  ## Fields

  - `:num_evolutions` - evolutions per input (default: `1`)
  - `:evolutions` - the distribution, a keyword list (or map) of evolution
    to weight (default: the seven evolutions, `1/7` each). Kept as a
    keyword list in deepeval's enum order

  Generating from scratch drops `:multi_context` from the distribution,
  as deepeval's `transform_distribution` does.

  ## Examples

      iex> DeepEvalEx.Synthesizer.EvolutionConfig.new(evolutions: %{in_breadth: 1, reasoning: 2})
      %DeepEvalEx.Synthesizer.EvolutionConfig{num_evolutions: 1, evolutions: [reasoning: 2, in_breadth: 1]}
  """

  alias DeepEvalEx.Synthesizer.Evolution

  @type t :: %__MODULE__{
          num_evolutions: non_neg_integer(),
          evolutions: [{Evolution.t(), number()}]
        }

  defstruct num_evolutions: 1,
            evolutions: Enum.map(Evolution.all(), &{&1, 1 / 7})

  @doc """
  Builds an evolution config from a keyword list or map of its fields
  (atom keys), or returns an `EvolutionConfig` as it is. Raises
  `ArgumentError` for an unknown field or evolution, a negative weight, or
  a `:num_evolutions` that is not a non-negative integer.
  """
  @spec new(t() | keyword() | map()) :: t()
  def new(%__MODULE__{} = config), do: config

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    config = struct!(__MODULE__, Map.new(attrs))

    unless is_integer(config.num_evolutions) and config.num_evolutions >= 0 do
      raise ArgumentError,
            "num_evolutions must be a non-negative integer, got: #{inspect(config.num_evolutions)}"
    end

    %{config | evolutions: distribution(config.evolutions)}
  end

  defp distribution(evolutions) when is_list(evolutions) or is_map(evolutions) do
    weights = Map.new(evolutions)

    for {evolution, weight} <- weights do
      unless evolution in Evolution.all() do
        raise ArgumentError, "unknown evolution: #{inspect(evolution)}"
      end

      unless is_number(weight) and weight >= 0 do
        raise ArgumentError,
              "evolution weights must be non-negative numbers, got: #{inspect(weight)}"
      end
    end

    for evolution <- Evolution.all(),
        Map.has_key?(weights, evolution),
        do: {evolution, Map.fetch!(weights, evolution)}
  end

  defp distribution(other) do
    raise ArgumentError, "evolutions must be a keyword list or map, got: #{inspect(other)}"
  end

  @doc """
  Draws an evolution from `evolutions`, a list of `{evolution, weight}`,
  as Python's `random.choices(population, weights)`: the first evolution
  whose cumulative weight exceeds a uniform draw over the total. Uses the
  calling process's `:rand` state.

  Raises `ArgumentError` when the weights add up to zero or there are no
  evolutions, where Python raises.

  ## Examples

      iex> DeepEvalEx.Synthesizer.EvolutionConfig.pick([reasoning: 0, in_breadth: 1])
      :in_breadth
  """
  @spec pick([{Evolution.t(), number()}]) :: Evolution.t()
  def pick(evolutions) do
    total = evolutions |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total <= 0 do
      raise ArgumentError, "Total of weights must be greater than zero"
    end

    draw = :rand.uniform() * total

    picked =
      Enum.reduce_while(evolutions, 0, fn {evolution, weight}, cumulative ->
        if cumulative + weight > draw,
          do: {:halt, {:picked, evolution}},
          else: {:cont, cumulative + weight}
      end)

    case picked do
      {:picked, evolution} ->
        evolution

      # Float rounding left the draw at the total: the last evolution with
      # weight, as Python's bisect stops at the last index.
      _cumulative ->
        evolutions |> Enum.reverse() |> Enum.find_value(fn {e, w} -> w > 0 and e end)
    end
  end

  @doc """
  The distribution for inputs generated from scratch, deepeval's
  `transform_distribution`: `evolutions` without `:multi_context`.
  """
  @spec prompt_distribution([{Evolution.t(), number()}]) :: [{Evolution.t(), number()}]
  def prompt_distribution(evolutions),
    do: Enum.reject(evolutions, &match?({:multi_context, _}, &1))
end
