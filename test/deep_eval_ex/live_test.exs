defmodule DeepEvalEx.LiveTest.ReqLLMSpec do
  @moduledoc false
  # The ReqLLM judge of the live suite: DEEP_EVAL_LIVE_REQLLM_MODEL, made an
  # inline spec when DEEP_EVAL_LIVE_REQLLM_BASE_URL is set.

  alias DeepEvalEx.LLM.Adapter

  def judge do
    with spec when is_binary(spec) <- Adapter.env("DEEP_EVAL_LIVE_REQLLM_MODEL"),
         base_url when is_binary(base_url) <- Adapter.env("DEEP_EVAL_LIVE_REQLLM_BASE_URL"),
         [provider, id] <- String.split(spec, ":", parts: 2) do
      %{provider: String.to_atom(provider), id: id, base_url: base_url}
      |> put_wire(Adapter.env("DEEP_EVAL_LIVE_REQLLM_WIRE"))
    else
      _ -> nil
    end
  end

  defp put_wire(spec, nil), do: spec
  defp put_wire(spec, wire), do: Map.put(spec, :extra, %{wire: %{protocol: wire}})
end

defmodule DeepEvalEx.LiveTest do
  @moduledoc """
  End-to-end checks against real LLM providers.

  Excluded by default. Configure credentials in `.devcontainer/.env`, recreate
  the container, then run:

      mix test --only live

  A provider runs only when its credentials are set; otherwise its tests are
  skipped. `DEEP_EVAL_LIVE_OPENAI_MODEL` and `DEEP_EVAL_LIVE_ANTHROPIC_MODEL`
  pick the judge model. Unset, each provider uses its adapter's default model,
  which a gateway may not serve under that name: behind a gateway, set both
  variables to the model IDs it publishes (often provider-prefixed).

  The `DeepEvalEx.LLM.Adapters.ReqLLM` case runs when
  `DEEP_EVAL_LIVE_REQLLM_MODEL` names a ReqLLM model spec, such as
  `google:gemini-2.5-flash` (with `GOOGLE_API_KEY` set), and is skipped
  otherwise. With `DEEP_EVAL_LIVE_REQLLM_BASE_URL` set, the spec becomes an
  inline one with that base URL, and `DEEP_EVAL_LIVE_REQLLM_WIRE` (for an
  `openai:` spec, `openai_responses` or `openai_chat`) names the API a
  model ReqLLM's catalog does not know speaks. An OpenAI-compatible gateway
  serving the Responses API is reached with, for example:

      DEEP_EVAL_LIVE_REQLLM_MODEL="openai:$DEEP_EVAL_LIVE_OPENAI_MODEL" \
      DEEP_EVAL_LIVE_REQLLM_BASE_URL="$OPENAI_BASE_URL" \
      DEEP_EVAL_LIVE_REQLLM_WIRE=openai_responses \
        mix test --only live

  ReqLLM reads the key from `OPENAI_API_KEY`.
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
      model:
        Adapter.env("DEEP_EVAL_LIVE_OPENAI_MODEL") ||
          DeepEvalEx.LLM.Adapters.OpenAI.model_name([])
    },
    %{
      adapter: :anthropic,
      key: "ANTHROPIC_API_KEY",
      model:
        Adapter.env("DEEP_EVAL_LIVE_ANTHROPIC_MODEL") ||
          DeepEvalEx.LLM.Adapters.Anthropic.model_name([])
    },
    %{
      adapter: :req_llm,
      key: "DEEP_EVAL_LIVE_REQLLM_MODEL",
      model: Adapter.env("DEEP_EVAL_LIVE_REQLLM_MODEL"),
      judge: DeepEvalEx.LiveTest.ReqLLMSpec.judge()
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

  defp judge(provider), do: Map.get(provider, :judge) || provider.model

  for provider <- @providers do
    @provider provider
    @configured Adapter.env(provider.key) != nil

    describe "#{provider.adapter} (#{provider.model})" do
      @describetag skip: if(@configured, do: false, else: "#{provider.key} not set")

      test "returns schema-conforming structured output and records usage" do
        opts = [adapter: @provider.adapter, model: judge(@provider)]

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
          DeepEvalEx.evaluate_run(
            test_cases(),
            metrics(),
            adapter: @provider.adapter,
            model: judge(@provider),
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
