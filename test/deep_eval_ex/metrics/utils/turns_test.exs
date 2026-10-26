defmodule DeepEvalEx.Metrics.Utils.TurnsTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.Utils.Turns
  alias DeepEvalEx.Params.{MultiTurn, SingleTurn}
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.{TestCase, Turn}
  alias Jason.OrderedObject

  doctest Turns

  # Builds turns from a string of roles ("u" for user, "a" for assistant),
  # each turn's content its role letter and index, e.g. "ua" -> u0, a1
  defp turns(roles) do
    roles
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {letter, index} ->
      role = if letter == "u", do: :user, else: :assistant
      Turn.new!(role: role, content: "#{letter}#{index}")
    end)
  end

  defp contents(groups), do: Enum.map(groups, fn group -> Enum.map(group, & &1.content) end)

  defp pairs(%OrderedObject{values: values}), do: values

  describe "format_turns/2" do
    test "keeps each truthy param in the order the params are given, as deepeval" do
      test_case =
        TestCase.new!(
          input: "i",
          actual_output: "",
          retrieval_context: [],
          context: ["c"],
          metadata: %{},
          tags: ["t"]
        )

      assert [all] = Turns.format_turns([test_case], SingleTurn.all())
      assert pairs(all) == [{"input", "i"}, {"context", ["c"]}, {"tags", ["t"]}]

      assert [reordered] = Turns.format_turns([test_case], [:tags, :input])
      assert pairs(reordered) == [{"tags", ["t"]}, {"input", "i"}]
    end

    test "returns one dict per test case" do
      cases = [TestCase.new!(input: "a"), TestCase.new!(input: "b", actual_output: "o")]

      assert cases |> Turns.format_turns([:input, :actual_output]) |> Enum.map(&pairs/1) ==
               [[{"input", "a"}], [{"input", "b"}, {"actual_output", "o"}]]
    end

    test "rejects a param that is not a single-turn param" do
      assert_raise ArgumentError, ~r/:scenario/, fn ->
        Turns.format_turns([TestCase.new!(input: "a")], [:scenario])
      end
    end
  end

  describe "convert_turn_to_dict/2" do
    setup do
      turn =
        Turn.new!(
          role: :assistant,
          content: "",
          provider_transcript: "pt",
          retrieval_context: [],
          metadata: %{"a" => 1}
        )

      %{turn: turn}
    end

    test "defaults to content then role, as deepeval", %{turn: turn} do
      assert pairs(Turns.convert_turn_to_dict(turn)) ==
               [{"content", ""}, {"role", "assistant"}]
    end

    test "skips the case-level params and keeps set turn fields, empty or not", %{turn: turn} do
      assert pairs(Turns.convert_turn_to_dict(turn, MultiTurn.all())) == [
               {"role", "assistant"},
               {"content", ""},
               {"provider_transcript", "pt"},
               {"retrieval_context", []}
             ]
    end

    test "follows the order of the params given", %{turn: turn} do
      params = [:role, :content, :retrieval_context, :provider_transcript]

      assert pairs(Turns.convert_turn_to_dict(turn, params)) == [
               {"role", "assistant"},
               {"content", ""},
               {"retrieval_context", []},
               {"provider_transcript", "pt"}
             ]
    end

    test "keeps tool calls and retrieved context as they are" do
      tool = %ToolCall{name: "search"}
      context = [%RetrievedContextData{context: "c", source: "s"}, "plain"]

      turn =
        Turn.new!(
          role: :assistant,
          content: "x",
          tools_called: [tool],
          retrieval_context: context
        )

      assert pairs(Turns.convert_turn_to_dict(turn, [:tools_called, :retrieval_context])) == [
               {"tools_called", [tool]},
               {"retrieval_context", context}
             ]
    end

    test "rejects a param that is not a multi-turn param", %{turn: turn} do
      assert_raise ArgumentError, ~r/:latency_ms/, fn ->
        Turns.convert_turn_to_dict(turn, [:latency_ms])
      end
    end
  end

  describe "get_turns_in_sliding_window/2" do
    setup do
      %{turns: turns("uuuu")}
    end

    test "gives each turn the window that ends at it", %{turns: turns} do
      assert contents(Turns.get_turns_in_sliding_window(turns, 2)) ==
               [["u0"], ["u0", "u1"], ["u1", "u2"], ["u2", "u3"]]

      assert contents(Turns.get_turns_in_sliding_window(turns, 1)) ==
               [["u0"], ["u1"], ["u2"], ["u3"]]
    end

    test "grows windows from the first turn while they are shorter than the size", %{
      turns: turns
    } do
      assert contents(Turns.get_turns_in_sliding_window(turns, 10)) ==
               [["u0"], ["u0", "u1"], ["u0", "u1", "u2"], ["u0", "u1", "u2", "u3"]]
    end

    test "gives empty windows for a size below one, as Python's slicing", %{turns: turns} do
      assert Turns.get_turns_in_sliding_window(turns, 0) == [[], [], [], []]
      assert Turns.get_turns_in_sliding_window(turns, -1) == [[], [], [], []]
    end

    test "gives no windows for no turns" do
      assert Turns.get_turns_in_sliding_window([], 3) == []
    end
  end

  describe "get_unit_interactions/1" do
    # Expected groupings observed from deepeval 4.3.1's get_unit_interactions
    for {roles, expected} <- [
          {"ua", [["u0", "a1"]]},
          {"uaua", [["u0", "a1"], ["u2", "a3"]]},
          {"auaua", [["a0", "u1", "a2"], ["u3", "a4"]]},
          {"uuaa", [["u0", "u1", "a2", "a3"]]},
          {"uaau", [["u0", "a1", "a2"]]},
          {"uau", [["u0", "a1"]]},
          {"uauaa", [["u0", "a1"], ["u2", "a3", "a4"]]},
          {"aua", [["a0", "u1", "a2"]]},
          {"aa", []},
          {"a", []},
          {"", []}
        ] do
      test "groups #{inspect(roles)} as deepeval" do
        assert contents(Turns.get_unit_interactions(turns(unquote(roles)))) ==
                 unquote(expected)
      end
    end
  end
end
