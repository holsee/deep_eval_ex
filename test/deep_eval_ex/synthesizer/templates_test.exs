defmodule DeepEvalEx.Synthesizer.TemplatesTest do
  @moduledoc """
  Renders the synthesizer templates for the arguments in
  test/fixtures/deepeval/synthesizer/templates.json and compares them, byte
  for byte, with the prompts deepeval 4.3.1's templates rendered for the
  same arguments (written by
  scripts/parity/generate_synthesizer_fixtures.py).
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Synthesizer.{
    EvolutionTemplate,
    ExtractionTemplate,
    FilterTemplate,
    PromptEvolutionTemplate,
    PromptSynthesizerTemplate,
    SynthesizerTemplate
  }

  @fixture Path.expand("../../fixtures/deepeval/synthesizer/templates.json", __DIR__)
  @external_resource @fixture

  @modules %{
    "SynthesizerTemplate" => SynthesizerTemplate,
    "FilterTemplate" => FilterTemplate,
    "EvolutionTemplate" => EvolutionTemplate,
    "PromptEvolutionTemplate" => PromptEvolutionTemplate,
    "PromptSynthesizerTemplate" => PromptSynthesizerTemplate,
    "ExtractionTemplate" => ExtractionTemplate
  }

  for {entry, index} <- @fixture |> File.read!() |> Jason.decode!() |> Enum.with_index() do
    @entry entry

    test "##{index} #{entry["template"]} renders deepeval's prompt" do
      [class, method] = String.split(@entry["template"], ".")
      opts = Enum.map(@entry["args"], fn {key, value} -> {String.to_atom(key), value} end)

      assert apply(Map.fetch!(@modules, class), String.to_atom(method), [opts]) ==
               @entry["prompt"]
    end
  end

  test "every template function is covered by the fixture" do
    covered =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> MapSet.new(& &1["template"])

    for {class, module} <- @modules, {name, 1} <- module.__info__(:functions) do
      assert "#{class}.#{name}" in covered
    end
  end
end
