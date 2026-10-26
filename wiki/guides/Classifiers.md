# Classifiers

A classifier labels a test case with exactly one label from a closed set:
did the assistant refuse, escalate, stay in scope? It is deepeval 4.3.1's
`Classifier`. Unlike a metric it has no score or threshold, and it only
passes or fails when the test case says which label it expects.

## Built-in classifiers

`DeepEvalEx.Classifiers` builds deepeval's thirteen built-ins:

```elixir
alias DeepEvalEx.Classifiers

Classifiers.refusal()                      # complied, refused, partial_refusal
Classifiers.scope_adherence(scope: "billing questions")
Classifiers.tone_adherence(tone: "friendly and concise")
Classifiers.required_disclosure(disclosures: ["an AI disclosure"])
```

The others are `escalation/1`, `clarification/1`, `abstention/1`,
`prompt_injection/1`, `data_leakage/1`, `forbidden_commitments/1`,
`response_language/1`, `instruction_completeness/1` and `resolution/1`.

## Your own labels

```elixir
ticket_type =
  DeepEvalEx.Classifier.new!(
    name: "ticket_type",
    labels: [
      {"billing", "Questions about invoices, charges or refunds."},
      "technical",
      {"account_access", "Logging in, passwords and two-factor codes."}
    ],
    allow_none: true
  )
```

A label's description is its boundary, so write it as carefully as G-Eval
criteria. `"NONE"` is reserved: with `allow_none: true` the judge may
decline to classify, which gives no label and no error.

## Expected labels

A test case names the label it expects per classifier in
`:expected_labels`. Without one, the classification has no verdict
(`success: nil`), like a score-only metric.

```elixir
test_case =
  DeepEvalEx.TestCase.new!(
    input: "Can I get a refund on a used ticket?",
    actual_output: "Used tickets can't be refunded, but I can offer a voucher.",
    expected_labels: %{"refusal" => "partial_refusal"}
  )
```

An expected label that is not one of the classifier's labels raises before
anything is evaluated. A key that names no classifier in the run only logs
a warning, so a dataset can carry expected labels for classifiers a run
leaves out.

## Running classifiers

```elixir
{:ok, %DeepEvalEx.EvaluationResult{test_results: [result]}} =
  DeepEvalEx.evaluate([test_case], [DeepEvalEx.Metrics.AnswerRelevancy],
    classifiers: [Classifiers.refusal()]
  )

[classification] = result.classifications
classification.label     #=> "partial_refusal"
classification.success   #=> true
result.success           #=> the metrics' verdict and the classifications'
```

Classifiers run after each test case's metrics. A failed classification
fails the test result; when no metric ran, the classifications alone
decide. Classifications are local, as in deepeval: they are never written
to the test run file, whose test cases pass or fail on their metrics
alone, and a run with classifiers and no metrics writes no test run.

`DeepEvalEx.Classifier.classify/3` classifies one test case directly.

## In ExUnit

```elixir
assert_evaluation(test_case, [AnswerRelevancy], classifiers: [Classifiers.refusal()])

# classifiers alone
assert_evaluation(test_case, [], classifiers: [Classifiers.refusal()])
```

A failure names what failed, as deepeval's `assert_test` does:

```
Classifiers: refusal (label: complied, expected: refused, error: None, reason: ...) failed.
```

## Eval modes

- `:llm` (the default) asks the LLM judge once for a label and a reason.
- `:system_one` asks a System One model (Jev) one Choice over the labels;
  the reason is built from its probabilities. Nothing falls back to the
  LLM.

A classifier has no `:hybrid` mode: `:hybrid`, from the option or the
`DEEPEVAL_EVAL_MODE` setting, runs it as `:llm`.

```elixir
Classifiers.refusal(eval_mode: :system_one)
```

## Custom classifiers

A module implementing the `c:DeepEvalEx.Classifier.classify/3` callback
can label test cases any way it likes; its answer is still resolved onto
the declared labels:

```elixir
defmodule MyApp.KeywordRefusal do
  @behaviour DeepEvalEx.Classifier

  @impl true
  def classify(_classifier, test_case, _opts) do
    label = if test_case.actual_output =~ "can't", do: "refused", else: "complied"
    {:ok, %{label: label, reason: nil}}
  end
end

DeepEvalEx.Classifier.new!(
  name: "keyword_refusal",
  labels: ["refused", "complied"],
  impl: MyApp.KeywordRefusal
)
```
