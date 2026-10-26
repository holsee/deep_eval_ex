# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/simulator/controller/template.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/simulator/templates_test.exs checks every byte.

defmodule DeepEvalEx.ConversationSimulator.SimulatorControllerTemplate do
  @moduledoc """
  deepeval 4.3.1's `SimulatorControllerTemplate`: the prompt the default
  stopping controller asks whether a conversation reached the golden's
  expected outcome with, rendered byte for byte.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  The prompt asking for `is_complete` and a `reason`, deepeval's
  `check_expected_outcome`. `previous_conversation` is the conversation
  as `DeepEvalEx.ConversationSimulator.SimulationTemplate.serialize_turns_for_prompt/1`
  writes it.
  """
  @spec check_expected_outcome(String.t(), String.t()) :: String.t()
  def check_expected_outcome(previous_conversation, expected_outcome) do
    ("""
     You are a Conversation Completion Checker.
                 Your task is to determine whether the conversation has achieved the expected outcome and should be terminated.

                 Guidelines:
                 1. Review the entire conversation and decide if the expected outcome has been met and the conversation has ended.
                 2. If the expected outcome has been met, mark the conversation as complete.
                 3. If not, mark it as incomplete and briefly describe what remains to be done.

                 IMPORTANT: The output must be formatted as a JSON object with two keys:
                 `is_complete` (a boolean) and `reason` (a string).

                 Example Expected Outcome: "The user has succesfully reset their password."
                 Example Conversation History:
                 [
                     {"role": "user", "content": "I forgot my password and need to reset it."},
                     {"role": "assistant", "content": "Sure. First, go to the login page and click 'Forgot Password'."},
                 ]
                 Example JSON Output:
                 {
                     "is_complete": false,
                     "reason": "The assistant explained how to forget password but ahas not confirmed that the user successfully set a new password."
                 }

                 Expected Outcome: "#{expected_outcome}"
                 Conversation History:
                 #{previous_conversation}
                 JSON Output:
     """ <> "            ")
    |> Python.dedent()
  end
end
