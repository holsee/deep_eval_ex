# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/metrics/dag/serialization/serialization.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Metrics.DAG.Serialization do
  @moduledoc false
  # JSON for DeepEvalEx.Metrics.DAG.Graph, deepeval 4.3.1's dag_to_dict,
  # dag_to_json, dag_from_dict and dag_from_json. See "JSON" in the Graph
  # moduledoc.

  alias DeepEvalEx.Metrics.DAG.{
    BinaryJudgementNode,
    Graph,
    Node,
    NonBinaryJudgementNode,
    TaskNode,
    VerdictNode
  }

  alias DeepEvalEx.Metrics.GEval
  alias DeepEvalEx.Metrics.GEval.Rubric
  alias DeepEvalEx.Params.SingleTurn
  alias DeepEvalEx.TestRun.JSON
  alias Jason.OrderedObject

  @node_types [
    {"TaskNode", TaskNode},
    {"BinaryJudgementNode", BinaryJudgementNode},
    {"NonBinaryJudgementNode", NonBinaryJudgementNode},
    {"VerdictNode", VerdictNode}
  ]

  @child_types ~w(node geval metric)

  # deepeval metric classes named without the "Metric" suffix.
  @unsuffixed ~w(GEval ConversationalGEval JevEval ConversationalJevEval)

  # Options never written as a metric child's kwargs: they are not
  # deepeval constructor arguments it could read back, or are secrets.
  @private_options [
    :model,
    :adapter,
    :api_key,
    :system_one_model,
    :system_one,
    :evaluation_template
  ]

  ## Writing

  @spec to_map(Graph.t()) :: %{String.t() => OrderedObject.t()}
  def to_map(%Graph{root_nodes: roots}) do
    ordered = walk(roots)
    ids = Map.new(ordered, &{&1.id, uuid4()})

    %{"nodes" => OrderedObject.new(Enum.map(ordered, &{ids[&1.id], node_map(&1, ids)}))}
  end

  @spec to_json(Graph.t(), non_neg_integer()) :: String.t()
  def to_json(graph, indent \\ 2), do: graph |> to_map() |> JSON.encode!(indent: indent)

  # deepeval's _walk_nodes: breadth first from the roots, each node once.
  defp walk(roots), do: walk(:queue.from_list(roots), %{}, [])

  defp walk(queue, seen, acc) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        Enum.reverse(acc)

      {{:value, node}, queue} ->
        if Map.has_key?(seen, node.id) do
          walk(queue, seen, acc)
        else
          queue = Enum.reduce(Node.edges(node), queue, &:queue.in/2)
          walk(queue, Map.put(seen, node.id, true), [node | acc])
        end
    end
  end

  defp node_map(%TaskNode{} = node, ids) do
    OrderedObject.new([
      {"type", "TaskNode"},
      {"instructions", node.instructions},
      {"output_label", node.output_label},
      {"label", node.label},
      {"evaluation_params", param_names(node.evaluation_params)},
      {"children", Enum.map(node.children, &ids[&1.id])}
    ])
  end

  defp node_map(%VerdictNode{} = node, ids) do
    OrderedObject.new(
      [{"type", "VerdictNode"}, {"verdict", node.verdict}] ++
        if(node.score != nil, do: [{"score", node.score}], else: []) ++
        if(node.child != nil, do: [{"child", child_map(node.child, ids)}], else: [])
    )
  end

  defp node_map(%module{} = node, ids) do
    OrderedObject.new([
      {"type", type_name(module)},
      {"criteria", node.criteria},
      {"label", node.label},
      {"evaluation_params", param_names(node.evaluation_params)},
      {"children", Enum.map(node.children, &ids[&1.id])}
    ])
  end

  defp type_name(module),
    do: Enum.find_value(@node_types, fn {name, m} -> m == module && name end)

  defp param_names(nil), do: nil
  defp param_names(params), do: Enum.map(params, &Atom.to_string/1)

  defp child_map(child, ids) do
    cond do
      Node.node?(child) -> OrderedObject.new([{"type", "node"}, {"ref", ids[child.id]}])
      match?(%GEval{}, child) -> geval_map(child)
      true -> metric_map(child)
    end
  end

  # deepeval's _serialize_geval: GEval's constructor arguments it keeps as
  # JSON-able attributes, in its signature's order. A rubric is not JSON
  # there, so it is written only when there is none.
  defp geval_map(%GEval{} = geval) do
    OrderedObject.new(
      [
        {"type", "geval"},
        {"name", geval.name},
        {"evaluation_params", param_names(geval.evaluation_params)},
        {"criteria", geval.criteria},
        {"evaluation_steps", geval.evaluation_steps}
      ] ++
        if(geval.rubric == nil, do: [{"rubric", nil}], else: []) ++
        [
          {"threshold", geval.threshold},
          {"top_logprobs", geval.top_logprobs},
          {"async_mode", true},
          {"strict_mode", geval.strict_mode || false},
          {"verbose_mode", geval.verbose_mode || false},
          {"_include_g_eval_suffix", geval.include_g_eval_suffix},
          {"flaky", geval.flaky || false}
        ]
    )
  end

  # deepeval's _serialize_metric: the class and its JSON-able options.
  defp metric_map(metric) do
    {module, options} = metric_options(metric)

    kwargs =
      for {key, value} <- options,
          key not in @private_options,
          not secret?(key),
          {:ok, json} <- [jsonable(value)],
          do: {Atom.to_string(key), json}

    OrderedObject.new([
      {"type", "metric"},
      {"metric_class", class_name(module)},
      {"kwargs", OrderedObject.new(kwargs)}
    ])
  end

  defp metric_options(module) when is_atom(module), do: {module, []}
  defp metric_options({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  defp metric_options(%module{} = struct),
    do: {module, struct |> Map.from_struct() |> Enum.reject(fn {_key, value} -> value == nil end)}

  defp metric_options(other) do
    raise ArgumentError,
          "VerdictNode.child has unsupported type #{inspect(other)}. Expected a DAG node, a " <>
            "GEval, or a metric (a module, {module, opts} or a metric struct)."
  end

  defp secret?(key) do
    name = Atom.to_string(key)
    Enum.any?(~w(key token secret password), &String.contains?(name, &1))
  end

  # deepeval's _maybe_jsonify: :error for anything that is not JSON.
  defp jsonable(value) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {:ok, value}

  defp jsonable(value) when is_binary(value), do: {:ok, value}
  defp jsonable(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp jsonable(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case jsonable(item) do
        {:ok, json} -> {:cont, {:ok, acc ++ [json]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp jsonable(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) or is_atom(key) ->
        case jsonable(value) do
          {:ok, json} -> {:cont, {:ok, Map.put(acc, to_string(key), json)}}
          :error -> {:halt, :error}
        end

      _pair, _acc ->
        {:halt, :error}
    end)
  end

  defp jsonable(_value), do: :error

  # A DeepEvalEx.Metrics module by deepeval's class name, any other module
  # by its Elixir name.
  defp class_name(module) do
    case Module.split(module) do
      ["DeepEvalEx", "Metrics", name] when name in @unsuffixed -> name
      ["DeepEvalEx", "Metrics", name] -> name <> "Metric"
      parts -> Enum.join(parts, ".")
    end
  end

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :rand.bytes(16)

    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  ## Reading

  @spec from_json(String.t()) :: Graph.t()
  def from_json(json), do: json |> Jason.decode!(objects: :ordered_objects) |> from_map()

  @spec from_map(map() | OrderedObject.t()) :: Graph.t()
  def from_map(data) do
    nodes = fetch_nodes!(data)

    Enum.each(nodes, fn {id, spec} ->
      if not (object?(spec) and has?(spec, "type")),
        do: raise(ArgumentError, "Node '#{id}' is missing required 'type' field.")

      node_module!(id, spec["type"])
    end)

    referenced = referenced_ids(nodes)
    root_ids = for {id, _spec} <- nodes, not MapSet.member?(referenced, id), do: id

    if root_ids == [] do
      raise ArgumentError,
            "No root nodes detected (every node is referenced as a child); graph would be " <>
              "empty or contain a cycle."
    end

    specs = Map.new(nodes)

    {roots, _built} =
      Enum.map_reduce(root_ids, %{}, fn id, built -> build(id, specs, [], built) end)

    Graph.new(roots)
  end

  defp fetch_nodes!(data) do
    if not (object?(data) and has?(data, "nodes")) do
      raise ArgumentError,
            "Invalid DAG document: expected a top-level object with a 'nodes' key."
    end

    case entries(data["nodes"]) do
      [_ | _] = nodes -> nodes
      _empty -> raise ArgumentError, "Invalid DAG document: 'nodes' must be a non-empty object."
    end
  end

  defp object?(%OrderedObject{}), do: true
  defp object?(term), do: is_map(term) and not is_struct(term)

  defp has?(%OrderedObject{values: values}, key), do: List.keymember?(values, key, 0)
  defp has?(map, key), do: Map.has_key?(map, key)

  defp entries(%OrderedObject{values: values}), do: values
  defp entries(map) when is_map(map) and not is_struct(map), do: Enum.to_list(map)
  defp entries(_other), do: nil

  defp node_module!(id, type) do
    Enum.find_value(@node_types, fn {name, module} -> name == type && module end) ||
      raise ArgumentError,
            "Node '#{id}' has unknown type '#{type}'. Expected one of: " <>
              "#{Enum.map_join(@node_types, ", ", &elem(&1, 0))}."
  end

  # deepeval's _collect_referenced_ids.
  defp referenced_ids(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn {_id, spec}, referenced ->
      referenced
      |> MapSet.union(MapSet.new(spec["children"] || []))
      |> MapSet.union(MapSet.new(child_ref(spec["child"])))
    end)
  end

  defp child_ref(%{} = child) do
    if child["type"] == "node" and is_binary(child["ref"]), do: [child["ref"]], else: []
  end

  defp child_ref(_none), do: []

  defp build(id, specs, stack, built) do
    cond do
      Map.has_key?(built, id) ->
        {built[id], built}

      id in stack ->
        raise ArgumentError, "Cycle detected in JSON refs involving node '#{id}'."

      not Map.has_key?(specs, id) ->
        raise ArgumentError, "Reference to unknown node id '#{id}'."

      true ->
        spec = specs[id]
        stack = [id | stack]
        {node, built} = build_node(node_module!(id, spec["type"]), spec, specs, stack, built)
        {node, Map.put(built, id, node)}
    end
  end

  defp build_node(VerdictNode, spec, specs, stack, built) do
    verdict = required!(spec, "verdict")

    if spec["score"] != nil do
      {VerdictNode.new(verdict: verdict, score: spec["score"]), built}
    else
      {child, built} = build_child(spec["child"], specs, stack, built)
      {VerdictNode.new(verdict: verdict, child: child), built}
    end
  end

  defp build_node(module, spec, specs, stack, built) do
    {children, built} =
      Enum.map_reduce(spec["children"] || [], built, &build(&1, specs, stack, &2))

    {module.new([children: children] ++ node_options(module, spec)), built}
  end

  # deepeval's _task_kwargs and _judgement_kwargs.
  defp node_options(TaskNode, spec) do
    [
      instructions: required!(spec, "instructions"),
      output_label: required!(spec, "output_label")
    ] ++ shared_options(spec)
  end

  defp node_options(_judgement, spec),
    do: [criteria: required!(spec, "criteria")] ++ shared_options(spec)

  defp shared_options(spec),
    do: [label: spec["label"], evaluation_params: params!(spec["evaluation_params"])]

  defp required!(spec, key) do
    if has?(spec, key),
      do: spec[key],
      else: raise(ArgumentError, "Node spec is missing '#{key}'.")
  end

  defp params!(nil), do: nil

  defp params!(names) do
    by_name = Map.new(SingleTurn.all(), &{Atom.to_string(&1), &1})

    Enum.map(names, fn name ->
      Map.get(by_name, name) ||
        raise ArgumentError,
              "Unknown evaluation_param '#{name}'. Expected one of: " <>
                "#{Enum.map_join(SingleTurn.all(), ", ", &Atom.to_string/1)}."
    end)
  end

  # deepeval's _build_verdict child half.
  defp build_child(nil, _specs, _stack, _built),
    do: raise(ArgumentError, "VerdictNode spec must have either 'score' or 'child'.")

  defp build_child(child, specs, stack, built) do
    if not (object?(child) and has?(child, "type")),
      do: raise(ArgumentError, "VerdictNode 'child' must be an object with a 'type' field.")

    case child["type"] do
      "node" ->
        build(node_ref!(child), specs, stack, built)

      "geval" ->
        {build_geval(child), built}

      "metric" ->
        {build_metric(child), built}

      type ->
        raise ArgumentError,
              "VerdictNode child has unknown type '#{type}'. Expected one of: " <>
                "#{Enum.join(@child_types, ", ")}."
    end
  end

  defp node_ref!(child) do
    case child["ref"] do
      ref when is_binary(ref) -> ref
      _none -> raise ArgumentError, "VerdictNode child of type 'node' requires 'ref'."
    end
  end

  # deepeval's _build_geval: GEval(**kwargs).
  defp build_geval(child) do
    child
    |> entries()
    |> Enum.reject(fn {key, value} -> key in ["type", "async_mode"] or value == nil end)
    |> Enum.map(fn
      {"evaluation_params", names} -> {:evaluation_params, params!(names)}
      {"_include_g_eval_suffix", suffix?} -> {:include_g_eval_suffix, suffix?}
      {"rubric", rubric} -> {:rubric, Enum.map(rubric, &rubric/1)}
      {key, value} -> {geval_option!(key), value}
    end)
    |> GEval.new()
  end

  @geval_options ~w(name criteria evaluation_steps threshold top_logprobs strict_mode verbose_mode flaky)

  defp geval_option!(key) when key in @geval_options, do: String.to_existing_atom(key)
  defp geval_option!(key), do: raise(ArgumentError, "GEval got an unexpected argument '#{key}'.")

  defp rubric(spec) do
    {low, high} =
      case spec["score_range"] do
        [low, high] -> {low, high}
        {low, high} -> {low, high}
      end

    Rubric.new!(score_range: {low, high}, expected_outcome: spec["expected_outcome"])
  end

  # deepeval's _build_metric: the class with its kwargs.
  defp build_metric(child) do
    class = child["metric_class"]

    if not (is_binary(class) and class != ""),
      do: raise(ArgumentError, "Metric child requires a non-empty 'metric_class' field.")

    module = metric_module(class)

    opts =
      for {key, value} <- entries(child["kwargs"]) || [],
          key != "async_mode",
          value != nil do
        key = metric_option!(module, key)
        {key, if(key == :evaluation_params, do: params!(value), else: value)}
      end

    if function_exported?(module, :new, 1), do: module.new(opts), else: {module, opts}
  end

  defp metric_option!(module, key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              [message: "#{inspect(module)} got an unexpected argument '#{key}'."],
              __STACKTRACE__
  end

  defp metric_module(class) do
    module =
      if String.contains?(class, ".") do
        existing_module("Elixir." <> class)
      else
        name = String.replace_suffix(class, "Metric", "")
        modules = Application.spec(:deep_eval_ex, :modules) || []
        Enum.find(modules, &(Module.split(&1) == ["DeepEvalEx", "Metrics", name]))
      end

    if module && Code.ensure_loaded?(module) && function_exported?(module, :measure, 2) do
      module
    else
      raise ArgumentError,
            "Unknown metric_class '#{class}'. It must be a DeepEvalEx.Metrics module by " <>
              "deepeval's class name (e.g. 'AnswerRelevancyMetric') or a metric module by its " <>
              "Elixir name."
    end
  end

  defp existing_module(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
