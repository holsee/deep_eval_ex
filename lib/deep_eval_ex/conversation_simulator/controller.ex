# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/simulator/controller/ (controller.py, types.py)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ConversationSimulator.Controller do
  @moduledoc """
  Stopping controllers: what decides, before each simulated user turn,
  whether a `DeepEvalEx.ConversationSimulator` conversation ends, deepeval
  4.3.1's `simulator/controller`.

  The default, `:expected_outcome`, is deepeval's
  `expected_outcome_controller`: when the golden has an expected outcome and
  the conversation has turns, the simulator's model is asked whether the
  outcome was reached (`DeepEvalEx.ConversationSimulator.SimulatorControllerTemplate`),
  and the conversation ends when it was.

  A custom controller is a function of one argument, or a
  `{module, function, args}` tuple called with the context then `args`. It
  gets a `DeepEvalEx.ConversationSimulator.Controller.Context` and returns
  `proceed/0` or `stop/1` (deepeval's `proceed()` and `end()`); anything
  else proceeds, as deepeval treats a non-`Decision` return.

      ConversationSimulator.new(
        model_callback: &MyApp.Chatbot.reply/1,
        stopping_controller: fn %Controller.Context{last_assistant_turn: turn} ->
          if turn && turn.content =~ "Goodbye",
            do: Controller.stop("The assistant said goodbye"),
            else: Controller.proceed()
        end
      )

  `max_user_simulations` caps every conversation whatever the controller
  decides.
  """

  alias DeepEvalEx.Dataset.ConversationalGolden
  alias DeepEvalEx.Turn

  defmodule Decision do
    @moduledoc """
    A stopping controller's decision, deepeval's `Decision`: whether the
    conversation ends, and why.
    """

    @type t :: %__MODULE__{should_end: boolean(), reason: String.t() | nil}

    @enforce_keys [:should_end]
    defstruct [:should_end, :reason]
  end

  defmodule Context do
    @moduledoc """
    What a stopping controller is given, deepeval's `Context`:

    - `:turns` - the conversation so far
    - `:golden` - the `DeepEvalEx.Dataset.ConversationalGolden` simulated
    - `:index` - the golden's position in the goldens simulated
    - `:thread_id` - the conversation's id, as the model callback gets it
    - `:simulated_user_turns` - the user turns simulated so far
    - `:max_user_simulations` - the cap on them
    - `:last_user_turn`, `:last_assistant_turn` - the last turn of each
      role, or `nil`
    """

    @type t :: %__MODULE__{
            turns: [Turn.t()],
            golden: ConversationalGolden.t(),
            index: non_neg_integer(),
            thread_id: String.t(),
            simulated_user_turns: non_neg_integer(),
            max_user_simulations: pos_integer(),
            last_user_turn: Turn.t() | nil,
            last_assistant_turn: Turn.t() | nil
          }

    defstruct [
      :turns,
      :golden,
      :index,
      :thread_id,
      :simulated_user_turns,
      :max_user_simulations,
      :last_user_turn,
      :last_assistant_turn
    ]
  end

  @typedoc "A stopping controller: the default, a function or an MFA."
  @type t :: :expected_outcome | (Context.t() -> term()) | {module(), atom(), list()}

  @doc """
  Goes on with the conversation, deepeval's `proceed()`.

  ## Examples

      iex> DeepEvalEx.ConversationSimulator.Controller.proceed()
      %DeepEvalEx.ConversationSimulator.Controller.Decision{should_end: false, reason: nil}
  """
  @spec proceed() :: Decision.t()
  def proceed, do: %Decision{should_end: false}

  @doc """
  Ends the conversation, deepeval's `end(reason)`.

  ## Examples

      iex> DeepEvalEx.ConversationSimulator.Controller.stop("Resolved")
      %DeepEvalEx.ConversationSimulator.Controller.Decision{should_end: true, reason: "Resolved"}
  """
  @spec stop(String.t() | nil) :: Decision.t()
  def stop(reason \\ nil), do: %Decision{should_end: true, reason: reason}

  @doc false
  # Whether a controller is one new/1 accepts.
  @spec valid?(term()) :: boolean()
  def valid?(:expected_outcome), do: true
  def valid?(fun) when is_function(fun, 1), do: true

  def valid?({module, function, args}) when is_atom(module) and is_atom(function),
    do: is_list(args)

  def valid?(_controller), do: false

  @doc false
  # Runs a custom controller: whether its decision ends the conversation.
  @spec should_end?((Context.t() -> term()) | {module(), atom(), list()}, Context.t()) ::
          boolean()
  def should_end?(controller, %Context{} = context) do
    decision =
      case controller do
        fun when is_function(fun, 1) -> fun.(context)
        {module, function, args} -> apply(module, function, [context | args])
      end

    match?(%Decision{should_end: true}, decision)
  end

  @doc false
  # deepeval's _build_context.
  @spec context([Turn.t()], ConversationalGolden.t(), keyword()) :: Context.t()
  def context(turns, golden, opts) do
    %Context{
      turns: turns,
      golden: golden,
      index: Keyword.fetch!(opts, :index),
      thread_id: Keyword.fetch!(opts, :thread_id),
      simulated_user_turns: Keyword.fetch!(opts, :simulated_user_turns),
      max_user_simulations: Keyword.fetch!(opts, :max_user_simulations),
      last_user_turn: last_turn(turns, :user),
      last_assistant_turn: last_turn(turns, :assistant)
    }
  end

  @doc false
  @spec last_turn([Turn.t()], :user | :assistant) :: Turn.t() | nil
  def last_turn(turns, role), do: turns |> Enum.reverse() |> Enum.find(&(&1.role == role))
end
