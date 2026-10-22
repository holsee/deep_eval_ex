defmodule DeepEvalEx.LiveTest do
  @moduledoc """
  End-to-end checks against real LLM providers.

  Excluded by default. Configure credentials in `.devcontainer/.env`, recreate
  the container, then run:

      mix test --only live

  A provider runs only when its credentials are set; otherwise its tests are
  skipped. `DEEP_EVAL_LIVE_OPENAI_MODEL` and `DEEP_EVAL_LIVE_ANTHROPIC_MODEL`
  pick the judge model (defaults: each adapter's default model).
  """

  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.{Adapter, Pricing, Usage}
  alias DeepEvalEx.Metrics.{ExactMatch, Faithfulness, GEval}
  alias DeepEvalEx.{TestCase, TestRun}
  alias DeepEvalEx.TestRun.JSON

  @moduletag :live
  @moduletag timeout: 300_000

  @providers [
    %{
      adapter: :openai,
      key: "OPENAI_API_KEY",
      model: Adapter.env("DEEP_EVAL_LIVE_OPENAI_MODEL") || "gpt-4o-mini"
    },
    %{
      adapter: :anthropic,
      key: "ANTHROPIC_API_KEY",
      model:
        Adapter.env("DEEP_EVAL_LIVE_ANTHROPIC_MODEL") ||
          DeepEvalEx.LLM.Adapters.Anthropic.model_name([])
    }
  ]

  @verdict_schema %{
    "type" => "object",
    "properties" => %{"verdict" => %{"type" => "string", "enum" => ["yes", "no"]}},
    "required" => ["verdict"],
    "additionalProperties" => false
  }

  defp test_cases do
    [
      TestCase.new!(
        name: "faithful",
        input: "What is the boiling point of water at sea level?",
        actual_output: "Water boils at 100 degrees Celsius at sea level.",
        expected_output: "Water boils at 100 degrees Celsius at sea level.",
        retrieval_context: ["At standard sea-level pressure, water boils at 100 °C (212 °F)."]
      ),
      TestCase.new!(
        name: "unfaithful",
        input: "What is the boiling point of water at sea level?",
        actual_output: "Water boils at 50 degrees Celsius at sea level.",
        expected_output: "Water boils at 100 degrees Celsius at sea level.",
        retrieval_context: ["At standard sea-level pressure, water boils at 100 °C (212 °F)."]
      )
    ]
  end

  defp metrics do
    [
      Faithfulness,
      GEval.new(
        name: "Correctness",
        criteria: "Is the actual output factually correct for the input?",
        evaluation_params: [:input, :actual_output]
      ),
      ExactMatch
    ]
  end

  for provider <- @providers do
    @provider provider
    @configured Adapter.env(provider.key) != nil

    describe "#{provider.adapter} (#{provider.model})" do
      @describetag skip: if(@configured, do: false, else: "#{provider.key} not set")

      test "returns schema-conforming structured output and records usage" do
        opts = [adapter: @provider.adapter, model: @provider.model]

        {result, usages} =
          Usage.track(fn ->
            Adapter.generate_with_schema(
              "Is Paris the capital of France? Answer with the verdict field.",
              @verdict_schema,
              opts
            )
          end)

        assert {:ok, %{"verdict" => "yes"}} = result
        assert [%Usage{model: model, input_tokens: input, output_tokens: output}] = usages
        assert model == @provider.model
        assert input > 0 and output > 0
      end

      @tag :tmp_dir
      test "exports a deepeval-compatible run with judge model, tokens and cost", %{
        tmp_dir: dir
      } do
        {results, _run, path} =
          DeepEvalEx.evaluate_run(test_cases(), metrics(),
            adapter: @provider.adapter,
            model: @provider.model,
            results_folder: dir,
            identifier: "live-#{@provider.adapter}"
          )

        assert [[faithful_f, faithful_g, _], [unfaithful_f, unfaithful_g, _]] = results

        for result <- [faithful_f, faithful_g, unfaithful_f, unfaithful_g] do
          assert result.error == nil, "#{result.metric} errored: #{result.error}"
        end

        assert faithful_f.score > unfaithful_f.score
        assert faithful_g.score > unfaithful_g.score
        assert faithful_f.success and faithful_g.success
        refute unfaithful_f.success

        json = File.read!(path)
        decoded = Jason.decode!(json)
        [case_one | _] = decoded["testCases"]

        for metric_data <- case_one["metricsData"] do
          case metric_data["name"] do
            "Exact Match" ->
              refute Map.has_key?(metric_data, "evaluationModel")

            _llm_metric ->
              assert metric_data["evaluationModel"] == @provider.model
              assert metric_data["inputTokenCount"] > 0
              assert metric_data["outputTokenCount"] > 0

              if Pricing.price(@provider.model) do
                assert metric_data["evaluationCost"] > 0
              end
          end
        end

        assert decoded["testPassed"] == 1
        assert decoded["testFailed"] == 1

        assert {:ok, loaded} = TestRun.load(path)
        assert loaded |> TestRun.to_map() |> JSON.encode!() == json
      end
    end
  end
end
