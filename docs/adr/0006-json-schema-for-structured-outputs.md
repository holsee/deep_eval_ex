# ADR-0006: JSON Schema Mode for Structured LLM Outputs

## Status

Accepted

## Date

2024-12-25

## Context

DeepEvalEx metrics require structured outputs from LLMs:

- Claims extraction needs `{claims: ["claim1", "claim2"]}`
- Verdict generation needs `{verdicts: [{claim: "...", verdict: "yes|no", reason: "..."}]}`
- G-Eval needs `{score: 0.85, reason: "..."}`

Without enforcement, LLMs may:
- Return malformed JSON
- Include extra fields
- Use wrong types (string instead of number)
- Wrap responses in markdown code blocks

Parsing failures cause metric evaluation to fail entirely.

## Decision

Use OpenAI's JSON Schema mode with strict schema validation.

```elixir
defmodule DeepEvalEx.Schemas.MetricOutputs.Faithfulness do
  def claims_schema do
    %{
      type: "object",
      properties: %{
        claims: %{
          type: "array",
          items: %{type: "string"}
        }
      },
      required: ["claims"],
      additionalProperties: false
    }
  end
end
```

The adapter sends the schema with the API request:

```elixir
def generate_with_schema(prompt, schema, opts) do
  body = %{
    model: model,
    messages: [%{role: "user", content: prompt}],
    response_format: %{
      type: "json_schema",
      json_schema: %{
        name: "response",
        strict: true,
        schema: schema
      }
    }
  }
  # ...
end
```

## Consequences

### Positive

- **Guaranteed structure**: LLM response always matches schema
- **No parsing errors**: JSON is always valid and typed correctly
- **No hallucinated fields**: `additionalProperties: false` blocks extras
- **Self-documenting**: Schema modules define expected output format
- **Reduced token waste**: No "Please respond in JSON format" preamble

### Negative

- **Provider lock-in**: JSON schema mode is OpenAI-specific (Anthropic has different approach)
- **Model requirements**: Only newer models support strict JSON schema
- **Increased latency**: Schema validation adds processing time
- **Rigid outputs**: Cannot include optional or variable fields

### Neutral

- Schema modules live alongside metrics for easy reference
- Adapter abstraction allows different structured output approaches per provider
- Fallback to prompt-based JSON for providers without schema mode

## Alternatives Considered

### Prompt-based JSON ("Respond in JSON format: {...}")

- **Rejected**: Unreliable. LLMs frequently add markdown, explanations, or malformed JSON.

### Function calling / Tool use

- **Rejected**: Semantically different purpose. Function calling is for actions, not structured data extraction.

### Custom parsing with regex/string manipulation

- **Rejected**: Brittle and error-prone. JSON schema mode eliminates this category of bugs.

### Pydantic-style class validation (via Instructor)

- **Rejected**: Adds dependency and complexity. Direct schema definition is simpler for our needs.

## References

- [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs)
- [JSON Schema Specification](https://json-schema.org/specification.html)
- [Anthropic Tool Use](https://docs.anthropic.com/claude/docs/tool-use)
