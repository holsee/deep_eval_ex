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

    test "returns an already strict schema unchanged" do
      schema = MetricOutputs.GEval.reason_score_schema()

      assert StrictSchema.to_strict(schema) == schema
      assert StrictSchema.to_strict(StrictSchema.to_strict(schema)) == schema
    end

    test "is idempotent on a schema it had to rewrite" do
      schema = %{
        "type" => "object",
        "properties" => %{"reason" => %{"type" => "string"}}
      }

      strict = StrictSchema.to_strict(schema)
      assert StrictSchema.to_strict(strict) == strict
    end

    test "recurses into nullable objects and arrays whose type is a list" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "detail" => %{
            "type" => ["object", "null"],
            "properties" => %{"reason" => %{"type" => "string"}}
          },
          "verdicts" => %{
            "type" => ["array", "null"],
            "items" => %{
              "type" => "object",
              "properties" => %{"verdict" => %{"type" => "string"}}
            }
          }
        },
        "required" => ["detail", "verdicts"]
      }

      strict = StrictSchema.to_strict(schema)

      assert strict["properties"]["detail"]["additionalProperties"] == false
      assert strict["properties"]["detail"]["required"] == ["reason"]
      assert strict["properties"]["verdicts"]["items"]["additionalProperties"] == false
      assert strict["properties"]["verdicts"]["items"]["required"] == ["verdict"]
    end

    test "recurses into $defs and definitions" do
      schema = %{
        "type" => "object",
        "properties" => %{"verdict" => %{"$ref" => "#/$defs/Verdict"}},
        "required" => ["verdict"],
        "$defs" => %{
          "Verdict" => %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}}
        },
        "definitions" => %{
          "Claim" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
        }
      }

      strict = StrictSchema.to_strict(schema)

      assert strict["$defs"]["Verdict"]["additionalProperties"] == false
      assert strict["$defs"]["Verdict"]["required"] == ["reason"]
      assert strict["definitions"]["Claim"]["additionalProperties"] == false
      assert strict["definitions"]["Claim"]["required"] == ["text"]
      assert strict["properties"]["verdict"] == %{"$ref" => "#/$defs/Verdict"}
    end

    test "recurses into allOf and oneOf branches" do
      branch = %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}}}
      schema = %{"allOf" => [branch], "oneOf" => [branch, %{"type" => "string"}]}

      strict = StrictSchema.to_strict(schema)
      strict_branch = StrictSchema.to_strict(branch)

      assert strict_branch["additionalProperties"] == false
      assert strict["allOf"] == [strict_branch]
      assert strict["oneOf"] == [strict_branch, %{"type" => "string"}]
    end

    test "rejects a free-form dictionary object instead of closing it" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "scores" => %{"type" => "object", "additionalProperties" => %{"type" => "number"}}
        },
        "required" => ["scores"]
      }

      assert_raise ArgumentError, ~r/strict mode cannot express.*additionalProperties/s, fn ->
        StrictSchema.to_strict(schema)
      end
    end

    test "rejects an object that explicitly allows additional properties" do
      schema = %{
        "type" => "object",
        "properties" => %{"reason" => %{"type" => "string"}},
        "additionalProperties" => true
      }

      assert_raise ArgumentError, ~r/additionalProperties/, fn ->
        StrictSchema.to_strict(schema)
      end
    end

    test "rejects a schema with atom keys" do
      schema = %{type: "object", properties: %{reason: %{type: "string"}}}

      assert_raise ArgumentError, ~r/string keys/, fn -> StrictSchema.to_strict(schema) end
    end
  end

  describe "built-in metric schemas" do
    @schemas [
      {MetricOutputs.AnswerRelevancy, [:statements_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.ArgumentCorrectness, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.Bias, [:opinions_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.ContextualPrecision, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.ContextualRecall, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.ContextualRelevancy, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.Faithfulness,
       [:claims_schema, :truths_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.GEval, [:steps_schema, :reason_score_schema]},
      {MetricOutputs.Hallucination, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.PIILeakage, [:extracted_pii_schema, :verdicts_schema, :reason_schema]},
      {MetricOutputs.PromptAlignment, [:verdicts_schema, :reason_schema]},
      {MetricOutputs.ToolCorrectness, [:tool_selection_score_schema]},
      {MetricOutputs.Toxicity, [:opinions_schema, :verdicts_schema, :reason_schema]}
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
