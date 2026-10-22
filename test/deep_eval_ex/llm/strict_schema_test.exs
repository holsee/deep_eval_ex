defmodule DeepEvalEx.LLM.StrictSchemaTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.LLM.StrictSchema
  alias DeepEvalEx.Schemas.MetricOutputs

  # OpenAI strict structured outputs reject any object schema that is open
  # (additionalProperties not false) or that leaves a property out of
  # `required`. Returns the paths that break either rule.
  defp strict_violations(%{"type" => "object"} = schema, path) do
    props = Map.get(schema, "properties", %{})

    own =
      [
        schema["additionalProperties"] != false && "#{path}: additionalProperties",
        Enum.sort(Map.get(schema, "required", [])) != Enum.sort(Map.keys(props)) &&
          "#{path}: required"
      ]
      |> Enum.filter(& &1)

    own ++ Enum.flat_map(props, fn {key, prop} -> strict_violations(prop, "#{path}.#{key}") end)
  end

  defp strict_violations(%{"type" => types} = schema, path) when is_list(types) do
    strict_violations(%{schema | "type" => hd(types -- ["null"])}, path)
  end

  defp strict_violations(%{"type" => "array", "items" => items}, path),
    do: strict_violations(items, path <> "[]")

  defp strict_violations(_schema, _path), do: []

  describe "to_strict/1" do
    test "closes objects and requires every property" do
      schema = %{
        "type" => "object",
        "properties" => %{"verdict" => %{"type" => "string"}},
        "required" => ["verdict"]
      }

      assert StrictSchema.to_strict(schema) == %{
               "type" => "object",
               "properties" => %{"verdict" => %{"type" => "string"}},
               "required" => ["verdict"],
               "additionalProperties" => false
             }
    end

    test "makes optional properties required but nullable" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["yes", "no"]},
          "reason" => %{"type" => "string", "description" => "Why"}
        },
        "required" => ["verdict"]
      }

      strict = StrictSchema.to_strict(schema)

      assert Enum.sort(strict["required"]) == ["reason", "verdict"]
      assert strict["properties"]["verdict"] == %{"type" => "string", "enum" => ["yes", "no"]}

      assert strict["properties"]["reason"] == %{
               "type" => ["string", "null"],
               "description" => "Why"
             }
    end

    test "adds null to the enum of an optional enum property" do
      schema = %{
        "type" => "object",
        "properties" => %{"verdict" => %{"type" => "string", "enum" => ["yes", "no"]}}
      }

      assert StrictSchema.to_strict(schema)["properties"]["verdict"] == %{
               "type" => ["string", "null"],
               "enum" => ["yes", "no", nil]
             }
    end

    test "recurses into array items and nested objects" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "verdicts" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{"reason" => %{"type" => "string"}}
            }
          }
        },
        "required" => ["verdicts"]
      }

      strict = StrictSchema.to_strict(schema)
      assert strict_violations(strict, "root") == []

      assert strict["properties"]["verdicts"]["items"]["properties"]["reason"]["type"] ==
               ["string", "null"]
    end

    test "leaves an already strict schema unchanged" do
      schema = MetricOutputs.GEval.reason_score_schema()

      assert StrictSchema.to_strict(StrictSchema.to_strict(schema)) ==
               StrictSchema.to_strict(schema)
    end
  end

  describe "built-in metric schemas" do
    @schemas [
      {MetricOutputs.AnswerRelevancy, [:statements_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.ContextualPrecision, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.ContextualRecall, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.Faithfulness,
       [:claims_schema, :truths_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.GEval, [:steps_schema, :reason_score_schema]},
      {MetricOutputs.Hallucination, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.ToolCorrectness, [:tool_selection_score_schema]}
    ]

    test "all satisfy OpenAI strict mode once converted" do
      for {module, functions} <- @schemas, function <- functions do
        schema = apply(module, function, [])
        path = "#{inspect(module)}.#{function}"
        assert strict_violations(StrictSchema.to_strict(schema), path) == []
      end
    end
  end
end
