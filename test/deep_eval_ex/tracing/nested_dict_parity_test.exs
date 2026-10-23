defmodule DeepEvalEx.Tracing.NestedDictParityTest do
  @moduledoc """
  Builds the nested trace dict (`DeepEvalEx.Tracing.NestedDict`) and the
  compact trace (`DeepEvalEx.Tracing.CompactTrace`) of every trace the
  traced fixtures' agent scripts capture, and compares them byte for byte,
  after the fixtures' normalisation, with deepeval 4.3.1's
  `create_nested_spans_dict` serialised by `serialize_to_json`
  (`nested.json`) and its `compact_trace` (`compact.json`): the popped
  keys, pydantic's field order, `None` dropped, tool calls as dicts (or
  as their `str()` in the compact trace), dropped spans kept and raw
  providers.

  The nested dict leaves out metric data, so `requires_trace`, whose
  metrics are ported by later units, is compared too.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.{TracedFixtures, TracingScenarios}
  alias DeepEvalEx.TestRun.JSON
  alias DeepEvalEx.Tracing.{CompactTrace, NestedDict}

  @moduletag :parity

  for scenario <- TracedFixtures.scenarios() do
    @external_resource Path.join([TracedFixtures.dir(), scenario, "input.json"])
    @external_resource Path.join([TracedFixtures.dir(), scenario, "nested.json"])
    @external_resource Path.join([TracedFixtures.dir(), scenario, "compact.json"])

    test "builds deepeval's nested and compact traces for #{scenario}" do
      scenario = unquote(scenario)
      input = TracedFixtures.load!(scenario, "input.json")

      nested =
        for trace <- scenario |> TracingScenarios.run_app(input) |> List.flatten() do
          assert [root] = trace.root_spans
          NestedDict.build(root)
        end

      # The generator decodes serialize_to_json's text and writes it with
      # json.dump(indent=2, ensure_ascii=False).
      assert TracedFixtures.normalise(NestedDict.to_json(nested, ensure_ascii: false) <> "\n") ==
               TracedFixtures.normalise(TracedFixtures.read!(scenario, "nested.json"))

      compact =
        nested
        |> Enum.map(&CompactTrace.compact/1)
        |> JSON.encode!(indent: 2, ensure_ascii: false)

      assert TracedFixtures.normalise(compact <> "\n") ==
               TracedFixtures.normalise(TracedFixtures.read!(scenario, "compact.json"))
    end
  end
end
