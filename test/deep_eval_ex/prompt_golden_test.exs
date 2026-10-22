defmodule DeepEvalEx.PromptGoldenTest do
  @moduledoc """
  Renders the prompt goldens of `test/fixtures/deepeval/prompts/` with
  DeepEvalEx's prompt functions and compares them with the prompts deepeval
  4.3.1 rendered for the same inputs, byte for byte (see the fixtures'
  README).

  Each case's `input.json` names the deepeval template (`template`, e.g.
  `"FaithfulnessMetric.generate_truths"`) and the metric-level `inputs`;
  `prompt.txt` is deepeval's rendering. `@templates` maps each template to
  the `DeepEvalEx.Prompts` function standing for it, and `options/2` turns
  the inputs into that function's options the way the DeepEvalEx metric
  does.

  Comparisons that fail because of a documented divergence from 4.3.1 are
  tagged `known_divergence: "<unit>"`, naming the ROADMAP unit that removes
  the tag. They are excluded by default; run them with
  `mix test --only known_divergence`.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Prompts
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase

  @moduletag :parity

  @fixtures Path.expand("../fixtures/deepeval/prompts", __DIR__)

  @cases @fixtures
         |> File.ls!()
         |> Enum.filter(&File.regular?(Path.join([@fixtures, &1, "input.json"])))
         |> Enum.sort()

  for name <- @cases, file <- ~w(input.json prompt.txt) do
    @external_resource Path.join([@fixtures, name, file])
  end

  # deepeval 4.3.1 template (class key and method) => the DeepEvalEx.Prompts
  # function standing for it. The fixtures' README has the same table.
  @templates %{
    "GEval.generate_evaluation_steps" => {Prompts.GEval, :generate_evaluation_steps},
    "GEval.generate_evaluation_results" => {Prompts.GEval, :generate_evaluation_results},
    "GEval.generate_strict_evaluation_results" =>
      {Prompts.GEval, :generate_strict_evaluation_results},
    "FaithfulnessMetric.generate_claims" => {Prompts.Faithfulness, :generate_claims},
    "FaithfulnessMetric.generate_truths" => {Prompts.Faithfulness, :generate_truths},
    "FaithfulnessMetric.generate_verdicts" => {Prompts.Faithfulness, :generate_verdicts},
    "FaithfulnessMetric.generate_reason" => {Prompts.Faithfulness, :generate_reason},
    "HallucinationMetric.generate_verdicts" => {Prompts.Hallucination, :generate_verdicts},
    "HallucinationMetric.generate_reason" => {Prompts.Hallucination, :generate_reason},
    "AnswerRelevancyMetric.generate_statements" =>
      {Prompts.AnswerRelevancy, :generate_statements},
    "AnswerRelevancyMetric.generate_verdicts" => {Prompts.AnswerRelevancy, :generate_verdicts},
    "AnswerRelevancyMetric.generate_reason" => {Prompts.AnswerRelevancy, :generate_reason},
    "ContextualPrecisionMetric.generate_verdicts" =>
      {Prompts.ContextualPrecision, :generate_verdicts},
    "ContextualPrecisionMetric.generate_reason" =>
      {Prompts.ContextualPrecision, :generate_reason},
    "ContextualRecallMetric.generate_verdicts" => {Prompts.ContextualRecall, :generate_verdicts},
    "ContextualRecallMetric.generate_reason" => {Prompts.ContextualRecall, :generate_reason},
    "ToolCorrectnessMetric.get_tool_selection_score" =>
      {Prompts.ToolCorrectness, :get_tool_selection_score}
  }

  # {the ROADMAP unit that removes the tag, cases}. The fixtures' README
  # lists every reason.
  @known_divergences []

  known_divergence = fn name ->
    Enum.find_value(@known_divergences, fn {unit, cases} -> if name in cases, do: unit end)
  end

  test "lists known divergences of existing cases only" do
    for {_unit, cases} <- @known_divergences do
      assert cases -- @cases == []
    end
  end

  test "covers every template of the seven LLM metrics" do
    templates = @cases |> Enum.map(&input(&1)["template"]) |> Enum.uniq() |> Enum.sort()

    assert templates == @templates |> Map.keys() |> Enum.sort()
  end

  test "maps every DeepEvalEx prompt function to a deepeval template" do
    prompt_functions =
      for module <- [
            Prompts.AnswerRelevancy,
            Prompts.ContextualPrecision,
            Prompts.ContextualRecall,
            Prompts.Faithfulness,
            Prompts.GEval,
            Prompts.Hallucination,
            Prompts.ToolCorrectness
          ],
          {fun, 1} <- module.__info__(:functions),
          not String.starts_with?(Atom.to_string(fun), "format_"),
          do: {module, fun}

    assert Enum.sort(prompt_functions) == @templates |> Map.values() |> Enum.sort()
  end

  for name <- @cases do
    if unit = known_divergence.(name), do: @tag(known_divergence: unit)

    test "#{name} renders deepeval's prompt" do
      %{"template" => template, "inputs" => inputs} = input(unquote(name))
      {module, fun} = Map.fetch!(@templates, template)

      assert apply(module, fun, [options(template, inputs)]) ==
               File.read!(Path.join([@fixtures, unquote(name), "prompt.txt"]))
    end
  end

  defp input(name),
    do: Path.join([@fixtures, name, "input.json"]) |> File.read!() |> Jason.decode!()

  # The options the DeepEvalEx metric passes its prompt function for these
  # metric-level inputs.
  defp options("GEval.generate_evaluation_steps", inputs) do
    [
      criteria: inputs["criteria"],
      parameters: Prompts.GEval.format_params(params(inputs))
    ]
  end

  defp options("GEval.generate_evaluation_results", inputs) do
    rubric = rubric(inputs["rubric"])

    options("GEval.generate_strict_evaluation_results", inputs) ++
      [rubric: Prompts.GEval.format_rubric(rubric), score_range: score_range(rubric)]
  end

  defp options("GEval.generate_strict_evaluation_results", inputs) do
    params = params(inputs)

    [
      evaluation_steps: inputs["evaluation_steps"],
      test_case_content:
        Prompts.GEval.format_test_case_content(TestCase.new!(inputs["test_case"]), params),
      parameters: Prompts.GEval.format_params(params)
    ]
  end

  defp options("FaithfulnessMetric.generate_claims", inputs) do
    [actual_output: inputs["actual_output"]]
  end

  defp options("FaithfulnessMetric.generate_truths", inputs) do
    [
      retrieval_context: Enum.join(inputs["retrieval_context"], "\n\n"),
      extraction_limit: inputs["truths_extraction_limit"]
    ]
  end

  defp options("FaithfulnessMetric.generate_verdicts", inputs) do
    [claims: inputs["claims"], retrieval_context: Enum.join(inputs["truths"], "\n\n")]
  end

  defp options("FaithfulnessMetric.generate_reason", inputs) do
    [score: inputs["score"], contradictions: inputs["contradictions"]]
  end

  defp options("HallucinationMetric.generate_verdicts", inputs) do
    [actual_output: inputs["actual_output"], contexts: inputs["contexts"]]
  end

  defp options("HallucinationMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      factual_alignments: inputs["factual_alignments"],
      contradictions: inputs["contradictions"]
    ]
  end

  defp options("AnswerRelevancyMetric.generate_statements", inputs) do
    [actual_output: inputs["actual_output"]]
  end

  defp options("AnswerRelevancyMetric.generate_verdicts", inputs) do
    [input: inputs["input"], statements: inputs["statements"]]
  end

  defp options("AnswerRelevancyMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      input: inputs["input"],
      irrelevant_statements: inputs["irrelevant_statements"]
    ]
  end

  defp options("ContextualPrecisionMetric.generate_verdicts", inputs) do
    [
      input: inputs["input"],
      expected_output: inputs["expected_output"],
      retrieval_context: inputs["retrieval_context"]
    ]
  end

  # The generator renders verdicts as plain strings. The metric passes its
  # verdict atoms, which print as deepeval's Verdict members, as the
  # scripted-judge scenarios check.
  defp options("ContextualPrecisionMetric.generate_reason", inputs) do
    verdicts =
      Enum.map(inputs["verdicts"], fn %{"verdict" => verdict, "reason" => reason} ->
        %{verdict: verdict, reason: reason}
      end)

    [score: inputs["score"], input: inputs["input"], verdicts: verdicts]
  end

  defp options("ContextualRecallMetric.generate_verdicts", inputs) do
    [
      expected_output: inputs["expected_output"],
      retrieval_context: inputs["retrieval_context"]
    ]
  end

  defp options("ContextualRecallMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      expected_output: inputs["expected_output"],
      supportive_reasons: inputs["supportive_reasons"],
      unsupportive_reasons: inputs["unsupportive_reasons"]
    ]
  end

  defp options("ToolCorrectnessMetric.get_tool_selection_score", inputs) do
    [
      user_input: inputs["input"],
      tools_called:
        inputs["tools_called"] |> tool_calls() |> Prompts.ToolCorrectness.format_tools(),
      available_tools:
        inputs["available_tools"] |> tool_calls() |> Prompts.ToolCorrectness.format_tools()
    ]
  end

  # Evaluation params name test case fields, atoms TestCase defines once
  # loaded.
  defp params(%{"evaluation_params" => names}) do
    Code.ensure_loaded!(TestCase)
    Enum.map(names, &String.to_existing_atom/1)
  end

  # deepeval's Rubric score ranges, as DeepEvalEx.Metrics.GEval's
  # {score, description} entries; the cases only use single-score ranges.
  defp rubric(nil), do: nil

  defp rubric(entries) do
    Enum.map(entries, fn %{"score_range" => [score, score], "expected_outcome" => outcome} ->
      {score, outcome}
    end)
  end

  # deepeval derives the score range from the rubric; 0-10 without one.
  defp score_range(nil), do: {0, 10}

  defp score_range(rubric) do
    {scores, _} = Enum.unzip(rubric)
    Enum.min_max(scores)
  end

  defp tool_calls(attrs) do
    Enum.map(attrs, fn attrs ->
      {:ok, tool_call} = ToolCall.new(attrs)
      tool_call
    end)
  end
end
