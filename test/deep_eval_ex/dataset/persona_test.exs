defmodule DeepEvalEx.Dataset.PersonaTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Dataset.Persona

  doctest DeepEvalEx.Dataset.Persona

  describe "new/1" do
    test "builds a persona from deepeval's field names, as atoms or strings" do
      assert {:ok, %Persona{name: "Ann", characteristics: "Grumpy", metadata: %{"age" => 61}}} =
               Persona.new(%{
                 "name" => "Ann",
                 "characteristics" => "Grumpy",
                 metadata: %{"age" => 61}
               })
    end

    test "drops the voice-only settings and unknown keys, as extra=\"ignore\"" do
      assert {:ok, persona} =
               Persona.new(
                 characteristics: "Calm",
                 voice: "alloy",
                 speaks_first: false,
                 interruption_behavior: %{frequency: "rare"},
                 hold_timeout: 5.0,
                 unknown: 1
               )

      assert persona == %Persona{characteristics: "Calm"}
    end

    test "requires characteristics" do
      assert {:error, _} = Persona.new(name: "Ann")
      assert {:error, _} = Persona.new(characteristics: 3)
    end

    test "new!/1 raises on error" do
      assert_raise RuntimeError, ~r/Invalid persona/, fn -> Persona.new!(name: "Ann") end
    end
  end

  describe "prompt_block/1" do
    test "renders the name, the trimmed characteristics and the metadata as deepeval" do
      persona =
        Persona.new!(
          name: "Ann",
          characteristics: "  Grumpy\n",
          metadata: %{"a" => [1, 2], "b" => "é", "c" => %{}}
        )

      # deepeval 4.3.1: json.dumps(metadata, indent=2, default=str), ASCII-escaped
      assert Persona.prompt_block(persona) == """
             <persona>
             Name: Ann

             Grumpy

             Details:
             {
               "a": [
                 1,
                 2
               ],
               "b": "\\u00e9",
               "c": {}
             }
             </persona>\
             """
    end

    test "leaves out an empty name, empty metadata and empty characteristics" do
      assert Persona.prompt_block(Persona.new!(name: "", characteristics: "x", metadata: %{})) ==
               "<persona>\nx\n</persona>"

      assert Persona.prompt_block(Persona.new!(name: "Bo", characteristics: "  ")) ==
               "<persona>\nName: Bo\n</persona>"
    end
  end
end
