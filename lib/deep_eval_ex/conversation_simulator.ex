# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/simulator/conversation_simulator.py,
# simulator/controller/controller.py and simulation_graph/runner.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ConversationSimulator do
  @moduledoc """
  Simulates conversations between a user played by an LLM and the chatbot
  under test, deepeval 4.3.1's `ConversationSimulator`: each
  `DeepEvalEx.Dataset.ConversationalGolden` becomes a
  `DeepEvalEx.ConversationalTestCase` ready for the conversational metrics.

      simulator =
        DeepEvalEx.ConversationSimulator.new(
          model_callback: fn input, turns -> MyApp.Chatbot.reply(input, turns) end,
          adapter: :openai,
          model: "gpt-4.1"
        )

      golden =
        DeepEvalEx.Dataset.ConversationalGolden.new!(
          scenario: "A customer wants a refund for a late order.",
          expected_outcome: "The refund is issued.",
          persona: [characteristics: "A busy parent, short on patience."]
        )

      {:ok, simulator} = DeepEvalEx.ConversationSimulator.simulate(simulator, [golden])

      simulator.simulated_conversations
      #=> [%DeepEvalEx.ConversationalTestCase{turns: [...], scenario: "...", ...}]

  `simulate/3` returns `{:ok, simulator}`, the simulator with the test
  cases as `:simulated_conversations` and their cost as `:simulation_cost`,
  as deepeval keeps them on the simulator, or `{:error, reason}` for the
  first judge call that failed or answered outside its schema, or the
  first `{:error, reason}` the model callback or a node action returned.

  ## A conversation

  A conversation starts from the golden's `:turns`, if any. Then, until
  `:max_user_simulations` user turns were simulated:

  1. the stopping controller decides whether the conversation ends (see
     `DeepEvalEx.ConversationSimulator.Controller`); by default it ends
     once the simulator's model judges the golden's `:expected_outcome`
     reached, which is never asked of an empty conversation or a golden
     without one
  2. the simulated user speaks: the current node of the simulation graph
     produces the turn (see `DeepEvalEx.ConversationSimulator.SimulationNode`);
     without a graph, the simulator's model writes it from the golden's
     scenario and persona and the conversation so far, in `:language`. When
     the last turn is already the user's (a golden's turns may end so), it
     is answered instead, and not counted
  3. the model callback replies as the chatbot under test
  4. the graph routes on the reply, and a terminal node ends the
     conversation

  The test case has the turns, the golden's scenario, expected outcome,
  expectations, user description, context, name and comments, and its
  additional metadata with the persona's characteristics under
  `"Persona"` (`nil` without a persona) as `:metadata`.

  ## The model callback

  The chatbot under test, called with the user's input, the turns so far
  (ending with that input's turn) and the conversation's thread id (a
  UUID), as deepeval passes the keyword arguments it declares:

  - a function of arity 1 (`input`), 2 (`input, turns`) or 3
    (`input, turns, thread_id`)
  - `{module, function, args}`, called with `input`, `turns`, `thread_id`
    then `args`

  It returns the reply as a `DeepEvalEx.Turn` (with role `:assistant`, as
  deepeval expects) or a string, alone or as `{:ok, reply}`, or
  `{:error, reason}`, which fails the simulation.

  ## Concurrency

  Goldens are simulated concurrently with `Task.async_stream/3`, up to
  `:max_concurrent` at a time (deepeval's semaphore), and the test cases
  keep the goldens' order. Each conversation runs in its own task: the
  model callback, node actions, controllers and hooks run there. The
  scripted `DeepEvalEx.LLM.Adapters.Mock` answers each step in call order,
  so tests replaying a script over several goldens set `max_concurrent: 1`.

  ## Model calls and cost

  The simulator's model is asked with
  `DeepEvalEx.LLM.Adapter.generate_with_schema/3`, for the schemas in
  `DeepEvalEx.ConversationSimulator.Schema`. `:simulation_cost` is the
  summed cost of the last simulation's native calls, `nil` when the
  simulator's model is not native (see `DeepEvalEx.LLM.Adapter.native?/1`)
  or a call was not priced. The calls' usage is also recorded in the
  caller's `DeepEvalEx.LLM.Usage` scope, if any.

  ## Not ported

  Voice simulation (`voice_config`, connectors, speech models, barge-in
  and the interrupt template), deepeval's `async_mode=False` path (which
  simulates the same conversations one at a time), the multimodal model
  check (DeepEvalEx's goldens carry no multimodal flag), progress bars, the
  deprecated `controller` argument and the private dataset attributes.
  """

  require Logger

  alias DeepEvalEx.ConversationalTestCase
  alias DeepEvalEx.ConversationSimulator.{Controller, Schema, SimulationGraphTemplate}
  alias DeepEvalEx.ConversationSimulator.{SimulationNode, SimulationTemplate}
  alias DeepEvalEx.ConversationSimulator.SimulatorControllerTemplate
  alias DeepEvalEx.Dataset.ConversationalGolden
  alias DeepEvalEx.LLM.{Adapter, Usage}
  alias DeepEvalEx.Turn

  @typedoc "The chatbot under test (see \"The model callback\")."
  @type model_callback ::
          (String.t() -> term())
          | (String.t(), [Turn.t()] -> term())
          | (String.t(), [Turn.t()], String.t() -> term())
          | {module(), atom(), list()}

  @type t :: %__MODULE__{
          model_callback: model_callback(),
          model: term(),
          adapter: term(),
          simulation_graph: SimulationNode.t(),
          stopping_controller: Controller.t(),
          max_concurrent: pos_integer(),
          language: String.t(),
          simulated_conversations: [ConversationalTestCase.t()],
          simulation_cost: float() | nil,
          llm_opts: keyword()
        }

  @enforce_keys [:model_callback, :simulation_graph]
  defstruct [
    :model_callback,
    :model,
    :adapter,
    :simulation_graph,
    stopping_controller: :expected_outcome,
    max_concurrent: 5,
    language: "English",
    simulated_conversations: [],
    simulation_cost: nil,
    llm_opts: []
  ]

  @new_options [
    :model_callback,
    :model,
    :adapter,
    :simulation_graph,
    :stopping_controller,
    :max_concurrent,
    :language
  ]

  @doc """
  Builds a simulator, deepeval's `ConversationSimulator(...)`.

  ## Options

  - `:model_callback` - the chatbot under test (required; see "The model
    callback")
  - `:model`, `:adapter` - the model playing the user, judging the
    expected outcome and routing the graph, as a metric's (default: the
    configured default model)
  - `:simulation_graph` - the root `DeepEvalEx.ConversationSimulator.SimulationNode`
    (default: `DeepEvalEx.ConversationSimulator.SimulationNode.default/1`)
  - `:stopping_controller` - `:expected_outcome` (the default), a function
    of a `DeepEvalEx.ConversationSimulator.Controller.Context` or an MFA
    (see `DeepEvalEx.ConversationSimulator.Controller`)
  - `:max_concurrent` - conversations simulated at once (default: `5`)
  - `:language` - the language the simulated user speaks (default:
    `"English"`)

  Raises `ArgumentError` for an unknown option, a missing or invalid
  callback, or an invalid setting.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @new_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown simulator options: #{inspect(unknown)}"
    end

    callback = Keyword.get(opts, :model_callback)

    unless valid_callback?(callback) do
      raise ArgumentError,
            "model_callback must be a function of arity 1 to 3 or a {module, function, args} " <>
              "tuple, got: #{inspect(callback)}"
    end

    max_concurrent = Keyword.get(opts, :max_concurrent, 5)

    unless is_integer(max_concurrent) and max_concurrent > 0 do
      raise ArgumentError,
            "max_concurrent must be a positive integer, got: #{inspect(max_concurrent)}"
    end

    graph = Keyword.get_lazy(opts, :simulation_graph, &SimulationNode.default/0)

    unless is_struct(graph, SimulationNode) do
      raise ArgumentError,
            "simulation_graph must be a SimulationNode (the root of the graph), " <>
              "got: #{inspect(graph)}"
    end

    controller = Keyword.get(opts, :stopping_controller, :expected_outcome)

    unless Controller.valid?(controller) do
      raise ArgumentError,
            "stopping_controller must be :expected_outcome, a function of arity 1 or a " <>
              "{module, function, args} tuple, got: #{inspect(controller)}"
    end

    %__MODULE__{
      model_callback: callback,
      model: opts[:model],
      adapter: opts[:adapter],
      simulation_graph: graph,
      stopping_controller: controller,
      max_concurrent: max_concurrent,
      language: Keyword.get(opts, :language, "English")
    }
  end

  @doc """
  Simulates a conversation for each golden, deepeval's `simulate`. See
  "A conversation".

  ## Options

  - `:max_user_simulations` - the most user turns simulated per
    conversation (default: `10`); with goldens to simulate, raises
    `ArgumentError` unless it is positive, with deepeval's message
  - `:on_turn` - a function of the turns and the golden's index, called
    after each turn is added; an exception it raises is logged and
    ignored, as deepeval does
  - `:on_simulation_complete` - a function of the test case and the
    golden's index, called as each conversation completes

  Any other option is passed to the LLM adapter.

  An exception raised by the model callback, a node action, a controller
  or `:on_simulation_complete` is raised again in the caller.
  """
  @spec simulate(t(), [ConversationalGolden.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def simulate(%__MODULE__{} = simulator, goldens, opts \\ []) when is_list(goldens) do
    {hooks, llm_opts} =
      Keyword.split(opts, [:max_user_simulations, :on_turn, :on_simulation_complete])

    max_user_simulations = Keyword.get(hooks, :max_user_simulations, 10)

    if goldens != [] and not (is_integer(max_user_simulations) and max_user_simulations > 0) do
      raise ArgumentError, "max_user_simulations must be greater than 0"
    end

    simulator = %{simulator | llm_opts: llm_opts}
    hooks = Keyword.put(hooks, :max_user_simulations, max_user_simulations)

    {result, usages} = Usage.track(fn -> run_conversations(simulator, goldens, hooks) end)

    Usage.record_all(usages)

    with {:ok, test_cases} <- result do
      {:ok,
       %{
         simulator
         | simulated_conversations: Enum.reverse(test_cases),
           simulation_cost: cost(simulator, usages),
           llm_opts: []
       }}
    end
  end

  defp run_conversations(simulator, goldens, hooks) do
    goldens
    |> Enum.with_index()
    |> Task.async_stream(&conversation_task(simulator, &1, hooks),
      max_concurrency: simulator.max_concurrent,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, &collect/2)
  end

  # One conversation, run in its task: {result, usages}, an exception
  # handed back as {:raised, exception, stacktrace}.
  defp conversation_task(simulator, {golden, index}, hooks) do
    Usage.track(fn -> protect(fn -> conversation(simulator, golden, index, hooks) end) end)
  end

  # Keeps a conversation's test case and usage; the first error stops the
  # rest, and an exception raised in its task is raised again here.
  defp collect({:ok, {result, usages}}, {:ok, acc}) do
    Usage.record_all(usages)

    case result do
      {:ok, test_case} -> {:cont, {:ok, [test_case | acc]}}
      {:error, _} = error -> {:halt, error}
      {:raised, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  @doc """
  Asks the simulator's model for the simulated user's next message, the
  default node's action: deepeval's `generate_first_user_input` when
  `turns` is empty, else `generate_next_user_input`, with `template`'s
  prompt (a `DeepEvalEx.ConversationSimulator.SimulationTemplate`).

  A custom node action may call it with the simulator it is given, to
  delegate a turn to the model.
  """
  @spec generate_user_input(t(), ConversationalGolden.t(), [Turn.t()], module()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_user_input(
        %__MODULE__{} = simulator,
        golden,
        turns,
        template \\ SimulationTemplate
      ) do
    prompt =
      case turns do
        [] -> template.simulate_first_user_turn(golden, simulator.language)
        turns -> template.simulate_user_turn(golden, turns, simulator.language)
      end

    generate_schema(simulator, prompt, Schema.simulated_input(), &Schema.parse_simulated_input/1)
  end

  # ---------------------------------------------------------------------------
  # One conversation

  defp conversation(simulator, golden, index, hooks) do
    state = %{
      turns: golden.turns || [],
      simulated: 0,
      node: simulator.simulation_graph,
      visits: %{},
      index: index,
      thread_id: uuid4()
    }

    with {:ok, turns} <- loop(simulator, golden, state, hooks) do
      test_case = test_case(golden, turns)

      case Keyword.get(hooks, :on_simulation_complete) do
        nil -> :ok
        fun -> fun.(test_case, index)
      end

      {:ok, test_case}
    end
  end

  # deepeval's _a_simulate_single_conversation loop, text mode.
  defp loop(simulator, golden, state, hooks) do
    max = Keyword.fetch!(hooks, :max_user_simulations)

    with false <- state.simulated >= max,
         {:ok, false} <- stop?(simulator, golden, state, max),
         {:ok, state, input, last?} <- user_turn(simulator, golden, state, hooks),
         {:ok, reply} <- reply(simulator, input, state) do
      state = add_turn(state, reply, hooks)

      with {:ok, state} <- route(simulator, state, reply) do
        if last?, do: {:ok, state.turns}, else: loop(simulator, golden, state, hooks)
      end
    else
      done when done in [true, {:ok, true}, :no_turn] -> {:ok, state.turns}
      {:error, _} = error -> error
    end
  end

  defp stop?(simulator, golden, state, max) do
    case simulator.stopping_controller do
      :expected_outcome ->
        expected_outcome_reached(simulator, golden, state.turns)

      controller ->
        context =
          Controller.context(state.turns, golden,
            index: state.index,
            thread_id: state.thread_id,
            simulated_user_turns: state.simulated,
            max_user_simulations: max
          )

        {:ok, Controller.should_end?(controller, context)}
    end
  end

  # deepeval's check_expected_outcome.
  defp expected_outcome_reached(_simulator, %ConversationalGolden{expected_outcome: nil}, _turns),
    do: {:ok, false}

  defp expected_outcome_reached(_simulator, _golden, []), do: {:ok, false}

  defp expected_outcome_reached(simulator, golden, turns) do
    prompt =
      SimulatorControllerTemplate.check_expected_outcome(
        SimulationTemplate.serialize_turns_for_prompt(turns),
        golden.expected_outcome
      )

    generate_schema(
      simulator,
      prompt,
      Schema.conversation_completion(),
      &Schema.parse_conversation_completion/1
    )
  end

  # The user's turn: the last turn when it is the user's, else the current
  # node's, unless its visits ran out. {:ok, state, input, last?}.
  defp user_turn(simulator, golden, state, hooks) do
    case List.last(state.turns) do
      %Turn{role: :user, content: content} ->
        {:ok, state, content, false}

      _ ->
        node = state.node
        visits = Map.get(state.visits, node.id, 0)

        if node.max_visits && visits >= node.max_visits do
          :no_turn
        else
          with {:ok, turn} <- SimulationNode.run(node, action_context(simulator, golden, state)) do
            state = %{
              state
              | simulated: state.simulated + 1,
                visits: Map.put(state.visits, node.id, visits + 1)
            }

            {:ok, add_turn(state, turn, hooks), turn.content, node.terminal}
          end
        end
    end
  end

  defp action_context(simulator, golden, state) do
    %{
      simulator: simulator,
      turns: state.turns,
      golden: golden,
      last_assistant_turn: Controller.last_turn(state.turns, :assistant),
      last_user_turn: Controller.last_turn(state.turns, :user),
      thread_id: state.thread_id,
      language: simulator.language
    }
  end

  defp add_turn(state, turn, hooks) do
    state = %{state | turns: state.turns ++ [turn]}
    on_turn(Keyword.get(hooks, :on_turn), state.turns, state.index)
    state
  end

  # deepeval's _dispatch_on_turn: a failing hook is logged, not raised.
  defp on_turn(nil, _turns, _index), do: :ok

  defp on_turn(fun, turns, index) do
    fun.(turns, index)
  rescue
    exception ->
      Logger.error("on_turn hook failed\n" <> Exception.format(:error, exception, __STACKTRACE__))
  end

  # The model callback's reply, deepeval's generate_turn_from_callback.
  defp reply(simulator, input, state) do
    callback = simulator.model_callback
    turns = state.turns

    result =
      case callback do
        fun when is_function(fun, 1) ->
          fun.(input)

        fun when is_function(fun, 2) ->
          fun.(input, turns)

        fun when is_function(fun, 3) ->
          fun.(input, turns, state.thread_id)

        {module, function, args} ->
          apply(module, function, [input, turns, state.thread_id | args])
      end

    assistant_turn(result)
  end

  defp assistant_turn(%Turn{} = turn), do: {:ok, turn}
  defp assistant_turn(content) when is_binary(content), do: {:ok, assistant(content)}
  defp assistant_turn({:ok, %Turn{} = turn}), do: {:ok, turn}
  defp assistant_turn({:ok, content}) when is_binary(content), do: {:ok, assistant(content)}
  defp assistant_turn({:error, _reason} = error), do: error

  defp assistant_turn(other) do
    raise ArgumentError,
          "model_callback must return a Turn or a string, alone or as {:ok, reply}, or " <>
            "{:error, reason}, got: #{inspect(other)}"
  end

  defp assistant(content), do: %Turn{role: :assistant, content: content}

  # deepeval's _SimulationGraphRunner.advance: the current node's edge the
  # model picks for the reply, or the same node.
  defp route(_simulator, %{node: %SimulationNode{edges: []}} = state, _reply), do: {:ok, state}

  defp route(simulator, %{node: node} = state, %Turn{content: reply}) do
    prompt = SimulationGraphTemplate.classify_edge(reply, Enum.map(node.edges, &elem(&1, 1)))

    with {:ok, index} <-
           generate_schema(simulator, prompt, Schema.edge_choice(), &Schema.parse_edge_choice/1) do
      case index do
        index when is_integer(index) and index >= 1 and index <= length(node.edges) ->
          {:ok, %{state | node: node.edges |> Enum.at(index - 1) |> elem(0)}}

        _none ->
          {:ok, state}
      end
    end
  end

  defp test_case(golden, turns) do
    persona = golden.persona && golden.persona.characteristics

    attrs = [
      turns: turns,
      scenario: golden.scenario,
      expected_outcome: golden.expected_outcome,
      expectations: golden.expectations,
      user_description: golden.user_description,
      context: golden.context,
      name: golden.name,
      metadata: Map.put(golden.additional_metadata || %{}, "Persona", persona),
      comments: golden.comments
    ]

    case attrs
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> ConversationalTestCase.new() do
      {:ok, test_case} ->
        test_case

      {:error, errors} ->
        raise ArgumentError, "Invalid conversational test case: #{inspect(errors)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Model calls

  # deepeval's a_generate_schema. A custom model's calls add nothing to the
  # simulation cost, as in deepeval.
  defp generate_schema(simulator, prompt, schema, parse) do
    opts = model_opts(simulator)
    {result, usages} = Usage.track(fn -> Adapter.generate_with_schema(prompt, schema, opts) end)

    usages =
      if Adapter.native?(opts),
        do: usages,
        else: Enum.map(usages, &%{&1 | cost: 0.0})

    Usage.record_all(usages)

    with {:ok, answer} <- result, do: parse.(answer)
  end

  defp model_opts(simulator) do
    simulator.llm_opts
    |> Keyword.drop([:adapter, :model])
    |> put_present(:adapter, simulator.adapter)
    |> put_present(:model, simulator.model)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp cost(simulator, usages) do
    if Adapter.native?(model_opts(simulator)) do
      costs = Enum.map(usages, & &1.cost)
      if Enum.any?(costs, &is_nil/1), do: nil, else: Enum.sum([0.0 | costs])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp valid_callback?(fun) when is_function(fun, 1) or is_function(fun, 2), do: true
  defp valid_callback?(fun) when is_function(fun, 3), do: true

  defp valid_callback?({module, function, args}) when is_atom(module) and is_atom(function),
    do: is_list(args)

  defp valid_callback?(_callback), do: false

  # Runs fun in a task, handing an exception back to the caller to raise.
  defp protect(fun) do
    fun.()
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :rand.bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
