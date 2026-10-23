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

  alias DeepEvalEx.{ConversationalTestCase, MLLMImage, TestCase}
  alias DeepEvalEx.Metrics.ConversationalGEval
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Metrics.Utils.Turns
  alias DeepEvalEx.Prompts
  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.Tracing.NestedDict
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
    "GEval.generate_trace_evaluation_steps" => {Prompts.GEval, :generate_trace_evaluation_steps},
    "GEval.generate_trace_evaluation_results" =>
      {Prompts.GEval, :generate_trace_evaluation_results},
    "GEval.generate_strict_trace_evaluation_results" =>
      {Prompts.GEval, :generate_strict_trace_evaluation_results},
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
      {Prompts.ToolCorrectness, :system_one_tool_selection_score},
    "TurnRelevancyMetric.generate_verdicts" => {Prompts.TurnRelevancy, :generate_verdicts},
    "TurnRelevancyMetric.generate_reason" => {Prompts.TurnRelevancy, :generate_reason},
    "TurnRelevancyMetric._experimental_system_one_questions" =>
      {Prompts.TurnRelevancy, :system_one_questions},
    "TurnRelevancyMetric._experimental_system_one_verdict" =>
      {Prompts.TurnRelevancy, :system_one_verdict},
    "ConversationCompletenessMetric.extract_user_intentions" =>
      {Prompts.ConversationCompleteness, :extract_user_intentions},
    "ConversationCompletenessMetric.generate_verdicts" =>
      {Prompts.ConversationCompleteness, :generate_verdicts},
    "ConversationCompletenessMetric.generate_reason" =>
      {Prompts.ConversationCompleteness, :generate_reason},
    "ConversationCompletenessMetric._experimental_system_one_questions" =>
      {Prompts.ConversationCompleteness, :system_one_questions},
    "ConversationCompletenessMetric._experimental_system_one_verdict" =>
      {Prompts.ConversationCompleteness, :system_one_verdict},
    "KnowledgeRetentionMetric.extract_data" => {Prompts.KnowledgeRetention, :extract_data},
    "KnowledgeRetentionMetric.generate_verdict" =>
      {Prompts.KnowledgeRetention, :generate_verdict},
    "KnowledgeRetentionMetric.generate_reason" => {Prompts.KnowledgeRetention, :generate_reason},
    "KnowledgeRetentionMetric._experimental_system_one_questions" =>
      {Prompts.KnowledgeRetention, :system_one_questions},
    "KnowledgeRetentionMetric._experimental_system_one_verdict" =>
      {Prompts.KnowledgeRetention, :system_one_verdict},
    "RoleAdherenceMetric.extract_out_of_character_response_verdicts" =>
      {Prompts.RoleAdherence, :extract_out_of_character_response_verdicts},
    "RoleAdherenceMetric.generate_reason" => {Prompts.RoleAdherence, :generate_reason},
    "RoleAdherenceMetric._experimental_system_one_questions" =>
      {Prompts.RoleAdherence, :system_one_questions},
    "RoleAdherenceMetric._experimental_system_one_verdict" =>
      {Prompts.RoleAdherence, :system_one_verdict},
    "TurnFaithfulnessMetric.generate_truths" => {Prompts.TurnFaithfulness, :generate_truths},
    "TurnFaithfulnessMetric.generate_claims" => {Prompts.TurnFaithfulness, :generate_claims},
    "TurnFaithfulnessMetric.generate_verdicts" => {Prompts.TurnFaithfulness, :generate_verdicts},
    "TurnFaithfulnessMetric.generate_reason" => {Prompts.TurnFaithfulness, :generate_reason},
    "TurnFaithfulnessMetric.generate_final_reason" =>
      {Prompts.TurnFaithfulness, :generate_final_reason},
    "TurnFaithfulnessMetric._experimental_system_one_questions" =>
      {Prompts.TurnFaithfulness, :system_one_questions},
    "TurnFaithfulnessMetric._experimental_system_one_verdict" =>
      {Prompts.TurnFaithfulness, :system_one_verdict},
    "TurnContextualPrecisionMetric.generate_verdicts" =>
      {Prompts.TurnContextualPrecision, :generate_verdicts},
    "TurnContextualPrecisionMetric.generate_reason" =>
      {Prompts.TurnContextualPrecision, :generate_reason},
    "TurnContextualPrecisionMetric.generate_final_reason" =>
      {Prompts.TurnContextualPrecision, :generate_final_reason},
    "TurnContextualPrecisionMetric._experimental_system_one_questions" =>
      {Prompts.TurnContextualPrecision, :system_one_questions},
    "TurnContextualPrecisionMetric._experimental_system_one_verdict" =>
      {Prompts.TurnContextualPrecision, :system_one_verdict},
    "TurnContextualRecallMetric.generate_verdicts" =>
      {Prompts.TurnContextualRecall, :generate_verdicts},
    "TurnContextualRecallMetric.generate_reason" =>
      {Prompts.TurnContextualRecall, :generate_reason},
    "TurnContextualRecallMetric.generate_final_reason" =>
      {Prompts.TurnContextualRecall, :generate_final_reason},
    "TurnContextualRecallMetric._experimental_system_one_questions" =>
      {Prompts.TurnContextualRecall, :system_one_questions},
    "TurnContextualRecallMetric._experimental_system_one_verdict" =>
      {Prompts.TurnContextualRecall, :system_one_verdict},
    "TurnContextualRelevancyMetric.generate_verdicts" =>
      {Prompts.TurnContextualRelevancy, :generate_verdicts},
    "TurnContextualRelevancyMetric.generate_reason" =>
      {Prompts.TurnContextualRelevancy, :generate_reason},
    "TurnContextualRelevancyMetric.generate_final_reason" =>
      {Prompts.TurnContextualRelevancy, :generate_final_reason},
    "TurnContextualRelevancyMetric._experimental_system_one_questions" =>
      {Prompts.TurnContextualRelevancy, :system_one_questions},
    "TurnContextualRelevancyMetric._experimental_system_one_verdict" =>
      {Prompts.TurnContextualRelevancy, :system_one_verdict},
    "GoalAccuracyMetric.get_accuracy_score" => {Prompts.GoalAccuracy, :get_accuracy_score},
    "GoalAccuracyMetric.get_plan_evaluation_score" =>
      {Prompts.GoalAccuracy, :get_plan_evaluation_score},
    "GoalAccuracyMetric.get_final_reason" => {Prompts.GoalAccuracy, :get_final_reason},
    "GoalAccuracyMetric._experimental_system_one_goal_score" =>
      {Prompts.GoalAccuracy, :system_one_goal_score},
    "GoalAccuracyMetric._experimental_system_one_plan_score" =>
      {Prompts.GoalAccuracy, :system_one_plan_score},
    "GoalAccuracyMetric._experimental_system_one_questions" =>
      {Prompts.GoalAccuracy, :system_one_questions},
    "ToolUseMetric.get_tool_selection_score" => {Prompts.ToolUse, :get_tool_selection_score},
    "ToolUseMetric.get_argument_correctness_score" =>
      {Prompts.ToolUse, :get_argument_correctness_score},
    "ToolUseMetric.get_tool_selection_final_reason" =>
      {Prompts.ToolUse, :get_tool_selection_final_reason},
    "ToolUseMetric.get_tool_argument_final_reason" =>
      {Prompts.ToolUse, :get_tool_argument_final_reason},
    "ToolUseMetric._experimental_system_one_tool_selection_score" =>
      {Prompts.ToolUse, :system_one_tool_selection_score},
    "ToolUseMetric._experimental_system_one_argument_correctness_score" =>
      {Prompts.ToolUse, :system_one_argument_correctness_score},
    "ToolUseMetric._experimental_system_one_questions" =>
      {Prompts.ToolUse, :system_one_questions},
    "TaskCompletionMetric.extract_goal_and_outcome" =>
      {Prompts.TaskCompletion, :extract_goal_and_outcome},
    "TaskCompletionMetric.extract_task_and_outcome_from_trace" =>
      {Prompts.TaskCompletion, :extract_task_and_outcome_from_trace},
    "TaskCompletionMetric.generate_verdict" => {Prompts.TaskCompletion, :generate_verdict},
    "TaskCompletionMetric._experimental_system_one_score" =>
      {Prompts.TaskCompletion, :system_one_score},
    "TaskCompletionMetric._experimental_system_one_questions" =>
      {Prompts.TaskCompletion, :system_one_questions},
    "StepEfficiencyMetric.extract_task_from_trace" =>
      {Prompts.StepEfficiency, :extract_task_from_trace},
    "StepEfficiencyMetric.get_execution_efficiency" =>
      {Prompts.StepEfficiency, :get_execution_efficiency},
    "StepEfficiencyMetric._experimental_system_one_score" =>
      {Prompts.StepEfficiency, :system_one_score},
    "StepEfficiencyMetric._experimental_system_one_questions" =>
      {Prompts.StepEfficiency, :system_one_questions},
    "PlanQualityMetric.evaluate_plan_quality" => {Prompts.PlanQuality, :evaluate_plan_quality},
    "PlanQualityMetric._experimental_system_one_score" =>
      {Prompts.PlanQuality, :system_one_score},
    "PlanQualityMetric._experimental_system_one_questions" =>
      {Prompts.PlanQuality, :system_one_questions},
    "PlanAdherenceMetric.extract_plan_from_trace" =>
      {Prompts.PlanAdherence, :extract_plan_from_trace},
    "PlanAdherenceMetric.evaluate_adherence" => {Prompts.PlanAdherence, :evaluate_adherence},
    "PlanAdherenceMetric._experimental_system_one_score" =>
      {Prompts.PlanAdherence, :system_one_score},
    "PlanAdherenceMetric._experimental_system_one_questions" =>
      {Prompts.PlanAdherence, :system_one_questions}
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

  test "covers every template of the thirty LLM metrics" do
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
            Prompts.ConversationCompleteness,
            Prompts.Faithfulness,
            Prompts.GEval,
            Prompts.GoalAccuracy,
            Prompts.Hallucination,
            Prompts.JsonCorrectness,
            Prompts.KnowledgeRetention,
            Prompts.PIILeakage,
            Prompts.PlanAdherence,
            Prompts.PlanQuality,
            Prompts.PromptAlignment,
            Prompts.RoleAdherence,
            Prompts.StepEfficiency,
            Prompts.Summarization,
            Prompts.TaskCompletion,
            Prompts.ToolCorrectness,
            Prompts.ToolUse,
            Prompts.Toxicity,
            Prompts.TurnContextualPrecision,
            Prompts.TurnContextualRecall,
            Prompts.TurnContextualRelevancy,
            Prompts.TurnFaithfulness,
            Prompts.TurnRelevancy
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
          else: [options(template, inputs, unquote(name)) ++ multimodal_options(template, inputs)]

      assert apply(module, fun, args) ==
               File.read!(Path.join([@fixtures, unquote(name), "prompt.txt"]))
    end
  end

  # The templates of the single-turn metrics that pass deepeval's
  # `multimodal` flag, the test case's: the metric puts it, and the test
  # case's images, in the options of each.
  @multimodal_templates ~w(
    AnswerRelevancyMetric.generate_statements AnswerRelevancyMetric.generate_verdicts
    AnswerRelevancyMetric.generate_reason ArgumentCorrectnessMetric.generate_verdicts
    ArgumentCorrectnessMetric.generate_reason BiasMetric.generate_opinions
    BiasMetric.generate_verdicts ContextualPrecisionMetric.generate_verdicts
    ContextualPrecisionMetric.generate_reason ContextualRecallMetric.generate_verdicts
    ContextualRecallMetric.generate_reason ContextualRelevancyMetric.generate_verdicts
    FaithfulnessMetric.generate_claims FaithfulnessMetric.generate_truths
    FaithfulnessMetric.generate_verdicts GEval.generate_evaluation_steps
    GEval.generate_evaluation_results GEval.generate_strict_evaluation_results
    GEval.generate_trace_evaluation_steps GEval.generate_trace_evaluation_results
    GEval.generate_strict_trace_evaluation_results
  )

  defp multimodal_options(template, inputs) when template in @multimodal_templates do
    {:ok, images} = MLLMImage.cast_images(Map.get(inputs, "images", []))
    [multimodal: Map.get(inputs, "multimodal", false), images: images]
  end

  defp multimodal_options(_template, _inputs), do: []

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

  # The trace metrics print their nested trace dict in its key order, so it
  # is read again with its order kept.
  defp options(template, inputs, name)
       when template in [
              "TaskCompletionMetric.extract_task_and_outcome_from_trace",
              "StepEfficiencyMetric.extract_task_from_trace",
              "StepEfficiencyMetric.get_execution_efficiency",
              "PlanAdherenceMetric.extract_plan_from_trace",
              "PlanAdherenceMetric.evaluate_adherence"
            ] do
    ordered =
      Path.join([@fixtures, name, "input.json"])
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)

    trace_json = NestedDict.to_json(ordered["inputs"]["trace"])

    [
      trace_json: trace_json,
      trace_json_str: trace_json,
      execution_trace_json: trace_json,
      task: inputs["task"],
      user_task: inputs["task"],
      agent_plan: Enum.join(inputs["plan"] || [], "\n"),
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  # GEval in trace mode prints the nested trace dict in its key order too.
  defp options(template, inputs, name)
       when template in [
              "GEval.generate_trace_evaluation_results",
              "GEval.generate_strict_trace_evaluation_results"
            ] do
    ordered =
      Path.join([@fixtures, name, "input.json"])
      |> File.read!()
      |> Jason.decode!(objects: :ordered_objects)

    rubric = rubric(inputs["rubric"])

    [
      evaluation_steps: inputs["evaluation_steps"],
      trace_json: NestedDict.to_json(ordered["inputs"]["trace"]),
      rubric: Prompts.GEval.format_rubric(rubric),
      score_range: Rubric.score_range(rubric)
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

  defp options("GEval.generate_trace_evaluation_steps", inputs) do
    [criteria: inputs["criteria"]]
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

  # The turns as the conversational metrics print them, their content and
  # role (Turns.convert_turn_to_dict/2's defaults).
  defp options("TurnRelevancyMetric.generate_verdicts", inputs),
    do: [sliding_window: turn_dicts(inputs["sliding_window"])]

  defp options("TurnRelevancyMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      irrelevancies:
        Enum.map(inputs["irrelevancies"], fn irrelevancy ->
          OrderedObject.new([
            {"message number", irrelevancy["message number"]},
            {"reason", irrelevancy["reason"]}
          ])
        end)
    ]
  end

  defp options("ConversationCompletenessMetric.extract_user_intentions", inputs),
    do: [turns: turn_dicts(inputs["turns"]), multimodal: Map.get(inputs, "multimodal", false)]

  defp options("ConversationCompletenessMetric.generate_verdicts", inputs) do
    [
      turns: turn_dicts(inputs["turns"]),
      intention: inputs["intention"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("ConversationCompletenessMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      incompletenesses: inputs["incompletenesses"],
      intentions: inputs["intentions"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("KnowledgeRetentionMetric.extract_data", inputs),
    do: [
      user_message: inputs["user_message"],
      previous_turns: turn_dicts(inputs["previous_turns"])
    ]

  defp options("KnowledgeRetentionMetric.generate_verdict", inputs) do
    [
      llm_message: inputs["llm_message"],
      accumulated_knowledge: inputs["accumulated_knowledge"]
    ]
  end

  defp options("KnowledgeRetentionMetric.generate_reason", inputs),
    do: [score: inputs["score"], attritions: inputs["attritions"]]

  defp options("RoleAdherenceMetric.extract_out_of_character_response_verdicts", inputs),
    do: [turns: turn_dicts(inputs["turns"]), role: inputs["role"]]

  defp options("RoleAdherenceMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      role: inputs["role"],
      out_of_character_responses: inputs["out_of_character_responses"]
    ]
  end

  # The Turn RAG metrics pass the test case's multimodal flag to their
  # window templates.
  defp options("TurnFaithfulnessMetric.generate_truths", inputs) do
    [
      reference_context: Enum.join(inputs["retrieval_context"], "\n\n"),
      extraction_limit: inputs["truths_extraction_limit"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnFaithfulnessMetric.generate_claims", inputs) do
    [
      input: inputs["input"],
      assistant_output: inputs["assistant_output"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnFaithfulnessMetric.generate_verdicts", inputs) do
    [
      claims: inputs["claims"],
      reference_context: Enum.join(inputs["truths"], "\n\n"),
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnFaithfulnessMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      contradictions: inputs["contradictions"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualPrecisionMetric.generate_verdicts", inputs) do
    [
      input: inputs["input"],
      expected_outcome: inputs["expected_outcome"],
      retrieval_context: inputs["retrieval_context"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualPrecisionMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      input: inputs["input"],
      verdicts:
        Enum.map(inputs["verdicts"], fn verdict ->
          %{verdict: String.to_existing_atom(verdict["verdict"]), reason: verdict["reason"]}
        end),
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualRecallMetric.generate_verdicts", inputs) do
    [
      expected_outcome: inputs["expected_outcome"],
      retrieval_context: inputs["retrieval_context"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualRecallMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      expected_outcome: inputs["expected_outcome"],
      supportive_reasons: inputs["supportive_reasons"],
      unsupportive_reasons: inputs["unsupportive_reasons"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualRelevancyMetric.generate_verdicts", inputs) do
    [
      input: inputs["input"],
      context: inputs["context"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("TurnContextualRelevancyMetric.generate_reason", inputs) do
    [
      score: inputs["score"],
      input: inputs["input"],
      irrelevant_statements: inputs["irrelevant_statements"],
      relevant_statements: inputs["relevant_statements"],
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options(
         "Turn" <> _ = template,
         %{"final_score" => final_score, "success" => success, "reasons" => reasons}
       )
       when template in [
              "TurnFaithfulnessMetric.generate_final_reason",
              "TurnContextualPrecisionMetric.generate_final_reason",
              "TurnContextualRecallMetric.generate_final_reason",
              "TurnContextualRelevancyMetric.generate_final_reason"
            ],
       do: [final_score: final_score, success: success, reasons: reasons]

  defp options("ToolCorrectnessMetric.get_tool_selection_score", inputs) do
    [
      user_input: inputs["input"],
      tools_called:
        inputs["tools_called"] |> tool_calls() |> Prompts.ToolCorrectness.format_tools(),
      available_tools:
        inputs["available_tools"] |> tool_calls() |> Prompts.ToolCorrectness.format_tools()
    ]
  end

  # TaskCompletion without a trace prints its tools called as
  # print_tools_called does.
  defp options("TaskCompletionMetric.extract_goal_and_outcome", inputs) do
    [
      input: inputs["input"],
      actual_output: inputs["actual_output"],
      tools_called_formatted:
        (inputs["tools_called"] || []) |> tool_calls() |> Prompts.ToolCorrectness.format_tools()
    ]
  end

  defp options("TaskCompletionMetric.generate_verdict", inputs),
    do: [task: inputs["task"], actual_outcome: inputs["outcome"]]

  defp options("TaskCompletionMetric._experimental_system_one_questions", inputs),
    do: [has_trace: inputs["has_trace"], has_task: inputs["has_task"]]

  defp options("StepEfficiencyMetric._experimental_system_one_questions", inputs),
    do: [has_trace: inputs["has_trace"]]

  # The plan metrics print the plan one step per line.
  defp options("PlanQualityMetric.evaluate_plan_quality", inputs),
    do: [user_task: inputs["task"], agent_plan: Enum.join(inputs["plan"], "\n")]

  defp options("PlanQualityMetric._experimental_system_one_questions", inputs),
    do: [has_trace: inputs["has_trace"]]

  defp options("PlanAdherenceMetric._experimental_system_one_questions", inputs),
    do: [has_trace: inputs["has_trace"]]

  # GoalAccuracy joins a unit's steps with newlines and builds its
  # evaluations as GoalAccuracy._generate_reason does.
  defp options("GoalAccuracyMetric." <> method, inputs)
       when method in ["get_accuracy_score", "get_plan_evaluation_score"] do
    [
      task: inputs["task"],
      steps_taken: Enum.join(inputs["steps_taken"], "\n"),
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  defp options("GoalAccuracyMetric.get_final_reason", inputs) do
    [
      final_score: inputs["final_score"],
      threshold: inputs["threshold"],
      goal_evaluations: evaluations(inputs["goal_scores"], ""),
      plan_evalautions: evaluations(inputs["plan_scores"], " \n"),
      multimodal: Map.get(inputs, "multimodal", false)
    ]
  end

  # ToolUse joins its tools' ToolCall.__repr__ with commas.
  defp options("ToolUseMetric." <> method, inputs)
       when method in ["get_tool_selection_score", "get_argument_correctness_score"] do
    [
      user_input: inputs["user_messages"],
      assistant_messages: inputs["assistant_messages"],
      tools_called: tool_reprs(inputs["tools_called"]),
      available_tools: tool_reprs(inputs["available_tools"])
    ]
  end

  defp options("ToolUseMetric." <> method, inputs)
       when method in ["get_tool_selection_final_reason", "get_tool_argument_final_reason"] do
    [
      all_scores_and_reasons:
        Enum.map_join(inputs["scores"], fn %{"score" => score, "reason" => reason} ->
          "\nScore: #{Prompts.Python.repr(score)} \nReason: #{reason} \n"
        end),
      final_score: inputs["final_score"],
      threshold: inputs["threshold"]
    ]
  end

  defp evaluations(scores, suffix) do
    Enum.map_join(scores, fn %{"score" => score, "reason" => reason} ->
      "Score: #{Prompts.Python.repr(score)}, Reason: #{reason}#{suffix}"
    end)
  end

  defp tool_reprs(tools),
    do: tools |> tool_calls() |> Enum.map_join(",", &Prompts.Python.repr/1)

  defp turn_dicts(turns),
    do: Enum.map(turns, &(&1 |> DeepEvalEx.Turn.new!() |> Turns.convert_turn_to_dict()))

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
