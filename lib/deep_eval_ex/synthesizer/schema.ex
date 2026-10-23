# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer.Schema do
  @moduledoc """
  The structured outputs `DeepEvalEx.Synthesizer` asks its model and critic
  for, deepeval 4.3.1's `synthesizer/schema.py` models, as JSON schemas,
  and their parsers.

  | Function                | deepeval model      | Step (see `DeepEvalEx.LLM.Adapters.Mock.step_key/1`) |
  | ----------------------- | ------------------- | ---------------------------------------------------- |
  | `synthetic_data_list/0` | `SyntheticDataList` | `"data"`                                             |
  | `synthetic_data/0`      | `SyntheticData`     | `"input,used_source_files"`                          |
  | `input_feedback/0`      | `InputFeedback`     | `"feedback,score"`                                   |
  | `rewritten_input/0`     | `RewrittenInput`    | `"rewritten_input"`                                  |
  | `prompt_styling/0`      | `PromptStyling`     | `"input_format,scenario,task"`                       |
  | `response/0`            | `Response`          | `"response"`                                         |

  Each `parse_*` function validates a decoded answer as pydantic validates
  the model, returning `{:error, {:invalid_response, model, answer}}` for
  an answer that does not fit.
  """

  @string %{"type" => "string"}

  @synthetic_data %{
    "type" => "object",
    "properties" => %{
      "input" => @string,
      "used_source_files" => %{"type" => ["array", "null"], "items" => @string}
    },
    "required" => ["input"]
  }

  @typedoc "A generated input, and the source files it used, if any."
  @type synthetic_data :: %{input: String.t(), used_source_files: [String.t()] | nil}

  @doc "deepeval's `SyntheticDataList`: generated inputs."
  @spec synthetic_data_list() :: map()
  def synthetic_data_list do
    object(%{"data" => %{"type" => "array", "items" => @synthetic_data}})
  end

  @doc "deepeval's `SyntheticData`: one input, restyled."
  @spec synthetic_data() :: map()
  def synthetic_data, do: @synthetic_data

  @doc "deepeval's `InputFeedback`: the critic's score and feedback."
  @spec input_feedback() :: map()
  def input_feedback, do: object(%{"score" => %{"type" => "number"}, "feedback" => @string})

  @doc "deepeval's `RewrittenInput`: an input rewritten from feedback."
  @spec rewritten_input() :: map()
  def rewritten_input, do: object(%{"rewritten_input" => @string})

  @doc "deepeval's `PromptStyling`: a styling extracted from inputs."
  @spec prompt_styling() :: map()
  def prompt_styling,
    do: object(%{"scenario" => @string, "task" => @string, "input_format" => @string})

  @doc "deepeval's `Response`: a custom model's free-text answer."
  @spec response() :: map()
  def response, do: object(%{"response" => @string})

  @doc """
  Parses a `SyntheticDataList` answer into its inputs.

  ## Examples

      iex> DeepEvalEx.Synthesizer.Schema.parse_synthetic_data_list(%{"data" => [%{"input" => "Why?"}]})
      {:ok, [%{input: "Why?", used_source_files: nil}]}
  """
  @spec parse_synthetic_data_list(term()) :: {:ok, [synthetic_data()]} | {:error, term()}
  def parse_synthetic_data_list(%{"data" => items} = answer) when is_list(items) do
    items
    |> Enum.reduce_while([], fn item, acc ->
      case parse_synthetic_data(item) do
        {:ok, data} -> {:cont, [data | acc]}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      :error -> invalid("SyntheticDataList", answer)
      data -> {:ok, Enum.reverse(data)}
    end
  end

  def parse_synthetic_data_list(answer), do: invalid("SyntheticDataList", answer)

  @doc """
  Parses a `SyntheticData` answer.
  """
  @spec parse_synthetic_data(term()) :: {:ok, synthetic_data()} | {:error, term()}
  def parse_synthetic_data(%{"input" => input} = answer) when is_binary(input) do
    case Map.get(answer, "used_source_files") do
      files when is_nil(files) or is_list(files) ->
        if Enum.all?(files || [], &is_binary/1),
          do: {:ok, %{input: input, used_source_files: files}},
          else: invalid("SyntheticData", answer)

      _ ->
        invalid("SyntheticData", answer)
    end
  end

  def parse_synthetic_data(answer), do: invalid("SyntheticData", answer)

  @doc """
  Parses an `InputFeedback` answer into `{score, feedback}`, the score a
  float as pydantic casts it.

  ## Examples

      iex> DeepEvalEx.Synthesizer.Schema.parse_input_feedback(%{"score" => 1, "feedback" => "Clear."})
      {:ok, {1.0, "Clear."}}
  """
  @spec parse_input_feedback(term()) :: {:ok, {float(), String.t()}} | {:error, term()}
  def parse_input_feedback(%{"score" => score, "feedback" => feedback})
      when is_number(score) and is_binary(feedback),
      do: {:ok, {score * 1.0, feedback}}

  def parse_input_feedback(answer), do: invalid("InputFeedback", answer)

  @doc "Parses a `RewrittenInput` answer into the rewritten input."
  @spec parse_rewritten_input(term()) :: {:ok, String.t()} | {:error, term()}
  def parse_rewritten_input(%{"rewritten_input" => input}) when is_binary(input), do: {:ok, input}
  def parse_rewritten_input(answer), do: invalid("RewrittenInput", answer)

  @doc "Parses a `PromptStyling` answer into a keyword list of its fields."
  @spec parse_prompt_styling(term()) :: {:ok, keyword()} | {:error, term()}
  def parse_prompt_styling(%{"scenario" => scenario, "task" => task, "input_format" => format})
      when is_binary(scenario) and is_binary(task) and is_binary(format),
      do: {:ok, [scenario: scenario, task: task, input_format: format]}

  def parse_prompt_styling(answer), do: invalid("PromptStyling", answer)

  @doc "Parses a `Response` answer into its text."
  @spec parse_response(term()) :: {:ok, String.t()} | {:error, term()}
  def parse_response(%{"response" => response}) when is_binary(response), do: {:ok, response}
  def parse_response(answer), do: invalid("Response", answer)

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
