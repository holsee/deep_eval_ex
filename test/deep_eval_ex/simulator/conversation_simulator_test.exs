defmodule DeepEvalEx.ConversationSimulatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.ConversationSimulator
  alias DeepEvalEx.ConversationSimulator.{Controller, SimulationNode, SimulationTemplate}
  alias DeepEvalEx.Dataset.ConversationalGolden
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Turn

  doctest DeepEvalEx.ConversationSimulator.Controller
  doctest DeepEvalEx.ConversationSimulator.Schema
  doctest DeepEvalEx.ConversationSimulator.SimulationTemplate

  defmodule Chatbot do
    @moduledoc false
    def reply(input, turns, thread_id, prefix),
      do: "#{prefix} #{input} (#{length(turns)} turns, #{byte_size(thread_id)})"
  end

  defmodule ShoutingTemplate do
    @moduledoc false
    @behaviour DeepEvalEx.ConversationSimulator.SimulationTemplate

    @impl true
    def simulate_first_user_turn(golden, language), do: "FIRST #{golden.scenario} #{language}"

    @impl true
    def simulate_user_turn(golden, turns, language),
      do: "NEXT #{golden.scenario} #{length(turns)} #{language}"
  end

  defmodule IncompleteTemplate do
    @moduledoc false
    def simulate_first_user_turn(_golden, _language), do: "first"
  end

  defp golden(attrs \\ []),
    do: ConversationalGolden.new!(Keyword.merge([scenario: "Asking for help."], attrs))

  defp inputs(texts), do: Enum.map(texts, &%{"simulated_input" => &1})

  describe "new/1" do
    test "takes deepeval's defaults" do
      simulator = ConversationSimulator.new(model_callback: fn _input -> "ok" end)

      assert %ConversationSimulator{
               max_concurrent: 5,
               language: "English",
               stopping_controller: :expected_outcome,
               simulated_conversations: [],
               simulation_cost: nil
             } = simulator

      assert %SimulationNode{name: "default", edges: []} = simulator.simulation_graph
    end

    test "requires a model callback, a fun of arity 1 to 3 or an MFA" do
      assert_raise ArgumentError, ~r/model_callback/, fn -> ConversationSimulator.new([]) end

      assert_raise ArgumentError, ~r/model_callback/, fn ->
        ConversationSimulator.new(model_callback: fn -> "no input" end)
      end

      assert %ConversationSimulator{} =
               ConversationSimulator.new(model_callback: {Chatbot, :reply, ["Bot:"]})
    end

    test "rejects unknown options and invalid settings" do
      callback = fn _input -> "ok" end

      assert_raise ArgumentError, ~r/unknown simulator options: \[:voice_config\]/, fn ->
        ConversationSimulator.new(model_callback: callback, voice_config: %{})
      end

      assert_raise ArgumentError, ~r/max_concurrent/, fn ->
        ConversationSimulator.new(model_callback: callback, max_concurrent: 0)
      end

      assert_raise ArgumentError, ~r/simulation_graph/, fn ->
        ConversationSimulator.new(model_callback: callback, simulation_graph: :root)
      end

      assert_raise ArgumentError, ~r/stopping_controller/, fn ->
        ConversationSimulator.new(model_callback: callback, stopping_controller: :never)
      end
    end
  end

  describe "simulate/3" do
    test "passes the input, the turns and the thread id to an MFA callback" do
      Mock.script(%{"simulated_input" => inputs(["Hi", "More?"])})

      simulator =
        ConversationSimulator.new(model_callback: {Chatbot, :reply, ["Bot:"]}, adapter: :mock)

      assert {:ok, %{simulated_conversations: [test_case]}} =
               ConversationSimulator.simulate(simulator, [golden()], max_user_simulations: 2)

      assert [
               %Turn{role: :user, content: "Hi"},
               %Turn{role: :assistant, content: "Bot: Hi (1 turns, 36)"},
               %Turn{role: :user, content: "More?"},
               %Turn{role: :assistant, content: "Bot: More? (3 turns, 36)"}
             ] = test_case.turns
    end

    test "wraps a string reply in an assistant turn and passes the turns to a fun of arity 2" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      callback = fn input, turns -> {:ok, "#{input}/#{length(turns)}"} end
      simulator = ConversationSimulator.new(model_callback: callback, adapter: :mock)

      assert {:ok, %{simulated_conversations: [test_case]}} =
               ConversationSimulator.simulate(simulator, [golden()], max_user_simulations: 1)

      assert [%Turn{role: :user}, %Turn{role: :assistant, content: "Hi/1"}] = test_case.turns
    end

    test "keeps the golden's fields and records the persona in the metadata" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      simulator = ConversationSimulator.new(model_callback: fn _ -> "Hello" end, adapter: :mock)

      golden =
        golden(
          persona: [characteristics: "Curious."],
          additional_metadata: %{"team" => "support"},
          expectations: %{"must" => ["Greets the user"]}
        )

      assert {:ok, %{simulated_conversations: [%ConversationalTestCase{} = test_case]}} =
               ConversationSimulator.simulate(simulator, [golden], max_user_simulations: 1)

      assert test_case.scenario == "Asking for help."
      assert test_case.user_description == "Curious."
      assert test_case.metadata == %{"team" => "support", "Persona" => "Curious."}
      assert test_case.expectations == golden.expectations
    end

    test "returns the first failed judge call as an error" do
      Mock.script(%{"simulated_input" => [%{"wrong" => "shape"}]})
      simulator = ConversationSimulator.new(model_callback: fn _ -> "Hello" end, adapter: :mock)

      assert {:error, {:invalid_response, "SimulatedInput", %{"wrong" => "shape"}}} =
               ConversationSimulator.simulate(simulator, [golden()])
    end

    test "returns a callback's error" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      callback = fn _input -> {:error, :chatbot_down} end
      simulator = ConversationSimulator.new(model_callback: callback, adapter: :mock)

      assert {:error, :chatbot_down} = ConversationSimulator.simulate(simulator, [golden()])
    end

    test "raises for a callback returning something else" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      simulator = ConversationSimulator.new(model_callback: fn _ -> 42 end, adapter: :mock)

      assert_raise ArgumentError, ~r/model_callback must return/, fn ->
        ConversationSimulator.simulate(simulator, [golden()])
      end
    end

    test "logs and ignores an on_turn hook that raises, as deepeval" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      simulator = ConversationSimulator.new(model_callback: fn _ -> "Hello" end, adapter: :mock)

      log =
        capture_log(fn ->
          assert {:ok, %{simulated_conversations: [test_case]}} =
                   ConversationSimulator.simulate(simulator, [golden()],
                     max_user_simulations: 1,
                     on_turn: fn _turns, _index -> raise "boom" end
                   )

          assert length(test_case.turns) == 2
        end)

      assert log =~ "on_turn hook failed"
      assert log =~ "boom"
    end

    test "with no goldens, simulates nothing whatever max_user_simulations is" do
      simulator = ConversationSimulator.new(model_callback: fn _ -> "Hello" end, adapter: :mock)

      assert {:ok, %{simulated_conversations: []}} =
               ConversationSimulator.simulate(simulator, [], max_user_simulations: 0)
    end

    test "simulates goldens concurrently and keeps their order" do
      Mock.script(%{"simulated_input" => inputs(List.duplicate("Hi", 6))})
      parent = self()

      callback = fn _input, turns ->
        send(parent, {:replying, self()})
        "Reply #{length(turns)}"
      end

      simulator =
        ConversationSimulator.new(model_callback: callback, adapter: :mock, max_concurrent: 3)

      goldens = for n <- 1..3, do: golden(scenario: "Scenario #{n}")

      assert {:ok, %{simulated_conversations: test_cases}} =
               ConversationSimulator.simulate(simulator, goldens, max_user_simulations: 2)

      assert Enum.map(test_cases, & &1.scenario) == ["Scenario 1", "Scenario 2", "Scenario 3"]
      assert Enum.all?(test_cases, &(length(&1.turns) == 4))

      pids = for _ <- 1..6, do: receive(do: ({:replying, pid} -> pid))
      assert pids |> Enum.uniq() |> length() == 3
    end

    test "passes adapter options on to the judge and records its usage" do
      Mock.script(%{"simulated_input" => inputs(["Hi"])})
      simulator = ConversationSimulator.new(model_callback: fn _ -> "Hello" end, adapter: :mock)

      {result, usages} =
        Usage.track(fn ->
          ConversationSimulator.simulate(simulator, [golden()],
            max_user_simulations: 1,
            mock_usage: [input_tokens: 10, output_tokens: 2]
          )
        end)

      assert {:ok, %{simulation_cost: nil}} = result
      assert [%Usage{input_tokens: 10, output_tokens: 2}] = usages
    end
  end

  describe "stopping controllers" do
    test "an MFA controller is called with the context" do
      Mock.script(%{"simulated_input" => inputs(["Hi", "Again"])})

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          stopping_controller: {__MODULE__, :stop_after, [1]}
        )

      assert {:ok, %{simulated_conversations: [test_case]}} =
               ConversationSimulator.simulate(simulator, [golden()])

      assert length(test_case.turns) == 2
    end

    test "anything but a decision proceeds, as deepeval normalizes it" do
      Mock.script(%{"simulated_input" => inputs(["Hi", "Again"])})

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          stopping_controller: fn _context -> true end
        )

      assert {:ok, %{simulated_conversations: [test_case]}} =
               ConversationSimulator.simulate(simulator, [golden()], max_user_simulations: 2)

      assert length(test_case.turns) == 4
    end
  end

  def stop_after(%Controller.Context{simulated_user_turns: turns} = context, limit) do
    assert context.max_user_simulations == 10
    assert context.index == 0
    if turns >= limit, do: Controller.stop(), else: Controller.proceed()
  end

  describe "simulation graphs" do
    test "a node's action gets the conversation and may return a user turn" do
      parent = self()

      follow_up =
        SimulationNode.new(fn context ->
          send(parent, {:context, context})
          Turn.new!(role: :user, content: "Follow-up")
        end)

      root =
        SimulationNode.default()
        |> SimulationNode.add_node(follow_up, "The assistant greeted the user")

      Mock.script(%{
        "simulated_input" => inputs(["Hi"]),
        "index,reason" => [%{"index" => 1, "reason" => "Greeted."}]
      })

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          simulation_graph: root,
          language: "Dutch"
        )

      assert {:ok, %{simulated_conversations: [test_case]}} =
               ConversationSimulator.simulate(simulator, [golden()], max_user_simulations: 2)

      assert Enum.map(test_case.turns, & &1.content) == ["Hi", "Hello", "Follow-up", "Hello"]

      assert_received {:context, context}
      assert context.language == "Dutch"
      assert context.last_user_turn.content == "Hi"
      assert context.last_assistant_turn.content == "Hello"
      assert length(context.turns) == 2
      assert is_binary(context.thread_id)
      assert %ConversationSimulator{} = context.simulator
      assert %ConversationalGolden{} = context.golden
    end

    test "an action returning an assistant turn raises, as deepeval's TypeError" do
      node = SimulationNode.new(fn -> Turn.new!(role: :assistant, content: "No") end, name: "bad")

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          simulation_graph: node
        )

      assert_raise ArgumentError,
                   "SimulationNode \"bad\" returned a Turn with role=\"assistant\"; must be 'user'.",
                   fn -> ConversationSimulator.simulate(simulator, [golden()]) end
    end

    test "an action returning something else raises" do
      node = SimulationNode.new(fn -> 42 end, name: "bad")

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          simulation_graph: node
        )

      assert_raise ArgumentError, ~r/action must return a string or a user Turn/, fn ->
        ConversationSimulator.simulate(simulator, [golden()])
      end
    end

    test "a custom template renders the default node's prompts" do
      Mock.script(%{"simulated_input" => inputs(["Hi", "Again"])})

      simulator =
        ConversationSimulator.new(
          model_callback: fn _ -> "Hello" end,
          adapter: :mock,
          simulation_graph: SimulationNode.default(template: ShoutingTemplate)
        )

      assert {:ok, _} =
               ConversationSimulator.simulate(simulator, [golden()], max_user_simulations: 2)

      assert Enum.map(Mock.scripted_prompts(), & &1.prompt) == [
               "FIRST Asking for help. English",
               "NEXT Asking for help. 2 English"
             ]
    end

    test "a template must define both functions" do
      assert_raise ArgumentError,
                   "simulation_template must define `simulate_user_turn(golden, turns, language)`.",
                   fn -> SimulationNode.default(template: IncompleteTemplate) end
    end

    test "nodes validate their options and edges" do
      assert_raise ArgumentError, "`action` must be a callable returning str or Turn.", fn ->
        SimulationNode.new(:not_a_fun)
      end

      assert_raise ArgumentError, "`max_visits` must be a positive integer.", fn ->
        SimulationNode.new(fn -> "Hi" end, max_visits: 0)
      end

      node = SimulationNode.new(fn -> "Hi" end)

      assert_raise ArgumentError, "`when=` must be a non-empty string description.", fn ->
        SimulationNode.add_node(node, node, "  ")
      end

      assert_raise ArgumentError, "`child` must be a SimulationNode instance.", fn ->
        SimulationNode.add_node(node, :child, "Always")
      end
    end
  end

  test "the default template is a SimulationTemplate" do
    assert Enum.sort(SimulationTemplate.behaviour_info(:callbacks)) == [
             simulate_first_user_turn: 2,
             simulate_user_turn: 3
           ]
  end
end
