# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.Utils.JSONSchemaTest do
  use ExUnit.Case, async: true

  alias DeepEvalEx.Metrics.Utils.JSONSchema
  alias Jason.OrderedObject

  doctest JSONSchema

  # pydantic's model_json_schema() of
  #
  #     class Address(BaseModel):
  #         city: str
  #         postcode: str
  #
  #     class Person(BaseModel):
  #         name: str
  #         age: int
  #         tags: List[str]
  #         address: Address
  #         nickname: Optional[str] = None
  @person ~S"""
  {
    "$defs": {
      "Address": {
        "properties": {
          "city": {"title": "City", "type": "string"},
          "postcode": {"title": "Postcode", "type": "string"}
        },
        "required": ["city", "postcode"],
        "title": "Address",
        "type": "object"
      }
    },
    "properties": {
      "name": {"title": "Name", "type": "string"},
      "age": {"title": "Age", "type": "integer"},
      "tags": {"items": {"type": "string"}, "title": "Tags", "type": "array"},
      "address": {"$ref": "#/$defs/Address"},
      "nickname": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Nickname"}
    },
    "required": ["name", "age", "tags", "address"],
    "title": "Person",
    "type": "object"
  }
  """

  defp person, do: JSONSchema.normalize!(@person)

  describe "normalize!/1" do
    test "decodes a JSON string keeping its key order" do
      assert %OrderedObject{values: [{"$defs", _}, {"properties", properties} | _]} = person()
      assert Enum.map(properties.values, &elem(&1, 0)) == ~w(name age tags address nickname)
    end

    test "turns atom keys into strings, recursively" do
      assert JSONSchema.normalize!(%{type: "object", properties: %{n: %{type: "integer"}}}) ==
               %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}
    end

    test "keeps an ordered object's order" do
      schema = %OrderedObject{values: [{"type", "object"}, {:title, "T"}]}

      assert JSONSchema.normalize!(schema) == %OrderedObject{
               values: [{"type", "object"}, {"title", "T"}]
             }
    end

    test "raises ArgumentError for a string that is not JSON or a schema that is not an object" do
      assert_raise ArgumentError, ~r/not valid JSON/, fn -> JSONSchema.normalize!("{") end
      assert_raise ArgumentError, ~r/must be a JSON object/, fn -> JSONSchema.normalize!("[]") end
      assert_raise ArgumentError, ~r/must be a JSON object/, fn -> JSONSchema.normalize!(42) end
    end
  end

  describe "validate_json/2" do
    test "accepts an output matching the schema, extra keys and an omitted optional included" do
      json =
        ~s({"name": "José", "age": 87, "tags": [], "address": {"city": "Lisbon", "postcode": "1100"}, "x": 1})

      assert JSONSchema.validate_json(json, person()) == :ok
    end

    test "accepts a float with no fractional part as an integer, as JSON Schema and pydantic do" do
      json =
        ~s({"name": "J", "age": 87.0, "tags": ["a"], "address": {"city": "L", "postcode": "P"}})

      assert JSONSchema.validate_json(json, person()) == :ok
    end

    test "reports every error, in field order, as pydantic lays its validation error out" do
      json =
        ~s({"name": "José", "age": "eighty-seven", "tags": ["writer", 1998], "address": {"city": "Lisbon"}})

      assert JSONSchema.validate_json(json, person()) ==
               {:error,
                """
                3 validation errors for Person
                age
                  Input should be a valid integer
                tags.1
                  Input should be a valid string
                address.postcode
                  Field required\
                """}
    end

    test "reports a missing required field" do
      json = ~s({"name": "J", "age": 1, "address": {"city": "L", "postcode": "P"}})

      assert JSONSchema.validate_json(json, person()) ==
               {:error, "1 validation error for Person\ntags\n  Field required"}
    end

    test "reports output that is not JSON, without a location" do
      assert {:error, "1 validation error for Person\n  Invalid JSON: " <> _} =
               JSONSchema.validate_json(~s(Sure! {"name": "J"), person())
    end

    test "reports a root of the wrong type without a location" do
      assert JSONSchema.validate_json("[]", person()) ==
               {:error, "1 validation error for Person\n  Input should be an object"}
    end

    test "names an untitled schema generically" do
      assert JSONSchema.validate_json("1", %{"type" => "string"}) ==
               {:error,
                "1 validation error for the expected schema\n  Input should be a valid string"}
    end

    test "reports the one non-null branch of an optional field" do
      json =
        ~s({"name": "J", "age": 1, "tags": [], "address": {"city": "L", "postcode": "P"}, "nickname": 3})

      assert JSONSchema.validate_json(json, person()) ==
               {:error,
                "1 validation error for Person\nnickname\n  Input should be a valid string"}
    end
  end

  describe "validate/2 keywords" do
    defp errors(value, schema) do
      schema = if is_boolean(schema), do: schema, else: JSONSchema.normalize!(schema)

      case JSONSchema.validate(value, schema) do
        :ok -> []
        {:error, errors} -> errors
      end
    end

    test "type, including a list of types" do
      assert errors(true, %{"type" => "boolean"}) == []
      assert errors(1, %{"type" => "boolean"}) == [{[], "Input should be a valid boolean"}]
      assert errors(1.5, %{"type" => "number"}) == []
      assert errors(1.5, %{"type" => "integer"}) == [{[], "Input should be a valid integer"}]
      assert errors(nil, %{"type" => ["string", "null"]}) == []

      assert errors(1, %{"type" => ["string", "null"]}) ==
               [{[], "Input should be a valid string or None"}]
    end

    test "enum and const, quoting values as Python does" do
      assert errors("red", %{"enum" => ["red", "green"]}) == []

      assert errors("blue", %{"enum" => ["red", "green", "amber"]}) ==
               [{[], "Input should be 'red', 'green' or 'amber'"}]

      assert errors(2, %{"const" => 1}) == [{[], "Input should be 1"}]
    end

    test "string length and pattern" do
      assert errors("é", %{"minLength" => 1, "maxLength" => 1}) == []
      assert errors("", %{"minLength" => 1}) == [{[], "String should have at least 1 character"}]

      assert errors("abc", %{"maxLength" => 2}) == [
               {[], "String should have at most 2 characters"}
             ]

      assert errors("ab1", %{"pattern" => "^[a-z]+$"}) == [
               {[], "String should match pattern '^[a-z]+$'"}
             ]
    end

    test "number bounds and multiples" do
      assert errors(0, %{"minimum" => 1}) == [{[], "Input should be greater than or equal to 1"}]
      assert errors(1, %{"exclusiveMinimum" => 1}) == [{[], "Input should be greater than 1"}]
      assert errors(3, %{"maximum" => 2.5}) == [{[], "Input should be less than or equal to 2.5"}]
      assert errors(2, %{"exclusiveMaximum" => 2}) == [{[], "Input should be less than 2"}]
      assert errors(7, %{"multipleOf" => 2}) == [{[], "Input should be a multiple of 2"}]
      assert errors(0.75, %{"multipleOf" => 0.25}) == []
    end

    test "arrays: items, prefixItems, length and uniqueness" do
      assert errors([1, "a"], %{"prefixItems" => [%{"type" => "integer"}, %{"type" => "string"}]}) ==
               []

      assert errors([1, 2, "x"], %{
               "prefixItems" => [%{"type" => "integer"}],
               "items" => %{"type" => "integer"}
             }) ==
               [{[2], "Input should be a valid integer"}]

      assert errors([], %{"minItems" => 1}) ==
               [{[], "List should have at least 1 item after validation, not 0"}]

      assert errors([1, 2, 3], %{"maxItems" => 2}) ==
               [{[], "List should have at most 2 items after validation, not 3"}]

      assert errors([1, 1], %{"uniqueItems" => true}) == [{[], "List should have unique items"}]
    end

    test "objects: additionalProperties" do
      closed = %{"properties" => %{"a" => %{}}, "additionalProperties" => false}
      assert errors(%{"a" => 1, "b" => 2}, closed) == [{["b"], "Extra inputs are not permitted"}]

      typed = %{"additionalProperties" => %{"type" => "integer"}}
      assert errors(%{"a" => "x"}, typed) == [{["a"], "Input should be a valid integer"}]
    end

    test "allOf, oneOf, not and boolean schemas" do
      assert errors(5, %{"allOf" => [%{"minimum" => 1}, %{"maximum" => 3}]}) ==
               [{[], "Input should be less than or equal to 3"}]

      assert errors(5, %{"oneOf" => [%{"type" => "integer"}, %{"type" => "number"}]}) ==
               [{[], "Input should match exactly one of the allowed schemas"}]

      assert errors(true, %{"anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]}) ==
               [{[], "Input should match at least one of the allowed schemas"}]

      assert errors(1, %{"not" => %{"type" => "integer"}}) ==
               [{[], "Input should not match the excluded schema"}]

      assert errors(1, true) == []
      assert errors(1, %{"properties" => %{"a" => false}}) == []

      assert errors(%{"a" => 1}, %{"properties" => %{"a" => false}}) == [
               {["a"], "Input is not permitted"}
             ]
    end

    test "$ref to $defs and definitions, recursively" do
      tree = %{
        "$defs" => %{
          "Node" => %{
            "type" => "object",
            "properties" => %{
              "children" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/Node"}}
            }
          }
        },
        "$ref" => "#/$defs/Node"
      }

      assert errors(%{"children" => [%{"children" => []}]}, tree) == []

      assert errors(%{"children" => [%{"children" => [1]}]}, tree) ==
               [{["children", 0, "children", 0], "Input should be an object"}]

      legacy = %{
        "definitions" => %{"N" => %{"type" => "integer"}},
        "items" => %{"$ref" => "#/definitions/N"}
      }

      assert errors(["x"], legacy) == [{[0], "Input should be a valid integer"}]
    end

    test "raises ArgumentError for a $ref outside the schema" do
      assert_raise ArgumentError, ~r/unsupported \$ref/, fn ->
        errors(1, %{"$ref" => "https://example.com/schema.json"})
      end
    end

    test "ignores annotations and unknown keywords" do
      assert errors("x", %{
               "title" => "T",
               "description" => "D",
               "format" => "email",
               "default" => 1
             }) ==
               []
    end
  end
end
