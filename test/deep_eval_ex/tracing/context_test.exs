defmodule DeepEvalEx.Tracing.ContextTest do
  # The update_*, next_* and drop_current_* functions: deepeval 4.3.1's
  # tracing/context.py. The tracing store is one global table; every test
  # works on its own traces, so they run concurrently.
  use ExUnit.Case, async: true

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.{TestCase, Tracing}
  alias DeepEvalEx.Tracing.{Span, Store, Trace}

  defp capture(fun), do: Tracing.capture([], fun)

  # The root span of the one trace `fun` records.
  defp root(fun) do
    {_, [%Trace{root_spans: [root]}]} = capture(fun)
    root
  end

  defp names(spans), do: Enum.map(spans, & &1.name)

  defp pending_rows, do: :ets.select(Store, [{{{:pending, :_}, self(), :_}, [], [:"$_"]}])

  describe "update_current_span/1" do
    test "sets the fields given, ignoring falsy values as Python's truthiness" do
      span =
        root(fn ->
          Tracing.span(:base, [name: "s", metadata: %{"kept" => true}], fn ->
            Tracing.update_current_span(
              input: "question",
              retrieval_context: ["doc"],
              context: ["truth"],
              expected_output: "answer",
              name: "renamed",
              metric_collection: "collection",
              metrics: [DeepEvalEx.Metrics.ExactMatch]
            )

            # nil, false, "", [], %{} and 0 set nothing.
            Tracing.update_current_span(
              input: "",
              output: 0,
              metadata: %{},
              retrieval_context: [],
              name: nil,
              expected_output: false
            )

            :result
          end)
        end)

      assert span.name == "renamed"
      assert span.input == "question"
      assert span.output == "result"
      assert span.metadata == %{"kept" => true}
      assert {span.retrieval_context, span.context} == {["doc"], ["truth"]}
      assert span.expected_output == "answer"
      assert span.metric_collection == "collection"
      assert span.metrics == [DeepEvalEx.Metrics.ExactMatch]
    end

    test "sets an update's input and output over the span's defaults" do
      span =
        root(fn ->
          Tracing.span(:tool, [name: "t", input: %{"q" => 1}], fn ->
            Tracing.update_current_span(input: "set", output: %{"set" => true})
            :returned
          end)
        end)

      assert {span.input, span.output} == {"set", %{"set" => true}}
    end

    test "sets integration and an LLM span's provider unless nil" do
      [llm, agent] =
        Enum.map([:llm, :agent], fn type ->
          root(fn ->
            Tracing.span(type, [name: "s", integration: "x"], fn ->
              Tracing.update_current_span(integration: "", provider: "")
            end)
          end)
        end)

      # `is not None`: an empty string is set.
      assert {llm.integration, llm.provider} == {"", ""}
      # Only LlmSpan has a provider.
      assert {agent.integration, agent.provider} == {"", nil}
    end

    test "unpacks a test case into the span's fields, over which the other options win" do
      span =
        root(fn ->
          Tracing.span(:retriever, [name: "r"], fn ->
            Tracing.update_current_span(expected_output: "earlier", context: ["kept?"])

            Tracing.update_current_span(
              test_case: %TestCase{
                input: "q",
                actual_output: "a",
                retrieval_context: ["doc"],
                tools_called: [%ToolCall{name: "index"}]
              },
              context: ["given"]
            )
          end)
        end)

      assert {span.input, span.output} == {"q", "a"}
      assert span.retrieval_context == ["doc"]
      assert span.tools_called == [%ToolCall{name: "index"}]
      # The test case's unset fields overwrite too, as deepeval assigns them all.
      assert span.expected_output == nil
      assert span.expected_tools == nil
      assert span.context == ["given"]
      # deepeval leaves llm_test_case to the evaluator.
      assert span.llm_test_case == nil
    end

    test "takes a test case as a keyword list, and tool calls as maps" do
      span =
        root(fn ->
          Tracing.span(:base, [name: "s"], fn ->
            Tracing.update_current_span(
              test_case: [input: "q", actual_output: "a"],
              expected_tools: [%{name: "search", input_parameters: %{"q" => "x"}}]
            )
          end)
        end)

      assert {span.input, span.output} == {"q", "a"}
      assert span.expected_tools == [%ToolCall{name: "search", input_parameters: %{"q" => "x"}}]
    end

    test "does nothing without a current span" do
      assert Tracing.update_current_span(name: "nowhere") == :ok

      {_, [trace]} =
        capture(fn -> Tracing.trace([], fn -> Tracing.update_current_span(name: "x") end) end)

      assert trace.root_spans == []
      Tracing.suppress(fn -> assert Tracing.update_current_span(name: "x") == :ok end)
    end

    test "updates the caller's span from a task with no span of its own" do
      span =
        root(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            fn -> Tracing.update_current_span(metadata: %{"from" => "task"}) end
            |> Task.async()
            |> Task.await()

            Tracing.update_current_span(output: "own")
          end)
        end)

      assert {span.metadata, span.output} == {%{"from" => "task"}, "own"}
    end

    test "raises ArgumentError on an unknown option" do
      assert_raise ArgumentError, ~r/unknown keys \[:model\]/, fn ->
        Tracing.update_current_span(model: "gpt-4o")
      end
    end
  end

  describe "update_current_trace/1" do
    test "sets the fields given, ignoring falsy values" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            Tracing.update_current_trace(
              name: "support",
              tags: ["beta"],
              metadata: %{"channel" => "chat"},
              thread_id: "thread",
              user_id: "user",
              output: "set",
              retrieval_context: ["doc"],
              context: ["truth"],
              expected_output: "expected",
              tools_called: [%{name: "search"}],
              expected_tools: [[name: "search"]],
              test_case_id: "tc",
              test_run_id: "tr",
              turn_id: "turn",
              metric_collection: "collection",
              metrics: [DeepEvalEx.Metrics.ExactMatch]
            )

            Tracing.update_current_trace(name: "", tags: [], user_id: nil, output: 0)
            :returned
          end)
        end)

      assert {trace.name, trace.tags, trace.metadata} ==
               {"support", ["beta"], %{"channel" => "chat"}}

      assert {trace.thread_id, trace.user_id} == {"thread", "user"}
      assert trace.output == "set"
      # Unset, and the root span had no input either.
      assert trace.input == nil
      assert {trace.retrieval_context, trace.context} == {["doc"], ["truth"]}
      assert trace.expected_output == "expected"
      assert trace.tools_called == [%ToolCall{name: "search"}]
      assert trace.expected_tools == [%ToolCall{name: "search"}]
      assert {trace.test_case_id, trace.test_run_id, trace.turn_id} == {"tc", "tr", "turn"}
      assert trace.metric_collection == "collection"
      assert trace.metrics == [DeepEvalEx.Metrics.ExactMatch]
    end

    test "unpacks a test case; its unset input and output leave the root's defaults" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a", input: "from the span"], fn ->
            Tracing.update_current_trace(expected_output: "earlier")

            Tracing.update_current_trace(
              test_case: %TestCase{input: "q", retrieval_context: ["d"]}
            )

            "from the result"
          end)
        end)

      assert trace.input == "q"
      assert trace.retrieval_context == ["d"]
      assert trace.expected_output == nil
      # deepeval sets the trace's output to None, and the root span's exit
      # then fills it in.
      assert trace.output == "from the result"
    end

    test "updates the trace of trace/2 with no span open" do
      {_, [trace]} =
        capture(fn -> Tracing.trace([], fn -> Tracing.update_current_trace(name: "n") end) end)

      assert trace.name == "n"
    end

    test "does nothing outside a trace" do
      assert Tracing.update_current_trace(name: "nowhere") == :ok
    end

    test "keeps every field of concurrent updates from many tasks" do
      fields = [:name, :thread_id, :user_id, :expected_output, :test_case_id, :turn_id]

      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "a"], fn ->
            fields
            |> Task.async_stream(
              fn field -> Tracing.update_current_trace([{field, "#{field}"}]) end,
              max_concurrency: length(fields)
            )
            |> Stream.run()
          end)
        end)

      for field <- fields, do: assert(Map.fetch!(trace, field) == "#{field}")
    end

    test "leaves nothing behind for a trace that has closed" do
      {ctx, [trace]} = capture(fn -> Tracing.span(:base, [name: "s"], &Tracing.context/0) end)

      Tracing.with_context(ctx, fn -> Tracing.update_current_trace(name: "late") end)

      assert :ets.select(Store, [{{{:trace_attr, trace.uuid, :_}, :_}, [], [:"$_"]}]) == []
    end

    test "raises ArgumentError on an unknown option" do
      assert_raise ArgumentError, fn -> Tracing.update_current_trace(environment: "dev") end
    end
  end

  describe "the typed span updates" do
    test "update_llm_span/1 sets an LLM span's fields; token counts and costs unless nil" do
      span =
        root(fn ->
          Tracing.span(:llm, [name: "llm", model: "gpt-4o-mini"], fn ->
            Tracing.update_llm_span(
              model: "gpt-4o",
              input_token_count: 0,
              output_token_count: 7,
              cost_per_input_token: 1.5e-7,
              cost_per_output_token: nil,
              token_intervals: %{1_000_000 => "Hel"},
              prompt: %{alias: "p", version: "00.00.01", label: "prod", hash: "abc"}
            )

            Tracing.update_llm_span(model: "", token_intervals: %{})
          end)
        end)

      assert span.model == "gpt-4o"
      # Zero is a count, and integers become floats, as pydantic's float.
      assert {span.input_token_count, span.output_token_count} == {0.0, 7.0}
      assert {span.cost_per_input_token, span.cost_per_output_token} == {1.5e-7, nil}
      assert span.token_intervals == %{1_000_000 => "Hel"}
      assert span.prompt == %{alias: "p", version: "00.00.01", label: "prod", hash: "abc"}

      assert {span.prompt_alias, span.prompt_version, span.prompt_label, span.prompt_commit_hash} ==
               {"p", "00.00.01", "prod", "abc"}
    end

    test "update_llm_span/1 reads a prompt with string keys, unset ones as nil" do
      span =
        root(fn ->
          Tracing.span(:llm, [name: "llm"], fn ->
            Tracing.update_llm_span(prompt: %{"alias" => "p", "hash" => "abc"})
          end)
        end)

      assert {span.prompt_alias, span.prompt_version, span.prompt_label, span.prompt_commit_hash} ==
               {"p", nil, nil, "abc"}
    end

    test "update_agent_span/1 and update_tool_span/1 set their fields unless nil" do
      agent =
        root(fn ->
          Tracing.span(:agent, [name: "a", available_tools: ["x"]], fn ->
            Tracing.update_agent_span(available_tools: [], agent_handoffs: ["billing"])
          end)
        end)

      tool =
        root(fn ->
          Tracing.span(:tool, [name: "t", description: "d"], fn ->
            Tracing.update_tool_span(description: "")
          end)
        end)

      assert {agent.available_tools, agent.agent_handoffs} == {[], ["billing"]}
      assert tool.description == ""
    end

    test "update_retriever_span/1 sets truthy fields" do
      span =
        root(fn ->
          Tracing.span(:retriever, [name: "r", embedder: "e"], fn ->
            Tracing.update_retriever_span(top_k: 2, chunk_size: 512)
            Tracing.update_retriever_span(embedder: "", top_k: 0)
          end)
        end)

      assert {span.embedder, span.top_k, span.chunk_size} == {"e", 2, 512}
    end

    test "each does nothing unless the current span has its type" do
      span =
        root(fn ->
          Tracing.span(:tool, [name: "t"], fn ->
            Tracing.update_llm_span(model: "gpt-4o")
            Tracing.update_agent_span(available_tools: ["x"])
            Tracing.update_retriever_span(top_k: 2)
          end)
        end)

      assert {span.model, span.available_tools, span.top_k} == {nil, [], nil}
      assert Tracing.update_tool_span(description: "outside") == :ok
    end

    test "raise ArgumentError on another type's option" do
      assert_raise ArgumentError, fn -> Tracing.update_tool_span(model: "gpt-4o") end
    end
  end

  describe "next_*_span/2" do
    test "stage fields for the next span of the type only, typed values winning" do
      {result, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            Tracing.next_span([metadata: %{"staged" => "base"}, metric_collection: "base"], fn ->
              Tracing.next_llm_span([model: "gpt-4o", metadata: %{"staged" => "llm"}], fn ->
                Tracing.span(:llm, [name: "first", model: "gpt-4o-mini"], fn -> 1 end)
                Tracing.span(:llm, [name: "second", model: "gpt-4o-mini"], fn -> 2 end)
              end)
            end)

            Tracing.next_tool_span([description: "staged", name: "renamed"], fn ->
              Tracing.span(:tool, [name: "lookup"], fn -> :found end)
            end)
          end)
        end)

      assert result == :found
      [%Span{children: [first, second, tool]}] = trace.root_spans

      assert {first.name, first.model, first.metadata, first.metric_collection} ==
               {"first", "gpt-4o", %{"staged" => "llm"}, "base"}

      assert {second.model, second.metadata, second.metric_collection} ==
               {"gpt-4o-mini", nil, nil}

      assert {tool.name, tool.description} == {"renamed", "staged"}
    end

    test "a span of another type takes only the base slot" do
      {_, [trace]} =
        capture(fn ->
          Tracing.next_span([name: "base"], fn ->
            Tracing.next_llm_span([model: "gpt-4o"], fn ->
              Tracing.span(:agent, [name: "agent"], fn ->
                Tracing.span(:llm, [name: "llm"], fn -> :ok end)
              end)
            end)
          end)
        end)

      assert [%Span{name: "base", children: [%Span{name: "llm", model: "gpt-4o"}]}] =
               trace.root_spans
    end

    test "staged values are the baseline that update_current_span overrides" do
      span =
        root(fn ->
          Tracing.next_span(
            [input: "staged input", output: "staged output", name: "staged"],
            fn ->
              Tracing.span(:base, [name: "s", input: "option"], fn ->
                Tracing.update_current_span(name: "updated")
                :returned
              end)
            end
          )
        end)

      assert {span.name, span.input, span.output} == {"updated", "staged input", "staged output"}
    end

    test "stage a test case, under the individual fields" do
      span =
        root(fn ->
          Tracing.next_span(
            [test_case: %TestCase{input: "q", actual_output: "a"}, expected_output: "e"],
            fn -> Tracing.span(:base, [name: "s"], fn -> :ok end) end
          )
        end)

      assert {span.input, span.output, span.expected_output} == {"q", "a", "e"}
    end

    test "staged tool calls and token counts are normalised" do
      span =
        root(fn ->
          Tracing.next_llm_span([tools_called: [%{name: "t"}], input_token_count: 3], fn ->
            Tracing.span(:llm, [name: "s"], fn -> :ok end)
          end)
        end)

      assert {span.tools_called, span.input_token_count} == {[%ToolCall{name: "t"}], 3.0}
    end

    test "the slot is cleared when the function returns or raises" do
      {_, traces} =
        capture(fn ->
          Tracing.next_span([name: "staged"], fn -> :unused end)

          assert_raise RuntimeError, fn ->
            Tracing.next_span([name: "staged"], fn -> raise "boom" end)
          end

          Tracing.span(:base, [name: "plain"], fn -> :ok end)
        end)

      assert [%Trace{root_spans: [%Span{name: "plain"}]}] = traces
      assert pending_rows() == []
    end

    test "an inner slot replaces the outer one for its function only" do
      {_, traces} =
        capture(fn ->
          Tracing.next_span([name: "outer"], fn ->
            Tracing.next_span([name: "inner"], fn ->
              Tracing.span(:base, [name: "a"], fn -> :ok end)
            end)

            Tracing.span(:base, [name: "b"], fn -> :ok end)
          end)
        end)

      assert Enum.flat_map(traces, &names(&1.root_spans)) == ["inner", "outer"]
    end

    test "a task joining through $callers consumes the slot once" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            Tracing.next_llm_span([model: "staged"], fn ->
              1..4
              |> Enum.map(fn i ->
                Task.async(fn -> Tracing.span(:llm, [name: "llm #{i}"], fn -> i end) end)
              end)
              |> Task.await_many()
            end)
          end)
        end)

      [%Span{children: children}] = trace.root_spans
      assert length(children) == 4
      assert Enum.count(children, &(&1.model == "staged")) == 1
    end

    test "return the function's result and leave no row behind" do
      assert Tracing.next_retriever_span([top_k: 3, embedder: "e", chunk_size: 9], fn -> :r end) ==
               :r

      assert Tracing.next_agent_span([available_tools: ["x"], agent_handoffs: []], fn -> :a end) ==
               :a

      assert pending_rows() == []
    end

    test "raise ArgumentError on an option the span type does not take" do
      assert_raise ArgumentError, ~r/unknown keys \[:model\]/, fn ->
        Tracing.next_tool_span([model: "gpt-4o"], fn -> :ok end)
      end

      assert_raise ArgumentError, fn -> Tracing.next_span([integration: "x"], fn -> :ok end) end
    end
  end

  describe "drop_current_span/0 and drop_current_trace/0" do
    test "mark the current span and trace dropped" do
      {_, [trace]} =
        capture(fn ->
          Tracing.span(:agent, [name: "agent"], fn ->
            Tracing.span(:base, [name: "plan"], fn -> Tracing.drop_current_span() end)
            Tracing.drop_current_trace()
          end)
        end)

      assert trace.drop
      [%Span{drop: false, children: [%Span{name: "plan", drop: true}]}] = trace.root_spans
    end

    test "do nothing outside a trace" do
      assert Tracing.drop_current_span() == :ok
      assert Tracing.drop_current_trace() == :ok
    end
  end
end
