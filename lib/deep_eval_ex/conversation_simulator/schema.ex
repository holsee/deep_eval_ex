# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/simulator/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ConversationSimulator.Schema do
  @moduledoc """
  The structured outputs `DeepEvalEx.ConversationSimulator` asks its model
  for, deepeval 4.3.1's `simulator/schema.py` models, as JSON schemas, and
  their parsers.

  | Function                    | deepeval model           | Step (see `DeepEvalEx.LLM.Adapters.Mock.step_key/1`) |
  | --------------------------- | ------------------------ | ---------------------------------------------------- |
  | `simulated_input/0`         | `SimulatedInput`         | `"simulated_input"`                                  |
  | `conversation_completion/0` | `ConversationCompletion` | `"is_complete,reason"`                               |
  | `edge_choice/0`             | `EdgeChoice`             | `"index,reason"`                                     |

  Each `parse_*` function validates a decoded answer as pydantic validates
  the model, returning `{:error, {:invalid_response, model, answer}}` for
  an answer that does not fit.
  """

  @doc "deepeval's `SimulatedInput`: the simulated user's next message."
  @spec simulated_input() :: map()
  def simulated_input, do: object(%{"simulated_input" => %{"type" => "string"}})

  @doc "deepeval's `ConversationCompletion`: whether the expected outcome was reached."
  @spec conversation_completion() :: map()
  def conversation_completion,
    do: object(%{"is_complete" => %{"type" => "boolean"}, "reason" => %{"type" => "string"}})

  @doc """
  deepeval's `EdgeChoice`: the 1-based index of the outgoing edge the
  assistant's reply matched, or `null` for none, and a reason.
  """
  @spec edge_choice() :: map()
  def edge_choice,
    do:
      object(%{
        "index" => %{"type" => ["integer", "null"]},
        "reason" => %{"type" => ["string", "null"]}
      })

  @doc """
  Parses a `SimulatedInput` answer into the message.

  ## Examples

      iex> DeepEvalEx.ConversationSimulator.Schema.parse_simulated_input(%{"simulated_input" => "Hi!"})
      {:ok, "Hi!"}
  """
  @spec parse_simulated_input(term()) :: {:ok, String.t()} | {:error, term()}
  def parse_simulated_input(%{"simulated_input" => input}) when is_binary(input), do: {:ok, input}
  def parse_simulated_input(answer), do: invalid("SimulatedInput", answer)

  @doc "Parses a `ConversationCompletion` answer into `is_complete`."
  @spec parse_conversation_completion(term()) :: {:ok, boolean()} | {:error, term()}
  def parse_conversation_completion(%{"is_complete" => complete, "reason" => reason})
      when is_boolean(complete) and is_binary(reason),
      do: {:ok, complete}

  def parse_conversation_completion(answer), do: invalid("ConversationCompletion", answer)

  @doc """
  Parses an `EdgeChoice` answer into the index, `nil` when it is `null` or
  missing (both fields are optional). As pydantic, a float with no
  fractional part is taken as an integer.

  ## Examples

      iex> DeepEvalEx.ConversationSimulator.Schema.parse_edge_choice(%{"index" => 2.0})
      {:ok, 2}

      iex> DeepEvalEx.ConversationSimulator.Schema.parse_edge_choice(%{"index" => nil, "reason" => "None."})
      {:ok, nil}
  """
  @spec parse_edge_choice(term()) :: {:ok, integer() | nil} | {:error, term()}
  def parse_edge_choice(answer) when is_map(answer) do
    with true <- Map.get(answer, "reason") |> then(&(is_nil(&1) or is_binary(&1))),
         {:ok, index} <- edge_index(Map.get(answer, "index")) do
      {:ok, index}
    else
      _ -> invalid("EdgeChoice", answer)
    end
  end

  def parse_edge_choice(answer), do: invalid("EdgeChoice", answer)

  defp edge_index(index) when is_nil(index) or is_integer(index), do: {:ok, index}
  defp edge_index(index) when is_float(index) and round(index) == index, do: {:ok, round(index)}
  defp edge_index(_index), do: :error

  defp object(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => properties |> Map.keys() |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp invalid(model, answer), do: {:error, {:invalid_response, model, answer}}
end
