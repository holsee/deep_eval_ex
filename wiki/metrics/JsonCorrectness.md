# JsonCorrectness Metric

Checks that the actual output is JSON matching an expected schema. The check is made in code; an LLM judge only explains a failure, and is not called at all when the output matches.

## When to Use

- Structured output (JSON mode, function calling) that downstream code parses
- Agents that must hand a tool well-formed arguments
- Cheap CI gates on the shape of an answer, with an explanation when it breaks

## How It Works

1. **Validate** - the actual output is parsed as JSON and validated against `:expected_schema`
2. **Score** - the integer `1` when it matches, else `0` (not JSON at all, or JSON of the wrong shape)
3. **Reason** - a match gets deepeval's fixed reason, `"The generated Json matches and is syntactically correct to the expected schema."`; a failure is explained by the judge, which is shown the output and the schema

The metric is **strict by default**, as deepeval's: its threshold is the integer `1` unless `strict_mode: false` is given.

## The Expected Schema

deepeval's `JsonCorrectnessMetric` takes a pydantic model, validates with `model_validate_json` and shows the judge the model's `model_json_schema()`. Elixir has no pydantic, so DeepEvalEx takes that **JSON Schema** directly and validates against it with `DeepEvalEx.Metrics.Utils.JSONSchema`, with no extra dependency.

Give the schema as:

- a **JSON string**, decoded keeping its key order, so the reason prompt prints it exactly as deepeval prints the model's schema. Paste `json.dumps(Model.model_json_schema())` to match deepeval byte for byte
- a `Jason.OrderedObject`, likewise
- a **map**, with string or atom keys, printed in map order

Supported keywords: `type`, `enum`, `const`, `properties`, `required`, `additionalProperties`, `items`, `prefixItems`, `minItems`, `maxItems`, `uniqueItems`, `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `anyOf`, `oneOf`, `allOf`, `not`, boolean schemas, and `$ref` to `#/$defs/...` or `#/definitions/...` (recursion included). Annotations such as `title`, `description`, `default` and `format` are ignored. Keys a schema does not declare are allowed unless `additionalProperties` is `false`, as pydantic ignores them by default.

Validation follows JSON Schema, not pydantic's lax mode: pydantic also accepts a numeric string (`"87"`) for an `int` field and `"yes"` or `1` for a `bool`, which this check rejects. A float with no fractional part (`87.0`) is an integer for both.

Peri schemas are not accepted: they cannot be printed as the JSON Schema deepeval shows the judge.

## Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `input` | String | The input prompt |
| `actual_output` | String | The LLM's response, expected to be JSON |

## Usage

```elixir
alias DeepEvalEx.{TestCase, Metrics.JsonCorrectness}

schema = ~S({
  "properties": {
    "name": {"title": "Name", "type": "string"},
    "age": {"title": "Age", "type": "integer"}
  },
  "required": ["name", "age"],
  "title": "Person",
  "type": "object"
})

test_case = TestCase.new!(
  input: "Return the customer's profile as JSON.",
  actual_output: ~s({"name": "Ana", "age": 30})
)

{:ok, result} = JsonCorrectness.measure(test_case, expected_schema: schema)

result.score   # => 1
result.success # => true
result.reason  # => "The generated Json matches and is syntactically correct to the expected schema."
```

A failure asks the judge why:

```elixir
test_case = TestCase.new!(input: "Profile?", actual_output: ~s({"name": "Ana", "age": "thirty"}))

{:ok, result} = JsonCorrectness.measure(test_case, expected_schema: schema)
result.score  # => 0
result.reason # => "The generated Json is not valid because 'age' is a string ..."
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:expected_schema` | JSON string, map or `Jason.OrderedObject` | required | The JSON Schema the output must match |
| `:strict_mode` | boolean | **true** | Force the threshold to the integer `1`, as deepeval's default |
| `:threshold` | float | 0.5 | Score threshold when not strict |
| `:include_reason` | boolean | true | Explain the score; `false` makes no judge call |
| `:model` | string | config | LLM model for the reason |
| `:verbose_mode` | boolean | false | Print the verbose logs after measuring |
| `:eval_mode` | atom | config | `:llm`, `:hybrid` or `:system_one`, see below |

A missing schema, or one that is not a JSON object, raises `ArgumentError`, as deepeval's constructor requires its model.

## As a Configured Metric

The schema belongs to the metric, as in deepeval's `JsonCorrectnessMetric(expected_schema=...)`. To evaluate with other metrics, or two schemas at once, build the metric with `new/1`:

```elixir
metrics = [
  JsonCorrectness.new(expected_schema: person_schema),
  JsonCorrectness.new(expected_schema: order_schema, strict_mode: false, threshold: 0.5)
]

DeepEvalEx.evaluate(test_cases, metrics)
```

## Score Interpretation

| Score | Meaning |
|-------|---------|
| 1 | The output is JSON matching the schema |
| 0 | It is not JSON, or does not match |

Results are named `"Json Correctness"`, matching deepeval's metric name.

## Eval Modes

As in deepeval, the score is decided in code in every mode, so System One has nothing to decide: no System One model is built or asked, and no TypeSafe key is needed.

- `:llm` and `:hybrid` - the judge explains a failure
- `:system_one` - there is no LLM: a failure's reason is the validation error, laid out as pydantic lays out its `ValidationError` (deepeval's reason in this mode), and the result has no evaluation model and a zero cost:

```text
2 validation errors for Person
age
  Input should be a valid integer
tags.1
  Input should be a valid string
```

The messages are pydantic's for the same failure, without the `[type=..., input_value=...]` details and documentation links pydantic appends; invalid JSON is described by Jason. Under `evaluate/3`, a `:system_one` JsonCorrectness counts towards batching its test case's other `:system_one` metrics, as in deepeval, but asks nothing in the batch.

## Verbose Logs

```text
LLM outputed Json:
{"name": "Ana", "age": "thirty"}
```

(deepeval's spelling, kept for parity.)

## Result Metadata

```elixir
result.metadata
# => %{validation_error: "1 validation error for Person\nage\n  Input should be a valid integer"}
```

`validation_error` is `nil` when the output matched.

## Source

Ported from `deepeval/metrics/json_correctness/json_correctness.py`
