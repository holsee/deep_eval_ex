# ADR-0002: Ecto Embedded Schemas Without Database

## Status

Accepted

## Date

2024-12-25

## Context

DeepEvalEx needs structured data representations for:

- **TestCase** - Input definition (input, expected output, context, etc.)
- **Result** - Evaluation output (metric name, score, success, reason, metadata)
- **MetricOutputs** - Structured responses from LLM calls (claims, verdicts, etc.)

These structures need:
- Validation of required fields and types
- Clear error messages for invalid data
- JSON serialization/deserialization
- Type safety and documentation

The framework does not require database persistence.

## Decision

Use Ecto embedded schemas (`use Ecto.Schema` with `embedded_schema`) without any database or Ecto.Repo.

```elixir
defmodule DeepEvalEx.Schemas.TestCase do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :input, :string
    field :actual_output, :string
    field :expected_output, :string
    field :context, {:array, :string}
    field :retrieval_context, {:array, :string}
  end

  def changeset(test_case, attrs) do
    test_case
    |> cast(attrs, [:input, :actual_output, :expected_output, :context, :retrieval_context])
    |> validate_required([:input])
  end
end
```

## Consequences

### Positive

- **Familiar patterns**: Most Elixir developers know Ecto changesets
- **Robust validation**: Built-in validators, custom validators, composable changesets
- **Type coercion**: Automatic type casting with clear error messages
- **Documentation**: Schema definitions are self-documenting
- **No custom code**: Leverages well-tested Ecto library for validation

### Negative

- **Ecto dependency**: Adds ~2MB dependency for projects not otherwise using Ecto
- **Schema boilerplate**: Embedded schemas require more code than plain structs
- **Learning curve**: Developers unfamiliar with Ecto must learn changeset patterns

### Neutral

- No database migrations or Repo configuration needed
- Schemas can be easily extended with additional fields
- JSON encoding/decoding works via Jason with `@derive Jason.Encoder`

## Alternatives Considered

### Plain structs with custom validation

- **Rejected**: Would require reimplementing validation logic that Ecto already provides. More code to maintain and test.

### NimbleOptions for validation

- **Rejected**: NimbleOptions is designed for keyword list options, not nested data structures. Less suitable for complex schemas like TestCase.

### TypedStruct + custom validators

- **Rejected**: TypedStruct handles struct definition but not validation. Would still need custom validation code.

### Params library

- **Rejected**: Less mature than Ecto, smaller community, fewer features.

## References

- [Ecto Embedded Schemas](https://hexdocs.pm/ecto/Ecto.Schema.html#module-embedded-schemas)
- [Ecto Changeset](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Using Ecto without a Database](https://dashbit.co/blog/writing-custom-ecto-types)
