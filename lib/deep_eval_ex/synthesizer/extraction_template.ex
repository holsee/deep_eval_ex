# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/synthesizer/templates/template_extraction.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/synthesizer/templates_test.exs checks every byte.

defmodule DeepEvalEx.Synthesizer.ExtractionTemplate do
  @moduledoc """
  deepeval 4.3.1's `ExtractionTemplate`: the prompt that infers a styling
  (scenario, task and input format) from example inputs, rendered byte for
  byte.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  The prompt asking for the `scenario`, `task` and `input_format` behind
  `:inputs`, deepeval's `extract_prompt_structure_from_inputs`.

  ## Options

  - `:inputs` - the example inputs, printed as a Python list (required)
  """
  @spec extract_prompt_structure_from_inputs(keyword()) :: String.t()
  def extract_prompt_structure_from_inputs(opts) do
    inputs = opts |> Keyword.fetch!(:inputs) |> Python.str()

    """

                You are a prompt engineer tasked with reverse-engineering the original prompt that may have produced the following inputs. 
                Each input is a message that a user might submit to an AI system.

                Your job is to infer the structure of the original prompt by analyzing patterns in these inputs.

                Specifically, extract the following:
                
                1. `scenario`: Describe the type of person or user who would have submitted these inputs, and the context or purpose for doing so.
                2. `task`: What was the AI system expected to do in response to these inputs?
                3. `input_format`: Describe the style, tone, or structure of the inputs — how the inputs are typically phrased.

                You MUST return your answer strictly in the following JSON format:

                ```json
                {
                    "scenario": "<your answer here>",
                    "task": "<your answer here>",
                    "input_format": "<your answer here>"
                }
                ```

                **
                IMPORTANT: Do not use any prior knowledge. Only rely on what is observable in the inputs themselves.   

                Example inputs: [
                    "How many users signed up last week?",
                    "Show me the total revenue for March.",
                    "Which products had the highest sales yesterday?"
                ]

                Example output:
                {
                    "scenario": "Non-technical users trying to query a database using plain English.",
                    "task": "Answering text-to-SQL-related queries by querying a database and returning the results to users.",
                    "input_format": "Questions in English that ask for data in a database."
                }

                Here are the inputs to analyze:

                #{inputs}
    """ <> "     "
  end
end
