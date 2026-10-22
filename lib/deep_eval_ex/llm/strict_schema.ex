defmodule DeepEvalEx.LLM.StrictSchema do
  @moduledoc """
  Converts a JSON schema to the form OpenAI's strict structured outputs accept.

  With `strict: true`, OpenAI rejects any object schema that allows extra
  properties or leaves a property out of `required`. deepeval meets this
  through pydantic, where an `Optional` field becomes required but nullable;
  this module applies the same rewrite to plain JSON schemas, so metric and
  custom schemas can keep marking fields as optional:

  - every object gets `"additionalProperties" => false`
  - every property is listed in `required`
  - a property that was optional becomes nullable (`"null"` is added to its
    type, and `nil` to its enum)

  Arrays, nested objects and `anyOf` branches are converted recursively.
  The response then carries `null` where the model had nothing to say, which
  reads the same as a missing key through `Map.get/2`.
  """

  @doc """
  Returns `schema` rewritten for OpenAI strict mode.

  An already strict schema is returned unchanged.
  """
  @spec to_strict(map()) :: map()
  def to_strict(%{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    optional = properties |> Map.keys() |> Enum.reject(&(&1 in required)) |> Enum.sort()

    properties =
      Map.new(properties, fn {key, property} ->
        property = to_strict(property)
        {key, if(key in optional, do: nullable(property), else: property)}
      end)

    schema
    |> Map.put("properties", properties)
    |> Map.put("required", required ++ optional)
    |> Map.put("additionalProperties", false)
  end

  def to_strict(%{"type" => "array", "items" => items} = schema),
    do: %{schema | "items" => to_strict(items)}

  def to_strict(%{"anyOf" => branches} = schema),
    do: %{schema | "anyOf" => Enum.map(branches, &to_strict/1)}

  def to_strict(schema), do: schema

  defp nullable(%{"type" => types} = schema) when is_list(types) do
    schema |> Map.put("type", Enum.uniq(types ++ ["null"])) |> nullable_enum()
  end

  defp nullable(%{"type" => type} = schema) do
    schema |> Map.put("type", [type, "null"]) |> nullable_enum()
  end

  defp nullable(%{"anyOf" => branches} = schema) do
    if Enum.any?(branches, &(&1 == %{"type" => "null"})),
      do: schema,
      else: %{schema | "anyOf" => branches ++ [%{"type" => "null"}]}
  end

  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  defp nullable_enum(%{"enum" => values} = schema) do
    if nil in values, do: schema, else: %{schema | "enum" => values ++ [nil]}
  end

  defp nullable_enum(schema), do: schema
end
