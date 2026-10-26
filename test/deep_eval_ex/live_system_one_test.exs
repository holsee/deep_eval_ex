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

  Costs are checked at the price the adapter resolves:
  `TYPESAFE_COST_PER_INPUT_TOKEN` when set, else Jev's for a registered
  model. A model with neither (such as a pinned `jev-1.14.0`) is unpriced:
  its costs are checked to be `nil`, and its token counts, which are not
  recorded, are not checked.
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
  # Jev's price per input token for its registered models (see the
  # adapter's "Usage and cost").
  @jev_price 0.042 / 1.0e6
  @jev_models ~w(jev-1.13.0 jev-latest jev-preview)

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
      price = price(opts)
      assert {:ok, %Answers{} = answers, usage} = TypeSafe.decide(state, questions, opts)

      assert %{"supported" => %Answers.Noul{probability: p}} = answers.nouls
      assert p > 0.5

      assert %Answers.Choice{choice: "yes", probabilities: choice_ps} = answers.choices["verdict"]

      assert Enum.map(choice_ps, &elem(&1, 0)) |> Enum.sort() == ~w(idk no yes)

      assert %Answers.Score{probabilities: score_ps} = answers.scores["relevance"]
      assert Enum.map(score_ps, &elem(&1, 0)) |> Enum.sort() == [0, 1, 2]

      if price do
        assert usage.model == TypeSafe.model_name(opts)
        assert usage.input_tokens > 0
        assert usage.cost == usage.input_tokens * price
      else
        assert usage == nil, "#{opts[:model]} has no price, so its usage is unpriced"
      end
    end

    for scenario <- @scenarios do
      @tag scenario: scenario
      @tag :tmp_dir
      test "evaluates #{scenario} as deepeval's test run shape", %{tmp_dir: dir} do
        scenario = unquote(scenario)
        {:ok, opts} = TypeSafe.init([])
        price = price(opts)

        {json, _calls} = SystemOneParity.test_run(scenario, dir, {TypeSafe, opts})
        live = JSON.decode!(json)

        fake =
          SystemOneParity.fixture(scenario, "test_run.json") |> File.read!() |> JSON.decode!()

        live_metrics = metrics_data(live)
        fake_metrics = metrics_data(fake)

        assert Enum.map(live_metrics, & &1["name"]) == Enum.map(fake_metrics, & &1["name"])

        for {got, want} <- Enum.zip(live_metrics, fake_metrics) do
          label = "#{scenario} #{got["name"]}"

          # An unpriced fake's run exports no evaluationCost; Jev's has one.
          # An unpriced model's run may export no token counts either.
          optional =
            if price,
              do: ["evaluationCost"],
              else: ~w(evaluationCost inputTokenCount outputTokenCount)

          assert Map.keys(Map.drop(got, optional)) |> Enum.sort() ==
                   Map.keys(Map.drop(want, optional)) |> Enum.sort(),
                 label

          assert got["error"] == nil, "#{label}: #{got["error"]}"
          # The fake's name becomes Jev's; a metric another model decides
          # keeps that model's.
          model = if want["evaluationModel"] == "fake-jev", do: TypeSafe.model_name(opts)
          assert got["evaluationModel"] == (model || want["evaluationModel"]), label

          if is_number(want["score"]) do
            assert got["score"] >= 0 and got["score"] <= 1, label
            assert is_boolean(got["success"]), label
          else
            assert got["score"] == want["score"], label
          end

          # An unpriced model's usage is not recorded, so a metric with no
          # other usage may have no token count.
          assert (is_integer(got["inputTokenCount"]) and got["inputTokenCount"] >= 0) or
                   (price == nil and got["inputTokenCount"] == nil),
                 label

          # Unpriced when the model is, or where deepeval's was although
          # its fake had a price (a hybrid metric whose judge has none);
          # Jev, unlike an unpriced fake, has one. Otherwise priced from
          # Jev's usage: a batch's cost is shared out across its metrics
          # with their token counts rounded, so within half a token per
          # metric of a metric's own.
          cond do
            # A metric no model decided (no evaluationModel) asked Jev
            # nothing and keeps its seeded cost; one Jev decided is voided.
            price == nil and want["evaluationModel"] == nil ->
              assert got["evaluationCost"] == want["evaluationCost"], label

            price == nil ->
              assert got["evaluationCost"] == nil, label

            want["evaluationCost"] == nil and fake_priced?(scenario) ->
              assert got["evaluationCost"] == nil, label

            true ->
              assert_in_delta got["evaluationCost"],
                              got["inputTokenCount"] * price,
                              price * length(live_metrics),
                              label
          end
        end

        # Jev bills the requests deepeval's evaluate() made: tokens when there
        # were any. An unpriced model's usage, tokens included, is not
        # recorded, as deepeval's calculate_cost returns None.
        tokens = live_metrics |> Enum.map(&(&1["inputTokenCount"] || 0)) |> Enum.sum()
        asked = SystemOneParity.fixture(scenario, "decide.json") |> File.read!() |> JSON.decode!()
        asked = asked["evaluate"]

        if price do
          assert tokens > 0 == (asked != []),
                 "#{scenario}: #{tokens} tokens for #{length(asked)} calls"
        end

        IO.puts(
          "\n  #{String.pad_trailing(scenario, 40)} metrics=#{length(live_metrics)} " <>
            "input_tokens=#{tokens} run_cost=$#{live["evaluationCost"]}"
        )
      end
    end
  end

  # The adapter's price: the configured one, else Jev's for a registered
  # model, else none.
  defp price(opts) do
    Keyword.get(opts, :cost_per_input_token) ||
      if Keyword.fetch!(opts, :model) in @jev_models, do: @jev_price
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
