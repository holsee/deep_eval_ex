# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/utils/generation.py (trimAndLoadJson)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.Utils.Generation do
  @moduledoc """
  Loading a judge's JSON answer, as deepeval 4.3.1's `trimAndLoadJson` does.

  deepeval's `generate_with_schema_and_extract` asks the judge for a schema
  and, when the judge returns its raw text rather than a schema instance,
  loads the text with `trimAndLoadJson`. In DeepEvalEx the asking half is
  `DeepEvalEx.LLM.Adapter.generate_with_schema/3`, which loads any text it
  gets back with `trim_and_load_json/1`, and the extracting half is each
  metric's schema `parse_*` function.

  ## Divergences

  Elixir's JSON decoder rejects the `NaN`, `Infinity` and `-Infinity`
  literals Python's `json.loads` accepts, so text holding them is invalid
  JSON here.

  deepeval's model-level `trim_and_load_json` (`deepeval/models/llms/utils.py`,
  used inside its native OpenAI, Anthropic and Ollama models) strips trailing
  commas before the first parse; this is the metric-level one, which only
  does so once a direct parse fails.
  """

  alias DeepEvalEx.LLM.InvalidJSONError

  # A comma before a closing bracket, whitespace between; deepeval's
  # r",\s*([\]}])" on a str, where \s is any Unicode whitespace.
  @trailing_comma ~r/,\s*([\]}])/u

  @doc """
  Loads the JSON object in `text`, as deepeval's `trimAndLoadJson`.

  The object runs from the first `{` to the last `}`, so prose or a code
  fence around it is dropped; a missing closing `}` is added when there is
  none at all. When that does not parse, trailing commas before a `]` or `}`
  are stripped and it is parsed again. Anything else, `nil` included, is
  `{:error, %DeepEvalEx.LLM.InvalidJSONError{}}`, with deepeval's message.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json(~s(```json\\n{"verdict": "yes",}\\n```))
      {:ok, %{"verdict" => "yes"}}

      iex> DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json(~s({"reason": "Fine."))
      {:ok, %{"reason" => "Fine."}}

      iex> {:error, error} = DeepEvalEx.Metrics.Utils.Generation.trim_and_load_json("No.")
      iex> Exception.message(error)
      "Evaluation LLM outputted an invalid JSON. Please use a better evaluation model."
  """
  @spec trim_and_load_json(String.t() | nil) :: {:ok, term()} | {:error, InvalidJSONError.t()}
  def trim_and_load_json(nil), do: {:error, %InvalidJSONError{}}

  def trim_and_load_json(text) when is_binary(text) do
    json = text |> trim() |> IO.iodata_to_binary()

    with {:error, _} <- Jason.decode(json),
         {:error, _} <- json |> String.replace(@trailing_comma, "\\1") |> Jason.decode() do
      {:error, %InvalidJSONError{}}
    end
  end

  # deepeval's `input_string[start:end]`, with `start` the first "{" and
  # `end` just past the last "}": empty unless both exist, and when they are
  # out of order. The braces are ASCII, so byte offsets slice as Python's
  # code point offsets do.
  defp trim(text) do
    case {first_brace(text), last_brace_end(text)} do
      {nil, _end} -> ""
      {start, nil} -> [binary_part(text, start, byte_size(text) - start), "}"]
      {start, stop} when stop > start -> binary_part(text, start, stop - start)
      _out_of_order -> ""
    end
  end

  defp first_brace(text) do
    case :binary.match(text, "{") do
      {start, 1} -> start
      :nomatch -> nil
    end
  end

  defp last_brace_end(text) do
    case :binary.matches(text, "}") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end
end
