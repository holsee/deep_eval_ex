defmodule DeepEvalEx.SystemOne.Adapters.Mock do
  @moduledoc """
  A System One model for tests: it answers from canned answers and logs what
  it was asked, without a network or an API key. A port of deepeval 4.3.1's
  test doubles `FakeSystemOneModel` and `ExplodingSystemOneModel`
  (`tests/test_metrics/system_one_fakes.py`).

  ## Handles

  `new/1` returns a `{Mock, opts}` handle, which any `:system_one_model`
  option accepts (see `DeepEvalEx.SystemOne.Model`). Each handle has its own
  call log, kept by an `Agent` linked to the process that called `new/1`, so
  metrics measured concurrently and async tests never see each other's
  calls. `calls/1` reads it.

      mock = DeepEvalEx.SystemOne.Adapters.Mock.new(
        answer_fn: DeepEvalEx.SystemOne.Adapters.Mock.noul_answers(0.9)
      )

      DeepEvalEx.SystemOne.decide(state, questions, system_one_model: mock)
      DeepEvalEx.SystemOne.Adapters.Mock.calls(mock)
      #=> [%DeepEvalEx.SystemOne.Adapters.Mock.Call{state: ..., questions: ..., ...}]

  The bare `:mock` alias (or `{:mock, opts}`) works too, for fixed answers,
  but has no log.

  ## Options

  - `:answers` - a `DeepEvalEx.SystemOne.Answers` returned on every call,
    or a list of them consumed one per call (default: empty answers). A
    call past the end of the list raises, as popping an empty list does
    in deepeval's fake
  - `:answer_fn` - a function of the questions (`[{key, question}]`)
    returning the answers; takes precedence over `:answers`. See
    `noul_answers/1` and `answer_everything/2`
  - `:raises` - an exception to fail every call with, deepeval's
    `ExplodingSystemOneModel`: usually a `DeepEvalEx.SystemOne.Error`, such
    as `%Error{reason: :connection, type: "ConnectionError", message: "Jev
    is down"}`. It is returned as `{:error, exception}`, or raised with
    `raise?: true`
  - `:cost` - what each call reports: `nil` (unpriced, deepeval's
    `cost=None`), a number (a cost without token counts), a
    `DeepEvalEx.LLM.Usage`, or `{value, input_tokens, output_tokens}`
    (deepeval's `EvaluationCost`). Default: `0.0`, as deepeval's fake
  - `:model` - the `model_name/1` (default: `"fake-jev"`, or
    `"exploding-jev"` with `:raises`)

  ## Fixtures

  `from_fixture/2` builds a handle from the `system_one` block of a System
  One fixture's `input.json` (`test/fixtures/deepeval/system_one`), and
  `dump_calls/1` writes the log as the fixture's `decide.json` records
  calls, so a run can be compared with deepeval's byte for byte.
  """

  use DeepEvalEx.SystemOne.Adapter

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Answers, Error, Question}
  alias Jason.OrderedObject

  defmodule Call do
    @moduledoc """
    One logged `decide/3` call of a `DeepEvalEx.SystemOne.Adapters.Mock`:
    the `state` and `questions` it was asked, then either the `answers` and
    `usage` it reported or the `error` it failed with. A call whose
    `:answer_fn` raised has neither.
    """

    alias DeepEvalEx.LLM.Usage
    alias DeepEvalEx.SystemOne.{Adapter, Answers, Question}

    @type t :: %__MODULE__{
            state: Adapter.state(),
            questions: Question.questions(),
            answers: Answers.t() | nil,
            usage: Usage.t() | nil,
            error: Exception.t() | nil
          }

    defstruct [:state, :answers, :usage, :error, questions: []]
  end

  @typedoc "A mock System One model, as `new/1` returns it."
  @type handle :: {module(), keyword()}

  @typedoc "Answers the questions of one call."
  @type answer_fn :: (Question.questions() -> Answers.t())

  @fixture_errors %{"ConnectionError" => :connection, "TimeoutError" => :timeout}

  @doc """
  A mock with its own call log, for the `:system_one_model` option. See the
  module docs for the options.

  ## Examples

      iex> {DeepEvalEx.SystemOne.Adapters.Mock, opts} = DeepEvalEx.SystemOne.Adapters.Mock.new(model: "jev-x")
      iex> DeepEvalEx.SystemOne.Model.resolve({DeepEvalEx.SystemOne.Adapters.Mock, opts}).name
      "jev-x"
  """
  @spec new(keyword()) :: handle()
  def new(opts \\ []) do
    {queue, opts} =
      case Keyword.get(opts, :answers) do
        answers when is_list(answers) -> {answers, Keyword.delete(opts, :answers)}
        _ -> {nil, opts}
      end

    {:ok, log} = Agent.start_link(fn -> %{calls: [], queue: queue} end)
    {__MODULE__, Keyword.put(opts, :log, log)}
  end

  @doc """
  A mock built from a System One fixture's `input.json["system_one"]`, as
  deepeval's fixture generator builds its fake.

  Each question is answered from `answers` by its type (`nouls`, `scores`,
  `choices`) and key; a question with no canned answer raises. A `cost` left
  out is `nil`. `raises: %{"type" => "ConnectionError" | "TimeoutError",
  "message" => message}` raises that error on every call, as a
  `DeepEvalEx.SystemOne.Error` with reason `:connection` or `:timeout`.

  Decode the fixture with `Jason.decode!(json, objects: :ordered_objects)`
  so Choice probabilities keep their order.

  ## Options

  - `:prefix` - looked up before each question's key: `"m1."` answers
    metric 1 of a batched scenario, measured alone, from the batch's canned
    answers (default: `""`)
  """
  @spec from_fixture(map() | OrderedObject.t(), keyword()) :: handle()
  def from_fixture(spec, opts \\ []) do
    model = spec["model"]

    case spec["raises"] do
      nil ->
        canned = Answers.from_dump(spec["answers"] || %{})
        prefix = Keyword.get(opts, :prefix, "")

        new(
          model: model,
          cost: fixture_cost(spec["cost"]),
          answer_fn: &canned(canned, prefix, &1)
        )

      raises ->
        new(model: model, raises: fixture_error(raises), raise?: true)
    end
  end

  # `{value, input_tokens, output_tokens}`, deepeval's EvaluationCost; a
  # map or a Jason.OrderedObject.
  defp fixture_cost(cost) when is_number(cost) or is_nil(cost), do: cost
  defp fixture_cost(cost), do: {cost["value"], cost["input_tokens"], cost["output_tokens"]}

  defp fixture_error(raises) do
    type = raises["type"]
    message = raises["message"]

    case Map.fetch(@fixture_errors, type) do
      {:ok, reason} ->
        %Error{reason: reason, type: type, message: message}

      :error ->
        raise ArgumentError,
              "unsupported System One fixture error #{inspect(type)}; expected one of " <>
                inspect(Map.keys(@fixture_errors))
    end
  end

  defp canned(canned, prefix, questions) do
    Enum.reduce(questions, %Answers{}, fn {key, question}, acc ->
      kind = kind(question)
      answer = Map.fetch!(canned, kind)[prefix <> key]

      if answer == nil do
        raise "no canned #{kind} answer for #{inspect(prefix <> key)}"
      end

      Map.update!(acc, kind, &Map.put(&1, key, answer))
    end)
  end

  defp kind(%Question.Noul{}), do: :nouls
  defp kind(%Question.Choice{}), do: :choices
  defp kind(%Question.Score{}), do: :scores

  @doc """
  The calls a mock from `new/1` received, in order.
  """
  @spec calls(handle()) :: [Call.t()]
  def calls({__MODULE__, opts}) do
    opts |> log!() |> Agent.get(&Enum.reverse(&1.calls))
  end

  @doc """
  The calls as a System One fixture's `decide.json` records them, ready
  for `DeepEvalEx.TestRun.JSON.encode!/2`: the `state`, the `questions` in
  the SDK's shape (`DeepEvalEx.SystemOne.Question.to_wire_map/1`), then
  the `answers` (`DeepEvalEx.SystemOne.Answers.to_dump/2`) and the `cost`
  (`null`, a number, or `{value, input_tokens, output_tokens}` when the
  usage has token counts), or the `error`'s `type` and `message`.
  """
  @spec dump_calls(handle()) :: [OrderedObject.t()]
  def dump_calls(handle), do: handle |> calls() |> Enum.map(&dump_call/1)

  defp dump_call(%Call{} = call) do
    OrderedObject.new(
      [{"state", call.state}, {"questions", Question.to_wire_map(call.questions)}] ++
        dump_outcome(call)
    )
  end

  defp dump_outcome(%Call{error: nil, answers: nil}), do: []

  defp dump_outcome(%Call{error: nil} = call),
    do: [
      {"answers", Answers.to_dump(call.answers, call.questions)},
      {"cost", dump_cost(call.usage)}
    ]

  defp dump_outcome(%Call{error: error}),
    do: [
      {"error",
       OrderedObject.new([
         {"type", Error.type_name(error)},
         {"message", Exception.message(error)}
       ])}
    ]

  defp dump_cost(nil), do: nil
  defp dump_cost(%Usage{input_tokens: nil, output_tokens: nil, cost: cost}), do: cost

  defp dump_cost(%Usage{} = usage) do
    OrderedObject.new([
      {"value", usage.cost},
      {"input_tokens", usage.input_tokens},
      {"output_tokens", usage.output_tokens}
    ])
  end

  @doc """
  An `:answer_fn` answering every question as a Noul with `probability`,
  deepeval's `noul_answers`.
  """
  @spec noul_answers(number()) :: answer_fn()
  def noul_answers(probability) do
    fn questions ->
      %Answers{
        nouls:
          Map.new(questions, fn {key, _} -> {key, %Answers.Noul{probability: probability}} end)
      }
    end
  end

  @doc """
  An `:answer_fn` answering any mix of questions, deepeval's
  `answer_everything`: every Noul with `probability`, every Score at its top
  level (all its probability there) and every Choice with its first option
  (probability `1.0`), both with `confidence`.
  """
  @spec answer_everything(number(), number()) :: answer_fn()
  def answer_everything(probability \\ 0.9, confidence \\ 0.8) do
    fn questions ->
      Enum.reduce(questions, %Answers{}, &everything(&1, &2, probability, confidence))
    end
  end

  defp everything({key, %Question.Noul{}}, acc, probability, _confidence),
    do: put_in(acc.nouls[key], %Answers.Noul{probability: probability})

  defp everything({key, %Question.Score{levels: levels}}, acc, _probability, confidence) do
    top = length(levels) - 1

    put_in(acc.scores[key], %Answers.Score{
      score: top,
      probabilities: for(i <- 0..top//1, do: {i, if(i == top, do: 1.0, else: 0.0)}),
      confidence: confidence
    })
  end

  defp everything(
         {key, %Question.Choice{options: [{first, _} | _]}},
         acc,
         _probability,
         confidence
       ),
       do:
         put_in(acc.choices[key], %Answers.Choice{
           choice: first,
           probabilities: [{first, 1.0}],
           confidence: confidence
         })

  @impl true
  def model_name(opts) do
    Keyword.get_lazy(opts, :model, fn ->
      if Keyword.has_key?(opts, :raises), do: "exploding-jev", else: "fake-jev"
    end)
  end

  @impl true
  def decide(state, questions, opts) do
    log = Keyword.get(opts, :log)
    index = log_call(log, %Call{state: state, questions: questions})

    case Keyword.fetch(opts, :raises) do
      {:ok, exception} ->
        update_call(log, index, &%{&1 | error: exception})
        if Keyword.get(opts, :raise?, false), do: raise(exception), else: {:error, exception}

      :error ->
        answers = next_answers(log, questions, opts)
        usage = usage(Keyword.get(opts, :cost, 0.0))
        update_call(log, index, &%{&1 | answers: answers, usage: usage})
        {:ok, answers, usage}
    end
  end

  defp next_answers(log, questions, opts) do
    case Keyword.fetch(opts, :answer_fn) do
      {:ok, answer_fn} -> answer_fn.(questions)
      :error -> canned_answers(log, Keyword.get(opts, :answers))
    end
  end

  defp canned_answers(_log, answers) when is_list(answers),
    do: raise(ArgumentError, "a list of :answers needs a mock from Mock.new/1")

  defp canned_answers(nil, answers), do: answers || %Answers{}

  defp canned_answers(log, answers) do
    Agent.get_and_update(log, fn
      %{queue: nil} = log -> {{:ok, answers || %Answers{}}, log}
      %{queue: []} = log -> {:empty, log}
      %{queue: [next | rest]} = log -> {{:ok, next}, %{log | queue: rest}}
    end)
    |> case do
      {:ok, answers} -> answers
      :empty -> raise "Mock has no canned answers left"
    end
  end

  defp usage(nil), do: nil
  defp usage(%Usage{} = usage), do: usage
  defp usage(cost) when is_number(cost), do: %Usage{cost: cost * 1.0}

  defp usage({cost, input_tokens, output_tokens}),
    do: %Usage{cost: cost && cost * 1.0, input_tokens: input_tokens, output_tokens: output_tokens}

  defp log_call(nil, _call), do: nil

  defp log_call(log, call) do
    Agent.get_and_update(log, fn log ->
      {length(log.calls), %{log | calls: [call | log.calls]}}
    end)
  end

  defp update_call(nil, _index, _fun), do: :ok

  defp update_call(log, index, fun) do
    Agent.update(log, fn log ->
      # The log is newest first: call `index` sits `count - 1 - index` from the head.
      position = length(log.calls) - 1 - index
      %{log | calls: List.update_at(log.calls, position, fun)}
    end)
  end

  defp log!(opts) do
    case Keyword.fetch(opts, :log) do
      {:ok, log} -> log
      :error -> raise ArgumentError, "the mock has no call log: build it with Mock.new/1"
    end
  end
end
