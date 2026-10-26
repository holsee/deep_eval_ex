defmodule DeepEvalEx.LiveSystemOneTest do
  @moduledoc """
  End-to-end checks against TypeSafe's System One model, Jev (unit P4-9).

  Excluded by default. Set `TYPESAFE_API_KEY` (and optionally
  `TYPESAFE_MODEL_NAME`) in `.devcontainer/.env`, recreate the container,
  then run:

      mix test --only live_system_one

  Without `TYPESAFE_API_KEY` the tests are skipped. `TYPESAFE_MODEL_NAME`
  defaults to `"jev-latest"`, as in deepeval's `TypeSafeModel`.

  The scenarios of `test/fixtures/deepeval/system_one/` that Jev decides
  alone (no LLM judge, no failing fake) are evaluated again with the real
  `DeepEvalEx.SystemOne.Adapters.TypeSafe` in place of deepeval's fake. The
  requests are those the fixture checks already match byte for byte with
  deepeval's, so this checks the other half: that Jev accepts every one and
  its answers come back as a test run shaped like deepeval's, priced from
  Jev's reported usage. Jev's scores differ from the fakes' canned answers,
  so only their range is checked. Each scenario's token count and cost are
  printed.
  """

  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.SystemOne.Adapters.TypeSafe
  alias DeepEvalEx.SystemOne.{Answers, Question}
  alias DeepEvalEx.Test.SystemOneParity

  @moduletag :live_system_one
  @moduletag timeout: 600_000

  @configured Adapter.env("TYPESAFE_API_KEY") != nil
  @model Adapter.env("TYPESAFE_MODEL_NAME") || "jev-latest"
  @price 0.042 / 1.0e6

  @fixtures Path.expand("../fixtures/deepeval/system_one", __DIR__)

  # Scenarios decided by the fake alone: no scripted judge, no raising fake.
  @scenarios @fixtures
             |> File.ls!()
             |> Enum.map(&{&1, Path.join([@fixtures, &1, "input.json"])})
             |> Enum.filter(fn {_scenario, path} -> File.regular?(path) end)
             |> Enum.map(fn {scenario, path} -> {scenario, JSON.decode!(File.read!(path))} end)
             |> Enum.filter(fn {_scenario, input} ->
               input["metrics"] != nil and input["responses"] in [nil, %{}] and
                 input["system_one"]["answers"] != nil
             end)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort()

  describe "TypeSafe Jev (#{@model})" do
    @describetag skip: if(@configured, do: false, else: "TYPESAFE_API_KEY not set")

    test "decide/3 answers a Noul, a Choice and a Score, priced from Jev's usage" do
      state =
        Jason.OrderedObject.new([
          {"context", "The Eiffel Tower is in Paris. It was completed in 1889."},
          {"claim", "The Eiffel Tower was finished in 1889."}
        ])

      questions = [
        {"supported", %Question.Noul{instructions: "The `claim` is supported by the `context`."}},
        {"verdict",
         %Question.Choice{
           instructions: "Classify how the `context` relates to the `claim`.",
           options: [
             {"yes", "The context supports the claim."},
             {"no", "The context contradicts the claim."},
             {"idk", "The context does not address the claim."}
           ]
         }},
        {"relevance",
         %Question.Score{
           instructions: "How relevant is the `context` to the `claim`?",
           levels: ["Unrelated.", "Mentions the topic only.", "Directly addresses the claim."]
         }}
      ]

      {:ok, opts} = TypeSafe.init([])
      assert {:ok, %Answers{} = answers, usage} = TypeSafe.decide(state, questions, opts)

      assert %{"supported" => %Answers.Noul{probability: p}} = answers.nouls
      assert p > 0.5

      assert %Answers.Choice{choice: "yes", probabilities: choice_ps} = answers.choices["verdict"]

      assert Enum.map(choice_ps, &elem(&1, 0)) |> Enum.sort() == ~w(idk no yes)

      assert %Answers.Score{probabilities: score_ps} = answers.scores["relevance"]
      assert Enum.map(score_ps, &elem(&1, 0)) |> Enum.sort() == [0, 1, 2]

      assert usage.model == "#{@model} (TypeSafe AI)"
      assert usage.input_tokens > 0
      assert usage.cost == usage.input_tokens * @price
    end

    for scenario <- @scenarios do
      @tag scenario: scenario
      @tag :tmp_dir
      test "evaluates #{scenario} as deepeval's test run shape", %{tmp_dir: dir} do
        scenario = unquote(scenario)
        {:ok, opts} = TypeSafe.init([])

        {json, []} = SystemOneParity.test_run(scenario, dir, {TypeSafe, opts})
        live = JSON.decode!(json)

        fake =
          SystemOneParity.fixture(scenario, "test_run.json") |> File.read!() |> JSON.decode!()

        live_metrics = metrics_data(live)
        fake_metrics = metrics_data(fake)

        assert Enum.map(live_metrics, & &1["name"]) == Enum.map(fake_metrics, & &1["name"])

        for {got, want} <- Enum.zip(live_metrics, fake_metrics) do
          label = "#{scenario} #{got["name"]}"

          # An unpriced fake's run exports no evaluationCost; Jev's has one.
          assert Map.keys(Map.delete(got, "evaluationCost")) |> Enum.sort() ==
                   Map.keys(Map.delete(want, "evaluationCost")) |> Enum.sort(),
                 label

          assert got["error"] == nil, "#{label}: #{got["error"]}"
          # The fake's name becomes Jev's; a metric another model decides
          # keeps that model's.
          model = if want["evaluationModel"] == "fake-jev", do: "#{@model} (TypeSafe AI)"
          assert got["evaluationModel"] == (model || want["evaluationModel"]), label

          if is_number(want["score"]) do
            assert got["score"] >= 0 and got["score"] <= 1, label
            assert is_boolean(got["success"]), label
          else
            assert got["score"] == want["score"], label
          end

          assert is_integer(got["inputTokenCount"]) and got["inputTokenCount"] >= 0, label

          # Unpriced where deepeval's was although its fake had a price (a
          # hybrid metric whose judge has none); Jev, unlike an unpriced
          # fake, has one. Otherwise priced from Jev's usage: a batch's cost
          # is shared out across its metrics with their token counts
          # rounded, so within half a token per metric of a metric's own.
          if want["evaluationCost"] == nil and fake_priced?(scenario) do
            assert got["evaluationCost"] == nil, label
          else
            assert_in_delta got["evaluationCost"],
                            got["inputTokenCount"] * @price,
                            @price * length(live_metrics),
                            label
          end
        end

        # Jev bills the requests deepeval's evaluate() made: tokens when there
        # were any.
        tokens = live_metrics |> Enum.map(& &1["inputTokenCount"]) |> Enum.sum()
        asked = SystemOneParity.fixture(scenario, "decide.json") |> File.read!() |> JSON.decode!()
        asked = asked["evaluate"]

        assert tokens > 0 == (asked != []),
               "#{scenario}: #{tokens} tokens for #{length(asked)} calls"

        IO.puts(
          "\n  #{String.pad_trailing(scenario, 40)} metrics=#{length(live_metrics)} " <>
            "input_tokens=#{tokens} run_cost=$#{live["evaluationCost"]}"
        )
      end
    end
  end

  defp fake_priced?(scenario) do
    input = SystemOneParity.fixture(scenario, "input.json") |> File.read!() |> JSON.decode!()
    input["system_one"]["cost"] != nil
  end

  defp metrics_data(test_run) do
    (test_run["testCases"] ++ test_run["conversationalTestCases"])
    |> Enum.flat_map(& &1["metricsData"])
  end
end
