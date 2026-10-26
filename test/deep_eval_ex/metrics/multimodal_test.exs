defmodule DeepEvalEx.Metrics.MultimodalTest do
  @moduledoc """
  Single-turn metrics on a multimodal test case: the judge gets the test
  case's images with deepeval's multimodal prompts, and no metric has a
  System One form for it.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.{Metrics, MLLMImage, TestCase}
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock

  # A judge that reports each prompt and the images it was given to the
  # test process (`:test_pid`), and answers with `:respond`'s response.
  defmodule CapturingJudge do
    @behaviour DeepEvalEx.LLM.Adapter

    @impl true
    def generate(_prompt, _opts), do: {:error, :unexpected}

    @impl true
    def generate_with_schema(prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:judge, prompt, opts[:images]})
      {:ok, Keyword.fetch!(opts, :respond).(prompt)}
    end

    @impl true
    def model_name(_opts), do: "capturing-judge"

    @impl true
    def supports_structured_outputs?, do: true

    @impl true
    def supports_log_probs?, do: false
  end

  setup do
    chart = MLLMImage.new!(url: "https://example.com/charts/sales.png", id: "sales-chart")
    dot = MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "red-dot")
    %{chart: chart, dot: dot}
  end

  test "AnswerRelevancy sends the test case's images with its multimodal prompts",
       %{chart: chart, dot: dot} do
    test_case =
      TestCase.new!(
        input: "What does #{chart} show?",
        actual_output: "Sales doubled.",
        images: [chart, dot]
      )

    respond = fn prompt ->
      cond do
        prompt =~ "breakdown and generate a list of statements" ->
          %{"statements" => ["Sales doubled."]}

        prompt =~ "For the provided list of statements" ->
          %{"verdicts" => [%{"verdict" => "yes"}]}

        true ->
          %{"reason" => "The score is 1.00 because it answers."}
      end
    end

    assert {:ok, result} =
             Metrics.AnswerRelevancy.measure(test_case,
               adapter: CapturingJudge,
               test_pid: self(),
               respond: respond
             )

    assert result.score == 1.0

    for _step <- 1..3 do
      assert_received {:judge, prompt, images}
      assert prompt =~ "--- MULTIMODAL INPUT RULES ---"
      assert images == %{"sales-chart" => chart, "red-dot" => dot}
    end
  end

  test "a text-only test case sends no images and no multimodal rules" do
    respond = fn prompt ->
      if prompt =~ "breakdown and generate a list of statements",
        do: %{"statements" => []},
        else: %{"reason" => "The score is 1.00."}
    end

    assert {:ok, _result} =
             Metrics.AnswerRelevancy.measure(TestCase.new!(input: "Q", actual_output: "A"),
               adapter: CapturingJudge,
               test_pid: self(),
               respond: respond
             )

    assert_received {:judge, prompt, nil}
    refute prompt =~ "MULTIMODAL"
  end

  test "ContextualRecall asks no System One verdicts under :hybrid for a multimodal test case",
       %{chart: chart} do
    system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.9))

    test_case =
      TestCase.new!(
        input: "How did sales change?",
        expected_output: "Sales doubled.",
        retrieval_context: ["The 2024 report: #{chart}"],
        images: [chart]
      )

    respond = fn prompt ->
      if prompt =~ "For EACH sentence and image",
        do: %{"verdicts" => [%{"verdict" => "yes", "reason" => "Node 2 shows it."}]},
        else: %{"reason" => "The score is 1.00."}
    end

    assert {:ok, result} =
             Metrics.ContextualRecall.measure(test_case,
               adapter: CapturingJudge,
               test_pid: self(),
               respond: respond,
               eval_mode: :hybrid,
               system_one_model: system_one
             )

    assert result.score == 1.0
    assert SystemOneMock.calls(system_one) == []

    assert_received {:judge, prompt, _images}

    assert prompt =~
             "['Node 1: The 2024 report: ', 'Node 2:', [DEEPEVAL:IMAGE:sales-chart]]"
  end

  test "no single-turn metric has a System One form for a multimodal test case" do
    test_case = TestCase.new!(input: "What is [DEEPEVAL:IMAGE:x]?", actual_output: "A dot.")

    for metric <- [
          Metrics.AnswerRelevancy,
          Metrics.ArgumentCorrectness,
          Metrics.Bias,
          Metrics.ContextualPrecision,
          Metrics.ContextualRecall,
          Metrics.ContextualRelevancy,
          Metrics.Faithfulness,
          Metrics.Hallucination,
          Metrics.PIILeakage,
          Metrics.PlanAdherence,
          Metrics.PlanQuality,
          Metrics.PromptAlignment,
          Metrics.StepEfficiency,
          Metrics.Summarization,
          Metrics.TaskCompletion,
          Metrics.Toxicity
        ] do
      assert metric.system_one_eval_spec(test_case, []) == nil, inspect(metric)
    end
  end
end
