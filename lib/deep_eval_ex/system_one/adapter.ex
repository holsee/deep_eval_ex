defmodule DeepEvalEx.SystemOne.Adapter do
  @moduledoc """
  Behaviour for System One providers, models that answer typed questions
  about a JSON state with probabilities instead of text. The port of
  deepeval 4.3.1's `DeepEvalBaseSystemOneModel`.

  TypeSafe AI's Jev is one such provider; any other implements the same two
  callbacks. A provider only answers questions: eval modes, LLM fallback,
  confidence, batching and cost splitting are DeepEvalEx's job, and every
  call goes through `DeepEvalEx.SystemOne.decide/3`, which adds telemetry
  and normalises errors.

  ## Implementing a provider

      defmodule MyApp.LogprobJudge do
        use DeepEvalEx.SystemOne.Adapter

        alias DeepEvalEx.LLM.Usage
        alias DeepEvalEx.SystemOne.{Answers, Error, Question}

        @impl true
        def model_name(opts), do: "logprob-" <> Keyword.get(opts, :model, "v1")

        @impl true
        def decide(state, questions, opts) do
          case MyApp.Client.ask(state, Question.to_wire_map(questions), opts) do
            {:ok, body} ->
              {:ok, to_answers(questions, body), Usage.new(model_name(opts), body["input_tokens"], 0)}

            {:error, :timeout} ->
              {:error, %Error{reason: :timeout, type: "TimeoutError", message: "timed out"}}

            {:error, other} ->
              {:error, %Error{reason: :connection, type: "ConnectionError", message: inspect(other)}}
          end
        end
      end

  `use DeepEvalEx.SystemOne.Adapter` declares the behaviour and defines the
  optional callbacks' defaults, which a provider may override: `init/1`
  accepts the options unchanged and `context_budget/1` is Jev's
  `#{inspect({32_000, 64_000})}`.

  ## Answers and usage

  `decide/3` answers every question under its own type and key (see
  `DeepEvalEx.SystemOne.Answers`) and **returns** the call's usage rather
  than recording it, unlike `DeepEvalEx.LLM.Adapter`: a batched request's
  cost is split between its metrics before it is booked. `nil` usage means
  the call could not be priced (deepeval's `cost=None`), which leaves the
  metric's summed cost `nil`. A cost without token counts is
  `%Usage{cost: cost}`.

  ## Errors

  Provider and transport failures are `{:error, %DeepEvalEx.SystemOne.Error{}}`
  (or a raised one). `DeepEvalEx.DeepEvalError`,
  `DeepEvalEx.ContextWindowExceededError` and `Req.TransportError` are
  handled as System One errors too. Anything else is a bug and propagates.
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Answers, Error, Question}

  @typedoc """
  What the questions are about: any JSON-encodable term, usually a
  `Jason.OrderedObject` so its keys keep deepeval's order.
  """
  @type state ::
          Jason.OrderedObject.t() | map() | list() | String.t() | number() | boolean() | nil

  @typedoc "Ordered like a Python dict; the keys are opaque to the provider."
  @type questions :: Question.questions()

  @type opts :: keyword()

  @typedoc "Token limits of one request: `{state_tokens, request_tokens}`."
  @type budget :: {pos_integer(), pos_integer()} | :unbounded

  @jev_budget {32_000, 64_000}

  @doc """
  Answers every question about `state`.

  Returns `{:ok, answers, usage}`, or `{:error, error}` for a provider or
  transport failure. Raise only on bugs.
  """
  @callback decide(state(), questions(), opts()) ::
              {:ok, Answers.t(), Usage.t() | nil} | {:error, Error.t() | Exception.t()}

  @doc """
  The model's name, reported as the evaluation model of a metric decided by
  System One alone and in its "Decided by ..." reasons.
  """
  @callback model_name(opts()) :: String.t()

  @doc """
  Checks the options before any measure (an API key is set, a dependency is
  loaded), deepeval's model construction. Returns the options to use.
  """
  @callback init(opts()) :: {:ok, opts()} | {:error, Error.t()}

  @doc """
  The token limits a request to this model must fit in, checked before a
  whole-metric or batched request is sent. Defaults to Jev's
  `#{inspect(@jev_budget)}`.
  """
  @callback context_budget(opts()) :: budget()

  @optional_callbacks init: 1, context_budget: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour DeepEvalEx.SystemOne.Adapter

      @impl true
      def init(opts), do: {:ok, opts}

      @impl true
      def context_budget(_opts), do: unquote(Macro.escape(@jev_budget))

      defoverridable init: 1, context_budget: 1
    end
  end

  @doc """
  Jev's token limits, `{state_tokens, request_tokens}`: the state plus the
  longest question must fit in 32,000 tokens, and the whole request in
  64,000. The default `c:context_budget/1`.
  """
  @spec jev_budget() :: {pos_integer(), pos_integer()}
  def jev_budget, do: @jev_budget
end
