# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/simulator/simulation_graph/ (node.py, default.py)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ConversationSimulator.SimulationNode do
  @moduledoc """
  A node of a simulation graph, deepeval 4.3.1's `SimulationNode`: one
  state of the simulated user.

  Each time the simulated user speaks, the current node's `:action`
  produces the turn. After the assistant replies, a node with outgoing
  edges asks the simulator's model which edge's description (`when`)
  matches the reply
  (`DeepEvalEx.ConversationSimulator.SimulationGraphTemplate`) and moves
  to that edge's node; with no match, or no edges, the conversation stays
  on the node.

      refund = SimulationNode.new(fn -> "Yes, please refund me." end)
      goodbye = SimulationNode.new(fn -> "Thanks, bye!" end, terminal: true)

      graph =
        SimulationNode.default()
        |> SimulationNode.add_node(refund, "The assistant offered a refund")
        |> SimulationNode.add_node(goodbye, "The assistant refunded the order")

      ConversationSimulator.new(model_callback: &MyApp.Chatbot.reply/1, simulation_graph: graph)

  Without a graph, the simulator runs `default/1`, whose action asks the
  simulator's model for the user's next message, as deepeval does.

  ## Actions

  An action is a function of no argument, or of one: a map with the
  `:simulator` (the `DeepEvalEx.ConversationSimulator`), the `:turns` so
  far, the `:golden`, the `:last_user_turn` and `:last_assistant_turn`
  (or `nil`), the `:thread_id` and the `:language`, as deepeval passes the
  keyword arguments an action declares. It returns the user's message as a
  string or a `DeepEvalEx.Turn` with role `:user`, either alone or as
  `{:ok, message}`, or `{:error, reason}` to fail the simulation.

  ## Visits and ends

  A `:terminal` node ends the conversation once the assistant has replied
  to its turn. A node with `:max_visits` speaks at most that many times
  per conversation; entered once more, it ends the conversation without
  speaking. Visits are counted per node: a node keeps its identity when it
  is added to several parents, as deepeval counts by object.

  Unlike deepeval's, nodes are immutable: `add_node/3` returns the parent
  with the new edge, so a graph is built from its leaves up and has no
  cycles. A node with no matching edge stays where it is, which covers a
  node repeating itself.
  """

  alias DeepEvalEx.ConversationSimulator
  alias DeepEvalEx.ConversationSimulator.SimulationTemplate
  alias DeepEvalEx.Turn

  @typedoc "What an action returns."
  @type action_result ::
          String.t() | Turn.t() | {:ok, String.t() | Turn.t()} | {:error, term()}

  @type t :: %__MODULE__{
          id: reference(),
          action: (-> action_result()) | (map() -> action_result()),
          terminal: boolean(),
          max_visits: pos_integer() | nil,
          name: String.t(),
          edges: [{t(), String.t()}]
        }

  @enforce_keys [:id, :action]
  defstruct [:id, :action, :max_visits, terminal: false, name: "simulation_node", edges: []]

  @doc """
  Builds a node from its `action` (see "Actions"), deepeval's
  `SimulationNode(action, ...)`.

  ## Options

  - `:terminal` - end the conversation after this node's turn is answered
    (default: `false`)
  - `:max_visits` - how many times the node may speak per conversation, a
    positive integer (default: `nil`, no cap)
  - `:name` - a name for debugging and errors (default: the action's
    function name for a named function, else `"simulation_node"`)

  Raises `ArgumentError` with deepeval's message for an action that is not
  a function of arity 0 or 1, or a `:max_visits` that is not positive.
  """
  @spec new(function(), keyword()) :: t()
  def new(action, opts \\ []) do
    unless is_function(action, 0) or is_function(action, 1) do
      raise ArgumentError, "`action` must be a callable returning str or Turn."
    end

    max_visits = Keyword.get(opts, :max_visits)

    unless is_nil(max_visits) or (is_integer(max_visits) and max_visits > 0) do
      raise ArgumentError, "`max_visits` must be a positive integer."
    end

    %__MODULE__{
      id: make_ref(),
      action: action,
      terminal: Keyword.get(opts, :terminal, false) == true,
      max_visits: max_visits,
      name: Keyword.get_lazy(opts, :name, fn -> action_name(action) end)
    }
  end

  @doc """
  The default node, deepeval's `default_simulation_node`: its action asks
  the simulator's model for the opening user turn
  (`c:SimulationTemplate.simulate_first_user_turn/2`) when there are no
  turns yet, else for the next one
  (`c:SimulationTemplate.simulate_user_turn/3`).

  Takes `new/2`'s options, `:name` defaulting to `"default"`, and
  `:template`, a module implementing
  `DeepEvalEx.ConversationSimulator.SimulationTemplate` (default: that
  module). Raises `ArgumentError` with deepeval's message for a template
  missing either function.
  """
  @spec default(keyword()) :: t()
  def default(opts \\ []) do
    {template, opts} = Keyword.pop(opts, :template)
    template = validate_template(template || SimulationTemplate)

    action = fn %{simulator: simulator, turns: turns, golden: golden} ->
      ConversationSimulator.generate_user_input(simulator, golden, turns, template)
    end

    new(action, Keyword.put_new(opts, :name, "default"))
  end

  @doc """
  Adds an edge from `parent` to `child`, followed when the model judges
  the assistant's reply matches `when`, a description in plain language;
  deepeval's `parent.add_node(child, when=...)`.

  Returns `parent` with the edge added after its others. Raises
  `ArgumentError` with deepeval's message for a `child` that is not a node
  or a blank `when`.
  """
  @spec add_node(t(), t(), String.t()) :: t()
  def add_node(%__MODULE__{} = parent, child, when_) do
    unless is_struct(child, __MODULE__) do
      raise ArgumentError, "`child` must be a SimulationNode instance."
    end

    unless is_binary(when_) and String.trim(when_) != "" do
      raise ArgumentError, "`when=` must be a non-empty string description."
    end

    %{parent | edges: parent.edges ++ [{child, when_}]}
  end

  @doc false
  # Runs the node's action: its user turn, or {:error, reason}. deepeval's
  # _invoke_action and _normalize_user_turn.
  @spec run(t(), map()) :: {:ok, Turn.t()} | {:error, term()}
  def run(%__MODULE__{action: action} = node, context) do
    result = if is_function(action, 0), do: action.(), else: action.(context)

    case result do
      {:error, _reason} = error -> error
      {:ok, value} -> {:ok, user_turn(value, node)}
      value -> {:ok, user_turn(value, node)}
    end
  end

  defp user_turn(content, _node) when is_binary(content),
    do: %Turn{role: :user, content: content}

  defp user_turn(%Turn{role: :user} = turn, _node), do: turn

  defp user_turn(%Turn{role: role}, node) do
    raise ArgumentError,
          "SimulationNode #{inspect(node.name)} returned a Turn with " <>
            "role=#{inspect(Atom.to_string(role))}; must be 'user'."
  end

  defp user_turn(other, node) do
    raise ArgumentError,
          "SimulationNode #{inspect(node.name)} action must return a string or a user Turn " <>
            "(alone or as {:ok, value}) or {:error, reason}; got #{inspect(other)}."
  end

  # deepeval's validate_simulation_template, for a module.
  defp validate_template(template) do
    for {name, arity, signature} <- [
          {:simulate_first_user_turn, 2, "simulate_first_user_turn(golden, language)"},
          {:simulate_user_turn, 3, "simulate_user_turn(golden, turns, language)"}
        ],
        not (is_atom(template) and Code.ensure_loaded?(template) and
               function_exported?(template, name, arity)) do
      raise ArgumentError, "simulation_template must define `#{signature}`."
    end

    template
  end

  defp action_name(action) do
    case Function.info(action, :type) do
      {:type, :external} -> action |> Function.info(:name) |> elem(1) |> Atom.to_string()
      _ -> "simulation_node"
    end
  end
end
