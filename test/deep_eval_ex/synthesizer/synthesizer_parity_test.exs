defmodule DeepEvalEx.Synthesizer.ParityTest do
  @moduledoc """
  Replays the judge scripts under test/fixtures/deepeval/synthesizer/scenarios
  through `DeepEvalEx.Synthesizer` and compares the prompts it sends and the
  goldens it returns with what deepeval 4.3.1's `Synthesizer` did with the
  same scripts (written by scripts/parity/generate_synthesizer_fixtures.py).

  The scripted judge answers each step's calls in order, so the synthesizer
  runs with `max_concurrent: 1`; the prompts are compared step by step,
  since deepeval's asyncio tasks interleave the steps of different contexts
  differently.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Synthesizer
  alias DeepEvalEx.Synthesizer.{Evolution, StylingConfig}

  @scenarios Path.expand("../../fixtures/deepeval/synthesizer/scenarios", __DIR__)

  for file <- @scenarios |> File.ls!() |> Enum.sort() do
    @path Path.join(@scenarios, file)
    @external_resource @path
    @scenario @path |> File.read!() |> Jason.decode!()

    test "#{Path.rootname(file)}: #{@scenario["method"]} as deepeval" do
      scenario = @scenario
      Mock.script(scenario["script"], model: "scripted-judge")
      synthesizer = synthesizer(scenario["synthesizer"])

      case scenario do
        %{"raised" => %{"type" => "TypeError", "message" => message}} ->
          assert_raise ArgumentError, message, fn -> run(synthesizer, scenario) end

        %{"goldens" => goldens, "styling_config" => styling} ->
          assert {:ok, %Synthesizer{} = synthesizer} = run(synthesizer, scenario)
          assert Enum.map(synthesizer.synthetic_goldens, &dump_golden/1) == goldens
          assert dump_styling(synthesizer.styling_config) == styling
          assert synthesizer.synthesis_cost == nil
      end

      assert by_step(Mock.scripted_prompts()) == by_step(scenario["prompts"])
    end
  end

  defp synthesizer(config) do
    evolution = config["evolution_config"]
    filtration = config["filtration_config"]

    styling =
      case config["styling_config"] do
        nil -> []
        styling -> [styling_config: StylingConfig.new(atomize(styling))]
      end

    Synthesizer.new(
      [
        adapter: :mock,
        max_concurrent: 1,
        evolution_config: [
          num_evolutions: evolution["num_evolutions"],
          evolutions:
            Enum.map(evolution["evolutions"], fn {value, weight} ->
              {Evolution.from_value(value), weight}
            end)
        ],
        filtration_config: [
          synthetic_input_quality_threshold: filtration["synthetic_input_quality_threshold"],
          max_quality_retries: filtration["max_quality_retries"],
          critic_adapter: :mock
        ]
      ] ++ styling
    )
  end

  defp run(synthesizer, %{"method" => "generate_goldens_from_contexts", "args" => args}) do
    {contexts, opts} = args |> atomize() |> Keyword.pop!(:contexts)
    Synthesizer.generate_goldens_from_contexts(synthesizer, contexts, opts)
  end

  defp run(synthesizer, %{"method" => "generate_goldens_from_scratch", "args" => args}) do
    {num_goldens, opts} = args |> atomize() |> Keyword.pop!(:num_goldens)
    Synthesizer.generate_goldens_from_scratch(synthesizer, num_goldens, opts)
  end

  defp run(synthesizer, %{"method" => "generate_goldens_from_goldens", "args" => args}) do
    {goldens, opts} = args |> atomize() |> Keyword.pop!(:goldens)
    goldens = Enum.map(goldens, &Golden.new!/1)
    Synthesizer.generate_goldens_from_goldens(synthesizer, goldens, opts)
  end

  defp atomize(map), do: Enum.map(map, fn {key, value} -> {String.to_atom(key), value} end)

  defp by_step(prompts) do
    Enum.group_by(prompts, &(&1[:step] || &1["step"]), &(&1[:prompt] || &1["prompt"]))
  end

  defp dump_golden(%Golden{} = golden) do
    %{
      "input" => golden.input,
      "expected_output" => golden.expected_output,
      "context" => golden.context,
      "source_file" => golden.source_file,
      "additional_metadata" => golden.additional_metadata
    }
  end

  defp dump_styling(%StylingConfig{} = styling) do
    %{
      "scenario" => styling.scenario,
      "task" => styling.task,
      "input_format" => styling.input_format,
      "expected_output_format" => styling.expected_output_format
    }
  end
end
