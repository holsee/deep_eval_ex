# Conversation Simulator

`DeepEvalEx.ConversationSimulator` turns conversational goldens into
conversations with your chatbot: an LLM plays the user described by each
golden's scenario and persona, your chatbot answers, and each conversation
becomes a `DeepEvalEx.ConversationalTestCase` ready for the conversational
metrics. It is deepeval 4.3.1's `ConversationSimulator`, with the same
prompts byte for byte.

## Simulating conversations

```elixir
alias DeepEvalEx.ConversationSimulator
alias DeepEvalEx.Dataset.ConversationalGolden

simulator =
  ConversationSimulator.new(
    model_callback: fn input, turns -> MyApp.Chatbot.reply(input, turns) end,
    adapter: :openai,
    model: "gpt-4.1"
  )

goldens = [
  ConversationalGolden.new!(
    scenario: "A customer wants a refund for a late order.",
    expected_outcome: "The refund is issued.",
    persona: [name: "Ann", characteristics: "A busy parent, short on patience."]
  )
]

{:ok, simulator} = ConversationSimulator.simulate(simulator, goldens, max_user_simulations: 6)

{:ok, result} =
  DeepEvalEx.evaluate(simulator.simulated_conversations, [
    DeepEvalEx.Metrics.ConversationCompleteness
  ])
```

Each conversation starts from the golden's `:turns`, if any, and then
repeats until `:max_user_simulations` user turns (default `10`) were
simulated:

1. the conversation ends if the golden's `:expected_outcome` was reached,
   as the simulator's model judges it (never asked before the first turn,
   nor for a golden without an expected outcome)
2. the simulated user speaks, in the simulator's `:language` (default
   `"English"`); when the golden's turns end with a user turn, that turn is
   answered first instead
3. your chatbot replies

The test case keeps the golden's scenario, expected outcome, expectations,
user description, context, name and comments; its `:metadata` is the
golden's additional metadata with the persona's characteristics under
`"Persona"`.

## The model callback

`:model_callback` is your chatbot. It gets the user's input, the turns so
far and a thread id (one UUID per conversation), as many of them as it
takes:

```elixir
model_callback: fn input -> MyApp.Chatbot.reply(input) end
model_callback: fn input, turns -> MyApp.Chatbot.reply(input, turns) end
model_callback: fn input, turns, thread_id -> MyApp.Chatbot.reply(input, turns, thread_id) end
model_callback: {MyApp.Chatbot, :reply, [:extra_arg]}  # reply(input, turns, thread_id, :extra_arg)
```

It returns the reply as a string or a `DeepEvalEx.Turn` (role
`:assistant`, with any retrieval context or tool calls your metrics need),
alone or as `{:ok, reply}`. `{:error, reason}` stops the simulation, which
returns that error.

## Stopping controllers

The default `:stopping_controller` ends a conversation once its expected
outcome is reached. A custom one gets a
`DeepEvalEx.ConversationSimulator.Controller.Context` before each user
turn and returns `Controller.proceed()` or `Controller.stop(reason)`
(deepeval's `proceed()` and `end()`):

```elixir
alias DeepEvalEx.ConversationSimulator.Controller

ConversationSimulator.new(
  model_callback: &MyApp.Chatbot.reply/1,
  stopping_controller: fn %Controller.Context{last_assistant_turn: turn} ->
    if turn && turn.content =~ "Goodbye",
      do: Controller.stop("The assistant said goodbye"),
      else: Controller.proceed()
  end
)
```

## Simulation graphs

By default the simulator's model writes every user turn. A simulation
graph scripts the user instead: each `DeepEvalEx.ConversationSimulator.SimulationNode`
produces a turn, and after your chatbot replies the model picks the
outgoing edge whose description matches the reply, or stays on the node:

```elixir
alias DeepEvalEx.ConversationSimulator.SimulationNode

order_number = SimulationNode.new(fn -> "It's order 1234." end, max_visits: 2)
goodbye = SimulationNode.new(fn -> "Thanks, bye!" end, terminal: true)

graph =
  SimulationNode.default()
  |> SimulationNode.add_node(order_number, "The assistant asked for an order number")
  |> SimulationNode.add_node(goodbye, "The assistant issued the refund")

ConversationSimulator.new(model_callback: &MyApp.Chatbot.reply/1, simulation_graph: graph)
```

An action takes no argument or a map of the conversation (`:turns`,
`:golden`, `:last_user_turn`, `:last_assistant_turn`, `:thread_id`,
`:language` and the `:simulator`) and returns the user's message. A
`:terminal` node ends the conversation after its turn is answered; a node
past its `:max_visits` ends it without speaking. Nodes are immutable, so
graphs are built from the leaves up and have no cycles.

`SimulationNode.default/1` is the node that asks the model; pass
`template: MyTemplate`, a module implementing
`DeepEvalEx.ConversationSimulator.SimulationTemplate`, to change its
prompts.

## Concurrency and cost

Goldens are simulated concurrently, `:max_concurrent` (default `5`) at a
time, and the test cases keep the goldens' order. `:simulation_cost` is
the simulation's cost with a native model (`nil` otherwise). Options
`simulate/3` does not know are passed to the LLM adapter.

## Testing with the Mock adapter

The scripted `DeepEvalEx.LLM.Adapters.Mock` answers each step in call
order: `"simulated_input"` for user turns, `"is_complete,reason"` for the
expected-outcome check and `"index,reason"` for graph routing. Simulate
one conversation at a time when several goldens share a script:

```elixir
DeepEvalEx.LLM.Adapters.Mock.script(%{
  "simulated_input" => [%{"simulated_input" => "my order is late"}],
  "is_complete,reason" => [%{"is_complete" => true, "reason" => "Refunded."}]
})

simulator =
  ConversationSimulator.new(
    model_callback: fn _input -> "Refunded!" end,
    adapter: :mock,
    max_concurrent: 1
  )

{:ok, simulator} = ConversationSimulator.simulate(simulator, goldens)
```

## Not ported

Voice simulation (connectors, speech models, interruptions), deepeval's
`async_mode=False` path, the multimodal model check, progress bars and the
deprecated `controller` argument.
