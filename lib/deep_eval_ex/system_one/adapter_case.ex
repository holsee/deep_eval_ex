defmodule DeepEvalEx.SystemOne.AdapterCase do
  @moduledoc """
  An ExUnit case template that checks a System One provider keeps the
  `DeepEvalEx.SystemOne.Adapter` contract, so any provider, not only Jev,
  can stand in for deepeval's System One model.

      defmodule MyApp.LogprobJudgeTest do
        use DeepEvalEx.SystemOne.AdapterCase,
          async: true,
          model: {MyApp.LogprobJudge, api_key: "test"},
          failing_model: {MyApp.LogprobJudge, api_key: "test", base_url: "http://down.invalid"},
          init_failure: {MyApp.LogprobJudge, []}
      end

  `use` starts an `ExUnit.Case` (`:async` and the other `ExUnit.Case`
  options are passed on) and adds a "System One adapter contract" describe
  block checking that:

  - `model_name/1` is a non-empty string
  - `context_budget/1`, when defined, is `{state, request}` positive
    integers with `state <= request`, or `:unbounded`
  - `init/1` accepts the model's options
  - `decide/3` answers a Noul, a Noul with criteria, a Choice and a Score
    question: every key under its own type and nothing else, probabilities
    in `0..1`, a chosen option among the options, Score levels integers
    within range, a score within the levels, Choice and Score confidences
    in `[0, 1]`, and a `DeepEvalEx.LLM.Usage` or `nil` as usage, both
    called directly and through `DeepEvalEx.SystemOne.decide/3`
  - with `:failing_model`, a failing request is a well-formed System One
    error (see `assert_error/1`)
  - with `:init_failure`, `init/1` rejects those options with a well-formed
    `DeepEvalEx.SystemOne.Error`

  ## Options

  - `:model` - the model under test, any `DeepEvalEx.SystemOne.Model`
    spec. It is evaluated in each test, so `Mock.new(...)` gives every test
    its own handle. A `:system_one_model` in the test context (set up by
    the module's own `setup`, for instance after stubbing the transport
    with `Req.Test`) takes precedence
  - `:failing_model` - a spec whose `decide/3` fails
  - `:init_failure` - a spec whose `init/1` fails
  - `:state` and `:questions` - what `decide/3` is asked (default: a
    small test-case state and the four questions above)

  The checks are public too (`assert_answers/2`, `assert_reply/2`,
  `assert_error/1`, `assert_budget/1`), for a provider's own tests.
  """

  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne.{Adapter, Answers, Error, Model, Question}
  alias Jason.OrderedObject

  @reasons [
    :context_limit,
    :timeout,
    :connection,
    :rate_limited,
    :auth,
    :http,
    :invalid_response,
    :missing_dependency
  ]

  @case_opts [:model, :failing_model, :init_failure, :state, :questions]

  defmacro __using__(opts) do
    {ours, case_opts} = Keyword.split(opts, @case_opts)
    model = Keyword.get(ours, :model)
    state = Keyword.get(ours, :state, quote(do: unquote(__MODULE__).state()))

    questions =
      Keyword.get(ours, :questions, quote(do: unquote(__MODULE__).questions()))

    quote do
      use ExUnit.Case, unquote(case_opts)

      describe "System One adapter contract" do
        test "model_name/1 is a non-empty string", context do
          model = unquote(__MODULE__).__model__(context, fn -> unquote(model) end)
          unquote(__MODULE__).__check_model__(model)
        end

        test "decide/3 answers every question under its own type", context do
          model = unquote(__MODULE__).__model__(context, fn -> unquote(model) end)

          unquote(__MODULE__).__check_decide__(
            model,
            unquote(state),
            unquote(questions)
          )
        end

        unquote(
          if failing = ours[:failing_model] do
            quote do
              test "a failing decide/3 is a well-formed System One error" do
                unquote(__MODULE__).__check_failure__(
                  unquote(failing),
                  unquote(state),
                  unquote(questions)
                )
              end
            end
          end
        )

        unquote(
          if init_failure = ours[:init_failure] do
            quote do
              test "a failing init/1 is a well-formed System One error" do
                unquote(__MODULE__).__check_init_failure__(unquote(init_failure))
              end
            end
          end
        )
      end
    end
  end

  @doc false
  def __model__(%{system_one_model: model}, _default) when model != nil, do: model

  def __model__(_context, default) do
    case default.() do
      nil ->
        fail!(
          "no System One model: pass :model to use AdapterCase, or set :system_one_model in setup"
        )

      model ->
        model
    end
  end

  @doc false
  def __check_model__(spec) do
    %Model{adapter: adapter, opts: opts} = model = spec |> Model.resolve() |> init!()
    name = adapter.model_name(opts)
    check(is_binary(name) and name != "", "model_name/1 returned #{inspect(name)}")
    assert_budget(Model.context_budget(model))
  end

  @doc false
  def __check_decide__(spec, state, questions) do
    %Model{adapter: adapter, opts: opts} = model = spec |> Model.resolve() |> init!()

    reply = adapter.decide(state, questions, opts)
    assert_reply(questions, reply)
    check(match?({:ok, _, _}, reply), "decide/3 failed: #{inspect(reply)}")

    case DeepEvalEx.SystemOne.decide(state, questions, system_one_model: model) do
      {:ok, answers, usage} ->
        assert_answers(questions, answers)

        check(
          usage == nil or usage.source == :system_one,
          "DeepEvalEx.SystemOne.decide/3 did not stamp the usage: #{inspect(usage)}"
        )

      result ->
        fail!("DeepEvalEx.SystemOne.decide/3 failed: #{inspect(result)}")
    end
  end

  @doc false
  def __check_failure__(spec, state, questions) do
    model = spec |> Model.resolve() |> init!()

    case DeepEvalEx.SystemOne.decide(state, questions, system_one_model: model) do
      {:error, error} -> assert_error(error)
      result -> fail!("expected the failing model to fail, got #{inspect(result)}")
    end
  end

  @doc false
  def __check_init_failure__(spec) do
    case Model.init(Model.resolve(spec)) do
      {:error, %Error{} = error} ->
        assert_error(error)

      result ->
        fail!("expected init/1 to fail with a DeepEvalEx.SystemOne.Error, got #{inspect(result)}")
    end
  end

  defp init!(model) do
    case Model.init(model) do
      {:ok, %Model{} = model} -> model
      result -> fail!("init/1 rejected the model's own options: #{inspect(result)}")
    end
  end

  @doc """
  The state the contract's `decide/3` is asked about: a test case's input,
  output and retrieval context, keys in order.
  """
  @spec state() :: Adapter.state()
  def state do
    OrderedObject.new([
      {"input", "What is the PTO policy?"},
      {"actual_output", "Employees get 20 days of PTO per year."},
      {"retrieval_context", ["Full-time employees receive 20 days of paid time off per year."]}
    ])
  end

  @doc """
  The questions the contract's `decide/3` answers: a Noul, a per-claim Noul
  with `true` / `false` criteria, a Choice and a four-level Score.
  """
  @spec questions() :: Question.questions()
  def questions do
    [
      {"q_0", %Question.Noul{instructions: "`actual_output` answers `input`."}},
      {"claim_0",
       %Question.Noul{
         instructions:
           OrderedObject.new([
             {"claim", "Employees get 20 days of PTO per year."},
             {"question", "Is `claim` supported by the facts in `retrieval_context`?"}
           ]),
         true: "The context states it.",
         false: "The context contradicts it or is silent."
       }},
      {"q_1",
       %Question.Choice{
         instructions: "The tone of `actual_output`.",
         options: [{"friendly", "Warm and polite"}, {"neutral", nil}, {"rude", "Hostile"}]
       }},
      {"q_2",
       %Question.Score{
         instructions: "How well is `actual_output` grounded in `retrieval_context`?",
         levels: ["Fabricated", "Mostly fabricated", "Mostly grounded", "Fully grounded"]
       }}
    ]
  end

  @doc """
  Asserts `answers` answer every one of `questions` under its own type and
  key, and nothing else, with well-formed values:

  - a Noul's probability is a number in `0..1`
  - a Choice's choice is one of its options, its probabilities are options
    with numbers in `0..1`, and its confidence is in `[0, 1]`
  - a Score's probabilities are integer level indices within its levels with
    numbers in `0..1`, its score a number between the lowest and the top
    level index, and its confidence in `[0, 1]`

  Raises `ExUnit.AssertionError` otherwise.
  """
  @spec assert_answers(Question.questions(), Answers.t()) :: :ok
  def assert_answers(questions, %Answers{} = answers) do
    for {key, question} <- questions do
      kind = kind(question)

      for other <- [:nouls, :choices, :scores] -- [kind] do
        check(
          not Map.has_key?(Map.fetch!(answers, other), key),
          "question #{inspect(key)} is a #{kind} question but was answered under #{other}"
        )
      end

      answer = Map.fetch!(answers, kind)[key]
      check(answer != nil, "question #{inspect(key)} was not answered under #{kind}")
      check_answer(key, question, answer)
    end

    asked = MapSet.new(questions, &elem(&1, 0))

    for kind <- [:nouls, :choices, :scores], {key, _} <- Map.fetch!(answers, kind) do
      check(
        MapSet.member?(asked, key),
        "#{inspect(key)} was answered under #{kind} but not asked"
      )
    end

    :ok
  end

  defp kind(%Question.Noul{}), do: :nouls
  defp kind(%Question.Choice{}), do: :choices
  defp kind(%Question.Score{}), do: :scores

  defp check_answer(key, %Question.Noul{}, %Answers.Noul{probability: p}),
    do: check(probability?(p), "#{inspect(key)}: probability #{inspect(p)} is not in 0..1")

  defp check_answer(key, %Question.Choice{options: options}, %Answers.Choice{} = answer) do
    names = Enum.map(options, &elem(&1, 0))

    check(
      answer.choice in names,
      "#{inspect(key)}: choice #{inspect(answer.choice)} is not one of #{inspect(names)}"
    )

    for {name, p} <- answer.probabilities do
      check(name in names, "#{inspect(key)}: probability for #{inspect(name)}, not an option")
      check(probability?(p), "#{inspect(key)}: probabilities #{inspect(p)} is not in 0..1")
    end

    check_confidence(key, answer.confidence)
  end

  defp check_answer(key, %Question.Score{levels: levels}, %Answers.Score{} = answer) do
    top = length(levels) - 1

    for {level, p} <- answer.probabilities do
      check(
        is_integer(level) and level >= 0 and level <= top,
        "#{inspect(key)}: level #{inspect(level)} is not an integer index in 0..#{top}"
      )

      check(probability?(p), "#{inspect(key)}: probabilities #{inspect(p)} is not in 0..1")
    end

    check(
      is_number(answer.score) and answer.score >= 0 and answer.score <= top,
      "#{inspect(key)}: score #{inspect(answer.score)} is not within 0..#{top}"
    )

    check_confidence(key, answer.confidence)
  end

  defp check_answer(key, question, answer),
    do: fail!("#{inspect(key)}: #{inspect(answer)} does not answer #{inspect(question)}")

  defp check_confidence(key, confidence) do
    check(
      probability?(confidence),
      "#{inspect(key)}: confidence #{inspect(confidence)} is not in [0, 1]"
    )
  end

  defp probability?(p), do: is_number(p) and p >= 0 and p <= 1

  @doc """
  Asserts `reply` is what `c:DeepEvalEx.SystemOne.Adapter.decide/3` may
  return: `{:ok, answers, usage}`, with answers passing `assert_answers/2`
  and usage `nil` or a `DeepEvalEx.LLM.Usage` with non-negative token counts
  and cost (each may be `nil`), or `{:error, exception}` passing
  `assert_error/1`. Raises `ExUnit.AssertionError` otherwise.
  """
  @spec assert_reply(Question.questions(), term()) :: :ok
  def assert_reply(questions, {:ok, %Answers{} = answers, usage}) do
    assert_answers(questions, answers)
    check_usage(usage)
  end

  def assert_reply(_questions, {:ok, answers, _usage}),
    do: fail!("decide/3 answered #{inspect(answers)}, not a DeepEvalEx.SystemOne.Answers")

  def assert_reply(_questions, {:error, error}), do: assert_error(error)

  def assert_reply(_questions, reply) do
    fail!(
      "decide/3 returned #{inspect(reply)}; expected {:ok, answers, usage} or {:error, exception}"
    )
  end

  defp check_usage(nil), do: :ok

  defp check_usage(%Usage{} = usage) do
    for {field, value} <- [input_tokens: usage.input_tokens, output_tokens: usage.output_tokens] do
      check(
        value == nil or (is_integer(value) and value >= 0),
        "usage #{field} #{inspect(value)} is not nil or a non-negative integer"
      )
    end

    check(
      usage.cost == nil or (is_number(usage.cost) and usage.cost >= 0),
      "usage cost #{inspect(usage.cost)} is not nil or a non-negative number"
    )
  end

  defp check_usage(usage),
    do: fail!("decide/3 usage #{inspect(usage)} is neither nil nor a DeepEvalEx.LLM.Usage")

  @doc """
  Asserts `error` is a well-formed System One error: an exception, and for
  a `DeepEvalEx.SystemOne.Error` a known `:reason`, a string `:type`, a
  string or `nil` `:message`, a boolean `:permanent?` and token counts that
  are `nil` or non-negative integers. Raises `ExUnit.AssertionError`
  otherwise.
  """
  @spec assert_error(term()) :: :ok
  def assert_error(%Error{} = error) do
    check(
      error.reason in @reasons,
      "error reason #{inspect(error.reason)} is not one of #{inspect(@reasons)}"
    )

    check(is_binary(error.type), "error type #{inspect(error.type)} is not a string")

    check(
      error.message == nil or is_binary(error.message),
      "error message #{inspect(error.message)} is not a string"
    )

    check(
      is_boolean(error.permanent?),
      "error permanent? #{inspect(error.permanent?)} is not a boolean"
    )

    for value <- [error.estimated_tokens, error.limit_tokens] do
      check(
        value == nil or (is_integer(value) and value >= 0),
        "error tokens #{inspect(value)} are not nil or a non-negative integer"
      )
    end

    :ok
  end

  def assert_error(error) do
    check(is_exception(error), "error #{inspect(error)} is not an exception")
    check(is_binary(Exception.message(error)), "error #{inspect(error)} has no string message")
  end

  @doc """
  Asserts `budget` is what `c:DeepEvalEx.SystemOne.Adapter.context_budget/1`
  may return: `{state, request}` positive integers with `state <= request`,
  or `:unbounded`. Raises `ExUnit.AssertionError` otherwise.
  """
  @spec assert_budget(term()) :: :ok
  def assert_budget(:unbounded), do: :ok

  def assert_budget({state, request})
      when is_integer(state) and is_integer(request) and state > 0 and state <= request,
      do: :ok

  def assert_budget(budget) do
    fail!(
      "context budget #{inspect(budget)} is not {state, request} positive integers " <>
        "with state <= request, or :unbounded"
    )
  end

  # ExUnit is not in the PLT: this library's runtime never loads it, only a
  # provider's test suite does. Without it fail!/1 never returns, so check/2
  # would look as if it only ever got `true`.
  @dialyzer {:nowarn_function, check: 2, fail!: 1}
  defp check(true, _message), do: :ok
  defp check(false, message), do: fail!(message)

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: raise(ExUnit.AssertionError, message: message)
end
