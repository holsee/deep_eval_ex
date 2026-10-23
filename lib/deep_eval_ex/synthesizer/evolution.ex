# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/types.py and the evolution maps of
# deepeval/synthesizer/synthesizer.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer.Evolution do
  @moduledoc """
  The seven evolutions `DeepEvalEx.Synthesizer` rewrites a synthetic input
  with, deepeval 4.3.1's `Evolution` enum, and their templates.

  | Atom             | deepeval value    | Rewrites the input to...                          |
  | ---------------- | ----------------- | ------------------------------------------------- |
  | `:reasoning`     | `"Reasoning"`     | need multi-step reasoning                         |
  | `:multi_context` | `"Multi-context"` | need every element of the context                 |
  | `:concretizing`  | `"Concretizing"`  | ask about something more specific                 |
  | `:constrained`   | `"Constrained"`   | add a constraint or requirement                   |
  | `:comparative`   | `"Comparative"`   | compare two or more things                        |
  | `:hypothetical`  | `"Hypothetical"`  | imagine a hypothetical scenario                   |
  | `:in_breadth`    | `"In-Breadth"`    | ask a rarer question in the same domain           |

  The value is what a synthetic golden records in its
  `additional_metadata["evolutions"]`. An input generated from a context is
  evolved with `DeepEvalEx.Synthesizer.EvolutionTemplate`; one generated
  from scratch, without a context, with
  `DeepEvalEx.Synthesizer.PromptEvolutionTemplate`, which has no
  `:multi_context` (deepeval's `PromptEvolution`).
  """

  alias DeepEvalEx.Synthesizer.{EvolutionTemplate, PromptEvolutionTemplate}

  @type t ::
          :reasoning
          | :multi_context
          | :concretizing
          | :constrained
          | :comparative
          | :hypothetical
          | :in_breadth

  # In deepeval's enum order, with each one's value and template function.
  @evolutions [
    reasoning: {"Reasoning", :reasoning_evolution},
    multi_context: {"Multi-context", :multi_context_evolution},
    concretizing: {"Concretizing", :concretizing_evolution},
    constrained: {"Constrained", :constrained_evolution},
    comparative: {"Comparative", :comparative_question_evolution},
    hypothetical: {"Hypothetical", :hypothetical_scenario_evolution},
    in_breadth: {"In-Breadth", :in_breadth_evolution}
  ]

  @doc """
  Every evolution, in deepeval's order.

  ## Examples

      iex> DeepEvalEx.Synthesizer.Evolution.all()
      [:reasoning, :multi_context, :concretizing, :constrained, :comparative, :hypothetical, :in_breadth]
  """
  @spec all() :: [t()]
  def all, do: Keyword.keys(@evolutions)

  @doc """
  The evolutions an input generated from scratch can take, deepeval's
  `PromptEvolution`: all but `:multi_context`.
  """
  @spec prompt_evolutions() :: [t()]
  def prompt_evolutions, do: all() -- [:multi_context]

  @doc """
  The deepeval value of `evolution`.

  ## Examples

      iex> DeepEvalEx.Synthesizer.Evolution.value(:in_breadth)
      "In-Breadth"
  """
  @spec value(t()) :: String.t()
  def value(evolution), do: @evolutions |> Keyword.fetch!(evolution) |> elem(0)

  @doc """
  The evolution whose deepeval value is `value`; raises `ArgumentError` for
  any other value.

  ## Examples

      iex> DeepEvalEx.Synthesizer.Evolution.from_value("Multi-context")
      :multi_context
  """
  @spec from_value(String.t()) :: t()
  def from_value(value) do
    case Enum.find(@evolutions, fn {_evolution, {v, _fun}} -> v == value end) do
      {evolution, _} -> evolution
      nil -> raise ArgumentError, "unknown evolution: #{inspect(value)}"
    end
  end

  @doc """
  Renders the prompt evolving `input` with `evolution`, from its `context`
  (a list of chunks) with `DeepEvalEx.Synthesizer.EvolutionTemplate`, or,
  when `context` is `:none` (an input generated from scratch), with
  `DeepEvalEx.Synthesizer.PromptEvolutionTemplate`, which has no
  `:multi_context`: raises `ArgumentError` with deepeval's message.
  """
  @spec prompt(t(), String.t(), [String.t()] | :none) :: String.t()
  def prompt(:multi_context, _input, :none) do
    raise ArgumentError, "Evolution 'MULTICONTEXT' not available for this method."
  end

  def prompt(evolution, input, :none) do
    {_value, fun} = Keyword.fetch!(@evolutions, evolution)
    apply(PromptEvolutionTemplate, fun, [[input: input]])
  end

  def prompt(evolution, input, context) do
    {_value, fun} = Keyword.fetch!(@evolutions, evolution)
    apply(EvolutionTemplate, fun, [[input: input, context: context]])
  end
end
