defmodule DeepEvalEx.ScriptedParityTest do
  @moduledoc """
  Replays the scripted-judge scenarios of `test/fixtures/deepeval/scripted/`
  through DeepEvalEx and compares each with what deepeval 4.3.1 did for the
  same judge responses (see `DeepEvalEx.Test.ScriptedParity` and the
  fixtures' README):

  - `prompts` - every prompt the metric sent, byte for byte
  - `measure` - score, success, reason, threshold, error, evaluation model,
    cost and tokens after measuring
  - `verbose_logs` - the metric's verbose logs
  - `test_run` - the exported test run, byte for byte

  Comparisons that fail because of a documented divergence from 4.3.1 are
  tagged `known_divergence: "<unit>"`, naming the ROADMAP unit that removes
  the tag. They are excluded by default; run them with
  `mix test --only known_divergence`.
  """

  use ExUnit.Case, async: true

  import DeepEvalEx.Test.ScriptedParity

  @moduletag :parity
  @moduletag :tmp_dir
  # Hallucination logs its one-time score direction warning on first measure.
  @moduletag :capture_log

  @scenarios scenarios()

  for scenario <- @scenarios, file <- ~w(script.json prompts.json measure.json test_run.json) do
    @external_resource fixture(scenario, file)
  end

  # Per facet, {the ROADMAP unit that removes the tag, scenarios}: when a
  # comparison diverges for several reasons, the last unit to land. The
  # fixtures' README lists every reason.
  @known_divergences %{
    prompts: [],
    measure: [],
    verbose_logs: [],
    test_run: []
  }

  known_divergence = fn scenario, facet ->
    Enum.find_value(@known_divergences[facet], fn {unit, scenarios} ->
      if scenario in scenarios, do: unit
    end)
  end

  test "lists known divergences of existing scenarios only" do
    for {_facet, units} <- @known_divergences, {_unit, scenarios} <- units do
      assert scenarios -- @scenarios == []
    end
  end

  test "covers each of the eighteen metrics" do
    kinds =
      @scenarios
      |> Enum.map(&(&1 |> fixture("script.json") |> File.read!() |> Jason.decode!()))
      |> Enum.map(& &1["metric"]["kind"])
      |> Enum.uniq()
      |> Enum.sort()

    assert kinds ==
             ~w(answer_relevancy argument_correctness bias contextual_precision contextual_recall contextual_relevancy
                exact_match faithfulness g_eval hallucination json_correctness pattern_match pii_leakage
                prompt_alignment summarization tool_correctness tool_permission toxicity)
  end

  describe "assert_matches_fixture/2 on prompts" do
    setup %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts.json")

      File.write!(
        path,
        Jason.encode!([
          %{step: "truths", prompt: "T"},
          %{step: "claims", prompt: "C"},
          %{step: "verdicts", prompt: "V"},
          %{step: "reason", prompt: "R"}
        ])
      )

      %{path: path}
    end

    test "rejects a step sent before a step it depends on", %{path: path} do
      reordered = [
        %{step: "truths", prompt: "T"},
        %{step: "claims", prompt: "C"},
        %{step: "reason", prompt: "R"},
        %{step: "verdicts", prompt: "V"}
      ]

      assert_raise ExUnit.AssertionError, ~r/"reason".*"verdicts"/s, fn ->
        assert_matches_fixture(reordered, path)
      end
    end

    test "accepts independent steps in either order", %{path: path} do
      swapped = [
        %{step: "claims", prompt: "C"},
        %{step: "truths", prompt: "T"},
        %{step: "verdicts", prompt: "V"},
        %{step: "reason", prompt: "R"}
      ]

      assert assert_matches_fixture(swapped, path)
    end
  end

  for scenario <- @scenarios do
    describe "#{scenario} scenario" do
      @describetag scenario: scenario

      if unit = known_divergence.(scenario, :prompts), do: @tag(known_divergence: unit)

      test "sends deepeval's prompts", %{scenario: scenario} do
        {_measured, prompts} = measure(scenario)

        assert_matches_fixture(prompts, fixture(scenario, "prompts.json"))
      end

      if unit = known_divergence.(scenario, :measure), do: @tag(known_divergence: unit)

      test "measures deepeval's score, success, reason, model, cost and tokens",
           %{scenario: scenario} do
        {measured, _prompts} = measure(scenario)

        assert_matches_fixture(
          Map.delete(measured, "verbose_logs"),
          fixture(scenario, "measure.json")
        )
      end

      if unit = known_divergence.(scenario, :verbose_logs), do: @tag(known_divergence: unit)

      test "has deepeval's verbose logs", %{scenario: scenario} do
        {measured, _prompts} = measure(scenario)

        assert_matches_fixture(
          Map.take(measured, ["verbose_logs"]),
          fixture(scenario, "measure.json")
        )
      end

      if unit = known_divergence.(scenario, :test_run), do: @tag(known_divergence: unit)

      test "exports deepeval's test run byte for byte", %{scenario: scenario, tmp_dir: tmp_dir} do
        scenario
        |> test_run(tmp_dir)
        |> assert_matches_fixture(fixture(scenario, "test_run.json"))
      end
    end
  end
end
