defmodule DeepEvalEx.LLM.MultimodalTest do
  @moduledoc """
  Compares the message content DeepEvalEx builds for a prompt holding image
  placeholders with what deepeval 4.3.1's OpenAI, Anthropic and Ollama
  models build (`test/fixtures/deepeval/multimodal/content_parts.json`,
  written by `scripts/parity/generate_fixtures.py multimodal`).
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Multimodal
  alias DeepEvalEx.MLLMImage

  doctest Multimodal

  @moduletag :parity

  @fixture Path.expand("../../fixtures/deepeval/multimodal/content_parts.json", __DIR__)
  @external_resource @fixture

  @cases @fixture |> File.read!() |> Jason.decode!()

  for {name, _case} <- @cases do
    describe "#{name} case" do
      setup do
        %{"prompt" => prompt, "images" => images} = case = Map.fetch!(@cases, unquote(name))
        {:ok, images} = MLLMImage.cast_images(images)
        %{case: case, prompt: prompt, images: images}
      end

      test "builds deepeval's OpenAI content", %{case: case, prompt: prompt, images: images} do
        assert json(Multimodal.openai_content(prompt, images)) == case["openai"]
      end

      test "builds deepeval's Anthropic content", %{case: case, prompt: prompt, images: images} do
        assert json(Multimodal.anthropic_content(prompt, images)) == case["anthropic"]
      end

      if @cases[name]["ollama"] do
        test "builds deepeval's Ollama messages", %{case: case, prompt: prompt, images: images} do
          assert {:ok, messages} = Multimodal.ollama_messages(prompt, images)
          assert json(messages) == case["ollama"]
        end
      end
    end
  end

  describe "parts/2" do
    test "is nil for a prompt without placeholders" do
      assert Multimodal.parts("Plain text", nil) == nil
    end

    test "is the prompt's text and images" do
      image = MLLMImage.new!(data_base64: "AAAA", mime_type: "image/png", id: "dot")

      assert Multimodal.parts("A #{image}", %{"dot" => image}) == ["A ", image]
    end
  end

  test "sends a prompt without placeholders as it is" do
    assert Multimodal.openai_content("Plain text", nil) == "Plain text"
    assert Multimodal.anthropic_content("Plain text", %{}) == "Plain text"

    assert Multimodal.ollama_messages("Plain text", nil) ==
             {:ok, [%{role: "user", content: "Plain text"}]}
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()
end
