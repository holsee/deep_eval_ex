# ADR-0008: Peri Schema Validation Replacing Ecto

## Status

Accepted

## Date

2026-03-10

## Context

ADR-0002 introduced Ecto embedded schemas for validating in-memory data structures (`TestCase`, `ToolCall`) without any database. While Ecto changesets are a familiar pattern in the Elixir ecosystem, using them purely for validation of in-memory structs created several problems:

1. **`cast_embed` rejects structs** — Ecto's changeset pipeline is designed for casting external input (maps from forms, JSON, database rows). You cannot nest a `%ToolCall{}` struct inside a `TestCase` changeset because `cast_embed` expects raw maps at cast time. Code that naturally composes structs breaks.

2. **Two construction paths** — `%TestCase{...}` (direct struct) works without validation, but `TestCase.new!/1` goes through the changeset pipeline with different rules. Callers must know which path to use and each behaves differently, particularly around nested data.

3. **Wrong tool for the job** — Ecto schemas model database-backed entities with cast/validate lifecycles. For plain evaluation data structures with no persistence, untrusted boundary, or user input, the changeset ceremony adds complexity without corresponding benefit. A simple struct with a validation function would be simpler and have no surprising behaviour.

4. **Heavyweight dependency** — Ecto adds ~2MB to the dependency tree for functionality that amounts to "validate a map has the right keys and types". Projects using `deep_eval_ex` that don't otherwise need Ecto pay this cost for nothing.

The core smell is using a persistence-oriented library for pure data validation in a library that has nothing to do with persistence.

## Decision

Replace `{:ecto, "~> 3.11"}` with `{:peri, "~> 0.3"}` and rewrite `TestCase` and `ToolCall` as plain structs with Peri schema validation.

Each schema module now follows this pattern:

```elixir
defmodule DeepEvalEx.Schemas.ToolCall do
  import Peri

  defstruct [:name, :description, :reasoning, :input_parameters, :output]

  defschema :tool_call_schema, %{
    name: {:required, :string},
    description: :string,
    reasoning: :string,
    input_parameters: :map,
    output: :string
  }

  def new(attrs) do
    case tool_call_schema(to_map(attrs)) do
      {:ok, validated} -> {:ok, struct(__MODULE__, validated)}
      {:error, _} = err -> err
    end
  end

  def json_schema do
    %{
      "type" => "object",
      "properties" => %{...},
      "required" => ["name", ...],
      "additionalProperties" => false
    }
  end
end
```

Key design decisions:

- **`defstruct` replaces `embedded_schema`** — struct shape is preserved, so `%TestCase{}` pattern matching continues to work. Default values for list fields (`tools_called: []`, `expected_tools: []`) replicate `embeds_many` defaults.
- **`defschema` replaces `changeset`** — Peri's declarative schema definition validates a plain map, then `struct/2` converts it. No two-phase cast/validate lifecycle.
- **Nested validation via inline schemas** — `TestCase` defines a `@tool_call_schema` module attribute and references it as `{:list, @tool_call_schema}`, replacing `cast_embed`. Validated nested maps are converted to `%ToolCall{}` structs after validation.
- **`json_schema/0` callback replaces Ecto introspection** — the OpenAI adapter previously introspected `__schema__(:fields)` and `__schema__(:types)` to build JSON schemas at runtime. Each module now exports an explicit `json_schema/0` function, which is simpler, faster, and doesn't couple the adapter to Ecto internals.
- **Single construction path** — `new/1` validates then builds the struct. Direct `%TestCase{...}` still works for tests and internal use. No changeset, no `apply_action`, no confusion.

## Consequences

### Positive

- **Structs compose naturally** — nested `%ToolCall{}` structs work everywhere without special handling
- **Single construction path** — `new/1` validates and returns a struct; no changeset/apply_action ceremony
- **Lighter dependency** — Peri is ~50KB vs Ecto's ~2MB; projects not using Ecto no longer pull it in
- **Declarative schemas** — Peri's `defschema` is concise and readable with no boilerplate (`@primary_key false`, `embedded_schema do ... end`)
- **Explicit JSON schemas** — `json_schema/0` is clearer than runtime Ecto introspection and works for any adapter, not just OpenAI
- **No surprising behaviour** — no `cast_embed` rejecting structs, no `apply_action` required to extract the struct

### Negative

- **Less familiar** — Peri is less widely known than Ecto; contributors may need to read its docs
- **Fewer built-in validators** — Ecto has validators like `validate_length`, `validate_format`, etc. If more complex validation is needed in future, custom functions would be required (though Peri supports `{:custom, &fun/1}`)
- **No changeset tracking** — Ecto changesets track which fields changed; Peri validates the whole map. This is irrelevant for our use case but worth noting

### Neutral

- Error format changes from `Ecto.Changeset.t()` to Peri's error tuples — internal only, not part of the public API contract
- The `changeset/1` function on `ToolCall` is retained for backwards compatibility but now delegates to Peri

## Alternatives Considered

### Plain structs with `@enforce_keys` and hand-written validation

- **Considered**: Would eliminate all dependencies for validation
- **Rejected**: Peri provides type checking, nested validation, and required-field enforcement declaratively. Hand-rolling this for `TestCase` (with nested `ToolCall` lists, type coercion, context normalisation) would be more code to write and maintain than the Peri schema definitions

### Keep Ecto, work around the friction

- **Rejected**: The friction points (struct rejection in `cast_embed`, dual construction paths) are fundamental to how Ecto changesets work. Working around them means fighting the library rather than using it as intended

### NimbleOptions

- **Rejected**: Designed for keyword list option validation, not nested map/struct validation. Same reasoning as ADR-0002

## References

- [ADR-0002](0002-ecto-schemas-without-database.md) — the decision this supersedes
- [Peri documentation](https://hexdocs.pm/peri)
- [ADR-0006](0006-json-schema-for-structured-outputs.md) — JSON schema usage in adapters (now via `json_schema/0` callbacks)
