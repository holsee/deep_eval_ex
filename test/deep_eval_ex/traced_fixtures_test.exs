defmodule DeepEvalEx.TracedFixturesTest do
  @moduledoc """
  Checks the structure of the traced fixtures of
  `test/fixtures/deepeval/traced/` (see the fixtures' README), which record
  what deepeval 4.3.1 makes of agent scripts run through `@observe`: the
  TraceApi it would post, the nested trace dict and compact trace its trace
  metrics read, and the test runs of its sync and async `evals_iterator`.

  Nothing is compared with DeepEvalEx here: these tests keep the fixtures
  loadable and consistent, and check
  `DeepEvalEx.Test.TracedFixtures.normalise/1`.
  `DeepEvalEx.Tracing.CaptureParityTest` compares DeepEvalEx's captured
  span trees with them.
  """

  use ExUnit.Case, async: true

  alias DeepEvalEx.Test.TracedFixtures
  alias Jason.OrderedObject

  @moduletag :parity

  @scenarios TracedFixtures.scenarios()

  for scenario <- @scenarios,
      file <- ~w(input.json trace_api.json nested.json compact.json test_run_sync.json
                 test_run_async.json prompts_sync.json prompts_async.json) do
    @external_resource Path.join([TracedFixtures.dir(), scenario, file])
  end

  @external_resource Path.join(TracedFixtures.dir(), "iso_table.json")

  # The scenarios of `scripts/parity/generate_fixtures.py traced`.
  @expected ~w(
    dropped_span errored_trace function_kwargs llm_prompt_fields metrics_without_input
    nested_spans next_span_staging plan_adherence plan_quality provider_normalisation
    raised_caught raised_uncaught
    requires_trace span_test_case trace_metrics two_top_level
  )

  @buckets ~w(baseSpans agentSpans llmSpans retrieverSpans toolSpans)
  @span_types [nil, "agent", "llm", "retriever", "tool"]
  @steps ~w(call update_current_span update_current_trace update_llm_span update_agent_span
            update_tool_span update_retriever_span with drop_current_span raise)

  # compact_trace's _TRACE_SPAN_KEYS, in order.
  @compact_keys ~w(name type description input output error model retrieval_context context
                   expected_output tools_called expected_tools available_tools agent_handoffs)

  defp load(scenario, file), do: TracedFixtures.load!(scenario, file)

  defp plain(%OrderedObject{values: values}), do: Map.new(values, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  defp keys(%OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  defp spans(trace), do: Enum.flat_map(@buckets, &(trace[&1] || []))

  defp nested_spans(span), do: [span | Enum.flat_map(span["children"], &nested_spans/1)]

  # Every step of a body, those inside `with` blocks included.
  defp steps(body), do: Enum.flat_map(body, &[&1 | steps(&1["body"] || [])])

  defp metric_specs(input) do
    function_specs =
      Enum.flat_map(input["functions"], fn {_name, function} ->
        (function["metrics"] || []) ++
          Enum.flat_map(steps(function["body"] || []), &((&1["kwargs"] || %{})["metrics"] || []))
      end)

    input["metrics"] ++ function_specs
  end

  test "covers every scenario of the fixture script" do
    assert @scenarios == Enum.sort(@expected)
  end

  for scenario <- @scenarios do
    describe scenario do
      setup do
        input = plain(load(unquote(scenario), "input.json"))
        %{input: input, traces: load(unquote(scenario), "trace_api.json")}
      end

      test "has its files", %{input: input} do
        judged? =
          Enum.any?(
            metric_specs(input),
            &(&1["kind"] in ~w(task_completion step_efficiency plan_quality plan_adherence))
          )

        expected =
          ~w(input.json trace_api.json nested.json compact.json) ++
            Enum.map(input["modes"], &"test_run_#{&1}.json") ++
            if(judged?, do: Enum.map(input["modes"], &"prompts_#{&1}.json"), else: [])

        assert [TracedFixtures.dir(), unquote(scenario)]
               |> Path.join()
               |> File.ls!()
               |> Enum.sort() ==
                 Enum.sort(expected)
      end

      test "describes an agent script", %{input: input} do
        assert is_binary(input["description"])
        assert [_ | _] = input["goldens"]
        assert Enum.all?(input["goldens"], &is_binary(&1["input"]))
        assert [_ | _] = input["modes"]
        assert input["modes"] -- ~w(sync async) == []

        functions = input["functions"]

        for {name, function} <- functions do
          assert function["type"] in @span_types, name
          assert Enum.all?(function["params"] || [], &match?([_ | _], &1)), name
        end

        for step <- steps(input["app"] ++ Enum.flat_map(functions, &(elem(&1, 1)["body"] || []))) do
          assert [_ | _] = Map.keys(step) -- ~w(args kwargs as catch body)
          assert Enum.any?(@steps, &Map.has_key?(step, &1)), inspect(step)
          if step["call"], do: assert(Map.has_key?(functions, step["call"]), step["call"])
        end
      end

      test "records one trace per top-level call", %{input: input, traces: traces} do
        count = length(input["goldens"]) * length(input["app"])
        assert length(traces) == count
        assert length(load(unquote(scenario), "nested.json")) == count
        assert length(load(unquote(scenario), "compact.json")) == count
      end

      test "exports well-formed traces outside evaluation", %{traces: traces} do
        for trace <- traces do
          assert trace["environment"] == "development"
          assert trace["status"] in ~w(SUCCESS ERRORED)
          spans = spans(trace)
          uuids = Enum.map(spans, & &1["uuid"])
          assert uuids == Enum.uniq(uuids)
          assert [_root] = Enum.filter(spans, &(&1["parentUuid"] == nil))

          for span <- spans do
            assert span["status"] in ~w(SUCCESS ERRORED)
            assert span["parentUuid"] in [nil | uuids]
            assert "#{span["type"]}Spans" in @buckets
          end
        end
      end

      test "nests and compacts every exported span", %{traces: traces} do
        nested = load(unquote(scenario), "nested.json")
        compact = load(unquote(scenario), "compact.json")

        for {trace, root, compact_root} <- Enum.zip([traces, nested, compact]) do
          names = root |> nested_spans() |> Enum.map(& &1["name"])
          # A dropped span is nested but not exported.
          assert Enum.map(spans(trace), & &1["name"]) -- names == []
          check_compact(root, compact_root)
        end
      end

      for mode <- ~w(sync async) do
        test "exports a test case per #{if mode == "sync", do: "golden", else: "trace"} in #{mode}",
             %{input: input} do
          if unquote(mode) in input["modes"] do
            test_run = load(unquote(scenario), "test_run_#{unquote(mode)}.json")

            per_golden = if unquote(mode) == "sync", do: 1, else: length(input["app"])
            assert length(test_run["testCases"]) == length(input["goldens"]) * per_golden

            for test_case <- test_run["testCases"] do
              assert %OrderedObject{} = trace = test_case["trace"]
              assert Enum.all?(@buckets, &is_list(trace[&1]))
            end

            scores = test_run["traceMetricsScores"]
            assert match?(%OrderedObject{}, scores) or scores == nil
          end
        end
      end

      test "normalises its files", %{input: input} do
        files =
          ~w(trace_api.json nested.json compact.json) ++
            Enum.map(input["modes"], &"test_run_#{&1}.json")

        for file <- files do
          normalised = TracedFixtures.normalise(TracedFixtures.read!(unquote(scenario), file))
          refute normalised =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-/
          assert TracedFixtures.decode!(normalised)
        end
      end
    end
  end

  # compact_trace keeps _TRACE_SPAN_KEYS in order, drops None, [] and "",
  # and nests the children it has.
  defp check_compact(nested, compact) do
    assert keys(compact) -- ["children"] ==
             Enum.filter(@compact_keys, &(nested[&1] not in [nil, [], ""]))

    assert length(compact["children"] || []) == length(nested["children"])

    for {child, compact_child} <- Enum.zip(nested["children"], compact["children"] || []) do
      check_compact(child, compact_child)
    end
  end

  describe "normalise/1" do
    @span ~s({"uuid": "6f1c2a8e-3b4d-4e5f-8a6b-7c8d9e0f1a2b", "startTime": "2026-10-23T03:17:08.044Z", ) <>
            ~s("endTime": "2026-10-23T03:17:08.045Z"})

    test "numbers uuids by first appearance, keeping links" do
      json =
        ~s({"uuid": "aaaaaaaa-1111-4111-8111-111111111111", "children": [{"uuid": ) <>
          ~s("bbbbbbbb-2222-4222-9222-222222222222", "parentUuid": ) <>
          ~s("aaaaaaaa-1111-4111-8111-111111111111"}]})

      assert TracedFixtures.normalise(json) ==
               ~s({"uuid": "<uuid-1>", "children": [{"uuid": "<uuid-2>", "parentUuid": "<uuid-1>"}]})
    end

    test "replaces span times, token interval keys and run durations" do
      json =
        ~s({"startTime": "2026-10-23T03:17:08.044Z", "endTime": "2026-10-23T03:17:08.044Z", ) <>
          ~s("tokenIntervals": {"2026-10-23T03:17:08.044001Z": "Hel", ) <>
          ~s("2026-10-23T03:17:08.044002Z": "lo"}, "runDuration": 0.000123})

      assert TracedFixtures.normalise(json) ==
               ~s({"startTime": "<timestamp>", "endTime": "<timestamp>", ) <>
                 ~s("tokenIntervals": {"<timestamp-us-1>": "Hel", "<timestamp-us-2>": "lo"}, ) <>
                 ~s("runDuration": "<normalised>"})
    end

    test "leaves a span with good times as it is otherwise" do
      assert TracedFixtures.normalise(@span) ==
               ~s({"uuid": "<uuid-1>", "startTime": "<timestamp>", "endTime": "<timestamp>"})
    end

    test "raises on a time deepeval does not write" do
      for bad <- ["2026-10-23T03:17:08.0445Z", "2026-10-23T03:17:08.044+00:00", "2026-10-23"] do
        assert_raise ArgumentError, ~r/not a to_zod_compatible_iso time/, fn ->
          TracedFixtures.normalise(String.replace(@span, "2026-10-23T03:17:08.044Z", bad))
        end
      end

      assert_raise ArgumentError, ~r/not a to_zod_compatible_iso time/, fn ->
        TracedFixtures.normalise(~s({"startTime": "2026-10-23T03:17:08.044Z"}))
      end

      assert_raise ArgumentError, ~r/tokenIntervals/, fn ->
        TracedFixtures.normalise(~s({"tokenIntervals": {"2026-10-23T03:17:08.044Z": "x"}}))
      end
    end

    test "raises on a span that ends before it starts" do
      json = String.replace(@span, "08.045Z", "08.043Z")

      assert_raise ArgumentError, ~r/ends .* before it starts/, fn ->
        TracedFixtures.normalise(json)
      end
    end

    test "raises on a time anywhere else" do
      assert_raise ArgumentError, ~r/a time outside/, fn ->
        TracedFixtures.normalise(~s({"metadata": {"at": "2026-10-23T03:17:08.044Z"}}))
      end
    end
  end

  describe "iso_table.json" do
    setup do
      rows =
        [TracedFixtures.dir(), "iso_table.json"] |> Path.join() |> File.read!() |> Jason.decode!()

      %{rows: rows}
    end

    test "covers truncation edges up to the last datetime", %{rows: rows} do
      epochs = Enum.map(rows, & &1["epoch_us"])
      assert epochs == Enum.sort(epochs)
      assert 999_500 in epochs and 999_999 in epochs
      assert List.last(rows)["milliseconds"] == "9999-12-31T23:59:59.999Z"
    end

    test "truncates to milliseconds and keeps microseconds, in UTC with a Z", %{rows: rows} do
      for %{"epoch_us" => us, "milliseconds" => millis, "microseconds" => micros} <- rows do
        datetime = DateTime.from_unix!(us, :microsecond)
        assert millis == datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
        assert micros == DateTime.to_iso8601(datetime)
      end
    end
  end
end
