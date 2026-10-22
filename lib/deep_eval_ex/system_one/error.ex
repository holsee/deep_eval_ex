defmodule DeepEvalEx.SystemOne.Error do
  @moduledoc """
  A System One provider failure: the error an adapter returns (or raises)
  from `c:DeepEvalEx.SystemOne.Adapter.decide/3` when it could not answer.

  One struct stands for the exception classes deepeval 4.3.1 catches around
  a System One call (`ConnectionError`, `TimeoutError`, the TypeSafe SDK's
  errors, `SystemOneContextLimitError`, ...): `:reason` says what went wrong
  for DeepEvalEx, `:type` names the deepeval class whose text it reproduces.

  ## Fields

  - `:reason` - one of `:context_limit`, `:timeout`, `:connection`,
    `:rate_limited`, `:auth`, `:http`, `:invalid_response` or
    `:missing_dependency`
  - `:type` - the deepeval-facing class name, e.g. `"ConnectionError"` or
    `"SystemOneContextLimitError"`, used by `format/1` and `type_name/1`
  - `:message` - the error's text, deepeval's `str(exc)` (`""` when `nil`)
  - `:estimated_tokens`, `:limit_tokens` - for a `:context_limit`, the
    estimated size of the request and the limit it exceeds; `:limit_tokens`
    is `nil` when the provider itself rejected the request as too large
  - `:permanent?` - whether the failure will not get better on a retry in
    the same measure (a missing or rejected key, a missing dependency):
    deepeval's `_is_permanent`. Under the `hybrid` eval mode a permanent
    failure keeps the rest of the measure on the LLM

  ## Examples

      {:error,
       %DeepEvalEx.SystemOne.Error{
         reason: :connection,
         type: "ConnectionError",
         message: "Jev is down"
       }}
  """

  @type reason ::
          :context_limit
          | :timeout
          | :connection
          | :rate_limited
          | :auth
          | :http
          | :invalid_response
          | :missing_dependency

  @type t :: %__MODULE__{
          reason: reason() | nil,
          type: String.t() | nil,
          message: String.t() | nil,
          estimated_tokens: non_neg_integer() | nil,
          limit_tokens: pos_integer() | nil,
          permanent?: boolean()
        }

  defexception [:reason, :type, :message, :estimated_tokens, :limit_tokens, permanent?: false]

  @impl true
  def message(%__MODULE__{message: message}), do: message || ""

  @doc """
  Describes a failed System One call for `system_one_fallback_reason`,
  deepeval's `_describe_failure`.

  ## Examples

      iex> DeepEvalEx.SystemOne.Error.describe(%DeepEvalEx.SystemOne.Error{
      ...>   reason: :context_limit, estimated_tokens: 32_001, limit_tokens: 32_000})
      "context limit (32001 est. tokens > 32000)"

      iex> DeepEvalEx.SystemOne.Error.describe(%DeepEvalEx.SystemOne.Error{
      ...>   reason: :connection, type: "ConnectionError", message: "Jev is down"})
      "ConnectionError: Jev is down"
  """
  @spec describe(Exception.t()) :: String.t()
  def describe(%__MODULE__{reason: :context_limit, limit_tokens: nil}),
    do: "context limit (rejected by Jev)"

  def describe(%__MODULE__{reason: :context_limit} = error),
    do: "context limit (#{error.estimated_tokens} est. tokens > #{error.limit_tokens})"

  def describe(%__MODULE__{reason: :timeout} = error), do: "timeout (#{message(error)})"

  def describe(exception) when is_exception(exception), do: format(exception)

  @doc """
  Formats any exception as deepeval's `format_error_text` does,
  `"<type>: <message>"`, with `type_name/1` as the type.

  ## Examples

      iex> DeepEvalEx.SystemOne.Error.format(%DeepEvalEx.DeepEvalError{message: "no key"})
      "DeepEvalError: no key"
  """
  @spec format(Exception.t()) :: String.t()
  def format(exception) when is_exception(exception),
    do: "#{type_name(exception)}: #{Exception.message(exception)}"

  @doc """
  The Python class name deepeval reports for `exception`: the `:type` of a
  `DeepEvalEx.SystemOne.Error` that has one, otherwise the last segment of
  the exception's module (`DeepEvalError`, `ContextWindowExceededError`).

  ## Examples

      iex> DeepEvalEx.SystemOne.Error.type_name(%DeepEvalEx.SystemOne.Error{type: "TimeoutError"})
      "TimeoutError"

      iex> DeepEvalEx.SystemOne.Error.type_name(%DeepEvalEx.ContextWindowExceededError{message: ""})
      "ContextWindowExceededError"
  """
  @spec type_name(Exception.t()) :: String.t()
  def type_name(%__MODULE__{type: type}) when is_binary(type), do: type
  def type_name(%module{}), do: module |> Module.split() |> List.last()
end
