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

  The conversion recurses into array `items`, nested objects (including a
  nullable one typed `["object", "null"]`), `$defs` and `definitions`, and
  `anyOf`, `allOf` and `oneOf` branches, following the OpenAI SDK's
  `to_strict_json_schema`. The response then carries `null` where the model
  had nothing to say, which reads the same as a missing key through
  `Map.get/2`.

  Schemas must use string keys, as they would after decoding JSON; a schema
  with atom keys raises `ArgumentError`.

  Strict mode has no way to express an object that accepts keys beyond its
  declared `properties`, such as a free-form dictionary
  (`"additionalProperties" => %{"type" => "string"}`). Rather than close such
  an object, which would leave the model only `{}` to return, `to_strict/1`
  raises `ArgumentError`; declare the keys as properties instead.
  """

  @branch_keys ["anyOf", "allOf", "oneOf"]
  @definition_keys ["$defs", "definitions"]

  @doc """
  Returns `schema` rewritten for OpenAI strict mode.

  An already strict schema is returned unchanged, and converting twice gives
  the same result as converting once.

  Raises `ArgumentError` for a schema with atom keys, or with an object whose
  `additionalProperties` is anything other than `false`.
  """
  @spec to_strict(map()) :: map()
  def to_strict(schema) when is_map(schema) do
    if Enum.any?(Map.keys(schema), &is_atom/1) do
      raise ArgumentError,
            "strict JSON schemas must use string keys, got: #{inspect(schema)}"
    end

    schema
    |> strict_definitions()
    |> strict_object()
    |> strict_items()
    |> strict_branches()
  end

  defp strict_definitions(schema) do
    Enum.reduce(@definition_keys, schema, fn key, schema ->
      case schema do
        %{^key => defs} when is_map(defs) ->
          %{schema | key => Map.new(defs, fn {name, def} -> {name, to_strict(def)} end)}

        _ ->
          schema
      end
    end)
  end

  defp strict_object(schema) do
    if object?(schema), do: close_object(schema), else: schema
  end

  defp close_object(schema) do
    case Map.get(schema, "additionalProperties", false) do
      false ->
        require_properties(schema)

      additional ->
        raise ArgumentError,
              "OpenAI strict mode cannot express an object with " <>
                "additionalProperties #{inspect(additional)}; declare its keys under " <>
                "\"properties\" instead. Schema: #{inspect(schema)}"
    end
  end

  defp require_properties(schema) do
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

  defp strict_items(%{"items" => items} = schema) when is_map(items),
    do: %{schema | "items" => to_strict(items)}

  defp strict_items(schema), do: schema

  defp strict_branches(schema) do
    Enum.reduce(@branch_keys, schema, fn key, schema ->
      case schema do
        %{^key => branches} when is_list(branches) ->
          %{schema | key => Enum.map(branches, &to_strict/1)}

        _ ->
          schema
      end
    end)
  end

  defp object?(%{"type" => "object"}), do: true
  defp object?(%{"type" => types}) when is_list(types), do: "object" in types
  defp object?(%{"properties" => properties}) when is_map(properties), do: true
  defp object?(_schema), do: false

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
