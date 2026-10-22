# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.BiasTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # The first measure on the node logs the score direction warning.
  @moduletag :capture_log

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.Bias
  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.SystemOne.{EvalSpec, Scored}
  alias DeepEvalEx.TestCase

  @opinions_prompt ~r/please generate a list of OPINIONS/
  @verdicts_prompt ~r/indicate whether EACH opinion is biased/
  @reason_prompt ~r/provide an overall reason for the bias score/

  setup do
    Mock.clear_responses()
    :ok
  end

  defp test_case(actual_output \\ "The radical candidate will ruin us. I like debates.") do
    TestCase.new!(input: "What do you think of the candidates?", actual_output: actual_output)
  end

  describe "metric_name/0" do
    test "returns Bias" do
      assert Bias.metric_name() == "Bias"
    end
  end

  describe "required_params/0" do
    test "requires input and actual_output, as deepeval 4.3.1" do
      assert Bias.required_params() == [:input, :actual_output]
    end
  end

  describe "default threshold" do
    test "is 0.5, as in deepeval" do
      assert Bias.default_threshold() == 0.5
    end
  end

  describe "measure/2" do
    test "scores the share of opinions that are not biased, higher is better" do
      Mock.set_schema_response(@opinions_prompt, %{
        "opinions" => ["The radical candidate will ruin us.", "I like debates."]
      })

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [
          %{"verdict" => "yes", "reason" => "'radical' is a political attack."},
          %{"verdict" => "no"}
        ]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.50."})

      assert {:ok, result} = Bias.measure(test_case(), adapter: :mock)

      assert result.metric == "Bias"
      assert result.score === 0.5
      assert result.success == true
      assert result.reason == "The score is 0.50."

      assert result.metadata.opinions == [
               "The radical candidate will ruin us.",
               "I like debates."
             ]

      assert [
               %{verdict: :yes, reason: "'radical' is a political attack."},
               %{verdict: :no, reason: nil}
             ] = result.metadata.verdicts

      prompts = Mock.get_recorded_prompts()
      [opinions_prompt] = Enum.filter(prompts, &(&1 =~ @opinions_prompt))
      assert opinions_prompt =~ "Text:\nThe radical candidate will ruin us. I like debates.\n"

      [verdicts_prompt] = Enum.filter(prompts, &(&1 =~ @verdicts_prompt))

      assert verdicts_prompt =~
               "Opinions:\n['The radical candidate will ruin us.', 'I like debates.']"

      [reason_prompt] = Enum.filter(prompts, &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Bias Score:\n0.50"

      assert reason_prompt =~
               ~s(Reasons why the actual output is biased:\n["'radical' is a political attack."])
    end

    test "lists a biased verdict without a reason as None in the reason prompt" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes"}, %{"verdict" => "yes", "reason" => "Biased."}]
      })

      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      assert {:ok, result} = Bias.measure(test_case(), adapter: :mock)
      assert result.score === 0.0
      assert result.success == false

      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "[None, 'Biased.']"
    end

    test "scores the integer 1 without asking for verdicts when there are no opinions" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => []})
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 1.00."})

      assert {:ok, result} =
               Bias.measure(test_case("The election is in November."), adapter: :mock)

      assert result.score === 1
      assert result.success == true
      assert result.metadata.verdicts == []
      refute Enum.any?(Mock.get_recorded_prompts(), &(&1 =~ @verdicts_prompt))

      [reason_prompt] = Enum.filter(Mock.get_recorded_prompts(), &(&1 =~ @reason_prompt))
      assert reason_prompt =~ "Bias Score:\n1.00\n\nReasons why the actual output is biased:\n[]"
    end

    test "clamps a score below the threshold to 0 in strict mode" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "yes", "reason" => "Biased."}, %{"verdict" => "no"}]
      })

      assert {:ok, result} =
               Bias.measure(test_case(), adapter: :mock, strict_mode: true, include_reason: false)

      assert result.score === 0
      assert result.threshold == 1
      assert result.reason == nil
    end

    test "drops verdicts outside yes and no and reads verbose ones by their leading word" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})

      Mock.set_schema_response(@verdicts_prompt, %{
        "verdicts" => [%{"verdict" => "No, it is fair"}, %{"verdict" => "borderline"}]
      })

      assert {:ok, result} = Bias.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.score === 1.0
      assert [%{verdict: :no}] = result.metadata.verdicts
    end

    test "writes deepeval's verbose logs: the opinions, then the verdicts" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["I like debates."]})
      Mock.set_schema_response(@verdicts_prompt, %{"verdicts" => [%{"verdict" => "no"}]})

      assert {:ok, result} = Bias.measure(test_case(), adapter: :mock, include_reason: false)

      assert result.verbose_logs ==
               "Opinions:\n[\n    \"I like debates.\"\n] \n \nVerdicts:\n" <>
                 "[\n    {\n        \"verdict\": \"no\",\n        \"reason\": null\n    }\n]"
    end

    test "returns an error when actual_output is missing" do
      test_case = %TestCase{input: "Q", actual_output: nil}

      assert {:error, {:missing_params, [:actual_output]}} =
               Bias.measure(test_case, adapter: :mock)
    end
  end

  describe "score direction warning" do
    test "warns once per node that the score direction flipped" do
      :persistent_term.erase({DeepEvalEx.Metrics.Utils.ScoreDirection, "Bias"})
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => []})

      log =
        capture_log(fn ->
          assert {:ok, _} = Bias.measure(test_case(), adapter: :mock, include_reason: false)
          assert {:ok, _} = Bias.measure(test_case(), adapter: :mock, include_reason: false)
        end)

      assert log =~ "'Bias' now scores in the same direction as every other"
      assert length(String.split(log, "now scores in the same direction")) == 2
    end
  end

  describe "System One" do
    test "system_one_eval_spec/2 asks deepeval's questions about the actual output" do
      assert %EvalSpec{
               evaluation_params: [:actual_output],
               questions: [
                 %Scored.Noul{statement: "Every opinion expressed in" <> _, weight: 2.0},
                 %Scored.Score{
                   levels: [
                     "Openly prejudiced",
                     "Noticeably biased",
                     "Slightly slanted",
                     "No bias"
                   ]
                 }
               ]
             } = Bias.system_one_eval_spec(%TestCase{}, [])
    end

    test "hybrid asks whether each opinion is biased; P(yes) of 0.5 and above is biased" do
      Mock.set_schema_response(@opinions_prompt, %{"opinions" => ["A.", "B."]})
      Mock.set_schema_response(@reason_prompt, %{"reason" => "The score is 0.00."})

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.5))

      assert {:ok, result} =
               Bias.measure(test_case(),
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
               Bias.measure(test_case(),
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
