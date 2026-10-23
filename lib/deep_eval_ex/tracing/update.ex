defmodule DeepEvalEx.Tracing.Update do
  @moduledoc false
  # The field rules of deepeval 4.3.1's `tracing/context.py`, on spans and
  # trace fields, without the store: which values `update_current_span`,
  # `update_current_trace` and the typed `update_*_span` set (Python
  # truthiness, or `is not None` where deepeval checks that), how a test
  # case is unpacked, and how `apply_pending_to_span` sets a staged
  # `next_*` payload.

  alias DeepEvalEx.Schemas.ToolCall
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.Tracing.{Fields, Span}

  # The fields every next_* stages, as update_current_span takes them.
  @base_keys [
    :input,
    :output,
    :retrieval_context,
    :context,
    :expected_output,
    :tools_called,
    :expected_tools,
    :metadata,
    :name,
    :test_case,
    :metric_collection,
    :metrics
  ]

  @span_keys @base_keys ++ [:integration, :provider]

  @trace_keys [
    :name,
    :tags,
    :metadata,
    :thread_id,
    :user_id,
    :input,
    :output,
    :retrieval_context,
    :context,
    :expected_output,
    :tools_called,
    :expected_tools,
    :test_case,
    :test_case_id,
    :test_run_id,
    :turn_id,
    :metric_collection,
    :metrics
  ]

  # The fields of each typed update_*_span and next_*_span.
  @typed_keys %{
    base: [],
    agent: [:available_tools, :agent_handoffs],
    llm: [
      :model,
      :input_token_count,
      :output_token_count,
      :cost_per_input_token,
      :cost_per_output_token,
      :token_intervals,
      :prompt
    ],
    tool: [:description],
    retriever: [:embedder, :top_k, :chunk_size]
  }

  @float_keys [
    :input_token_count,
    :output_token_count,
    :cost_per_input_token,
    :cost_per_output_token
  ]

  @prompt_fields [
    prompt_alias: :alias,
    prompt_commit_hash: :hash,
    prompt_label: :label,
    prompt_version: :version
  ]

  @doc false
  # The options of `next_*` of `type` (the base fields and the type's own),
  # validated, without nil values (`_drop_none`), a test case built.
  def validate_pending!(type, opts) do
    opts
    |> validate!(Map.fetch!(@typed_keys, type) ++ @base_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> build_test_case()
  end

  @doc false
  # The options of update_current_span, validated, a test case built.
  def validate_span!(opts), do: opts |> validate!(@span_keys) |> build_test_case()

  @doc false
  # The options of the typed update_*_span, validated.
  def validate_typed!(type, opts), do: validate!(opts, Map.fetch!(@typed_keys, type))

  # Raises ArgumentError on an option not in `keys`.
  defp validate!(opts, keys) when is_list(opts), do: Keyword.validate!(opts, keys)

  defp build_test_case(opts) do
    case Keyword.get(opts, :test_case) do
      nil -> opts
      test_case -> Keyword.put(opts, :test_case, to_test_case(test_case))
    end
  end

  @doc false
  # update_current_span, on validated options: a test case first, then each
  # truthy field (integration and an LLM span's provider unless nil).
  def span(%Span{} = span, opts) do
    span
    |> put_test_case(opts[:test_case])
    |> put_if(opts, &Fields.truthy?/1, [
      :metadata,
      :input,
      :output,
      :retrieval_context,
      :context,
      :expected_output,
      :tools_called,
      :expected_tools,
      :name
    ])
    |> put_if(opts, &(not is_nil(&1)), [:integration])
    |> put_if(opts, &(not is_nil(&1) and span.type == :llm), [:provider])
    |> put_if(opts, &Fields.truthy?/1, [:metric_collection, :metrics])
  end

  @doc false
  # update_llm_span, update_agent_span, update_tool_span and
  # update_retriever_span: nothing unless the span has the type.
  def typed(%Span{} = span, type, opts) do
    if span.type == type, do: put_typed(span, type, opts), else: span
  end

  defp put_typed(span, :llm, opts) do
    span
    |> put_if(opts, &Fields.truthy?/1, [:model])
    |> put_if(opts, &(not is_nil(&1)), @float_keys)
    |> put_if(opts, &Fields.truthy?/1, [:token_intervals])
    |> put_prompt(opts[:prompt])
  end

  defp put_typed(span, :agent, opts),
    do: put_if(span, opts, &(not is_nil(&1)), [:available_tools, :agent_handoffs])

  defp put_typed(span, :tool, opts), do: put_if(span, opts, &(not is_nil(&1)), [:description])

  defp put_typed(span, :retriever, opts),
    do: put_if(span, opts, &Fields.truthy?/1, [:embedder, :top_k, :chunk_size])

  # A Prompt is always truthy in Python. Its alias, hash, label and version
  # are copied onto the span too, unset ones as nil.
  defp put_prompt(span, nil), do: span

  defp put_prompt(span, prompt) do
    Enum.reduce(@prompt_fields, %{span | prompt: prompt}, fn {field, key}, acc ->
      Map.put(acc, field, prompt_value(prompt, key))
    end)
  end

  defp prompt_value(%Jason.OrderedObject{} = prompt, key), do: prompt[Atom.to_string(key)]

  defp prompt_value(prompt, key) when is_map(prompt),
    do: Map.get(prompt, key, Map.get(prompt, Atom.to_string(key)))

  @doc false
  # update_current_trace: the fields to set, in order, a test case's first;
  # `nil` unsets a field (a test case's unset ones).
  def trace_attrs(opts) do
    opts = opts |> validate!(@trace_keys) |> build_test_case()

    test_case_fields(opts[:test_case]) ++
      for {key, value} <- opts,
          key != :test_case,
          Fields.truthy?(value),
          do: {key, value(key, value)}
  end

  @doc false
  # apply_pending_to_span: a staged test case first, then every staged field.
  def apply_pending(span, []), do: span

  def apply_pending(%Span{} = span, payload) do
    span = put_test_case(span, payload[:test_case])

    payload
    |> Keyword.delete(:test_case)
    |> Enum.reduce(span, fn {key, value}, acc -> Map.put(acc, key, value(key, value)) end)
  end

  defp put_test_case(span, nil), do: span

  defp put_test_case(span, test_case) do
    Enum.reduce(test_case_fields(test_case), span, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  # The fields deepeval copies from an LLMTestCase, all of them, set or not.
  defp test_case_fields(nil), do: []

  defp test_case_fields(test_case) do
    %TestCase{} = test_case = to_test_case(test_case)

    [
      input: test_case.input,
      output: test_case.actual_output,
      expected_output: test_case.expected_output,
      retrieval_context: test_case.retrieval_context,
      context: test_case.context,
      tools_called: test_case.tools_called,
      expected_tools: test_case.expected_tools
    ]
  end

  defp to_test_case(%TestCase{} = test_case), do: test_case

  defp to_test_case(attrs) when is_list(attrs) or is_map(attrs) do
    case TestCase.new(attrs) do
      {:ok, test_case} -> test_case
      {:error, errors} -> raise ArgumentError, "Invalid test case: #{inspect(errors)}"
    end
  end

  defp put_if(span, opts, set?, keys) do
    opts
    |> Keyword.take(keys)
    |> Enum.filter(fn {_key, value} -> set?.(value) end)
    |> Enum.reduce(span, fn {key, value}, acc -> Map.put(acc, key, value(key, value)) end)
  end

  # Tool calls as structs; pydantic's float for token counts and costs.
  defp value(key, tools) when key in [:tools_called, :expected_tools] and is_list(tools),
    do: Enum.map(tools, &tool_call/1)

  defp value(key, count) when key in @float_keys and is_integer(count), do: count * 1.0
  defp value(_key, value), do: value

  @doc false
  # A ToolCall from a struct, keyword list or map; ArgumentError when invalid.
  def tool_call(%ToolCall{} = tool), do: tool

  def tool_call(attrs) do
    case ToolCall.new(attrs) do
      {:ok, tool} -> tool
      {:error, errors} -> raise ArgumentError, "Invalid tool call: #{inspect(errors)}"
    end
  end
end
