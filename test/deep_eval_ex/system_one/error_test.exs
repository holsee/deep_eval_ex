defmodule DeepEvalEx.SystemOne.ErrorTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.{ContextWindowExceededError, DeepEvalError}
  alias DeepEvalEx.SystemOne.Error

  doctest DeepEvalEx.SystemOne.Error

  describe "describe/1" do
    test "a context limit with a limit names both token counts" do
      error = %Error{reason: :context_limit, estimated_tokens: 32_001, limit_tokens: 32_000}
      assert Error.describe(error) == "context limit (32001 est. tokens > 32000)"
    end

    test "a context limit without one was rejected by Jev" do
      error = %Error{reason: :context_limit, estimated_tokens: 900, message: "too large"}
      assert Error.describe(error) == "context limit (rejected by Jev)"
    end

    test "a timeout wraps its message" do
      error = %Error{reason: :timeout, type: "TimeoutError", message: "Jev took too long"}
      assert Error.describe(error) == "timeout (Jev took too long)"
    end

    test "anything else is its type and message" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      assert Error.describe(error) == "ConnectionError: Jev is down"

      assert Error.describe(%DeepEvalError{message: "no key"}) == "DeepEvalError: no key"
    end
  end

  describe "format/1" do
    test "is deepeval's format_error_text, \"<type>: <message>\"" do
      error = %Error{reason: :connection, type: "ConnectionError", message: "Jev is down"}
      assert Error.format(error) == "ConnectionError: Jev is down"

      assert Error.format(%ContextWindowExceededError{message: "too big"}) ==
               "ContextWindowExceededError: too big"

      assert Error.format(%RuntimeError{message: "boom"}) == "RuntimeError: boom"
    end

    test "a context limit is formatted like any other error" do
      error = %Error{reason: :context_limit, type: "SystemOneContextLimitError", message: "big"}
      assert Error.format(error) == "SystemOneContextLimitError: big"
    end
  end

  describe "type_name/1" do
    test "is the error's type, else the exception module's last segment" do
      assert Error.type_name(%Error{type: "ConnectionError"}) == "ConnectionError"
      assert Error.type_name(%Error{}) == "Error"
      assert Error.type_name(%DeepEvalError{message: "x"}) == "DeepEvalError"
    end
  end

  test "an error without a message raises with an empty one, as str(TimeoutError())" do
    assert Exception.message(%Error{reason: :timeout, type: "TimeoutError"}) == ""
    assert_raise Error, "Jev is down", fn -> raise Error, message: "Jev is down" end
  end

  test "DeepEvalError and ContextWindowExceededError carry a message" do
    assert_raise DeepEvalError, "no questions", fn -> raise DeepEvalError, "no questions" end

    assert_raise ContextWindowExceededError, "big", fn ->
      raise ContextWindowExceededError, "big"
    end
  end
end
