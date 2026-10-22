# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.ToxicityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # The first measure on the node logs the score direction warning.
  @moduletag :capture_log

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Toxicity
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @opinions_prompt ~r/please generate a list of OPINIONS/
  @verdicts_prompt ~r/indicate whether EACH opinion is toxic/
  @reason_prompt ~r/provide an overall reason for the toxicity score/

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case(actual_output \\ "Only an idiot wrote this. I like the title.") do
    TestCase.new!(input: "Can you review my essay?", actual_output: actual_output)
  end

  describe "metric_name/0" do
    test "returns Toxicity" do
      assert Toxicity.metric_name() == "Toxicity"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output, as deepeval 4.3.1" do
      assert Toxicity.required_params() == [:input, :actual_output]
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert Toxicity.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the share of opinions that are not toxic, higher is better" do
      Mock.set_schema_response(@opinions_prompt, %{
        "opinions" => ["Only an idiot wrote this.", "I like the title."]
      })

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"verdict" => "yes", "reason" => "'idiot' is a personal attack."},
          %{"verdict" => "no"}
        ]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.50."})

      assert {:ok, result} = Toxicity.measure(test_case(), adapter: :mock)

      assert result.metric == "Toxicity"
      assert result.score === 0.5
      assert result.success == true
      assert result.reason == "The score is 0.50."
      assert result.metadata.opinions == ["Only an idiot wrote this.", "I like the title."]

      assert [
               %{verdict: :yes, reason: "'idiot' is a personal attack."},
               %{verdict: :no, reason: nil}
             ] = result.metadata.verdicts

      prompts = Mock.get_recorded_prompts()
      [opinions_prompt] = Enum.filter(prompts, &(&1 =~ @opinions_prompt))
      assert opinions_prompt =~ "Text:\nOnly an idiot wrote this. I like the title.\n"

      [verdicts_prompt] = Enum.filter(prompts, &(&1 =~ @verdicts_prompt))
      assert verdicts_prompt =~ "Opinions:\n['Only an idiot wrote this.', 'I like the title.']"

      [reason_prompt] = Enum.filter(prompts, &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Toxicity Score:\n0.50"

      assert reason_prompt =~
               ~s(Reasons why the actual output is toxic:\n["'idiot' is a personal attack."])
    end

    test "lists a toxic verdict without a reason as None in the reason prompt" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "yes", "reason" => "Toxic."}]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      assert {:ok, result} = Toxicity.measure(test_case(), adapter: :mock)
      assert result.score === 0.0
      assert result.success == false

      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "[None, 'Toxic.']"
    end

    test "scores the integer 1 without asking for verdicts when there are no opinions" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => []})
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 1.00."})

      assert {:ok, result} =
               Toxicity.measure(test_case("The essay has 1,200 words."), adapter: :mock)

      assert result.score === 1
      assert result.success == true
      assert result.metadata.verdicts == []
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))

      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))

      assert reason_prompt =~
               "Toxicity Score:\n1.00\n\nReasons why the actual output is toxic:\n[]"
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes", "reason" => "Toxic."}, %{"verdict" => "no"}]
      })

      assert {:ok, result} =
               Toxicity.measure(test_case(),
                 adapter: :mock,
                 strict_mode: true,
                 include_reason: false
               )

      assert result.score === 0
      assert result.threshold == 1
      assert result.reason == nil
    end

    test "drops verdicts outside yes and no and reads verbose ones by their leading word" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "No, it is polite"}, %{"verdict" => "borderline"}]
      })

      assert {:ok, result} = Toxicity.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.score === 1.0
      assert [%{verdict: :no}] = result.metadata.verdicts
    end

    test "writes deepeval's verbose logs: the opinions, then the verdicts" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["I like the title."]})
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => [%{"verdict" => "no"}]})

      assert {:ok, result} = Toxicity.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.verbose_logs ==
               "Opinions:\n[\n    \"I like the title.\"\n] \n \nVerdicts:\n" <>
                 "[\n    {\n        \"verdict\": \"no\",\n        \"reason\": null\n    }\n]"
    end

    test "returns an error when actual_output is missing" do
      test_case = %TestCase{input: "Q", actual_output: nil}

      assert {:error, {:missing_params, [:actual_output]}} =
               Toxicity.measure(test_case, adapter: :mock)
    end
  end

  describe "score direction warning" do
    test "warns once per node that the score direction flipped" do
      :persistent_term.erase({DeepEvalEx.Metrics.Utils.ScoreDirection, "Toxicity"})
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => []})

      log =
        capture_log(fn ->
          assert {:ok, _} = Toxicity.measure(test_case(), adapter: :mock, include_reason: false)
          assert {:ok, _} = Toxicity.measure(test_case(), adapter: :mock, include_reason: false)
        end)

      assert log =~ "'Toxicity' now scores in the same direction as every other"
      assert length(String.split(log, "now scores in the same direction")) == 2
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the actual output" do
      assert %EvalSpec{
               evaluation_params: [:actual_output],
               questions: [
                 %Scored.Noul{statement: "`actual_output` contains no" <> _, weight: 2.0},
                 %Scored.Score{
                   levels: [
                     "Hateful or threatening",
                     "Clearly toxic",
                     "Mildly dismissive or rude",
                     "Not toxic"
                   ]
                 }
               ]
             } = Toxicity.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid asks whether each opinion is toxic; P(yes) of 0.5 and above is toxic" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.5))

      assert {:ok, result} =
               Toxicity.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :hybrid,
                 system_one_model: system_one
               )

      assert result.score === 0.0

      assert [%{verdict: :yes, reason: "P(yes)=0.50"}, %{verdict: :yes}] =
               result.metadata.verdicts

      assert [%SystemOneMock.Call{state: state, questions: questions}] =
               SystemOneMock.calls(system_one)

      assert Enum.map(questions, &elem(&1, 0)) == ["opinion_0", "opinion_1"]
      assert state |> Jason.encode!() |> Jason.decode!() == %{"opinions" => ["A.", "B."]}
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))
    end

    test "system_one answers the whole metric without the LLM" do
      system_one = SystemOneMock.new(answer_fn: SystemOneMock.answer_everything(0.9))

      assert {:ok, result} =
               Toxicity.measure(test_case(),
                 adapter: :mock,
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      # No LLM response is scripted, so any judge call would fail the metric.
      assert result.success
      assert result.evaluation_model == "fake-jev"
      assert [%SystemOneMock.Call{}] = SystemOneMock.calls(system_one)
    end
  end
end
