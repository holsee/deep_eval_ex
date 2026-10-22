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

  alias DeepEvalEx.{ConversationalTestCase, TestCase}
  alias DeepEvalEx.Metrics.ConversationalGEval
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Metrics.Utils.Turns
  alias DeepEvalEx.Prompts
  alias DeepEvalEx.Schemas.ToolCall
  alias Jason.OrderedObject

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
    "ConversationalGEval.generate_evaluation_steps" =>
      {Prompts.ConversationalGEval, :generate_evaluation_steps},
    "ConversationalGEval.generate_evaluation_results" =>
      {Prompts.ConversationalGEval, :generate_evaluation_results},
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
    "ContextualRelevancyMetric.generate_verdicts" =>
      {Prompts.ContextualRelevancy, :generate_verdicts},
    "ContextualRelevancyMetric.generate_reason" =>
      {Prompts.ContextualRelevancy, :generate_reason},
    "BiasMetric.generate_opinions" => {Prompts.Bias, :generate_opinions},
    "BiasMetric.generate_verdicts" => {Prompts.Bias, :generate_verdicts},
    "BiasMetric.generate_reason" => {Prompts.Bias, :generate_reason},
    "ToxicityMetric.generate_opinions" => {Prompts.Toxicity, :generate_opinions},
    "ToxicityMetric.generate_verdicts" => {Prompts.Toxicity, :generate_verdicts},
    "ToxicityMetric.generate_reason" => {Prompts.Toxicity, :generate_reason},
    "PIILeakageMetric.extract_pii" => {Prompts.PIILeakage, :extract_pii},
    "PIILeakageMetric.generate_verdicts" => {Prompts.PIILeakage, :generate_verdicts},
    "PIILeakageMetric.generate_reason" => {Prompts.PIILeakage, :generate_reason},
    "PromptAlignmentMetric.generate_verdicts" => {Prompts.PromptAlignment, :generate_verdicts},
    "PromptAlignmentMetric.generate_reason" => {Prompts.PromptAlignment, :generate_reason},
    "SummarizationMetric.generate_questions" => {Prompts.Summarization, :generate_questions},
    "SummarizationMetric.generate_answers" => {Prompts.Summarization, :generate_answers},
    "SummarizationMetric.generate_alignment_verdicts" =>
      {Prompts.Summarization, :generate_alignment_verdicts},
    "SummarizationMetric.generate_reason" => {Prompts.Summarization, :generate_reason},
    "ArgumentCorrectnessMetric.generate_verdicts" =>
      {Prompts.ArgumentCorrectness, :generate_verdicts},
    "ArgumentCorrectnessMetric.generate_reason" =>
      {Prompts.ArgumentCorrectness, :generate_reason},
    "ToolCorrectnessMetric.get_tool_selection_score" =>
      {Prompts.ToolCorrectness, :get_tool_selection_score},
    "JsonCorrectnessMetric.generate_reason" => {Prompts.JsonCorrectness, :generate_reason},
    "FaithfulnessMetric._experimental_system_one_questions" =>
      {Prompts.Faithfulness, :system_one_questions},
    "FaithfulnessMetric._experimental_system_one_verdict" =>
      {Prompts.Faithfulness, :system_one_verdict},
    "AnswerRelevancyMetric._experimental_system_one_questions" =>
      {Prompts.AnswerRelevancy, :system_one_questions},
    "AnswerRelevancyMetric._experimental_system_one_verdict" =>
      {Prompts.AnswerRelevancy, :system_one_verdict},
    "ContextualPrecisionMetric._experimental_system_one_questions" =>
      {Prompts.ContextualPrecision, :system_one_questions},
    "ContextualPrecisionMetric._experimental_system_one_verdict" =>
      {Prompts.ContextualPrecision, :system_one_verdict},
    "ContextualRecallMetric._experimental_system_one_questions" =>
      {Prompts.ContextualRecall, :system_one_questions},
    "ContextualRecallMetric._experimental_system_one_verdict" =>
      {Prompts.ContextualRecall, :system_one_verdict},
    "ContextualRelevancyMetric._experimental_system_one_questions" =>
      {Prompts.ContextualRelevancy, :system_one_questions},
    "ContextualRelevancyMetric._experimental_system_one_verdict" =>
      {Prompts.ContextualRelevancy, :system_one_verdict},
    "BiasMetric._experimental_system_one_questions" => {Prompts.Bias, :system_one_questions},
    "BiasMetric._experimental_system_one_verdict" => {Prompts.Bias, :system_one_verdict},
    "ToxicityMetric._experimental_system_one_questions" =>
      {Prompts.Toxicity, :system_one_questions},
    "ToxicityMetric._experimental_system_one_verdict" => {Prompts.Toxicity, :system_one_verdict},
    "PIILeakageMetric._experimental_system_one_questions" =>
      {Prompts.PIILeakage, :system_one_questions},
    "PIILeakageMetric._experimental_system_one_verdict" =>
      {Prompts.PIILeakage, :system_one_verdict},
    "PromptAlignmentMetric._experimental_system_one_questions" =>
      {Prompts.PromptAlignment, :system_one_questions},
    "PromptAlignmentMetric._experimental_system_one_verdict" =>
      {Prompts.PromptAlignment, :system_one_verdict},
    "SummarizationMetric._experimental_system_one_questions" =>
      {Prompts.Summarization, :system_one_questions},
    "SummarizationMetric._experimental_system_one_verdict" =>
      {Prompts.Summarization, :system_one_verdict},
    "ArgumentCorrectnessMetric._experimental_system_one_questions" =>
      {Prompts.ArgumentCorrectness, :system_one_questions},
    "ArgumentCorrectnessMetric._experimental_system_one_verdict" =>
      {Prompts.ArgumentCorrectness, :system_one_verdict},
    "HallucinationMetric._experimental_system_one_questions" =>
      {Prompts.Hallucination, :system_one_questions},
    "HallucinationMetric._experimental_system_one_verdict" =>
      {Prompts.Hallucination, :system_one_verdict},
    "ToolCorrectnessMetric._experimental_system_one_tool_selection_score" =>
      {Prompts.ToolCorrectness, :system_one_tool_selection_score}
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

  test "covers every template of the sixteen LLM metrics" do
    templates = @cases |> Enum.map(&input(&1)["template"]) |> Enum.uniq() |> Enum.sort()

    assert templates == @templates |> Map.keys() |> Enum.sort()
  end

  test "maps every DeepEvalEx prompt function to a deepeval template" do
    prompt_functions =
      for module <- [
            Prompts.AnswerRelevancy,
            Prompts.ArgumentCorrectness,
            Prompts.Bias,
            Prompts.ContextualPrecision,
            Prompts.ContextualRecall,
            Prompts.ContextualRelevancy,
            Prompts.ConversationalGEval,
            Prompts.Faithfulness,
            Prompts.GEval,
            Prompts.Hallucination,
            Prompts.JsonCorrectness,
            Prompts.PIILeakage,
            Prompts.PromptAlignment,
            Prompts.Summarization,
            Prompts.ToolCorrectness,
            Prompts.Toxicity
          ],
          {fun, arity} <- module.__info__(:functions),
          arity in [0, 1],
          not String.starts_with?(Atom.to_string(fun), "format_"),
          do: {module, fun}

    assert Enum.sort(prompt_functions) == @templates |> Map.values() |> Enum.sort()
  end

  for name <- @cases do
    if unit = known_divergence.(name), do: @tag(known_divergence: unit)

    test "#{name} renders deepeval's prompt" do
      %{"template" => template, "inputs" => inputs} = input(unquote(name))
      {module, fun} = Map.fetch!(@templates, template)

      Code.ensure_loaded!(module)

      args =
        if function_exported?(module, fun, 0),
          do: [],
          else: [options(template, inputs, unquote(name))]

      assert apply(module, fun, args) ==
               File.read!(Path.join([@fixtures, unquote(name), "prompt.txt"]))
    end
  end

  defp input(name),
    do: Path.join([@fixtures, name, "input.json"]) |> File.read!() |> Jason.decode!()

  # JsonCorrectness prints its expected schema in its key order, so the
  # schema is read again with its order kept.
  defp options("JsonCorrectnessMetric.generate_reason", inputs, name) do
    ordered =
      Path.join([@fixtures, name, "input.json"])
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)

    [
      actual_output: inputs["actual_output"],
      expected_schema: ordered["inputs"]["expected_schema"],
      is_valid_json: inputs["is_valid_json"]
    ]
  end

  # The conversation keeps its JSON objects' key order (metadata), as
  # deepeval's dicts do, so it is read again with its order kept.
  defp options("ConversationalGEval.generate_evaluation_results", inputs, name) do
    ordered =
      Path.join([@fixtures, name, "input.json"])
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)

    metric = conversational_g_eval(inputs, evaluation_steps: inputs["evaluation_steps"])
    test_case = conversational_test_case(ordered["inputs"]["test_case"])

    [
      evaluation_steps: metric.evaluation_steps,
      test_case_content:
        Prompts.ConversationalGEval.format_test_case_content(test_case, metric.evaluation_params),
      turns: Enum.map(test_case.turns, &Turns.convert_turn_to_dict(&1, metric.evaluation_params)),
      parameters: Prompts.ConversationalGEval.format_params(metric.evaluation_params),
      rubric: Prompts.ConversationalGEval.format_rubric(metric.rubric)
    ]
  end

  defp options(template, inputs, _name), do: options(template, inputs)

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
      [rubric: Prompts.GEval.format_rubric(rubric), score_range: Rubric.score_range(rubric)]
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

  # The metric's constructor appends :content and :role to its params.
  defp options("ConversationalGEval.generate_evaluation_steps", inputs) do
    metric = conversational_g_eval(inputs, criteria: inputs["criteria"])

    [
      criteria: metric.criteria,
      parameters: Prompts.ConversationalGEval.format_params(metric.evaluation_params)
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

  defp options("ContextualRelevancyMetric.generate_verdicts", inputs) do
    [input: inputs["input"], context: inputs["context"]]
  end

  defp options("ContextualRelevancyMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      input: inputs["input"],
      irrelevant_statements: inputs["irrelevant_statements"],
      relevant_statements: inputs["relevant_statements"]
    ]
  end

  defp options("BiasMetric.generate_opinions", inputs),
    do: [actual_output: inputs["actual_output"]]

  defp options("BiasMetric.generate_verdicts", inputs), do: [opinions: inputs["opinions"]]

  defp options("BiasMetric.generate_reason", inputs),
    do: [score: inputs["score"], biases: inputs["biases"]]

  defp options("ToxicityMetric.generate_opinions", inputs),
    do: [actual_output: inputs["actual_output"]]

  defp options("ToxicityMetric.generate_verdicts", inputs), do: [opinions: inputs["opinions"]]

  defp options("ToxicityMetric.generate_reason", inputs),
    do: [score: inputs["score"], toxics: inputs["toxics"]]

  defp options("PIILeakageMetric.extract_pii", inputs),
    do: [actual_output: inputs["actual_output"]]

  defp options("PIILeakageMetric.generate_verdicts", inputs),
    do: [extracted_pii: inputs["extracted_pii"]]

  defp options("PIILeakageMetric.generate_reason", inputs),
    do: [score: inputs["score"], privacy_violations: inputs["privacy_violations"]]

  defp options("PromptAlignmentMetric.generate_verdicts", inputs) do
    [
      prompt_instructions: inputs["prompt_instructions"],
      input: inputs["input"],
      actual_output: inputs["actual_output"]
    ]
  end

  defp options("PromptAlignmentMetric.generate_reason", inputs) do
    [
      unalignment_reasons: inputs["unalignment_reasons"],
      input: inputs["input"],
      actual_output: inputs["actual_output"],
      score: inputs["score"]
    ]
  end

  defp options("PromptAlignmentMetric._experimental_system_one_questions", inputs),
    do: [prompt_instructions: inputs["prompt_instructions"]]

  defp options("SummarizationMetric.generate_questions", inputs),
    do: [text: inputs["text"], n: inputs["n"]]

  defp options("SummarizationMetric.generate_answers", inputs),
    do: [questions: inputs["questions"], text: inputs["text"]]

  # The metric joins the truths with blank lines.
  defp options("SummarizationMetric.generate_alignment_verdicts", inputs) do
    [
      summary_claims: inputs["summary_claims"],
      original_text: Enum.join(inputs["truths"], "\n\n")
    ]
  end

  defp options("SummarizationMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      contradictions: inputs["contradictions"],
      redundancies: inputs["redundancies"],
      questions: inputs["questions"]
    ]
  end

  defp options("SummarizationMetric._experimental_system_one_questions", inputs),
    do: [assessment_questions: inputs["assessment_questions"]]

  defp options("ArgumentCorrectnessMetric.generate_verdicts", inputs),
    do: [input: inputs["input"], tools_called: tool_calls(inputs["tools_called"])]

  defp options("ArgumentCorrectnessMetric.generate_reason", inputs) do
    [
      incorrect_tool_calls_reasons: inputs["incorrect_tool_calls_reasons"],
      input: inputs["input"],
      score: inputs["score"]
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

  # Evaluation params name test case fields, atoms TestCase and
  # ConversationalTestCase define once loaded.
  defp params(%{"evaluation_params" => names}) do
    Code.ensure_loaded!(TestCase)
    Code.ensure_loaded!(ConversationalTestCase)
    Enum.map(names, &String.to_existing_atom/1)
  end

  defp conversational_g_eval(inputs, opts) do
    ConversationalGEval.new(
      [
        name: "Golden",
        evaluation_params: params(inputs),
        rubric: rubric(inputs["rubric"])
      ] ++ opts
    )
  end

  # The test case's fields as a map, each turn's too; nested JSON objects
  # (metadata, tool call parameters) stay ordered.
  defp conversational_test_case(%OrderedObject{} = spec) do
    spec
    |> fields()
    |> Map.update!("turns", &Enum.map(&1, fn turn -> fields(turn) end))
    |> ConversationalTestCase.new!()
  end

  defp fields(%OrderedObject{values: pairs}) do
    Map.new(pairs, fn
      {"tools_called", tool_calls} -> {"tools_called", Enum.map(tool_calls, &Map.new(&1.values))}
      {"retrieval_context", items} -> {"retrieval_context", Enum.map(items, &context_item/1)}
      pair -> pair
    end)
  end

  # A {"context", "source"} item is a RetrievedContextData.
  defp context_item(%OrderedObject{values: pairs}), do: Map.new(pairs)
  defp context_item(context), do: context

  # deepeval's Rubric entries, validated and sorted as GEval's constructor
  # does.
  defp rubric(nil), do: nil

  defp rubric(entries) do
    entries
    |> Enum.map(fn %{"score_range" => range, "expected_outcome" => outcome} ->
      Rubric.new!(score_range: range, expected_outcome: outcome)
    end)
    |> Rubric.validate_and_sort()
  end

  defp tool_calls(attrs) do
    Enum.map(attrs, fn attrs ->
      {:ok, tool_call} = ToolCall.new(attrs)
      tool_call
    end)
  end
end
