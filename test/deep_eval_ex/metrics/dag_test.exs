# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.DAGTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.Adapters.Mock
  alias DeepEvalEx.Metrics.{DAG, ExactMatch, GEval}

  alias DeepEvalEx.Metrics.DAG.{
    BinaryJudgementNode,
    Graph,
    NonBinaryJudgementNode,
    TaskNode,
    VerdictNode
  }

  alias DeepEvalEx.SystemOne.Adapters.Mock, as: SystemOneMock
  alias DeepEvalEx.Test.ScriptedParity
  alias DeepEvalEx.TestCase
  alias DeepEvalEx.TestRun.JSON

  @moduletag :capture_log

  doctest DeepEvalEx.Metrics.DAG.Node
  doctest DeepEvalEx.Schemas.MetricOutputs.DAG

  @scripted ~w(dag_fail dag_geval_child dag_multiple_roots dag_pass dag_strict)

  for scenario <- @scripted do
    @external_resource ScriptedParity.fixture(scenario, "dag.json")
  end

  defp test_case(attrs \\ []) do
    TestCase.new!(
      Keyword.merge(
        [
          input: "Summarise the meeting.",
          actual_output: "Intro: Plan.\nBody: QA.\nConclusion: May."
        ],
        attrs
      )
    )
  end

  # Extract -> has all headings? -> (no: 0 | yes: 10)
  defp headings_dag do
    judge =
      [criteria: "Are all three headings there?"]
      |> BinaryJudgementNode.new()
      |> BinaryJudgementNode.add_verdict(false, score: 0)
      |> BinaryJudgementNode.add_verdict(true, score: 10)

    extract =
      TaskNode.new(
        instructions: "Extract the headings.",
        output_label: "Headings",
        evaluation_params: [:actual_output],
        children: [judge]
      )

    Graph.new([extract])
  end

  describe "VerdictNode.new/1" do
    test "takes a score from 0 to 10 or a child, not both and not neither" do
      assert %VerdictNode{verdict: true, score: 10} = VerdictNode.new(verdict: true, score: 10)

      assert_raise ArgumentError,
                   "A VerdictNode can have either a 'score' or a 'child', but not both.",
                   fn -> VerdictNode.new(verdict: true, score: 1, child: ExactMatch) end

      assert_raise ArgumentError, "A VerdictNode must have either a 'score' or a 'child'.", fn ->
        VerdictNode.new(verdict: true)
      end

      assert_raise ArgumentError, "The score must be between 0 and 10, inclusive.", fn ->
        VerdictNode.new(verdict: "x", score: 11)
      end
    end
  end

  describe "node validation" do
    test "a TaskNode's children are nodes other than verdicts" do
      assert_raise ArgumentError,
                   "A TaskNode must not have a VerdictNode as one of their 'children'.",
                   fn ->
                     TaskNode.new(
                       instructions: "i",
                       output_label: "o",
                       children: [VerdictNode.new(verdict: true, score: 1)]
                     )
                   end

      assert_raise ArgumentError, "A TaskNode's children must be BaseNode instances.", fn ->
        TaskNode.new(instructions: "i", output_label: "o", children: [ExactMatch])
      end
    end

    test "a BinaryJudgementNode has one true and one false verdict" do
      assert_raise ArgumentError, "BinaryJudgementNode must have exactly 2 children.", fn ->
        BinaryJudgementNode.new(
          criteria: "c",
          children: [VerdictNode.new(verdict: true, score: 1)]
        )
      end

      assert_raise ArgumentError,
                   "All children BinaryJudgementNode must have a boolean verdict.",
                   fn ->
                     BinaryJudgementNode.new(
                       criteria: "c",
                       children: [
                         VerdictNode.new(verdict: true, score: 1),
                         VerdictNode.new(verdict: "no", score: 0)
                       ]
                     )
                   end

      assert_raise ArgumentError,
                   "BinaryJudgementNode must have one True and one False VerdictNode child.",
                   fn ->
                     BinaryJudgementNode.new(
                       criteria: "c",
                       children: [
                         VerdictNode.new(verdict: true, score: 1),
                         VerdictNode.new(verdict: true, score: 0)
                       ]
                     )
                   end
    end

    test "a NonBinaryJudgementNode has distinct string verdicts" do
      node =
        [criteria: "c"]
        |> NonBinaryJudgementNode.new()
        |> NonBinaryJudgementNode.add_verdict("a", score: 1)
        |> NonBinaryJudgementNode.add_verdict("a", score: 2)

      assert_raise ArgumentError,
                   "Duplicate verdict found: a in children of NonBinaryJudgementNode.",
                   fn -> Graph.new([node]) end

      assert_raise ArgumentError, "NonBinaryJudgementNode must have at least one child.", fn ->
        Graph.new([NonBinaryJudgementNode.new(criteria: "c")])
      end
    end
  end

  describe "Graph.new/1" do
    test "rejects a judgement root among several roots" do
      task = TaskNode.new(instructions: "i", output_label: "o", evaluation_params: [:input])
      judge = headings_dag().root_nodes |> hd() |> Map.fetch!(:children) |> hd()

      assert_raise ArgumentError,
                   "You cannot provide more than one root node when a BinaryJudgementNode " <>
                     "or NonBinaryJudgementNode is a root.",
                   fn -> Graph.new([task, judge]) end
    end

    test "rejects a root reachable from another root" do
      [extract] = headings_dag().root_nodes
      second = TaskNode.new(instructions: "i", output_label: "o", children: [extract])

      assert_raise ArgumentError,
                   "You cannot declare a node as a root node when it is also reachable " <>
                     "from another root node.",
                   fn -> Graph.new([second, extract]) end
    end

    test "detects a cycle made by adding a node to its own descendant" do
      task = TaskNode.new(instructions: "i", output_label: "o", evaluation_params: [:input])

      judge =
        [criteria: "c"]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true, then: task)
        |> BinaryJudgementNode.add_verdict(false, score: 0)

      assert_raise ArgumentError, "Cycle detected in DAG graph.", fn ->
        Graph.new([TaskNode.add_node(task, judge)])
      end
    end

    test "rejects two versions of one node" do
      task = TaskNode.new(instructions: "i", output_label: "o", evaluation_params: [:input])
      [extract] = headings_dag().root_nodes
      grown = TaskNode.add_node(task, hd(extract.children))
      root = TaskNode.new(instructions: "r", output_label: "R", children: [task, grown])

      assert_raise ArgumentError, ~r/appears in two versions/, fn -> Graph.new([root]) end
    end

    test "lists the evaluation params of the nodes before any verdict, in order" do
      nested =
        [criteria: "c", evaluation_params: [:expected_output]]
        |> NonBinaryJudgementNode.new()
        |> NonBinaryJudgementNode.add_verdict("x", score: 1)

      judge =
        [criteria: "c", evaluation_params: [:input, :actual_output]]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true, then: nested)
        |> BinaryJudgementNode.add_verdict(false, score: 0)

      task =
        TaskNode.new(
          instructions: "i",
          output_label: "o",
          evaluation_params: [:actual_output],
          children: [judge]
        )

      assert Graph.required_params(Graph.new([task])) == [:actual_output, :input]
    end
  end

  describe "Graph serialisation" do
    for scenario <- @scripted do
      test "writes the graph of #{scenario} as deepeval's to_dict does" do
        script = unquote(scenario) |> ScriptedParity.fixture("script.json") |> File.read!()

        dag =
          script
          |> Jason.decode!(objects: :ordered_objects)
          |> get_in(["metric", "params", "dag"])

        ours = dag |> Graph.from_map() |> Graph.to_map() |> number_ids()

        assert JSON.encode!(ours, indent: 2, ensure_ascii: false) <> "\n" ==
                 File.read!(ScriptedParity.fixture(unquote(scenario), "dag.json"))
      end
    end

    test "round-trips through JSON" do
      dag = headings_dag()
      json = Graph.to_json(dag)

      assert json =~ ~s("type": "TaskNode")

      assert dag |> Graph.to_map() |> number_ids() ==
               json |> Graph.from_json() |> Graph.to_map() |> number_ids()
    end

    test "writes metric children with their class and JSON-able options" do
      judge =
        [criteria: "c"]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true,
          then: {ExactMatch, threshold: 0.7, model: "gpt-4o"}
        )
        |> BinaryJudgementNode.add_verdict(false, score: 0)

      %{"nodes" => %Jason.OrderedObject{values: nodes}} = Graph.to_map(Graph.new([judge]))
      [_judge, {_id, true_verdict}, _false] = nodes

      assert JSON.encode!(true_verdict["child"]) ==
               ~s({"type": "metric", "metric_class": "ExactMatchMetric", "kwargs": {"threshold": 0.7}})

      rebuilt = nodes |> Jason.OrderedObject.new() |> then(&%{"nodes" => &1}) |> Graph.from_map()
      [%BinaryJudgementNode{children: [%VerdictNode{child: child}, _]}] = rebuilt.root_nodes
      assert child == {ExactMatch, threshold: 0.7}
    end

    test "raises deepeval's errors for malformed documents" do
      assert_raise ArgumentError,
                   "Invalid DAG document: expected a top-level object with a 'nodes' key.",
                   fn -> Graph.from_map(%{}) end

      assert_raise ArgumentError,
                   "Invalid DAG document: 'nodes' must be a non-empty object.",
                   fn ->
                     Graph.from_map(%{"nodes" => %{}})
                   end

      assert_raise ArgumentError,
                   "Node 'a' has unknown type 'Nope'. Expected one of: TaskNode, " <>
                     "BinaryJudgementNode, NonBinaryJudgementNode, VerdictNode.",
                   fn -> Graph.from_map(%{"nodes" => %{"a" => %{"type" => "Nope"}}}) end

      assert_raise ArgumentError, "Reference to unknown node id 'b'.", fn ->
        Graph.from_map(%{
          "nodes" => %{
            "a" => %{
              "type" => "TaskNode",
              "instructions" => "i",
              "output_label" => "o",
              "children" => ["b"]
            }
          }
        })
      end

      assert_raise ArgumentError, ~r/^No root nodes detected/, fn ->
        Graph.from_map(%{
          "nodes" => %{
            "a" => %{
              "type" => "TaskNode",
              "instructions" => "i",
              "output_label" => "o",
              "children" => ["a"]
            }
          }
        })
      end

      assert_raise ArgumentError,
                   ~r/^Unknown evaluation_param 'nope'. Expected one of: input,/,
                   fn ->
                     Graph.from_map(%{
                       "nodes" => %{
                         "a" => %{
                           "type" => "TaskNode",
                           "instructions" => "i",
                           "output_label" => "o",
                           "evaluation_params" => ["nope"]
                         }
                       }
                     })
                   end
    end
  end

  describe "metric_name/1" do
    test "carries deepeval's [DAG] suffix unless turned off" do
      assert DAG.metric_name(DAG.new(name: "Format", dag: headings_dag())) == "Format [DAG]"

      assert DAG.metric_name(
               DAG.new(name: "Format", dag: headings_dag(), include_dag_suffix: false)
             ) ==
               "Format"
    end

    test "new/1 requires a name and a graph" do
      assert_raise ArgumentError, ~r/DAG requires a :dag/, fn -> DAG.new(name: "Format") end
    end
  end

  describe "measure/2" do
    test "walks the graph with the LLM and scores the leaf it reaches" do
      Mock.script(
        %{
          "output" => [%{"output" => "Intro, Body, Conclusion"}],
          "reason,verdict" => [%{"verdict" => true, "reason" => "All there."}],
          "reason" => [%{"reason" => "Every heading is there."}]
        },
        model: "scripted-judge"
      )

      assert {:ok, result} =
               DAG.measure(test_case(), adapter: :mock, name: "Format", dag: headings_dag())

      assert result.metric == "Format [DAG]"
      assert result.score == 1.0
      assert result.success
      assert result.reason == "Every heading is there."

      assert [
               %{step: "output"},
               %{step: "reason,verdict", prompt: verdict_prompt},
               %{step: "reason"}
             ] =
               Mock.scripted_prompts()

      assert verdict_prompt =~ "Headings:\nIntro, Body, Conclusion\n\n"
    end

    test "requires the evaluation params of its nodes" do
      Mock.script(%{}, model: "scripted-judge")

      assert {:error, {:missing_params, [:actual_output]}} =
               DAG.measure(TestCase.new!(input: "x"),
                 adapter: :mock,
                 name: "Format",
                 dag: headings_dag()
               )
    end

    test "raises for a TaskNode with neither evaluation params nor parents" do
      Mock.script(%{}, model: "scripted-judge")
      task = TaskNode.new(instructions: "i", output_label: "o")

      assert_raise ArgumentError,
                   "A TaskNode must have either a 'evaluation_params' or parent node(s).",
                   fn ->
                     DAG.measure(test_case(), adapter: :mock, name: "F", dag: Graph.new([task]))
                   end
    end

    test "runs a node fed by both verdicts of one judgement once, whichever fires" do
      shared =
        TaskNode.new(
          instructions: "Summarise.",
          output_label: "Summary",
          children: [
            [criteria: "Is it short?"]
            |> BinaryJudgementNode.new()
            |> BinaryJudgementNode.add_verdict(true, score: 8)
            |> BinaryJudgementNode.add_verdict(false, score: 2)
          ]
        )

      root =
        [criteria: "Is it English?", evaluation_params: [:actual_output]]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true, then: shared)
        |> BinaryJudgementNode.add_verdict(false, then: shared)

      Mock.script(
        %{
          "reason,verdict" => [
            %{"verdict" => false, "reason" => "No."},
            %{"verdict" => true, "reason" => "Yes."}
          ],
          "output" => [%{"output" => "Short."}]
        },
        model: "scripted-judge"
      )

      assert {:ok, result} =
               DAG.measure(test_case(),
                 adapter: :mock,
                 name: "F",
                 dag: Graph.new([root]),
                 include_reason: false
               )

      assert result.score == 0.8
      assert result.reason == nil

      assert Enum.map(Mock.scripted_prompts(), & &1.step) == [
               "reason,verdict",
               "output",
               "reason,verdict"
             ]
    end

    test "hands the score to a metric child and logs its verbose logs" do
      judge =
        [criteria: "Is it an answer?", evaluation_params: [:actual_output]]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true, then: ExactMatch)
        |> BinaryJudgementNode.add_verdict(false, score: 0)

      Mock.script(%{"reason,verdict" => [%{"verdict" => true, "reason" => "Yes."}]},
        model: "scripted-judge"
      )

      assert {:ok, result} =
               DAG.measure(test_case(expected_output: "Paris", actual_output: "Paris"),
                 adapter: :mock,
                 name: "F",
                 dag: Graph.new([judge])
               )

      assert result.score == 1.0
      assert result.reason == "The actual and expected outputs are exact matches."
      assert result.verbose_logs =~ "Type: Exact Match Metric"
    end

    test "rebuilds a GEval child with the DAG's judge" do
      geval =
        GEval.new(
          name: "Tone",
          criteria: "Is it polite?",
          evaluation_params: [:actual_output],
          model: "other"
        )

      judge =
        [criteria: "Is it an answer?", evaluation_params: [:actual_output]]
        |> BinaryJudgementNode.new()
        |> BinaryJudgementNode.add_verdict(true, then: geval)
        |> BinaryJudgementNode.add_verdict(false, score: 0)

      Mock.script(
        %{
          "reason,verdict" => [%{"verdict" => true, "reason" => "Yes."}],
          "steps" => [%{"steps" => ["Check the tone."]}],
          "reason,score" => [%{"reason" => "Polite.", "score" => 7}]
        },
        model: "scripted-judge"
      )

      assert {:ok, result} =
               DAG.measure(test_case(), adapter: :mock, name: "F", dag: Graph.new([judge]))

      assert result.score == 0.7
      assert result.evaluation_model == "scripted-judge"
      assert result.verbose_logs =~ "Type: Tone [GEval] Metric\n\nCriteria:\nIs it polite?\n"
    end

    test "under hybrid asks System One for each judgement" do
      Mock.script(
        %{"output" => [%{"output" => "Intro"}], "reason" => [%{"reason" => "Missing."}]},
        model: "scripted-judge"
      )

      system_one = SystemOneMock.new(answer_fn: SystemOneMock.noul_answers(0.2))

      assert {:ok, result} =
               DAG.measure(test_case(),
                 adapter: :mock,
                 name: "F",
                 dag: headings_dag(),
                 eval_mode: :system_one,
                 system_one_model: system_one
               )

      assert result.score == 0.0
      assert result.confidence == 0.6
      assert result.verbose_logs =~ "Verdict: False\nReason: P(true)=0.20\n"
      assert [%SystemOneMock.Call{state: state}] = SystemOneMock.calls(system_one)
      assert JSON.encode!(state) == ~s({"text": "Headings:\\nIntro\\n\\n"})
    end
  end

  # deepeval's dag.json numbers the nodes in to_dict's order; ours have
  # random uuids.
  defp number_ids(%{"nodes" => %Jason.OrderedObject{values: nodes}}) do
    ids = nodes |> Enum.with_index() |> Map.new(fn {{id, _}, i} -> {id, "node_#{i}"} end)

    renumbered =
      for {id, node} <- nodes do
        node =
          node
          |> update_ordered("children", &Enum.map(&1, fn child -> ids[child] end))
          |> update_ordered("child", fn
            %Jason.OrderedObject{} = child -> update_ordered(child, "ref", &ids[&1])
            child -> child
          end)

        {ids[id], node}
      end

    %{"nodes" => Jason.OrderedObject.new(renumbered)}
  end

  defp update_ordered(%Jason.OrderedObject{values: values}, key, fun) do
    Jason.OrderedObject.new(
      Enum.map(values, fn
        {^key, value} -> {key, fun.(value)}
        pair -> pair
      end)
    )
  end
end
