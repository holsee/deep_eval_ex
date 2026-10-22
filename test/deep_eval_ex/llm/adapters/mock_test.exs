defmodule DeepEvalEx.LLM.Adapters.MockTest do
  # Scripts belong to the process that loads them, so these tests can run
  # alongside others using the Mock adapter.
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.LLM.Usage

  doctest Mock

  @verdicts_schema %{
    "type" => "object",
    "properties" => %{"verdicts" => %{"type" => "array"}},
    "required" => ["verdicts"]
  }

  @reason_score_schema %{
    "type" => "object",
    "properties" => %{"score" => %{"type" => "number"}, "reason" => %{"type" => "string"}}
  }

  describe "step_key/1" do
    test "is the sorted, comma-separated property names of the schema" do
      assert Mock.step_key(@verdicts_schema) == "verdicts"
      assert Mock.step_key(@reason_score_schema) == "reason,score"
    end

    test "accepts atom-keyed schemas and schema modules" do
      assert Mock.step_key(%{properties: %{steps: %{}}}) == "steps"
      assert Mock.step_key(__MODULE__.Schema) == "claims"
    end

    test "is \"text\" for a call without a schema" do
      assert Mock.step_key(nil) == "text"
    end
  end

  describe "scripted mode" do
    test "replays responses by step and call index, whatever the prompt" do
      Mock.script(%{
        "verdicts" => [%{"verdicts" => [%{"verdict" => "yes"}]}, %{"verdicts" => []}],
        "reason,score" => [%{"reason" => "Fine.", "score" => 7}]
      })

      assert {:ok, %{"reason" => "Fine.", "score" => 7}} =
               Mock.generate_with_schema("Score it", @reason_score_schema)

      assert {:ok, %{"verdicts" => [%{"verdict" => "yes"}]}} =
               Mock.generate_with_schema("First", @verdicts_schema)

      assert {:ok, %{"verdicts" => []}} = Mock.generate_with_schema("Second", @verdicts_schema)
    end

    test "replays text responses for generate/2" do
      Mock.script(%{"text" => ["Hello."]})

      assert {:ok, "Hello."} = Mock.generate("Say hello")
    end

    test "returns an error once a step has no response left" do
      Mock.script(%{"verdicts" => [%{"verdicts" => []}]})

      assert {:ok, _} = Mock.generate_with_schema("First", @verdicts_schema)

      assert {:error, {:no_scripted_response, "verdicts", 1}} =
               Mock.generate_with_schema("Second", @verdicts_schema)

      assert {:error, {:no_scripted_response, "text", 0}} = Mock.generate("Anything")
    end

    test "records every prompt with its step, in call order" do
      Mock.script(%{
        "claims" => [%{"claims" => []}],
        "verdicts" => [%{"verdicts" => []}]
      })

      Mock.generate_with_schema("Extract claims", __MODULE__.Schema)
      Mock.generate_with_schema("Judge claims", @verdicts_schema)

      assert Mock.scripted_prompts() == [
               %{step: "claims", prompt: "Extract claims"},
               %{step: "verdicts", prompt: "Judge claims"}
             ]
    end

    test "serves processes started from the scripting process" do
      Mock.script(%{"text" => ["One.", "Two."]}, model: "scripted-judge")

      results =
        [1, 2]
        |> Task.async_stream(fn i -> Mock.generate("Prompt #{i}") end)
        |> Enum.map(fn {:ok, {:ok, text}} -> text end)

      assert Enum.sort(results) == ["One.", "Two."]
      assert Task.await(Task.async(fn -> Mock.model_name([]) end)) == "scripted-judge"
      assert length(Mock.scripted_prompts()) == 2
    end

    test "reports the script's judge model, recorded as the call's usage" do
      Mock.script(%{"text" => ["Hi."]}, model: "scripted-judge")

      assert Mock.model_name([]) == "scripted-judge"
      assert Adapter.model_name(adapter: :mock) == "scripted-judge"

      assert {{:ok, "Hi."}, [%Usage{model: "scripted-judge"}]} =
               Usage.track(fn -> Adapter.generate("Hi?", adapter: :mock) end)
    end

    test "loading a new script replaces the previous one and its prompts" do
      Mock.script(%{"text" => ["Old."]})
      Mock.generate("Old prompt")

      Mock.script(%{"text" => ["New."]})

      assert Mock.scripted_prompts() == []
      assert {:ok, "New."} = Mock.generate("New prompt")
    end

    test "is per process: other processes keep the unscripted behaviour" do
      Mock.script(%{"text" => ["Scripted."]}, model: "scripted-judge")

      parent = self()

      spawn(fn ->
        send(parent, {:unscripted, Mock.model_name([]), Mock.scripted_prompts()})
      end)

      assert_receive {:unscripted, "mock-model", []}
    end

    test "is dropped when the scripting process exits" do
      parent = self()

      owner =
        spawn(fn ->
          Mock.script(%{"text" => ["Scripted."]})
          send(parent, {:agent, :global.whereis_name({Mock, :script, self()})})
        end)

      assert_receive {:agent, agent}
      ref = Process.monitor(agent)
      assert_receive {:DOWN, ^ref, :process, ^agent, _reason}
      refute Process.alive?(owner)
    end

    test "stop_script/0 returns to the unscripted behaviour" do
      Mock.script(%{"text" => ["Scripted."]})
      assert :ok = Mock.stop_script()

      assert {:ok, "This is a mock response."} =
               Mock.generate("unscripted prompt #{inspect(self())}")

      assert Mock.scripted_prompts() == []
    end
  end

  defmodule Schema do
    @moduledoc false
    def json_schema, do: %{"type" => "object", "properties" => %{"claims" => %{}}}
  end
end
