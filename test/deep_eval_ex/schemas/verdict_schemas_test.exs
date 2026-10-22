# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Schemas.VerdictSchemasTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.MetricOutputs.{
    AnswerRelevancy,
    Bias,
    ContextualPrecision,
    ContextualRecall,
    ContextualRelevancy,
    Faithfulness,
    Hallucination,
    PIILeakage,
    PromptAlignment,
    Toxicity
  }

  # deepeval 4.3.1's verdict schemas: `YesNoBorderline` for Faithfulness and
  # AnswerRelevancy, `YesNo` for the others
  @vocabularies [
    {AnswerRelevancy, ["yes", "no", "borderline"]},
    {Faithfulness, ["yes", "no", "borderline"]},
    {Hallucination, ["yes", "no"]},
    {ContextualRecall, ["yes", "no"]},
    {ContextualPrecision, ["yes", "no"]},
    {ContextualRelevancy, ["yes", "no"]},
    {Bias, ["yes", "no"]},
    {Toxicity, ["yes", "no"]},
    {PIILeakage, ["yes", "no"]},
    {PromptAlignment, ["yes", "no"]}
  ]

  for {schema, vocabulary} <- @vocabularies do
    test "#{inspect(schema)} asks for deepeval's verdict vocabulary" do
      verdict =
        get_in(unquote(schema).verdicts_schema(), [
          "properties",
          "verdicts",
          "items",
          "properties",
          "verdict"
        ])

      assert verdict["enum"] == unquote(vocabulary)
    end
  end
end
