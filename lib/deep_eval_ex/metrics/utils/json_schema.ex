# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0

defmodule DeepEvalEx.Metrics.Utils.JSONSchema do
  @moduledoc """
  Validates JSON against a JSON Schema, for `DeepEvalEx.Metrics.JsonCorrectness`.

  deepeval 4.3.1's `JsonCorrectnessMetric` takes a pydantic model and checks
  the output with `model_validate_json`. Elixir has no pydantic, so
  DeepEvalEx takes the model's JSON Schema, which is what deepeval prints
  in its reason prompt (`model_json_schema()`), and validates against that
  with this module. It needs no dependency beyond `Jason`.

  ## Supported keywords

  - `type` (one type or a list), `enum`, `const`
  - objects: `properties`, `required`, `additionalProperties` (`false` or a
    schema); keys a schema does not declare are allowed unless
    `additionalProperties` is `false`, as pydantic ignores them by default
  - arrays: `items`, `prefixItems`, `minItems`, `maxItems`, `uniqueItems`
  - strings: `minLength`, `maxLength` (in code points), `pattern` (a PCRE
    search, see `Regex`)
  - numbers: `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
    `multipleOf`
  - `anyOf`, `oneOf`, `allOf`, `not`, and the boolean schemas `true` and
    `false`
  - `$ref` to a JSON pointer within the schema (`"#/$defs/Address"`,
    `"#/definitions/Address"`, `"#"`), recursion included

  Other keywords (`title`, `description`, `default`, `format`, ...) are
  annotations and are ignored. Keyword-specific checks apply only to values
  of their kind: `minLength` says nothing about a number. Like JSON Schema,
  and like pydantic for an `int` field, a float with no fractional part
  (`87.0`) is an integer.

  ## Differences from pydantic

  Validation follows JSON Schema, not pydantic's lax mode, which also
  coerces some JSON values: a numeric string (`"87"`) for an `int` or
  `float` field, `"true"`, `"yes"`, `1` and the like for a `bool`. Such
  output passes deepeval's check but not this one. A schema written for
  the output it validates (as pydantic's own `model_json_schema()` is) sees
  no other difference.

  ## Errors

  `validate_json/2` lays its errors out as pydantic's `ValidationError`
  does, which is deepeval's reason under the `:system_one` eval mode: a
  header naming the schema's `title`, then each error's location (dotted
  keys and indices, none at the root) and message, in the schema's field
  order. The messages are pydantic's for the same failure (`"Field
  required"`, `"Input should be a valid integer"`), without the
  `[type=..., input_value=...]` details and documentation links pydantic
  appends, and invalid JSON is described by `Jason.DecodeError`.
  """

  alias DeepEvalEx.Prompts.Python
  alias Jason.OrderedObject

  @typedoc """
  A JSON Schema with string keys: a map, a `Jason.OrderedObject` keeping
  its key order, or a boolean schema.
  """
  @type schema :: map() | OrderedObject.t() | boolean()

  @typedoc "Where an error is: object keys and array indices from the root."
  @type location :: [String.t() | non_neg_integer()]

  @typedoc "One validation error: its location and message."
  @type error :: {location(), String.t()}

  @type_descriptions %{
    "string" => "a valid string",
    "integer" => "a valid integer",
    "number" => "a valid number",
    "boolean" => "a valid boolean",
    "null" => "None",
    "array" => "a valid list",
    "object" => "an object"
  }

  @doc """
  Normalises a schema given as a JSON string, a map or a
  `Jason.OrderedObject`: a string is decoded keeping its key order, and
  atom keys (and atoms among `required`'s names) become strings. Key order
  matters only for how the schema prints, in deepeval's reason prompt.

  Raises `ArgumentError` when the string is not JSON or the schema is not
  a JSON object.

  ## Examples

      iex> DeepEvalEx.Metrics.Utils.JSONSchema.normalize!(%{type: "object", required: [:name]})
      %{"required" => ["name"], "type" => "object"}
  """
  @spec normalize!(String.t() | map() | OrderedObject.t()) :: map() | OrderedObject.t()
  def normalize!(schema) when is_binary(schema) do
    case Jason.decode(schema, objects: :ordered_objects) do
      {:ok, decoded} ->
        normalize!(decoded)

      {:error, error} ->
        raise ArgumentError, "expected_schema is not valid JSON: #{Exception.message(error)}"
    end
  end

  def normalize!(%OrderedObject{} = schema), do: stringify(schema)
  def normalize!(schema) when is_map(schema) and not is_struct(schema), do: stringify(schema)

  def normalize!(schema) do
    raise ArgumentError,
          "expected_schema must be a JSON object (a JSON Schema), got: #{inspect(schema)}"
  end

  defp stringify(%OrderedObject{values: values}),
    do: %OrderedObject{
      values: Enum.map(values, fn {key, value} -> {key(key), stringify(value)} end)
    }

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp stringify(term), do: term

  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: key

  @doc """
  Decodes `json` and validates it against `schema` (normalised, see
  `normalize!/1`), as deepeval's `model_validate_json`. Returns `:ok`, or
  `{:error, message}` with every error laid out as pydantic's
  `ValidationError` (see "Errors").

  ## Examples

      iex> schema = %{"title" => "Person", "type" => "object", "required" => ["age"]}
      iex> DeepEvalEx.Metrics.Utils.JSONSchema.validate_json(~s({"age": 3}), schema)
      :ok
      iex> DeepEvalEx.Metrics.Utils.JSONSchema.validate_json("{}", schema)
      {:error, "1 validation error for Person\\nage\\n  Field required"}
  """
  @spec validate_json(String.t(), schema()) :: :ok | {:error, String.t()}
  def validate_json(json, schema) when is_binary(json) do
    result =
      case Jason.decode(json) do
        {:ok, value} -> validate(value, schema)
        {:error, error} -> {:error, [{[], "Invalid JSON: #{Exception.message(error)}"}]}
      end

    case result do
      :ok -> :ok
      {:error, errors} -> {:error, format(errors, schema)}
    end
  end

  @doc """
  Validates a decoded JSON `value` against `schema` (normalised, see
  `normalize!/1`). Returns `:ok` or `{:error, errors}`, each error its
  location and message.

  Raises `ArgumentError` for a `$ref` that does not point within the
  schema.
  """
  @spec validate(term(), schema()) :: :ok | {:error, [error()]}
  def validate(value, schema) do
    case check(value, schema, schema, []) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp format(errors, schema) do
    count = length(errors)
    noun = if count == 1, do: "error", else: "errors"
    title = if is_boolean(schema), do: nil, else: get(schema, "title")

    header = "#{count} validation #{noun} for #{title || "the expected schema"}"

    lines =
      Enum.map(errors, fn
        {[], message} -> "  " <> message
        {location, message} -> Enum.join(location, ".") <> "\n  " <> message
      end)

    Enum.join([header | lines], "\n")
  end

  # Errors of `value` at `path` against `schema`; `root` resolves $refs.
  defp check(_value, true, _root, _path), do: []
  defp check(_value, false, _root, path), do: [{path, "Input is not permitted"}]

  defp check(value, schema, root, path) do
    ref_errors =
      case get(schema, "$ref") do
        nil -> []
        ref -> check(value, resolve(ref, root), root, path)
      end

    case type_errors(value, get(schema, "type"), path) do
      [] -> ref_errors ++ keyword_errors(value, schema, root, path)
      errors -> ref_errors ++ errors
    end
  end

  defp keyword_errors(value, schema, root, path) do
    Enum.concat([
      enum_errors(value, schema, path),
      kind_errors(value, schema, root, path),
      combinator_errors(value, schema, root, path)
    ])
  end

  ## type

  defp type_errors(_value, nil, _path), do: []

  defp type_errors(value, type, path) do
    types = List.wrap(type)

    if Enum.any?(types, &type?(value, &1)),
      do: [],
      else: [{path, "Input should be " <> Enum.map_join(types, " or ", &@type_descriptions[&1])}]
  end

  defp type?(value, "string"), do: is_binary(value)

  defp type?(value, "integer"),
    do: is_integer(value) or (is_float(value) and trunc(value) == value)

  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "null"), do: is_nil(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "object"), do: is_map(value)
  defp type?(_value, _unknown), do: true

  ## enum and const

  defp enum_errors(value, schema, path) do
    enum =
      case get(schema, "enum") do
        values when is_list(values) ->
          if Enum.any?(values, &(&1 == value)),
            do: [],
            else: [{path, "Input should be " <> alternatives(values)}]

        _ ->
          []
      end

    const =
      case fetch(schema, "const") do
        {:ok, expected} when expected != value ->
          [{path, "Input should be " <> Python.repr(expected)}]

        _ ->
          []
      end

    enum ++ const
  end

  # pydantic's "'a', 'b' or 'c'".
  defp alternatives([only]), do: Python.repr(only)

  defp alternatives(values) do
    {init, [last]} = Enum.split(values, -1)
    Enum.map_join(init, ", ", &Python.repr/1) <> " or " <> Python.repr(last)
  end

  ## Keywords of one kind of value

  defp kind_errors(value, schema, _root, path) when is_binary(value),
    do: string_errors(value, schema, path)

  defp kind_errors(value, schema, _root, path) when is_number(value),
    do: number_errors(value, schema, path)

  defp kind_errors(value, schema, root, path) when is_list(value),
    do: array_errors(value, schema, root, path)

  defp kind_errors(value, schema, root, path) when is_map(value),
    do: object_errors(value, schema, root, path)

  defp kind_errors(_value, _schema, _root, _path), do: []

  defp string_errors(value, schema, path) do
    length = value |> String.to_charlist() |> length()

    [
      bound(
        get(schema, "minLength"),
        &(length < &1),
        &"String should have at least #{plural(&1, "character")}"
      ),
      bound(
        get(schema, "maxLength"),
        &(length > &1),
        &"String should have at most #{plural(&1, "character")}"
      ),
      bound(
        get(schema, "pattern"),
        &(not Regex.match?(Regex.compile!(&1, "u"), value)),
        &"String should match pattern '#{&1}'"
      )
    ]
    |> located(path)
  end

  defp number_errors(value, schema, path) do
    [
      bound(
        get(schema, "minimum"),
        &(value < &1),
        &"Input should be greater than or equal to #{Python.repr(&1)}"
      ),
      bound(
        get(schema, "exclusiveMinimum"),
        &(value <= &1),
        &"Input should be greater than #{Python.repr(&1)}"
      ),
      bound(
        get(schema, "maximum"),
        &(value > &1),
        &"Input should be less than or equal to #{Python.repr(&1)}"
      ),
      bound(
        get(schema, "exclusiveMaximum"),
        &(value >= &1),
        &"Input should be less than #{Python.repr(&1)}"
      ),
      bound(
        get(schema, "multipleOf"),
        &(not multiple?(value, &1)),
        &"Input should be a multiple of #{Python.repr(&1)}"
      )
    ]
    |> located(path)
  end

  defp multiple?(value, divisor) when is_integer(value) and is_integer(divisor),
    do: rem(value, divisor) == 0

  defp multiple?(value, divisor) do
    quotient = value / divisor
    abs(quotient - Float.round(quotient)) < 1.0e-9
  end

  defp array_errors(value, schema, root, path) do
    count = length(value)
    prefix = List.wrap(get(schema, "prefixItems"))

    item_errors =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        case Enum.at(prefix, index) do
          nil -> items_errors(item, get(schema, "items"), root, path ++ [index])
          item_schema -> check(item, item_schema, root, path ++ [index])
        end
      end)

    size_errors =
      [
        bound(
          get(schema, "minItems"),
          &(count < &1),
          &"List should have at least #{plural(&1, "item")} after validation, not #{count}"
        ),
        bound(
          get(schema, "maxItems"),
          &(count > &1),
          &"List should have at most #{plural(&1, "item")} after validation, not #{count}"
        ),
        bound(
          get(schema, "uniqueItems"),
          &(&1 == true and length(Enum.uniq(value)) != count),
          fn _ -> "List should have unique items" end
        )
      ]
      |> located(path)

    item_errors ++ size_errors
  end

  defp items_errors(_item, nil, _root, _path), do: []
  defp items_errors(item, items, root, path), do: check(item, items, root, path)

  defp object_errors(value, schema, root, path) do
    properties = pairs(get(schema, "properties"))
    required = List.wrap(get(schema, "required"))
    declared = Enum.map(properties, &elem(&1, 0))

    property_errors =
      Enum.flat_map(properties, fn {name, property} ->
        property_errors(Map.fetch(value, name), property, name in required, root, path ++ [name])
      end)

    undeclared_required =
      for name <- required,
          name not in declared,
          not Map.has_key?(value, name),
          do: {path ++ [name], "Field required"}

    extra_errors =
      case get(schema, "additionalProperties") do
        nil ->
          []

        additional ->
          for key <- value |> Map.keys() |> Enum.sort(),
              key not in declared,
              error <- additional_errors(Map.fetch!(value, key), additional, root, path ++ [key]),
              do: error
      end

    property_errors ++ undeclared_required ++ extra_errors
  end

  defp property_errors({:ok, item}, property, _required?, root, path),
    do: check(item, property, root, path)

  defp property_errors(:error, _property, true, _root, path), do: [{path, "Field required"}]
  defp property_errors(:error, _property, false, _root, _path), do: []

  defp additional_errors(_value, false, _root, path),
    do: [{path, "Extra inputs are not permitted"}]

  defp additional_errors(value, additional, root, path), do: check(value, additional, root, path)

  ## anyOf, oneOf, allOf, not

  defp combinator_errors(value, schema, root, path) do
    Enum.concat([
      any_of_errors(value, get(schema, "anyOf"), root, path),
      one_of_errors(value, get(schema, "oneOf"), root, path),
      all_of_errors(value, get(schema, "allOf"), root, path),
      not_errors(value, fetch(schema, "not"), root, path)
    ])
  end

  defp any_of_errors(_value, nil, _root, _path), do: []

  defp any_of_errors(value, branches, root, path) do
    results = Enum.map(branches, &check(value, &1, root, path))
    if Enum.any?(results, &(&1 == [])), do: [], else: no_match(branches, results, path)
  end

  defp one_of_errors(_value, nil, _root, _path), do: []

  defp one_of_errors(value, branches, root, path) do
    results = Enum.map(branches, &check(value, &1, root, path))

    case Enum.count(results, &(&1 == [])) do
      1 -> []
      0 -> no_match(branches, results, path)
      _ -> [{path, "Input should match exactly one of the allowed schemas"}]
    end
  end

  # An optional field (anyOf a schema and null) reports its one schema's
  # errors; any other union says no branch matched.
  defp no_match(branches, results, path) do
    case Enum.reject(Enum.zip(branches, results), fn {branch, _} -> null_only?(branch) end) do
      [{_branch, errors}] -> errors
      _ -> [{path, "Input should match at least one of the allowed schemas"}]
    end
  end

  defp null_only?(schema) when is_boolean(schema), do: false
  defp null_only?(schema), do: get(schema, "type") == "null" and length(pairs(schema)) == 1

  defp all_of_errors(_value, nil, _root, _path), do: []

  defp all_of_errors(value, branches, root, path),
    do: Enum.flat_map(branches, &check(value, &1, root, path))

  defp not_errors(value, {:ok, excluded}, root, path) do
    if check(value, excluded, root, path) == [],
      do: [{path, "Input should not match the excluded schema"}],
      else: []
  end

  defp not_errors(_value, :error, _root, _path), do: []

  ## $ref

  defp resolve("#", root), do: root

  defp resolve("#/" <> pointer = ref, root) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce(root, fn segment, schema ->
      case fetch(schema, segment) do
        {:ok, next} -> next
        :error -> raise ArgumentError, "unsupported $ref #{inspect(ref)}: nothing at that pointer"
      end
    end)
  end

  defp resolve(ref, _root) do
    raise ArgumentError,
          "unsupported $ref #{inspect(ref)}: only pointers within the schema (\"#/...\") are resolved"
  end

  ## Helpers

  # A failed check's message, or nothing when the keyword is absent.
  defp bound(nil, _failed?, _message), do: nil
  defp bound(limit, failed?, message), do: if(failed?.(limit), do: message.(limit))

  defp located(messages, path), do: for(message <- messages, message != nil, do: {path, message})

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp get(schema, key) do
    case fetch(schema, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch(%OrderedObject{} = schema, key), do: OrderedObject.fetch(schema, key)
  defp fetch(schema, key) when is_map(schema), do: Map.fetch(schema, key)
  defp fetch(_schema, _key), do: :error

  defp pairs(%OrderedObject{values: values}), do: values
  defp pairs(map) when is_map(map), do: Map.to_list(map)
  defp pairs(_other), do: []
end
