defmodule DeepEvalEx.Metrics.Utils.GenerationTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.InvalidJSONError
  alias DeepEvalEx.Metrics.Utils.Generation

  doctest Generation

  @invalid "Evaluation LLM outputted an invalid JSON. Please use a better evaluation model."

  describe "trim_and_load_json/1" do
    # Each pair was run through deepeval 4.3.1's trimAndLoadJson. The last
    # has a no-break space (U+00A0) after its trailing comma, which Python's
    # \s matches.
    @loaded [
      {~s({"a": 1}), %{"a" => 1}},
      {~s(Sure! ```json\n{"a": [1, 2]}\n```), %{"a" => [1, 2]}},
      {~s({"a": [1, 2,], }), %{"a" => [1, 2]}},
      {~s({"a": "x, ]"}), %{"a" => "x, ]"}},
      {~s({"a": 1), %{"a" => 1}},
      {~s({"a": 1,}\n trailing), %{"a" => 1}},
      {~s({"a": "x, }", "b": [1,],}), %{"a" => "x}", "b" => [1]}},
      {~s({"reason": "café — ok", }), %{"reason" => "café — ok"}}
    ]

    for {input, expected} <- @loaded do
      test "loads #{inspect(input)} as deepeval does" do
        assert Generation.trim_and_load_json(unquote(input)) ==
                 {:ok, unquote(Macro.escape(expected))}
      end
    end

    # Each was rejected by deepeval 4.3.1's trimAndLoadJson with its
    # ValueError.
    @rejected [
      ~s({"a": {"b": 1}),
      "no json here",
      "} {",
      "abc}",
      "",
      ~s({"a": 1}{"b": 2}),
      ~s({"a": ",  }"),
      nil
    ]

    for input <- @rejected do
      test "rejects #{inspect(input)} with deepeval's error" do
        assert {:error, %InvalidJSONError{} = error} =
                 Generation.trim_and_load_json(unquote(input))

        assert Exception.message(error) == @invalid
      end
    end

    test "strips trailing commas only after a direct parse fails" do
      # Valid JSON whose string holds ", ]" must not be rewritten.
      assert Generation.trim_and_load_json(~s({"a": "1, ]", "b": "2 ,}"})) ==
               {:ok, %{"a" => "1, ]", "b" => "2 ,}"}}
    end
  end
end
