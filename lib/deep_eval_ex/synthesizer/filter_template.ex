# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/synthesizer/templates/template.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/synthesizer/templates_test.exs checks every byte.

defmodule DeepEvalEx.Synthesizer.FilterTemplate do
  @moduledoc """
  deepeval 4.3.1's `FilterTemplate`: the prompt the critic model scores a
  synthetic input's clarity and answerability with, rendered byte for byte.
  """

  alias DeepEvalEx.Prompts.Python

  @doc """
  The prompt asking the critic for `feedback` and a `score` from 0 to 1,
  deepeval's `evaluate_synthetic_inputs`.

  ## Options

  - `:query` - the synthetic input (required)
  """
  @spec evaluate_synthetic_inputs(keyword()) :: String.t()
  def evaluate_synthetic_inputs(opts) do
    query = opts |> Keyword.fetch!(:query) |> Python.str()

    """
    Evaluate the provided synthetic query (which may be a question, task, or instruction) for clarity and answerability, assuming sufficient domain knowledge. Use the following criteria to guide your assessment:

            1. **Self-Containment**: Can the query be understood and completed without needing additional context or external references not provided within the query itself? It should be self-sufficient, meaning it doesn't depend on specific documents, tables, or prior knowledge not included in the query.
            2. **Clear Objective**: Does the query clearly convey its intent? It should specify what information, action, or response is being requested, allowing for a direct and appropriate answer or execution without ambiguity.

            Based on these criteria, assign a score between 0 and 1, where:
            - "1" means the query is clear, self-contained, and answerable.
            - "0" means the query is vague, relies on external references, or is unclear in its intent.
            - Scores between 0 and 1 indicate partial clarity or answerability, where the query meets some but not all of the criteria.

            **
            IMPORTANT: Please make sure to only return in JSON format, with the 'feedback' and 'score' keys.

            Example query: "What technological innovations have changed communication over the last 20 years?"
            Example JSON:
            {
                "feedback": "The query is somewhat vague as it asks about 'technological innovations' without specifying particular areas of communication (e.g., social media, messaging apps). It could be improved by narrowing the focus to a specific type of innovation or timeframe.",
                "score": 0.5
            }

            Example query: "Explain the impact of renewable energy policies in Germany on local economies in 2021."
            Example JSON:
            {
                "feedback": "This query clearly specifies the focus (renewable energy policies), the region (Germany), and the timeframe (2021). It is self-contained and answerable without needing additional context, making it clear and effective.",
                "score": 1.0
            }

            Example query: "What are the main criticisms of the current education system in the United States?"
            Example JSON:
            {
                "feedback": "The question is broad and lacks specificity, as 'main criticisms' could refer to various aspects (e.g., funding, curriculum, access). To improve clarity, it could specify which aspect of the education system is being critiqued.",
                "score": 0.4
            }

            Example query: "Discuss the role of AI in healthcare, particularly in diagnostics, as noted in the last report."
            Example JSON:
            {
                "feedback": "This question refers to 'the last report' without providing context or details, making it unclear and dependent on external information. It would be clearer if it provided some background on the report or defined what aspects of AI in diagnostics to address.",
                "score": 0.3
            }
                    
            The `feedback` MUST be a STRING and `score` must be a float from 0 to 1.
            **
                    
            Query:
            #{query}

            JSON:
    """ <> "        "
  end
end
