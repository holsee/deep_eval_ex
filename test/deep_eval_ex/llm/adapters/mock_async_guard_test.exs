defmodule DeepEvalEx.LLM.Adapters.MockAsyncGuardTest do
  # Guards the test suite against the race the Mock's configured responses
  # invite: they are shared by every process on the node, so an
  # `async: true` module that sets or clears them clobbers the responses of
  # every other async module running at the same time, failing tests at
  # random seeds. Such modules must use the Mock's scripted mode, whose
  # script belongs to the test process, or be `async: false`.
  use ExUnit.Case, async: true

  @global_api [
    :set_response,
    :set_schema_response,
    :clear_responses,
    :clear_recorded_prompts,
    :get_recorded_prompts
  ]

  @mock DeepEvalEx.LLM.Adapters.Mock

  @test_root Path.expand("../../..", __DIR__)

  describe "test modules using the Mock's configured responses" do
    test "are not async: true" do
      offenders =
        for path <- Path.wildcard(Path.join(@test_root, "**/*.exs")),
            source = File.read!(path),
            async?(source),
            calls = global_mock_calls(source),
            calls != [],
            do: "#{Path.relative_to(path, @test_root)}: #{Enum.join(calls, ", ")}"

      assert offenders == [],
             """
             These async: true test modules call the Mock's node-wide configured
             responses API, which races with every other async test. Use
             Mock.script/2 and Mock.scripted_prompts/0, or make them async: false:

               #{Enum.join(offenders, "\n  ")}
             """
    end

    test "are not test support modules, which async tests may call" do
      offenders =
        for path <- Path.wildcard(Path.join(@test_root, "support/**/*.ex")),
            calls = path |> File.read!() |> global_mock_calls(),
            calls != [],
            do: "#{Path.relative_to(path, @test_root)}: #{Enum.join(calls, ", ")}"

      assert offenders == []
    end
  end

  describe "the guard" do
    test "finds the API called through an alias, a multi-alias, in full, or imported" do
      source = """
      defmodule SomeTest do
        use ExUnit.Case, async: true
        alias DeepEvalEx.LLM.Adapters.Mock
        alias DeepEvalEx.LLM.Adapters.Mock, as: Judge
        alias DeepEvalEx.LLM.Adapters.{OpenAI, Mock}

        test "x" do
          Mock.set_schema_response(~r/x/, %{})
          Judge.clear_responses()
          DeepEvalEx.LLM.Adapters.Mock.get_recorded_prompts()
          Mock.script(%{})
        end
      end
      """

      assert async?(source)

      assert global_mock_calls(source) ==
               [
                 "Mock.set_schema_response",
                 "Judge.clear_responses",
                 "DeepEvalEx.LLM.Adapters.Mock.get_recorded_prompts"
               ]

      imported = """
      defmodule SomeTest do
        use DeepEvalEx.SomeCase, async: true
        import DeepEvalEx.LLM.Adapters.Mock, only: [set_response: 2]
        test "x", do: set_response("a", "b")
      end
      """

      assert async?(imported)
      assert global_mock_calls(imported) == ["set_response"]
    end

    test "ignores async: false modules and other modules named Mock" do
      refute async?("defmodule T do\n  use ExUnit.Case, async: false\nend\n")
      refute async?("defmodule T do\n  use ExUnit.Case\nend\n")

      source = """
      defmodule SomeTest do
        alias DeepEvalEx.SystemOne.Adapters.Mock
        test "x", do: Mock.set_response(:a, :b)
      end
      """

      assert global_mock_calls(source) == []
    end
  end

  # Whether a module in `source` uses a case template with `async: true`.
  defp async?(source) do
    source
    |> Code.string_to_quoted!()
    |> collect(fn
      {:use, _meta, [_case, opts]} when is_list(opts) -> Keyword.get(opts, :async) == true
      _node -> false
    end)
    |> Enum.any?()
  end

  # The global API calls in `source`, as written: through an alias of the
  # LLM Mock, its full name, or an import of it.
  defp global_mock_calls(source) do
    ast = Code.string_to_quoted!(source)
    aliases = mock_aliases(ast)
    imported? = ast |> collect(&imports_mock?/1) |> Enum.any?()

    collect(ast, fn
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, _args} when fun in @global_api ->
        if Module.concat(parts) == @mock or parts in aliases,
          do: "#{Enum.join(parts, ".")}.#{fun}"

      {fun, _, args} when imported? and fun in @global_api and is_list(args) ->
        "#{fun}"

      _node ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The alias names (as `__aliases__` parts) the LLM Mock goes by.
  defp mock_aliases(ast) do
    ast
    |> collect(&mock_alias/1)
    |> Enum.reject(&is_nil/1)
  end

  defp mock_alias({:alias, _, [{:__aliases__, _, parts}]}),
    do: if(Module.concat(parts) == @mock, do: [List.last(parts)])

  defp mock_alias({:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, as}]]}),
    do: if(Module.concat(parts) == @mock, do: as)

  defp mock_alias({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}) do
    Enum.find_value(children, fn {:__aliases__, _, parts} ->
      if Module.concat(base ++ parts) == @mock, do: parts
    end)
  end

  defp mock_alias(_node), do: nil

  defp imports_mock?({:import, _, [{:__aliases__, _, parts} | _opts]}),
    do: Module.concat(parts) == @mock

  defp imports_mock?(_node), do: false

  # `fun` applied to every node of `ast`, in source order.
  defp collect(ast, fun) do
    {_ast, acc} = Macro.prewalk(ast, [], fn node, acc -> {node, [fun.(node) | acc]} end)
    Enum.reverse(acc)
  end
end
