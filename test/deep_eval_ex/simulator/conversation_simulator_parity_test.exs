defmodule DeepEvalEx.ConversationSimulator.ParityTest do
  @moduledoc """
  Replays the judge scripts and chatbot replies under
  test/fixtures/deepeval/simulator/scenarios through
  `DeepEvalEx.ConversationSimulator` and compares the prompts it sends, the
  calls it makes to the chatbot and the hooks, and the test cases it returns
  with what deepeval 4.3.1's `ConversationSimulator` did with the same
  scripts (written by scripts/parity/generate_simulator_fixtures.py).

  Scenarios with several goldens run with `max_concurrent: 1`, as deepeval's
  did, so both consume the scripts in the same order.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.ConversationSimulator
  alias DeepEvalEx.ConversationSimulator.{Controller, SimulationNode}
  alias DeepEvalEx.Dataset.ConversationalGolden
  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn

  @scenarios Path.expand("../../fixtures/deepeval/simulator/scenarios", __DIR__)

  for file <- @scenarios |> File.ls!() |> Enum.sort() do
    @path Path.join(@scenarios, file)
    @external_resource @path
    @scenario @path |> File.read!() |> Jason.decode!()

    test "#{Path.rootname(file)} simulates as deepeval" do
      scenario = @scenario
      Mock.script(scenario["script"], model: "scripted-judge")

      {:ok, log} =
        Agent.start_link(fn -> %{replies: scenario["replies"], calls: [], hooks: []} end)

      simulator = simulator(scenario["simulator"], log)
      # A golden with only a user_description warns, as deepeval's.
      goldens =
        with_io(:stderr, fn -> Enum.map(scenario["goldens"], &ConversationalGolden.new!/1) end)
        |> elem(0)

      opts = [
        max_user_simulations: scenario["max_user_simulations"],
        on_turn: fn turns, index -> log(log, {:on_turn, index, length(turns)}) end,
        on_simulation_complete: fn %ConversationalTestCase{}, index ->
          log(log, {:completed, index})
        end
      ]

      case scenario do
        %{"raised" => %{"type" => "ValueError", "message" => message}} ->
          assert_raise ArgumentError, message, fn ->
            ConversationSimulator.simulate(simulator, goldens, opts)
          end

        %{"test_cases" => test_cases} ->
          assert {:ok, %ConversationSimulator{} = simulator} =
                   ConversationSimulator.simulate(simulator, goldens, opts)

          assert Enum.map(simulator.simulated_conversations, &dump_test_case/1) == test_cases
          assert simulator.simulation_cost == nil

          %{calls: calls, hooks: hooks} = Agent.get(log, & &1)
          assert Enum.reverse(calls) == scenario["callback_calls"]

          assert for(
                   {:on_turn, index, turns} <- Enum.reverse(hooks),
                   do: %{"index" => index, "turns" => turns}
                 ) == scenario["on_turn"]

          assert for({:completed, index} <- Enum.reverse(hooks), do: index) ==
                   scenario["completed"]
      end

      assert Mock.scripted_prompts() ==
               Enum.map(scenario["prompts"], &%{step: &1["step"], prompt: &1["prompt"]})
    end
  end

  defp simulator(options, log) do
    options = options || %{}

    graph =
      case options["simulation_graph"] do
        nil -> []
        spec -> [simulation_graph: build_node(spec)]
      end

    controller =
      case options["stopping_controller"] do
        nil -> []
        spec -> [stopping_controller: controller(spec)]
      end

    ConversationSimulator.new(
      [
        model_callback: chatbot(log),
        adapter: :mock,
        language: Map.get(options, "language", "English"),
        max_concurrent: Map.get(options, "max_concurrent", 5)
      ] ++ graph ++ controller
    )
  end

  # The scripted chatbot: replies in order, recording each call's input and
  # how many turns it was given.
  defp chatbot(log) do
    fn input, turns, thread_id ->
      assert is_binary(thread_id) and thread_id != ""

      Agent.get_and_update(log, fn %{replies: [reply | rest], calls: calls} = state ->
        call = %{"input" => input, "turns" => length(turns)}

        {Turn.new!(role: :assistant, content: reply),
         %{state | replies: rest, calls: [call | calls]}}
      end)
    end
  end

  defp log(log, hook), do: Agent.update(log, &%{&1 | hooks: [hook | &1.hooks]})

  # generate_simulator_fixtures.py's build_node.
  defp build_node(spec) do
    opts =
      for {key, value} <- spec,
          key in ~w(terminal max_visits name),
          do: {String.to_atom(key), value}

    node =
      if spec["default"] do
        SimulationNode.default(opts)
      else
        text = spec["text"]
        SimulationNode.new(fn -> text end, opts)
      end

    Enum.reduce(spec["edges"] || [], node, fn edge, node ->
      SimulationNode.add_node(node, build_node(edge["node"]), edge["when"])
    end)
  end

  # generate_simulator_fixtures.py's build_controller.
  defp controller(%{"end_after" => end_after} = spec) do
    fn %Controller.Context{simulated_user_turns: turns, last_assistant_turn: last} ->
      assert last == nil or last.role == :assistant

      if turns >= end_after,
        do: Controller.stop(spec["reason"]),
        else: Controller.proceed()
    end
  end

  defp dump_test_case(%ConversationalTestCase{} = test_case) do
    %{
      "turns" =>
        test_case.turns
        |> Enum.map(&Turn.model_dump_for_prompt/1)
        |> JSON.encode!()
        |> Jason.decode!(),
      "scenario" => test_case.scenario,
      "expected_outcome" => test_case.expected_outcome,
      "user_description" => test_case.user_description,
      "context" => test_case.context,
      "name" => test_case.name,
      "comments" => test_case.comments,
      "additional_metadata" => test_case.metadata
    }
  end
end
