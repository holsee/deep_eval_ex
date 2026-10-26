# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/simulator/template.py and utils.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/simulator/templates_test.exs checks every byte.

defmodule DeepEvalEx.ConversationSimulator.SimulationTemplate do
  @moduledoc """
  deepeval 4.3.1's `SimulationTemplate`: the prompts the simulated user's
  turns are generated with, rendered byte for byte, and the behaviour a
  custom template implements.

  A custom template is a module implementing both callbacks, passed to
  `DeepEvalEx.ConversationSimulator.SimulationNode.default/1` as
  `:template`, as deepeval's `default_simulation_node(template=...)` takes a
  `SimulationTemplate` subclass. The model must answer either prompt with
  a JSON object whose `simulated_input` key holds the user's next message.

      defmodule MyApp.TerseUser do
        @behaviour DeepEvalEx.ConversationSimulator.SimulationTemplate

        @impl true
        def simulate_first_user_turn(golden, language),
          do: "Open a conversation in \#{language} about: \#{golden.scenario} ..."

        @impl true
        def simulate_user_turn(golden, turns, language), do: "..."
      end

  As deepeval's, the default templates are dedented with Python's
  `textwrap.dedent` after the golden and turns are filled in (see
  `DeepEvalEx.Prompts.Python.dedent/1`).
  """

  alias DeepEvalEx.Dataset.{ConversationalGolden, Persona}
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn

  @doc "The prompt for the conversation's opening user turn."
  @callback simulate_first_user_turn(golden :: ConversationalGolden.t(), language :: String.t()) ::
              String.t()

  @doc "The prompt for the next user turn, given the conversation so far."
  @callback simulate_user_turn(
              golden :: ConversationalGolden.t(),
              turns :: [Turn.t()],
              language :: String.t()
            ) :: String.t()

  @behaviour __MODULE__

  @multimodal_rules """

                            --- MULTIMODAL INPUT RULES ---
                            - Treat image content as factual evidence.
                            - Only reference visual details that are explicitly and clearly visible.
                            - Do not infer or guess objects, text, or details not visibly present.
                            - If an image is unclear or ambiguous, mark uncertainty explicitly.
                    """ <> "    "

  @doc """
  The prompt for the opening user turn, deepeval's
  `simulate_first_user_turn`: the scenario, the persona (when the golden
  has one) and the language to write in.
  """
  @impl true
  @spec simulate_first_user_turn(ConversationalGolden.t(), String.t()) :: String.t()
  def simulate_first_user_turn(%ConversationalGolden{} = golden, language) do
    ("""
     Pretend you are a user of an LLM app. Your goal is to start a conversation in #{language} based on a scenario 
                 and persona. The scenario defines your context and motivation for interacting with the LLM, 
                 while the persona describes who you are and how you speak.

                 Guidelines:
                 1. The opening message should clearly convey the user's intent or need within the scenario.
                 2. Match the persona's tone faithfully. If the user is frustrated, impatient, blunt, or impolite, reflect that naturally instead of making them warm or courteous.
                 3. Avoid providing excessive details upfront; the goal is to initiate the conversation and build rapport, not to solve it in the first message.
                 4. The message should be concise, ideally no more than 1-3 sentences.

                 #{@multimodal_rules}

                 IMPORTANT: The output must be formatted as a JSON object with a single key `simulated_input`, where the value is the generated opening message in #{language}.

                 Example Language: english
                 Example Persona:
                 <persona>
                 Jeff Seid, is available Monday and Thursday afternoons, and their phone number is 0010281839. He suffers from chronic migraines.
                 </persona>
                 Example Scenario: "A sick person trying to get a diagnosis for persistent headaches and fever."
                 Example JSON Output:
                 {
                     "simulated_input": "Hi, I haven’t been feeling well lately. I’ve had these headaches and a fever that just won’t go away. Could you help me figure out what’s going on?"
                 }

                 Language: #{language}
                 #{persona_block(golden)}
                 Scenario: "#{golden.scenario}"
                 JSON Output:
     """ <> "        ")
    |> Python.dedent()
  end

  @doc """
  The prompt for the next user turn, deepeval's `simulate_user_turn`: as
  `simulate_first_user_turn/2`, with the conversation so far
  (`serialize_turns_for_prompt/1`).
  """
  @impl true
  @spec simulate_user_turn(ConversationalGolden.t(), [Turn.t()], String.t()) :: String.t()
  def simulate_user_turn(%ConversationalGolden{} = golden, turns, language) do
    previous_conversation = serialize_turns_for_prompt(turns)

    ("""

                 Pretend you are a user of an LLM app. Your task is to generate the next user input in #{language} 
                 based on the provided scenario, persona, and the previous conversation.

                 Guidelines:
                 1. Use the scenario and persona as the guiding context for the user's next input.
                 2. Ensure the next input feels natural, conversational, and relevant to the last assistant reply in the conversation.
                 3. Keep the tone consistent with the previous user inputs.
                 4. The generated user input should be concise, ideally no more than 1-2 sentences.

                 #{@multimodal_rules}

                 IMPORTANT: The output must be formatted as a JSON object with a single key `simulated_input`, 
                 where the value is the generated user input in #{language}.

                 Example Language: english
                 Example Persona:
                 <persona>
                 Jeff Seid, is available Monday and Thursday afternoons, and their phone number is 0010281839.
                 </persona>
                 Example Scenario: "A user seeking tips for securing a funding round."
                 Example Previous Conversation:
                 [
                     {"role": "user", "content": "Hi, I need help preparing for my funding pitch."},
                     {"role": "assistant", "content": "Of course! Can you share more about your business and the type of investors you are targeting?"}
                 ]
                 Example JSON Output:
                 {
                     "simulated_input": "Sure, we are a SaaS startup focusing on productivity tools for small businesses."
                 }

                 Language: #{language}
                 #{persona_block(golden)}
                 Scenario: "#{golden.scenario}"
                 Previous Conversation:
                 #{previous_conversation}

                 JSON Output:
     """ <> "        ")
    |> Python.dedent()
  end

  @doc """
  The turns as a prompt shows them, deepeval's `serialize_turns_for_prompt`:
  each turn's `DeepEvalEx.Turn.model_dump_for_prompt/1` in a JSON list
  indented by four spaces, non-ASCII characters kept.

  ## Examples

      iex> DeepEvalEx.ConversationSimulator.SimulationTemplate.serialize_turns_for_prompt([])
      "[]"
  """
  @spec serialize_turns_for_prompt([Turn.t()]) :: String.t()
  def serialize_turns_for_prompt(turns) do
    turns
    |> Enum.map(&Turn.model_dump_for_prompt/1)
    |> JSON.encode!(indent: 4, ensure_ascii: false)
  end

  # deepeval's _persona_block: the persona's prompt block, its continuation
  # lines indented as the template's own.
  defp persona_block(%ConversationalGolden{persona: nil}), do: ""

  defp persona_block(%ConversationalGolden{persona: persona}),
    do:
      persona |> Persona.prompt_block() |> String.replace("\n", "\n" <> String.duplicate(" ", 12))
end
