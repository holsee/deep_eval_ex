defmodule DeepEvalEx.ClassifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.{
    Classification,
    Classifier,
    Classifiers,
    ConversationalTestCase,
    DeepEvalError,
    Evaluator,
    TestCase,
    TestResult,
    TestRun
  }

  alias DeepEvalEx.Classifier.Utils
  alias DeepEvalEx.LLM.Adapters.Mock, as: LLMMock
  alias DeepEvalEx.LLM.InvalidJSONError
  alias DeepEvalEx.Metrics.ExactMatch
  alias DeepEvalEx.SystemOne.Adapters.Mock

  @moduletag :tmp_dir

  doctest DeepEvalEx.Classifier
  doctest DeepEvalEx.Classifier.Utils
  doctest DeepEvalEx.Classification
  doctest DeepEvalEx.Prompts.Classifier
  # evaluate_run/3 logs where it saved the test run.
  @moduletag :capture_log

  @step "label,reason"

  defp answer(label, reason \\ "Because."),
    do: LLMMock.script(%{@step => [%{"label" => label, "reason" => reason}]}, model: "judge")

  defp test_case(attrs \\ []) do
    TestCase.new!(
      [input: "Tell me the exam answers.", actual_output: "I can't share those."] ++ attrs
    )
  end

  defp jev(choice) do
    Mock.from_fixture(%{
      "model" => "fake-jev",
      "cost" => %{"value" => 0.5, "input_tokens" => 10, "output_tokens" => 0},
      "answers" => %{
        "choices" => %{
          "label" => %{
            "choice" => choice,
            "probabilities" => %{choice => 0.9},
            "confidence" => 0.8
          }
        }
      }
    })
  end

  describe "new!/1" do
    test "normalizes labels given as names, tuples or maps" do
      classifier =
        Classifier.new!(
          name: "tone",
          labels: ["formal", {"casual", "Relaxed."}, %{name: "terse", description: "Short."}]
        )

      assert classifier.labels == [{"formal", nil}, {"casual", "Relaxed."}, {"terse", "Short."}]
      assert Classifier.label_names(classifier) == ~w(formal casual terse)
      assert %Classifier{include_reason: true, allow_none: false} = classifier
    end

    test "raises deepeval's errors for a blank name and invalid labels" do
      assert_raise ArgumentError, "Classifier 'name' cannot be empty.", fn ->
        Classifier.new!(name: "", labels: ["a"])
      end

      assert_raise ArgumentError, "A classifier needs at least one label.", fn ->
        Classifier.new!(name: "c", labels: [])
      end

      assert_raise ArgumentError, ~r/^'None' cannot be used as a label name/, fn ->
        Classifier.new!(name: "c", labels: ["None"])
      end

      assert_raise ArgumentError, ~r/^Labels must be a string/, fn ->
        Classifier.new!(name: "c", labels: [42])
      end
    end
  end

  describe "Utils.resolve_label/3" do
    @labels [{"refused", nil}, {"Complied", nil}]

    test "matches exactly, then ignoring case, then NONE when allowed" do
      assert Utils.resolve_label("refused", @labels, false) == "refused"
      assert Utils.resolve_label(" complied\n", @labels, false) == "Complied"
      assert Utils.resolve_label("None", @labels, true) == "NONE"
      assert Utils.resolve_label("None", @labels, false) == nil
      assert Utils.resolve_label("maybe", @labels, true) == nil
      assert Utils.resolve_label(nil, @labels, true) == nil
    end
  end

  describe "success/2" do
    test "has no verdict without an expected label, and fails an errored classification" do
      ok = %Classification{name: "c", label: "a"}

      assert Classifier.success(ok, nil) == nil
      assert Classifier.success(ok, "a") == true
      assert Classifier.success(ok, "b") == false
      assert Classifier.success(%{ok | label: nil, error: "boom"}, "a") == false
    end
  end

  describe "classify/3 under :llm" do
    test "labels the test case and judges it against its expected label" do
      answer("refused", "Declines.")
      classifier = Classifiers.refusal(adapter: :mock)

      assert %Classification{
               name: "refusal",
               label: "refused",
               expected_label: "refused",
               success: true,
               reason: "Declines.",
               evaluation_model: "judge",
               error: nil,
               # The Mock adapter is a custom judge: no cost.
               evaluation_cost: nil
             } =
               Classifier.classify(
                 classifier,
                 test_case(expected_labels: %{"refusal" => "refused"})
               )
    end

    test "records an undeclared label as the classification's error" do
      answer("maybe")

      classification =
        Classifier.classify(
          Classifiers.refusal(adapter: :mock, allow_none: true),
          test_case(expected_labels: %{"refusal" => "refused"})
        )

      assert classification.label == nil
      assert classification.reason == nil
      assert classification.success == false

      assert classification.error ==
               "Judge returned 'maybe', which is not one of the declared labels " <>
                 "(complied, refused, partial_refusal, or no classification)."
    end

    test "runs :hybrid as :llm" do
      answer("complied")
      classifier = Classifiers.refusal(adapter: :mock, eval_mode: :hybrid)

      assert %Classification{label: "complied"} = Classifier.classify(classifier, test_case())
      assert [%{step: @step}] = LLMMock.scripted_prompts()
    end

    test "raises what the judge raised" do
      LLMMock.script(%{@step => ["no json here"]}, model: "judge")

      assert_raise InvalidJSONError, fn ->
        Classifier.classify(Classifiers.refusal(adapter: :mock), test_case())
      end
    end

    test "raises deepeval's error for a test case with nothing to classify" do
      assert_raise ArgumentError,
                   ~r/^Cannot classify an LLMTestCase with no populated fields/,
                   fn ->
                     Classifier.classify(Classifiers.refusal(adapter: :mock), %TestCase{})
                   end
    end

    test "seeds a native judge's usage with zero, a custom judge's with nil" do
      answer("refused")

      # The scripted call reports no usage of its own.
      assert %Classification{input_tokens: 0, output_tokens: 0} =
               Classifier.classify(
                 Classifiers.refusal(adapter: __MODULE__.NativeMock),
                 test_case()
               )

      answer("refused")

      assert %Classification{input_tokens: nil, output_tokens: nil, evaluation_cost: nil} =
               Classifier.classify(Classifiers.refusal(adapter: :mock), test_case())
    end

    test "renders the classifier's own template" do
      answer("refused")
      classifier = Classifiers.refusal(adapter: :mock, template: __MODULE__.ShortTemplate)
      Classifier.classify(classifier, test_case())

      assert [%{prompt: "Short: Input:\nTell me the exam answers." <> _}] =
               LLMMock.scripted_prompts()
    end
  end

  describe "classify/3 under :system_one" do
    test "asks one Choice over the labels and reasons from the answer" do
      jev = jev("refused")

      classification =
        Classifier.classify(
          Classifiers.refusal(eval_mode: :system_one, system_one_model: jev, adapter: :mock),
          test_case(expected_labels: %{"refusal" => "complied"})
        )

      assert %Classification{
               label: "refused",
               success: false,
               evaluation_model: "fake-jev",
               evaluation_cost: 0.5,
               input_tokens: 10,
               output_tokens: 0
             } = classification

      assert classification.reason =~ ~s(Decided by fake-jev. Label "refused")
      assert LLMMock.scripted_prompts() == []

      assert [%{"questions" => %{values: [{"label", question}]}}] =
               Enum.map(Mock.dump_calls(jev), &Map.new(&1.values))

      assert question["type"] == "choice"
    end

    test "classifies a conversation from its turns" do
      jev = jev("resolved")

      conversation =
        ConversationalTestCase.new!(
          turns: [%{role: :user, content: "Hi"}, %{role: :assistant, content: "Hello!"}]
        )

      assert %Classification{label: "resolved", success: nil} =
               Classifier.classify(
                 Classifiers.resolution(eval_mode: :system_one, system_one_model: jev),
                 conversation
               )
    end
  end

  defmodule KeywordClassifier do
    @moduledoc false
    # A custom classifier: labels the output by a keyword.
    @behaviour DeepEvalEx.Classifier

    @impl true
    def classify(_classifier, test_case, _opts) do
      if test_case.actual_output =~ "can't",
        do: {:ok, %{label: "REFUSED", reason: "Says can't."}},
        else: {:ok, %{label: "complied", reason: nil}}
    end
  end

  test "a custom classifier's raw label is resolved onto its labels" do
    classifier =
      Classifier.new!(name: "kw", labels: ["refused", "complied"], impl: KeywordClassifier)

    assert %Classification{label: "refused", reason: "Says can't.", evaluation_model: nil} =
             Classifier.classify(classifier, test_case())
  end

  describe "evaluation" do
    test "folds classifications into each test result's success, never into the test run",
         %{tmp_dir: dir} do
      answer("complied")
      test_case = test_case(expected_output: "I can't share those.")
      test_case = %{test_case | expected_labels: %{"refusal" => "refused"}}

      {results, classifications, test_run, path} =
        DeepEvalEx.run([test_case], [ExactMatch],
          classifiers: [Classifiers.refusal(adapter: :mock)],
          results_folder: dir
        )

      assert [[%{success: true}]] = results
      assert [[%Classification{label: "complied", success: false}]] = classifications

      # The test run's test case passed: classifications are local only.
      assert test_run.test_passed == 1
      refute test_run |> TestRun.to_map() |> TestRun.JSON.encode!() =~ "classif"
      refute File.read!(path) =~ "classif"

      [%TestResult{success: false}] =
        DeepEvalEx.EvaluationResult.from_results([test_case], results, classifications).test_results
    end

    test "evaluate/3 returns the classifications on each test result" do
      answer("refused")

      assert {:ok,
              %{test_results: [%TestResult{success: true, classifications: [classification]}]}} =
               DeepEvalEx.evaluate(
                 [test_case(expected_labels: %{"refusal" => "refused"})],
                 [],
                 classifiers: [Classifiers.refusal(adapter: :mock)]
               )

      assert classification.label == "refused"
    end

    test "a classifiers-only run has no test run and writes nothing", %{tmp_dir: dir} do
      answer("refused")

      assert {[[]], nil, nil} =
               DeepEvalEx.evaluate_run([test_case()], [],
                 classifiers: [Classifiers.refusal(adapter: :mock)],
                 results_folder: dir
               )

      assert File.ls!(dir) == []
    end

    test "raises a classifier's error unless errors are ignored" do
      LLMMock.script(%{@step => ["no json", "no json"]}, model: "judge")
      classifier = Classifiers.refusal(adapter: :mock)

      assert_raise InvalidJSONError, fn ->
        Evaluator.run([test_case()], [], classifiers: [classifier])
      end

      assert {[[]], [[%Classification{label: nil, error: error}]], _durations} =
               Evaluator.run([test_case()], [], classifiers: [classifier], ignore_errors: true)

      assert error ==
               "Evaluation LLM outputted an invalid JSON. Please use a better evaluation model."
    end

    test "errors a classifier that outlives its timeout" do
      classifier = Classifier.new!(name: "slow", labels: ["a"], impl: __MODULE__.Slow)

      assert {[[]], [[%Classification{error: error}]], _durations} =
               Evaluator.run([test_case()], [],
                 classifiers: [classifier],
                 ignore_errors: true,
                 metric_timeout: 50
               )

      assert error =~ "Timed out/cancelled while evaluating metric."

      assert_raise DeepEvalError, ~r/^Timed out/, fn ->
        Evaluator.run([test_case()], [], classifiers: [classifier], metric_timeout: 50)
      end
    end

    test "validates the classifiers against the test cases before evaluating" do
      classifier = Classifiers.refusal(adapter: :mock)

      assert_raise ArgumentError,
                   ~r/^expected_labels\['refusal'\] = 'nope' is not one of classifier 'refusal' labels/,
                   fn ->
                     Evaluator.run(
                       [test_case(expected_labels: %{"refusal" => "nope"})],
                       [],
                       classifiers: [classifier]
                     )
                   end

      assert LLMMock.scripted_prompts() == []

      assert capture_log(fn ->
               answer("refused")

               Evaluator.run([test_case(expected_labels: %{"other" => "x"})], [],
                 classifiers: [classifier]
               )
             end) =~
               "expected_labels keys matched no classifier in this run: 'other' (1 test case)."
    end

    test "rejects an unrecognised eval mode before evaluating" do
      assert_raise ArgumentError, ~r/^Unsupported eval_mode/, fn ->
        Evaluator.run([test_case()], [],
          classifiers: [Classifiers.refusal(adapter: :mock, eval_mode: "fast")]
        )
      end
    end
  end

  defmodule Slow do
    @moduledoc false
    @behaviour DeepEvalEx.Classifier

    @impl true
    def classify(_classifier, _test_case, _opts) do
      Process.sleep(1_000)
      {:ok, %{label: "a", reason: nil}}
    end
  end

  defmodule ShortTemplate do
    @moduledoc false
    @behaviour DeepEvalEx.Prompts.Classifier

    @impl true
    def classify_single_turn(opts), do: "Short: " <> Keyword.fetch!(opts, :test_case_content)
  end

  defmodule NativeMock do
    @moduledoc false
    # The Mock adapter declared native, so a classification reports its cost.
    use DeepEvalEx.LLM.Adapter

    @impl true
    defdelegate generate(prompt, opts), to: LLMMock

    @impl true
    defdelegate generate_with_schema(prompt, schema, opts), to: LLMMock

    @impl true
    defdelegate model_name(opts), to: LLMMock

    @impl true
    defdelegate supports_structured_outputs?, to: LLMMock

    @impl true
    defdelegate supports_log_probs?, to: LLMMock

    @impl true
    def native?, do: true
  end
end
