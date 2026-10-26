# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Prompt text copied verbatim from deepeval 4.3.1
# (deepeval/synthesizer/templates/template.py), Copyright Confident AI,
# Apache-2.0. Original: https://github.com/confident-ai/deepeval
#
# Keep the whitespace inside the prompts: it is deepeval's, and
# test/deep_eval_ex/synthesizer/templates_test.exs checks every byte.

defmodule DeepEvalEx.Synthesizer.SynthesizerTemplate do
  @moduledoc """
  deepeval 4.3.1's `SynthesizerTemplate`: the prompts
  `DeepEvalEx.Synthesizer` generates inputs and expected outputs with.

  Each function renders the deepeval method of the same name byte for byte.
  Lists (a context, the available source files) are printed as Python
  lists and `nil` as `None`, as deepeval's f-strings print them (see
  `DeepEvalEx.Prompts.Python.str/1`). A styling field that is `nil` or
  `""` is left out, as deepeval leaves out a falsy one.
  """

  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.TestRun.JSON

  @doc """
  The prompt asking for the expected output of an input, deepeval's
  `generate_synthetic_expected_output`.

  ## Options

  - `:input` - the (evolved) input (required)
  - `:context` - the context, its chunks joined with newlines (required)
  - `:expected_output_format` - the format the output must follow
  """
  @spec generate_synthetic_expected_output(keyword()) :: String.t()
  def generate_synthetic_expected_output(opts) do
    input = opts |> Keyword.fetch!(:input) |> Python.str()
    context = opts |> Keyword.fetch!(:context) |> Python.str()
    expected_output_format = Keyword.get(opts, :expected_output_format)

    important_section =
      if present?(expected_output_format),
        do:
          "IMPORTANT: Please ensure that the generated response strictly adheres to the following format: #{expected_output_format}, and make sure it is concise and straight to the point, using supporting information in context.",
        else:
          "IMPORTANT: Please make sure to generate a response that is concise and straight to the point, and uses supporting information in context."

    """
    Given the input, which may or may not be a question, generate a response using information presented in context.

            **
            #{important_section}
            **

            Context:
            #{context}

            Input:
            #{input}

            Generated Response:
    """ <> "        "
  end

  @doc """
  The prompt asking for up to `:max_goldens_per_context` inputs from a
  context, deepeval's `generate_synthetic_inputs`.

  ## Options

  - `:context` - the context, a list of chunks (required)
  - `:max_goldens_per_context` - how many inputs to ask for (required)
  - `:scenario`, `:task`, `:input_format` - the styling, each optional
  - `:available_source_files` - the source labels of a context spanning
    files; with two or more, the prompt asks for cross-file inputs and
    their `used_source_files`
  - `:target_files_per_context` - how many of those files each input
    must combine
  """
  @spec generate_synthetic_inputs(keyword()) :: String.t()
  def generate_synthetic_inputs(opts) do
    context = opts |> Keyword.fetch!(:context) |> Python.str()
    max_goldens_per_context = opts |> Keyword.fetch!(:max_goldens_per_context) |> Python.str()
    scenario = Keyword.get(opts, :scenario)
    task = Keyword.get(opts, :task)
    input_format = Keyword.get(opts, :input_format)

    input_format_section =
      if present?(input_format),
        do: "`input` MUST strictly adhere to the following format: #{input_format}.",
        else: "`input` MUST be a STRING."

    scenario_section =
      if present?(scenario),
        do:
          "`input`s MUST be relevant to this specific scenario: ```#{scenario}``` (The scenario describes the circumstances under which the inputs are generated and the user's intent in eliciting a response).",
        else: ""

    task_section =
      if present?(task),
        do:
          "`input`s MUST be framed in a way that evokes a response aligned with the following task: #{task} (The task represents the goal or function the entity is expected to achieve when responding).",
        else: ""

    source_files_section =
      source_files_section(
        Keyword.get(opts, :available_source_files),
        Keyword.get(opts, :target_files_per_context)
      )

    """
    I want you act as a copywriter. Based on the given context, which is list of strings, please generate a list of JSON objects with a `input` key.
            The `input` can either be a question or a statement that can be addressed by the given context.

            **
            IMPORTANT: Please make sure to only return in JSON format, with the 'data' key as a list of JSON objects.
            You MUST TRY to generate #{max_goldens_per_context} data points, unless the `input` is getting repetitive.

            Example context: ["Einstein won the Nobel Prize for his discovery of penicillin.", "Einstein won the Nobel Prize in 1968."]
            Example max goldens per context: 2
            Example JSON:
            {
                "data": [
                    {
                        "input": "What was Einstein known for?"
                    },
                    {
                        "input": "Einstein was a smart guy huh"
                    }
                ]  
            }


            You should NOT incorporate any prior knowledge you have and take each context at face value.
            You MUST include at least one statement as the input.
            #{input_format_section}
            #{scenario_section}
            #{task_section}
            #{source_files_section}
            You MUST TRY to generate #{max_goldens_per_context} data points, unless the generated `input` is getting repetitive.
            **

            Max Goldens Per Context:
            #{max_goldens_per_context}

            Context:
            #{context}

            JSON:
    """ <> "        "
  end

  defp source_files_section(available, target)
       when is_list(available) and length(available) >= 2 do
    cross_file_strength_section =
      if is_nil(target),
        do:
          "Each generated `input` SHOULD combine information from multiple source files whenever possible.",
        else:
          "Each generated `input` MUST meaningfully combine information from at least #{target} different source files. Ensure ATLEAST #{target} source files are used in the `input`."

    example_sources = available |> Enum.take(2) |> JSON.encode!()
    available_source_files = Python.repr(available)

    """

                    This context is constructed from multiple files with these source labels: #{available_source_files}.
                    Each chunk in the context is prefixed with its origin as `[SOURCE: <label>]`.
                    Your goal is to generate powerful, cross-file goldens that test reasoning across different files, not single-file recall.

                    #{cross_file_strength_section}

                    For each generated item, include a `used_source_files` key listing only the source labels actually used to form that `input`.
                    `used_source_files` MUST be a JSON array of strings and each value MUST come from: #{available_source_files}.

                    Example JSON when source files are provided:
                    {
                        "data": [
                            {
                                "input": "...",
                                "used_source_files": #{example_sources}
                            }
                        ]
                    }
    """ <> "            "
  end

  defp source_files_section(_available, _target), do: ""

  @doc """
  The prompt restyling an evolved input to the scenario, task and input
  format, deepeval's `rewrite_evolved_input`.

  ## Options

  - `:evolved_input` - the evolved input (required)
  - `:scenario`, `:task`, `:input_format` - the styling, each optional
  """
  @spec rewrite_evolved_input(keyword()) :: String.t()
  def rewrite_evolved_input(opts) do
    evolved_input = opts |> Keyword.fetch!(:evolved_input) |> Python.str()
    scenario = Keyword.get(opts, :scenario)
    task = Keyword.get(opts, :task)
    input_format = Keyword.get(opts, :input_format)

    scenario_section = labelled("Scenario", scenario)
    task_section = labelled("Task", task)
    input_format_section = labelled("Input Format", input_format)
    example_scenario = labelled("Example Scenario", scenario)
    example_task = labelled("Example Task", task)
    example_input_format = labelled("Example Input Format", input_format)

    """
    Given the evolved input, which may be a question or a statement, generate a JSON object with a key 'input'. This key should contain a statement or question that fits any provided scenario, aligns with the task's purpose, and matches the required input format (if specified).

            **
            IMPORTANT: Try to change the evolved input as little as possible. However, if the evolved input does not align with the provided scenario, task, or input format, it must ultimately be adjusted to fit these requirements. The output must be in JSON format, with the 'input' key only. If necessary, the evolved input should be rewritten to ensure it conforms to the scenario, task, and input format.

            Example Evolved Input: "Is it okay to joke about someone losing their job in front of their coworkers if I'm just trying to lighten the mood?"
            #{example_scenario}
            #{example_task}
            #{example_input_format}
            Example JSON: {
                "input": "How can I joke about someone losing their job without making the situation worse? Is it possible to use humor here without hurting anyone's feelings?"
            }

            Evolved Input:
            #{evolved_input}
            
            #{scenario_section}
            #{task_section}
            #{input_format_section}

            JSON:
    """ <> "        "
  end

  @doc """
  The prompt rewriting an input the critic scored below the threshold,
  deepeval's `rewrite_synthetic_inputs`.

  ## Options

  - `:context` - the context, a list of chunks (required)
  - `:original_query` - the input to rewrite (required)
  - `:feedback` - the critic's feedback (required)
  """
  @spec rewrite_synthetic_inputs(keyword()) :: String.t()
  def rewrite_synthetic_inputs(opts) do
    context = opts |> Keyword.fetch!(:context) |> Python.str()
    original_query = opts |> Keyword.fetch!(:original_query) |> Python.str()
    feedback = opts |> Keyword.fetch!(:feedback) |> Python.str()

    """
    I want you to act as a query rewriter. Based on the provided context, original query, and feedback, generate a rewritten query that improves its clarity and answerability based on the feedback provided.

            **
            IMPORTANT: Please make sure to only return in JSON format, with the 'rewritten_input' key.

            Example context: "The Golden Gate Bridge, located in San Francisco, was completed in 1937 and is known for its Art Deco design. It connects the city of San Francisco to Marin County and spans the Golden Gate Strait."
            Example query: "When was the bridge completed?"
            Example feedback: "The question asks about the completion of 'the bridge' but does not specify which bridge it refers to. There are many famous bridges, and without specifying the name, the question is too vague. To improve clarity, include the bridge's name."
            Example JSON:
            {
                "rewritten_input": "When was the Golden Gate Bridge completed?"
            }

            Example context: "The paper 'Advancements in Quantum Computing' by Dr. Alice Thompson discusses breakthroughs in quantum algorithms and was published in 2022. It explores the potential applications of quantum computing in cryptography and drug discovery."
            Example query: "What applications of quantum computing are discussed in the paper?"
            Example feedback: "The query is asking about applications of quantum computing but doesn't specify which paper is being referenced. Since many papers may discuss quantum computing, it would help to specify the title or author of the paper to improve clarity."
            Example JSON:
            {
                "rewritten_input": "What applications of quantum computing are discussed in the paper 'Advancements in Quantum Computing' by Dr. Alice Thompson?"
            }

            You should NOT incorporate any prior knowledge and should base the rewritten query only on the context and feedback provided.
            The `rewritten_input` MUST be a STRING.
            **

            Context:
            #{context}

            Query:
            #{original_query}

            Feedback:
            #{feedback}

            JSON:
    """ <> "        "
  end

  # `Label: "value"`, or "" for a falsy value, as deepeval's
  # f'Label: "{value}"' if value else "".
  defp labelled(label, value) do
    if present?(value), do: ~s(#{label}: "#{value}"), else: ""
  end

  # Python truthiness of an optional string.
  defp present?(value), do: value not in [nil, ""]
end
