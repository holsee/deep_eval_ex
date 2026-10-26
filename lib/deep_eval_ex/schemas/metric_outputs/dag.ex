# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/schema.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Schemas.MetricOutputs.DAG do
  @moduledoc """
  JSON schemas for the LLM responses of a `DeepEvalEx.Metrics.DAG` graph's
  nodes, deepeval 4.3.1's `TaskNodeOutput`, `BinaryJudgementVerdict`, the
  `NonBinaryJudgementVerdict` model each non-binary judgement builds over
  its options, and `MetricScoreReason`.
  """

  @doc """
  JSON schema for a task's output: a string or a list of strings.

  deepeval's model also allows an object of strings, a free-form
  dictionary that OpenAI's strict structured outputs cannot express (see
  `DeepEvalEx.LLM.StrictSchema`), so the schema leaves it out;
  `parse_task_output/1` still accepts one from a judge answering in text.
  """
  @spec task_output_schema() :: map()
  def task_output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "output" => %{
          "anyOf" => [
            %{"type" => "string"},
            %{"type" => "array", "items" => %{"type" => "string"}}
          ]
        }
      },
      "required" => ["output"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses a task's output: a string, a list of strings or a map of strings,
  as deepeval's `Union[str, list[str], dict[str, str]]`.
  """
  @spec parse_task_output(term()) :: {:ok, String.t() | [String.t()] | map()} | {:error, term()}
  def parse_task_output(%{"output" => output} = response) do
    if task_output?(output), do: {:ok, output}, else: {:error, {:invalid_task_output, response}}
  end

  def parse_task_output(other), do: {:error, {:invalid_task_output, other}}

  defp task_output?(output) when is_binary(output), do: true
  defp task_output?(output) when is_list(output), do: Enum.all?(output, &is_binary/1)

  defp task_output?(output) when is_map(output) and not is_struct(output),
    do: Enum.all?(output, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp task_output?(_output), do: false

  @doc """
  JSON schema for a binary judgement's verdict.
  """
  @spec binary_verdict_schema() :: map()
  def binary_verdict_schema do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{"type" => "boolean"},
        "reason" => %{"type" => "string"}
      },
      "required" => ["verdict", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses a binary judgement's verdict. Like pydantic's lax booleans,
  `"true"`/`"false"`, `"yes"`/`"no"`, `"on"`/`"off"`, `"t"`/`"f"`,
  `"y"`/`"n"`, `"1"`/`"0"` (in any case) and `1`/`0` are accepted too.

  ## Examples

      iex> DeepEvalEx.Schemas.MetricOutputs.DAG.parse_binary_verdict(%{"verdict" => "Yes", "reason" => "Fine."})
      {:ok, %{verdict: true, reason: "Fine."}}
  """
  @spec parse_binary_verdict(term()) ::
          {:ok, %{verdict: boolean(), reason: String.t()}} | {:error, term()}
  def parse_binary_verdict(%{"verdict" => verdict, "reason" => reason} = response)
      when is_binary(reason) do
    case boolean(verdict) do
      {:ok, verdict} -> {:ok, %{verdict: verdict, reason: reason}}
      :error -> {:error, {:invalid_verdict, response}}
    end
  end

  def parse_binary_verdict(other), do: {:error, {:invalid_verdict, other}}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(value) when value in [1, 1.0], do: {:ok, true}
  defp boolean(value) when value in [0, 0.0], do: {:ok, false}

  defp boolean(value) when is_binary(value) do
    case String.downcase(value) do
      text when text in ~w(true t yes y on 1) -> {:ok, true}
      text when text in ~w(false f no n off 0) -> {:ok, false}
      _other -> :error
    end
  end

  defp boolean(_value), do: :error

  @doc """
  JSON schema for a non-binary judgement's verdict, one of `options`.
  """
  @spec non_binary_verdict_schema([String.t()]) :: map()
  def non_binary_verdict_schema(options) do
    %{
      "type" => "object",
      "properties" => %{
        "verdict" => %{"type" => "string", "enum" => options},
        "reason" => %{"type" => "string"}
      },
      "required" => ["verdict", "reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses a non-binary judgement's verdict, which must be one of `options`.
  """
  @spec parse_non_binary_verdict(term(), [String.t()]) ::
          {:ok, %{verdict: String.t(), reason: String.t()}} | {:error, term()}
  def parse_non_binary_verdict(%{"verdict" => verdict, "reason" => reason} = response, options)
      when is_binary(reason) do
    if verdict in options,
      do: {:ok, %{verdict: verdict, reason: reason}},
      else: {:error, {:invalid_verdict, response}}
  end

  def parse_non_binary_verdict(other, _options), do: {:error, {:invalid_verdict, other}}

  @doc """
  JSON schema for the reason of the score a verdict ended the walk with.
  """
  @spec reason_schema() :: map()
  def reason_schema do
    %{
      "type" => "object",
      "properties" => %{"reason" => %{"type" => "string"}},
      "required" => ["reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Parses the reason.
  """
  @spec parse_reason(term()) :: {:ok, String.t()} | {:error, term()}
  def parse_reason(%{"reason" => reason}) when is_binary(reason), do: {:ok, reason}
  def parse_reason(other), do: {:error, {:invalid_reason_response, other}}
end
