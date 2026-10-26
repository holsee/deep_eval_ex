defmodule DeepEvalEx.LLM.Adapters.MockTableTest do
  # Deletes and inspects the Mock's shared table of configured responses and
  # recorded prompts, so it cannot run alongside other tests using the Mock.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapters.Mock

  @table :deep_eval_ex_mock_responses

  setup do
    Mock.clear_responses()
    Mock.clear_recorded_prompts()
    :ok
  end

  describe "the table of configured responses and recorded prompts" do
    test "is owned by a process the application supervises" do
      owner = Process.whereis(Mock.Table)

      assert {Mock.Table, ^owner, :worker, _modules} =
               List.keyfind(Supervisor.which_children(DeepEvalEx.Supervisor), Mock.Table, 0)

      Mock.set_response("owned", "yes")
      assert :ets.info(@table, :owner) == owner
    end

    test "outlives the short-lived process that first used it" do
      # As if no process had used the Mock yet.
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

      fn ->
        Mock.set_response("capital of France", "Paris")
        assert {:ok, "Paris"} = Mock.generate("What is the capital of France?")
      end
      |> Task.async()
      |> Task.await()

      assert {:ok, "Paris"} = Mock.generate("Again, the capital of France?")

      assert Mock.get_recorded_prompts() == [
               "What is the capital of France?",
               "Again, the capital of France?"
             ]
    end

    test "is created once when processes race to first use it" do
      if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

      results =
        1..50
        |> Task.async_stream(fn i -> Mock.generate("Race #{i}") end, max_concurrency: 50)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _response}, &1))
      assert length(Mock.get_recorded_prompts()) == 50
    end
  end

  describe "get_recorded_prompts/0" do
    test "has every prompt of concurrent callers once, each caller's in call order" do
      Mock.set_response("never matched", "unused")

      1..200
      |> Task.async_stream(
        fn i ->
          Mock.generate("Prompt #{i} first")
          Mock.generate_with_schema("Prompt #{i} second", %{})
        end,
        max_concurrency: 200
      )
      |> Stream.run()

      prompts = Mock.get_recorded_prompts()

      assert length(prompts) == 400

      assert Enum.sort(prompts) ==
               Enum.sort(for i <- 1..200, o <- ["first", "second"], do: "Prompt #{i} #{o}")

      assert Mock.get_recorded_prompts() == prompts

      for i <- 1..200 do
        assert Enum.find_index(prompts, &(&1 == "Prompt #{i} first")) <
                 Enum.find_index(prompts, &(&1 == "Prompt #{i} second"))
      end
    end

    test "keeps every prompt in call order around clears, with responses configured" do
      Mock.set_response("one", "1")
      Mock.set_schema_response("two", %{"n" => 2})

      Mock.generate("one")
      Mock.generate("two")
      Mock.clear_recorded_prompts()

      Mock.generate("three")
      Mock.set_response("four", "4")
      Mock.generate_with_schema("four", %{})
      Mock.generate("five")

      assert Mock.get_recorded_prompts() == ["three", "four", "five"]
      assert {:ok, "1"} = Mock.generate("one")
      assert Mock.get_recorded_prompts() == ["three", "four", "five", "one"]
    end
  end
end
