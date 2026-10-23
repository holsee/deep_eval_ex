# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/synthesizer/templates/template_prompt.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/synthesizer/templates_test.exs checks every byte.

defmodule DeepEvalEx.Synthesizer.PromptSynthesizerTemplate do
  @moduledoc """
  deepeval 4.3.1's `PromptSynthesizerTemplate`: the prompt
  `DeepEvalEx.Synthesizer` generates inputs from scratch with, rendered
  byte for byte.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  The prompt asking for `:num_goldens` inputs fitting a scenario, task and
  input format, deepeval's `generate_synthetic_prompts`.

  ## Options

  - `:scenario`, `:task`, `:input_format` - the styling (required)
  - `:num_goldens` - how many inputs to ask for (required)
  """
  @spec generate_synthetic_prompts(keyword()) :: String.t()
  def generate_synthetic_prompts(opts) do
    scenario = opts |> Keyword.fetch!(:scenario) |> Python.str()
    task = opts |> Keyword.fetch!(:task) |> Python.str()
    input_format = opts |> Keyword.fetch!(:input_format) |> Python.str()
    num_goldens = opts |> Keyword.fetch!(:num_goldens) |> Python.str()

    """
    Generate a series of input prompts from scratch based on the provided scenario, task, and output format.
            The inputs must align with the given scenario and task description, and conform to specified output format.

            **
            IMPORTANT: Please make sure to only return in JSON format, with the 'data' key as a list of JSON objects.
            You MUST TRY to generate #{num_goldens} data points.

            Example scenario: technical SWE typing SQL queries to query from a database called FAST_FOOD_RESTAURANTS
            Example task: Text2SQL LLM Assistant
            Example input format: SQL String
            Example num prompts: 2
            Example JSON:
            {
                "data": [
                    {
                        "input": "SELECT * FROM menu"
                    },
                    {
                        "input": "SELECT AVG(price) FROM menu;"
                    }
                ]  
            }

            You MUST include at least one statement as the input. `input` MUST be of `#{input_format}` format.
            You MUST TRY to generate #{num_goldens} data points, unless the generated `input` is getting repetitive.
            **

            scenario: #{scenario}
            task: #{task}
            input format: #{input_format}
            num prompts: #{num_goldens}
            JSON:
    """ <> "        "
  end
end
