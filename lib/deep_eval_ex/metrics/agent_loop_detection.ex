# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/agent_loop_detection/agent_loop_detection.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.AgentLoopDetection do
  @moduledoc """
  AgentLoopDetection, deepeval 4.3.1's `AgentLoopDetectionMetric`: whether
  a traced agent got stuck in a loop, from `1.0` (clean execution) down to
  `0.0` (severe looping). It is deterministic: no LLM or System One model
  is called, it costs nothing, and it reports no evaluation model.

  It requires the trace (`requires_trace?/0`): run it on a traced
  component or trace with `DeepEvalEx.evaluate_traced/3` or
  `DeepEvalEx.ExUnit.assert_trace/3`, which give the test case its nested
  trace dict (`:trace_dict`, see `DeepEvalEx.Tracing.NestedDict`). Without
  one the score is `0.0` and the test case fails.

  ## How It Works

  Three independent checks over every span of the nested trace dict, each
  scoring `1.0`, `0.5` or `0.0`:

  1. **Tool repetition** (weight 0.40) - tool spans are counted by name and
     arguments: an input map (or a string holding a JSON object) as its
     `str()`'d key/value pairs, in any order, anything else as its `str()`.
     The most repeated call scores `0.5` at `:repetition_threshold` calls
     and `0.0` at twice that
  2. **Reasoning stagnation** (weight 0.35) - consecutive LLM span outputs
     are lowercased, split on whitespace and stripped of deepeval's stop
     words and words of two characters or fewer; a pair with fewer than 20
     words left is skipped. Their similarity is the larger of the bigram
     Jaccard index and `DeepEvalEx.Metrics.Utils.SequenceMatcher.ratio/3`
     of the remaining words. The most similar pair scores `0.5` at
     `:similarity_threshold` and `0.0` above `0.95`
  3. **Call graph cycles** (weight 0.25) - a depth-first walk flags a span
     whose `type:name:input` label (the input as `input_hash/1` makes it)
     already appears on its own ancestry path: the agent called itself
     again with the same input. Repeated siblings are left to the first
     check

  The score is the weighted mean of the checks that run, `1.0` when none
  does. The reason gathers the reasons of the checks that scored below
  `1.0`, or is "No loop patterns detected.". The result's metadata holds
  each check's score as `:score_breakdown`.

  Terms with no Python counterpart (tuples, pids, structs other than
  deepeval's models) are compared as their `inspect/1` text (a tuple as a
  list), so they never raise.

  ## Usage

  ```elixir
  DeepEvalEx.evaluate_traced(goldens, &MyApp.Agent.run(&1.input),
    metrics: [DeepEvalEx.Metrics.AgentLoopDetection]
  )

  # Or on a traced component: the span's own subtree is checked
  deftraced run(query), type: :agent, metrics: [DeepEvalEx.Metrics.AgentLoopDetection] do
    ...
  end
  ```

  ## Options

  - `:threshold` - Minimum passing score (default: 0.5, higher is better)
  - `:strict_mode` - Force the threshold to `1` and score below it `0.0`
    (default: false)
  - `:repetition_threshold` - Identical tool calls that score `0.5`; twice
    as many score `0.0` (default: 3)
  - `:similarity_threshold` - Similarity of consecutive LLM outputs that
    scores `0.5` (default: 0.85)
  - `:check_tool_repetition`, `:check_reasoning_stagnation`,
    `:check_call_graph_cycles` - Run each check (default: true)
  - `:verbose_mode` - Print the result's `:verbose_logs` after measuring
    (default: false)

  ## Eval Modes

  Like deepeval's, it ignores the eval mode (see
  `DeepEvalEx.SystemOne.Mode`): it measures the same way under `:hybrid`
  and `:system_one`, and builds and calls no System One model.
  """

  use DeepEvalEx.Metrics.BaseMetric, default_threshold: 0.5

  alias DeepEvalEx.Metrics.BaseMetric
  alias DeepEvalEx.Metrics.Utils.{SequenceMatcher, Verbose}
  alias DeepEvalEx.Prompts.Python
  alias DeepEvalEx.Prompts.Python.EnumMember
  alias DeepEvalEx.Schemas.{RetrievedContextData, ToolCall}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Turn
  alias Jason.OrderedObject

  # deepeval's _STOP_WORDS: common words and agent boilerplate that inflate
  # the similarity of reasoning without signalling stagnation.
  @stop_words MapSet.new(~w(
    the a an is are was were i will now based on information provided to of in
    and that this with for it my next step going so do be have has not but as
    or from at by about above below up its let
  ))

  # Python's str.split() separators: the characters str.isspace() accepts.
  @whitespace ~r/[\t\n\x0b\x0c\r\x1c-\x1f \x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]+/u

  # Unicode's Case_Ignorable and Cased properties, as Python's lower()
  # reads them for the final sigma: the general categories, plus the
  # Word_Break MidLetter, MidNumLet and Single_Quote characters.
  @case_ignorable ~r/^(?:[\p{Mn}\p{Me}\p{Cf}\p{Lm}\p{Sk}]|['.:\x{b7}\x{387}\x{55f}\x{5f4}\x{2018}\x{2019}\x{2024}\x{2027}\x{fe13}\x{fe52}\x{fe55}\x{ff07}\x{ff0e}\x{ff1a}])$/u
  @cased ~r/^[\p{Lu}\p{Ll}\p{Lt}]$/u

  @capital_sigma 0x3A3

  @no_trace_reason "No trace data found. This metric requires trace data from @observe."

  @impl true
  def metric_name, do: "Agent Loop Detection"

  @impl true
  def required_params, do: [:input, :actual_output]

  @doc """
  `true`: AgentLoopDetection reads the trace, deepeval's `requires_trace`.
  """
  @impl true
  def requires_trace?, do: true

  @doc """
  `false`: AgentLoopDetection takes no part in System One (see "Eval
  Modes").
  """
  @impl true
  def system_one?, do: false

  @doc """
  Measures how much the traced agent looped.

  ## Options

  See the moduledoc.
  """
  def do_measure(%{trace_dict: nil}, opts) do
    {:ok,
     Result.new(
       metric: metric_name(),
       score: 0.0,
       success: false,
       threshold: BaseMetric.threshold(opts, default_threshold()),
       reason: @no_trace_reason,
       verbose_logs: "",
       evaluation_cost: 0,
       strict_applied: true
     )}
  end

  def do_measure(%{trace_dict: trace_dict}, opts) do
    threshold = BaseMetric.threshold(opts, default_threshold())
    checks = checks(opts)

    spans = all_spans(trace_dict)
    tool_spans = Enum.filter(spans, &(get(&1, "type") == "tool"))
    llm_spans = Enum.filter(spans, &(get(&1, "type") == "llm"))

    {rep_score, rep_reason} =
      if checks.tool_repetition,
        do: score_tool_repetition(tool_spans, Keyword.get(opts, :repetition_threshold, 3)),
        else: {1.0, "Tool repetition check skipped."}

    {stag_score, stag_reason} =
      if checks.reasoning_stagnation,
        do: score_reasoning_stagnation(llm_spans, Keyword.get(opts, :similarity_threshold, 0.85)),
        else: {1.0, "Reasoning stagnation check skipped."}

    {cycle_score, cycle_reason} =
      if checks.call_graph_cycles,
        do: score_call_graph_cycles(trace_dict),
        else: {1.0, "Call graph cycles check skipped."}

    score = combine_scores(checks, rep_score, stag_score, cycle_score)

    score =
      if Keyword.get(opts, :strict_mode, false) and score < threshold, do: 0.0, else: score

    reason =
      reason(score, [
        {checks.tool_repetition, rep_score, rep_reason},
        {checks.reasoning_stagnation, stag_score, stag_reason},
        {checks.call_graph_cycles, cycle_score, cycle_reason}
      ])

    verbose_logs =
      Verbose.construct_verbose_logs(
        metric_name(),
        [
          "Tool Repetition Score: #{Verbose.to_str(rep_score)} (#{rep_reason})",
          "Reasoning Stagnation Score: #{Verbose.to_str(stag_score)} (#{stag_reason})",
          "Call Graph Cycles Score: #{Verbose.to_str(cycle_score)} (#{cycle_reason})",
          "Combined Loop Score: #{Verbose.to_str(score)}",
          "Final Reason: #{reason}"
        ],
        opts
      )

    {:ok,
     Result.new(
       metric: metric_name(),
       score: score,
       threshold: threshold,
       reason: reason,
       verbose_logs: verbose_logs,
       evaluation_cost: 0,
       strict_applied: true,
       metadata: %{
         score_breakdown: %{
           tool_repetition: rep_score,
           reasoning_stagnation: stag_score,
           call_graph_cycles: cycle_score
         }
       }
     )}
  end

  defp checks(opts) do
    %{
      tool_repetition: Keyword.get(opts, :check_tool_repetition, true),
      reasoning_stagnation: Keyword.get(opts, :check_reasoning_stagnation, true),
      call_graph_cycles: Keyword.get(opts, :check_call_graph_cycles, true)
    }
  end

  defp reason(score, _checks) when score == 1.0, do: "No loop patterns detected."

  defp reason(_score, checks) do
    reason =
      Enum.join(for({true, score, reason} <- checks, score < 1.0, reason != "", do: reason), " ")

    if String.trim(reason) == "",
      do: "Loops detected but no explicit reason provided.",
      else: reason
  end

  # deepeval's _combine_scores, its float operations in its order.
  defp combine_scores(checks, rep_score, stag_score, cycle_score) do
    {weights, total} =
      [
        {checks.tool_repetition, rep_score, 0.40},
        {checks.reasoning_stagnation, stag_score, 0.35},
        {checks.call_graph_cycles, cycle_score, 0.25}
      ]
      |> Enum.reduce({0.0, 0.0}, fn
        {true, score, weight}, {weights, total} -> {weights + weight, total + score * weight}
        {false, _score, _weight}, acc -> acc
      end)

    if weights == 0.0, do: 1.0, else: total / weights
  end

  # deepeval's _extract_all_spans: the dict and its descendants, depth
  # first, skipping empty ones.
  defp all_spans(span) do
    if dict?(span) and dict_pairs(span) != [],
      do: [span | Enum.flat_map(children(span), &all_spans/1)],
      else: []
  end

  ## Tool repetition

  defp score_tool_repetition([], _repetition_threshold), do: {1.0, "No tool spans found."}

  defp score_tool_repetition(tool_spans, repetition_threshold) do
    {keys, counts} =
      Enum.reduce(tool_spans, {[], %{}}, fn span, {keys, counts} ->
        key = {get(span, "name", ""), call_arguments(get(span, "input", %{}))}

        if Map.has_key?(counts, key),
          do: {keys, Map.update!(counts, key, &(&1 + 1))},
          else: {[key | keys], Map.put(counts, key, 1)}
      end)

    # max() keeps the first call counted most, in first-call order.
    {{name, _arguments}, count} =
      keys
      |> Enum.reverse()
      |> Enum.map(&{&1, Map.fetch!(counts, &1)})
      |> Enum.max_by(&elem(&1, 1))

    message = "Tool '#{py_str(name)}' called #{count} times with identical arguments."

    cond do
      count >= repetition_threshold * 2 -> {0.0, message}
      count >= repetition_threshold -> {0.5, message}
      true -> {1.0, "Tool calls are within acceptable repetition limits."}
    end
  end

  # A string holding JSON is its value; a dict is its sorted (str(key),
  # str(value)) pairs, anything else its str().
  defp call_arguments(input) when is_binary(input) do
    case Jason.decode(input, objects: :ordered_objects) do
      {:ok, value} -> arguments(value)
      {:error, _} -> arguments(input)
    end
  end

  defp call_arguments(input), do: arguments(input)

  defp arguments(value) do
    if dict?(value),
      do:
        {:dict,
         value |> dict_pairs() |> Enum.map(fn {k, v} -> {py_str(k), py_str(v)} end) |> Enum.sort()},
      else: {:value, py_str(value)}
  end

  ## Call graph cycles

  @doc """
  The input part of a span's cycle label, deepeval's `_input_hash`: a
  dict input as JSON with sorted keys (as `json.dumps(raw, sort_keys=True)`,
  non-ASCII characters escaped), or as its `str()` when JSON cannot dump
  it (keys of mixed types, or values JSON has no form for); any other input
  as its `str()`. Cut to its first 64 characters (code points). A span
  without an input has `""`.

  ## Examples

      iex> DeepEvalEx.Metrics.AgentLoopDetection.input_hash(%{"input" => %{"q" => "café", "a" => 1}})
      ~S({"a": 1, "q": "caf\\u00e9"})
  """
  @spec input_hash(map()) :: String.t()
  def input_hash(span) do
    raw = get(span, "input", "")

    text =
      if dict?(raw) do
        case sorted_json(raw) do
          {:ok, json} -> json
          :error -> py_str(raw)
        end
      else
        py_str(raw)
      end

    text |> String.to_charlist() |> Enum.take(64) |> List.to_string()
  end

  defp score_call_graph_cycles(trace_dict) do
    if dict?(trace_dict) and dict_pairs(trace_dict) != [] do
      case find_cycle(trace_dict, []) do
        nil ->
          {1.0, "No execution cycles detected."}

        path ->
          {0.0, "Cycle detected in execution path: #{Enum.map_join(path, " -> ", &display/1)}."}
      end
    else
      {1.0, "No call graph cycles detected."}
    end
  end

  # A label without its input part, for the reason: label.split(":", 2)'s
  # first two parts.
  defp display(label) do
    [type, name | _input] = String.split(label, ":", parts: 3)
    "#{type}:#{name}"
  end

  # The path from the first occurrence of a label on the ancestry path
  # (root first) to its repeat, or nil.
  defp find_cycle(span, ancestors) do
    label = label(span)

    case Enum.find_index(ancestors, &(&1 == label)) do
      nil ->
        ancestors = ancestors ++ [label]
        Enum.find_value(children(span), &find_cycle(&1, ancestors))

      index ->
        Enum.drop(ancestors, index) ++ [label]
    end
  end

  defp label(span),
    do:
      "#{py_str(get(span, "type", "unknown"))}:#{py_str(get(span, "name", "unnamed"))}:" <>
        input_hash(span)

  ## Reasoning stagnation

  defp score_reasoning_stagnation(llm_spans, _similarity_threshold) when length(llm_spans) < 2,
    do: {1.0, "Not enough LLM spans to check for reasoning stagnation."}

  defp score_reasoning_stagnation(llm_spans, similarity_threshold) do
    {max_overlap, {first, second}} =
      llm_spans
      |> Enum.zip(tl(llm_spans))
      |> Enum.with_index()
      |> Enum.reduce({0.0, {-1, -1}}, fn {{span1, span2}, i}, {max_overlap, _pair} = acc ->
        case similarity(get(span1, "output", ""), get(span2, "output", "")) do
          similarity when is_float(similarity) and similarity > max_overlap ->
            {similarity, {i, i + 1}}

          _skipped_or_lower ->
            acc
        end
      end)

    cond do
      max_overlap >= similarity_threshold and max_overlap > 0.95 ->
        {0.0, "Identical reasoning outputs at steps #{first} and #{second}."}

      max_overlap >= similarity_threshold ->
        {0.5,
         "High reasoning overlap (#{Python.format_fixed(max_overlap, 2)}) at steps " <>
           "#{first} and #{second}."}

      true ->
        {1.0, "No reasoning stagnation."}
    end
  end

  # The larger of the bigram Jaccard index and the SequenceMatcher ratio of
  # two outputs' meaningful words; nil when either is not text or has
  # fewer than 20 of them.
  defp similarity(output1, output2) when is_binary(output1) and is_binary(output2) do
    words1 = clean_words(output1)
    words2 = clean_words(output2)

    if length(words1) < 20 or length(words2) < 20 do
      nil
    else
      jaccard = bigram_jaccard(words1, words2)
      ratio = SequenceMatcher.ratio(Enum.join(words1, " "), Enum.join(words2, " "))
      max(jaccard, ratio)
    end
  end

  defp similarity(_output1, _output2), do: nil

  defp clean_words(text) do
    text
    |> python_lower()
    |> String.split(@whitespace, trim: true)
    |> Enum.filter(&(not MapSet.member?(@stop_words, &1) and length(String.to_charlist(&1)) > 2))
  end

  defp bigram_jaccard(words1, words2) when length(words1) < 2 or length(words2) < 2, do: 0.0

  defp bigram_jaccard(words1, words2) do
    bigrams1 = MapSet.new(Enum.zip(words1, tl(words1)))
    bigrams2 = MapSet.new(Enum.zip(words2, tl(words2)))

    case MapSet.size(MapSet.union(bigrams1, bigrams2)) do
      0 -> 0.0
      union -> MapSet.size(MapSet.intersection(bigrams1, bigrams2)) / union
    end
  end

  # Python's str.lower(): String.downcase/1, with a capital sigma in
  # Unicode's Final_Sigma context (after a cased letter and not before one,
  # case-ignorable characters skipped) lowered to the final sigma.
  defp python_lower(text) do
    if String.contains?(text, <<@capital_sigma::utf8>>) do
      chars = text |> String.to_charlist() |> List.to_tuple()

      chars
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(&lower_sigma(&1, chars))
      |> List.to_string()
      |> String.downcase()
    else
      String.downcase(text)
    end
  end

  defp lower_sigma({@capital_sigma, i}, chars),
    do: if(final_sigma?(chars, i), do: 0x3C2, else: 0x3C3)

  defp lower_sigma({char, _i}, _chars), do: char

  defp final_sigma?(chars, i) do
    before = Enum.find((i - 1)..0//-1, &(not case_ignorable?(elem(chars, &1))))

    after_ =
      Enum.find((i + 1)..(tuple_size(chars) - 1)//1, &(not case_ignorable?(elem(chars, &1))))

    before != nil and cased?(elem(chars, before)) and
      (after_ == nil or not cased?(elem(chars, after_)))
  end

  defp case_ignorable?(char), do: Regex.match?(@case_ignorable, <<char::utf8>>)
  defp cased?(char), do: Regex.match?(@cased, <<char::utf8>>)

  ## Python values

  # Python's str() of a value, with terms Python has no form for made
  # printable first.
  defp py_str(term), do: term |> printable() |> Python.str()

  defp printable(term)
       when is_nil(term) or is_boolean(term) or is_atom(term) or is_number(term),
       do: term

  defp printable(binary) when is_binary(binary),
    do: if(String.valid?(binary), do: binary, else: inspect(binary))

  defp printable(%struct{} = term)
       when struct in [ToolCall, Turn, RetrievedContextData, EnumMember],
       do: term

  defp printable(%OrderedObject{values: values}),
    do: OrderedObject.new(for {key, value} <- values, do: {printable(key), printable(value)})

  defp printable(map) when is_map(map) and not is_struct(map),
    do: OrderedObject.new(for {key, value} <- map, do: {printable(key), printable(value)})

  defp printable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> printable()

  defp printable(list) when is_list(list) do
    if List.improper?(list), do: inspect(list), else: Enum.map(list, &printable/1)
  end

  defp printable(term), do: inspect(term)

  # json.dumps(raw, sort_keys=True): :error where it raises TypeError.
  defp sorted_json(dict) do
    {:ok, dict |> json_value() |> JSON.encode!()}
  catch
    :not_json -> :error
  end

  defp json_value(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp json_value(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp json_value(binary) when is_binary(binary),
    do: if(String.valid?(binary), do: binary, else: throw(:not_json))

  defp json_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_value()

  defp json_value(list) when is_list(list) do
    if List.improper?(list), do: throw(:not_json), else: Enum.map(list, &json_value/1)
  end

  defp json_value(dict) do
    unless dict?(dict), do: throw(:not_json)

    keys = for {key, value} <- dict_pairs(dict), do: {json_key(key), json_value(value)}

    # sorted() compares keys of one kind only; None compares with nothing.
    case keys |> Enum.map(fn {{kind, _sort, _text}, _value} -> kind end) |> Enum.uniq() do
      [] -> :ok
      [_kind] when length(keys) == 1 -> :ok
      [kind] when kind != :none -> :ok
      _kinds -> throw(:not_json)
    end

    keys
    |> Enum.sort_by(fn {{_kind, sort, _text}, _value} -> sort end)
    |> Enum.map(fn {{_kind, _sort, text}, value} -> {text, value} end)
    |> OrderedObject.new()
  end

  # A key's kind, its sort value and its JSON text, as json.dumps writes
  # str, int, float, bool and None keys.
  defp json_key(nil), do: {:none, nil, "null"}
  defp json_key(true), do: {:number, 1, "true"}
  defp json_key(false), do: {:number, 0, "false"}

  defp json_key(atom) when is_atom(atom),
    do: {:string, Atom.to_string(atom), Atom.to_string(atom)}

  defp json_key(integer) when is_integer(integer),
    do: {:number, integer, Integer.to_string(integer)}

  defp json_key(float) when is_float(float), do: {:number, float, JSON.float_repr(float)}

  defp json_key(binary) when is_binary(binary) do
    if String.valid?(binary), do: {:string, binary, binary}, else: throw(:not_json)
  end

  defp json_key(_key), do: throw(:not_json)

  ## Nested dict access

  # deepeval's isinstance(value, dict).
  defp dict?(%OrderedObject{}), do: true
  defp dict?(value), do: is_map(value) and not is_struct(value)

  defp dict_pairs(%OrderedObject{values: values}), do: values
  defp dict_pairs(map), do: Enum.to_list(map)

  # dict.get(key, default): the default only when the key is missing.
  defp get(span, key, default \\ nil)

  defp get(%OrderedObject{values: values}, key, default) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp get(map, key, default) when is_map(map) and not is_struct(map),
    do: Map.get(map, key, default)

  defp get(_span, _key, default), do: default

  defp children(span) do
    case get(span, "children", []) do
      children when is_list(children) -> children
      _none -> []
    end
  end
end
