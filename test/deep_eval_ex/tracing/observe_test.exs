defmodule DeepEvalEx.Tracing.ObserveTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Tracing
  alias DeepEvalEx.Tracing.Span
  alias Jason.OrderedObject

  defmodule Agent do
    @moduledoc false
    use DeepEvalEx.Tracing

    deftraced answer(query), type: :agent, available_tools: ["retrieve"] do
      docs = retrieve(query)
      "answer from #{length(docs)} docs"
    end

    deftraced retrieve(query, k \\ 2), type: :retriever, embedder: "small" do
      Enum.map(1..k, &"#{query} #{&1}")
    end

    deftraced ping do
      "pong"
    end

    deftraced zero(), do: 0

    deftraced patterns(%{id: id} = request, _ignored, {a, b}, _, opts \\ []) do
      {id, request, a + b, opts}
    end

    deftraced pinned(prefix = "v" <> _version), do: prefix

    deftraced guarded(n) when is_integer(n) and n > 0, type: :tool, name: "positive" do
      n * 2
    end

    deftraced classify(input), type: :tool, name: "classify" do
      text when is_binary(text) -> {:text, text}
      %{} -> :map
      _other -> :other
    end

    deftraced fetch(url) do
      if url == "bad", do: raise(ArgumentError, "bad url"), else: url
    rescue
      error in ArgumentError -> {:rescued, Exception.message(error)}
    end

    deftraced dropped(x), type: :llm, drop_if_root: true do
      x
    end

    def call_private(x), do: secret(x)

    defptraced secret(x), type: :tool, name: "secret" do
      x + 1
    end

    deftraced dynamic(x), name: "dynamic #{x}" do
      x
    end

    deftraced with_input(x), input: "custom" do
      x
    end
  end

  defp capture(fun) do
    {result, traces} = Tracing.capture([], fun)
    {result, Enum.flat_map(traces, & &1.root_spans)}
  end

  defp input(%Span{input: %OrderedObject{values: values}}), do: values

  test "names the span after the function and records its arguments in order" do
    {result, [answer]} = capture(fn -> Agent.answer("reset") end)

    assert result == "answer from 2 docs"
    assert %Span{name: "answer", type: :agent, available_tools: ["retrieve"]} = answer
    assert input(answer) == [{"query", "reset"}]
    assert answer.output == "answer from 2 docs"

    assert [%Span{name: "retrieve", type: :retriever, embedder: "small"} = retrieve] =
             answer.children

    # Defaults are applied, as inspect's apply_defaults.
    assert input(retrieve) == [{"query", "reset"}, {"k", 2}]
    assert retrieve.output == ["reset 1", "reset 2"]
  end

  test "records the input of a zero-argument function as {}" do
    {_, [ping, zero]} = capture(fn -> {Agent.ping(), Agent.zero()} end)

    assert {ping.name, input(ping), ping.output} == {"ping", [], "pong"}
    assert {zero.name, input(zero), zero.output} == {"zero", [], 0}
  end

  test "binds patterns, underscored and ignored arguments" do
    {result, [span]} = capture(fn -> Agent.patterns(%{id: 7}, :skip, {1, 2}, :any) end)

    assert result == {7, %{id: 7}, 3, []}

    assert input(span) == [
             {"request", %{"id" => 7}},
             {"ignored", "skip"},
             {"arg3", [1, 2]},
             {"arg4", "any"},
             {"opts", []}
           ]

    {_, [pinned]} = capture(fn -> Agent.pinned("v2") end)
    assert input(pinned) == [{"prefix", "v2"}]
  end

  test "keeps guards, and the name and type options" do
    {_, [span]} = capture(fn -> Agent.guarded(3) end)
    assert {span.name, span.type, span.output} == {"positive", :tool, 6}

    assert_raise FunctionClauseError, fn -> Agent.guarded(-1) end
  end

  test "makes one span for a multi-clause function" do
    {results, spans} =
      capture(fn -> Enum.map(["hi", %{}, 1], &Agent.classify/1) end)

    assert results == [{:text, "hi"}, :map, :other]
    assert Enum.map(spans, &input/1) == [[{"input", "hi"}], [{"input", %{}}], [{"input", 1}]]
    assert Enum.all?(spans, &(&1.name == "classify" and &1.children == []))
  end

  test "keeps a rescue in the body inside the span" do
    {result, [span]} = capture(fn -> Agent.fetch("bad") end)

    assert result == {:rescued, "bad url"}
    assert span.status == :success
  end

  test "passes drop_if_root and evaluates options at call time" do
    {result, spans} = capture(fn -> {Agent.dropped(1), Agent.dynamic(2)} end)

    assert result == {1, 2}
    assert [%Span{name: "dynamic 2"}] = spans
  end

  test "defptraced defines a traced private function" do
    {result, [span]} = capture(fn -> Agent.call_private(1) end)

    assert result == 2
    assert {span.name, span.type} == {"secret", :tool}
    refute function_exported?(Agent, :secret, 1)
  end

  test "keeps @doc and @spec on the function" do
    alias DeepEvalEx.Test.TracedGreeter

    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(TracedGreeter)

    assert {_, _, _, %{"en" => "Greets someone."}, _} =
             List.keyfind(docs, {:function, :greet, 1}, 0)

    {:ok, specs} = Code.Typespec.fetch_specs(TracedGreeter)
    assert List.keymember?(specs, {:greet, 1}, 0)

    {"Hello, Ada", [%Span{name: "greet", type: :agent}]} =
      capture(fn -> TracedGreeter.greet("Ada") end)
  end

  test "marks a raising function's span ERRORED and re-raises" do
    {_, traces} =
      Tracing.capture([], fn ->
        assert_raise ArgumentError, fn -> Agent.retrieve("q", :not_a_number) end
      end)

    assert [[%Span{name: "retrieve", status: :errored}]] = Enum.map(traces, & &1.root_spans)
  end

  test "rejects an :input option, since the arguments are the input" do
    assert_raise ArgumentError, ~r/deftraced records the call's arguments as its input/, fn ->
      Agent.with_input(1)
    end
  end

  test "rejects clauses in a body with rescue, catch, else or after" do
    quoted =
      quote do
        defmodule DeepEvalEx.Tracing.ObserveTest.ClausesWithRescue do
          use DeepEvalEx.Tracing

          deftraced classify(input) do
            text when is_binary(text) -> text
          rescue
            _error -> :rescued
          end
        end
      end

    assert_raise ArgumentError, ~r/deftraced classify\(input\) lists clauses in its body/, fn ->
      Code.eval_quoted(quoted)
    end
  end
end
