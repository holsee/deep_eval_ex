defmodule DeepEvalEx.SystemOne.Limits do
  @moduledoc """
  The context-budget pre-check for System One requests, a port of deepeval
  4.3.1's `deepeval/models/system_one/limits.py`.

  Jev has a bounded context window, and an overflow surfaces as an opaque
  4xx from the API. Estimating the request's size before sending it gives a
  clear "too large" error instead: `check/3` returns a
  `DeepEvalEx.SystemOne.Error` with `reason: :context_limit` (deepeval's
  `SystemOneContextLimitError`) when

  - the state plus the longest question exceeds the state budget, or
  - the state plus every question exceeds the request budget.

  The budget is `{state_tokens, request_tokens}`, by default Jev's
  `#{inspect(DeepEvalEx.SystemOne.Adapter.jev_budget())}`
  (`c:DeepEvalEx.SystemOne.Adapter.context_budget/1`).

  As in deepeval, the whole-metric runner, the batch and the TypeSafe
  adapter check the budget; the per-decision hybrid helpers do not.

  ## Estimating tokens

  A token is estimated as 3 characters, rounded up: JSON tokenizes denser
  than English prose (roughly 4), so the estimate errs high and the check
  stays conservative. Characters are counted as Python's `len/1` counts
  them, in Unicode code points, over the text deepeval measures:

  - a string as it is, without JSON-encoding it
  - anything else as `json.dumps(value, ensure_ascii=False)` writes it,
    with `", "` and `": "` separators and Python's float `repr`
    (`DeepEvalEx.TestRun.JSON`); a term JSON cannot encode is counted as
    its `inspect/1` text, deepeval's `str(value)` fallback
  """

  alias DeepEvalEx.SystemOne.{Adapter, Error, Question}
  alias DeepEvalEx.SystemOne.Question.{Choice, Noul, Score}
  alias DeepEvalEx.TestRun.JSON
  alias Jason.OrderedObject

  # Characters per token: see "Estimating tokens".
  @chars_per_token 3

  @typedoc """
  The questions of a request: `{key, question}` pairs, as a list, a map or
  a `Jason.OrderedObject` (`DeepEvalEx.SystemOne.Question.to_wire_map/1`).
  """
  @type questions :: Question.questions() | OrderedObject.t() | %{optional(term()) => term()}

  @doc """
  Upper-bound token estimate for `value`, deepeval's `estimate_tokens`:
  `ceil(len(text) / 3)` over the text described in "Estimating tokens", and
  `0` for `nil`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Limits.estimate_tokens("18°C at the café")
      6

      iex> DeepEvalEx.SystemOne.Limits.estimate_tokens(%{"claim" => "café"})
      6

      iex> DeepEvalEx.SystemOne.Limits.estimate_tokens(nil)
      0
  """
  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(text) when is_binary(text), do: text |> code_points(0) |> per_token()
  def estimate_tokens(value), do: value |> dump() |> estimate_tokens()

  @doc """
  Token estimate for one question: a `DeepEvalEx.SystemOne.Question` struct
  is estimated as deepeval estimates its pydantic model (`model_dump()`:
  a Noul's `instructions`, `true` and `false`, `null` included; a Choice's
  `instructions` and `options`; a Score's `instructions` and `levels`).
  Anything else, such as the SDK's wire shape from
  `DeepEvalEx.SystemOne.Question.to_wire/1`, is estimated as it is.

  ## Examples

      iex> DeepEvalEx.SystemOne.Limits.question_tokens(
      ...>   %DeepEvalEx.SystemOne.Question.Noul{instructions: "x"})
      17
  """
  @spec question_tokens(Question.t() | term()) :: non_neg_integer()
  def question_tokens(question), do: question |> model_dump() |> estimate_tokens()

  @doc """
  Checks that a request of `state` and `questions` is likely to fit in
  `budget`, deepeval's `check_context_budget`.

  Returns `:ok`, or `{:error, %DeepEvalEx.SystemOne.Error{reason:
  :context_limit}}` carrying the estimate (`:estimated_tokens`), the budget
  it exceeds (`:limit_tokens`) and deepeval's message. The state budget is
  checked first. An `:unbounded` budget always passes.

  ## Examples

      iex> questions = [{"q_0", %DeepEvalEx.SystemOne.Question.Noul{instructions: "x"}}]
      iex> DeepEvalEx.SystemOne.Limits.check("It rained.", questions)
      :ok
      iex> {:error, error} = DeepEvalEx.SystemOne.Limits.check("It rained.", questions, {20, 100})
      iex> error.message
      "System One state (4 est. tokens) plus the longest question (17) exceeds the 20-token state budget. Send less state or judge this test case with the LLM."
  """
  @spec check(term(), questions(), Adapter.budget()) :: :ok | {:error, Error.t()}
  def check(state, questions, budget \\ Adapter.jev_budget())

  def check(_state, _questions, :unbounded), do: :ok

  def check(state, questions, {max_state_tokens, max_request_tokens}) do
    state_tokens = estimate_tokens(state)
    question_tokens = Enum.map(questions, fn {_key, question} -> question_tokens(question) end)
    longest = Enum.max(question_tokens, fn -> 0 end)
    total = state_tokens + Enum.sum(question_tokens)

    cond do
      state_tokens + longest > max_state_tokens ->
        context_limit(
          "System One state (#{state_tokens} est. tokens) plus the longest " <>
            "question (#{longest}) exceeds the #{max_state_tokens}-token state " <>
            "budget. Send less state or judge this test case with the LLM.",
          state_tokens + longest,
          max_state_tokens
        )

      total > max_request_tokens ->
        context_limit(
          "System One request (#{total} est. tokens across " <>
            "#{length(question_tokens)} questions) exceeds the " <>
            "#{max_request_tokens}-token request budget. Ask fewer questions " <>
            "per request or judge this test case with the LLM.",
          total,
          max_request_tokens
        )

      true ->
        :ok
    end
  end

  defp context_limit(message, estimated_tokens, limit_tokens) do
    {:error,
     %Error{
       reason: :context_limit,
       type: "SystemOneContextLimitError",
       message: message,
       estimated_tokens: estimated_tokens,
       limit_tokens: limit_tokens
     }}
  end

  # Python's json.dumps(value, ensure_ascii=False, default=str), falling back
  # to str(value) when the value cannot be encoded at all.
  defp dump(value) do
    JSON.encode!(value, ensure_ascii: false)
  rescue
    ArgumentError -> inspect(value)
  end

  defp model_dump(%Noul{} = question) do
    OrderedObject.new([
      {"instructions", question.instructions},
      {"true", question.true},
      {"false", question.false}
    ])
  end

  defp model_dump(%Choice{} = question) do
    OrderedObject.new([
      {"instructions", question.instructions},
      {"options", OrderedObject.new(question.options)}
    ])
  end

  defp model_dump(%Score{} = question) do
    OrderedObject.new([{"instructions", question.instructions}, {"levels", question.levels}])
  end

  defp model_dump(question), do: question

  # Python's len(str): code points, not graphemes or bytes. A byte that is
  # not valid UTF-8 counts as one.
  defp code_points(<<_::utf8, rest::binary>>, count), do: code_points(rest, count + 1)
  defp code_points(<<_, rest::binary>>, count), do: code_points(rest, count + 1)
  defp code_points(<<>>, count), do: count

  defp per_token(characters), do: div(characters + @chars_per_token - 1, @chars_per_token)
end
