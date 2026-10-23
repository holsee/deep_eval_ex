# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/simulator/simulation_graph/template.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/simulator/templates_test.exs checks every byte.

defmodule DeepEvalEx.ConversationSimulator.SimulationGraphTemplate do
  @moduledoc """
  deepeval 4.3.1's `SimulationGraphTemplate`: the prompt a simulation
  graph routes on the assistant's reply with, rendered byte for byte.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  The prompt asking which of the outgoing edges' `choices` describes the
  assistant's reply, deepeval's `classify_edge`: the choices numbered from
  1, then "None of the above". The model answers with the chosen `index`
  (`null` for none) and a `reason`.
  """
  @spec classify_edge(String.t(), [String.t()]) :: String.t()
  def classify_edge(assistant_reply, choices) do
    numbered_choices =
      choices
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {choice, index} -> "  #{index}) #{choice}" end)

    none_index = length(choices) + 1

    ("""
     You are routing a simulated conversation. The assistant just said:
                 <<<
                 #{assistant_reply}
                 >>>

                 Which of the following best describes the assistant's reply?
                 #{numbered_choices}
                   #{none_index}) None of the above

                 Pick exactly one option. Respond with the option's number.

                 IMPORTANT: The output must be formatted as a JSON object with two keys:
                 - `index`: the 1-based number of the option you chose, OR `null` if you chose "None of the above" (option #{none_index}).
                 - `reason`: a short rationale (one sentence).

                 Example JSON Output for a match:
                 {
                     "index": 1,
                     "reason": "The reply explicitly approved the refund."
                 }

                 Example JSON Output for no match:
                 {
                     "index": null,
                     "reason": "The reply asked a clarifying question that does not fit any option."
                 }

                 JSON Output:
     """ <> "            ")
    |> Python.dedent()
  end
end
