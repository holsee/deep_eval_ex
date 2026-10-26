# ADR-0009: System One Models and Eval Modes (llm | hybrid | system_one)

## Status

Accepted

## Date

2026-10-22

## Context

deepeval 4.3.1 lets a metric route its *decisions* to a **System One model**, a model that answers typed questions about a JSON state with probabilities rather than text. Today the only such model is TypeSafe AI's Jev. There are three question primitives:

- **Noul**: P(true) of a proposition. Its confidence is `|2p − 1|`.
- **Choice**: one option from a closed set, with a probability for each option and a confidence.
- **Score**: one level out of 2–10 ordered levels, with a probability for each level. It is normalised to 0..1 as `score / (levels − 1)`.

A metric's `eval_mode` decides who judges:

| Mode | Who extracts / explains | Who decides | On a System One failure |
|---|---|---|---|
| `llm` | LLM | LLM | n/a (unchanged behaviour) |
| `hybrid` | LLM | System One, one Noul per claim, statement, node, sentence or context (or a Score/Choice) | that decision falls back to the LLM; the reason is recorded in `system_one_fallback_reason` |
| `system_one` | nobody | one request answers the whole metric (`SystemOneEvalSpec`), and the score and reason are deterministic | raised; a context overflow is rewrapped as "switch back to llm" |

On top of the three modes, deepeval has:

- **JevEval**: user-written weighted Noul, Score and Choice questions, always decided by System One.
- **Classifiers**: one Choice over the classifier's labels.
- **Batching**: `evaluate()` merges a test case's `system_one` metrics into as few requests as the token budget allows, and splits the cost among them by question share.
- **A context budget pre-check**: 32k tokens for the state plus the longest question, 64k for the whole request, estimated as `ceil(len(json) / 3)`.

The P0-3 fixtures (`test/fixtures/deepeval/system_one/`, 24 scenarios) record exactly what deepeval sends (`decide.json`), what a metric ends up with (`measure.json`), the judge prompts (`prompts.json`) and the export (`test_run.json`). Today `system_one_fixtures_test.exs` checks only their structure. This design must make them pass byte for byte.

The maintainer has four requirements:

1. Support Jev **and** a **generic System One model**: any provider that implements a contract.
2. Support all three eval modes.
3. Reach behaviour and output parity with deepeval 4.3.1.
4. Be idiomatic Elixir.

Some of the existing code already helps:

- `DeepEvalEx.Config` already parses `DEEPEVAL_EVAL_MODE` (as `normalize_eval_mode`) and the `TYPESAFE_*` settings.
- `LLM.Usage` is a process-scoped usage ledger with `async/await`.
- `BaseMetric.measure/2` wraps `do_measure/2` with validation, telemetry, strict semantics and usage.
- `LLM.Retry` holds per-provider retry policies.
- `Prompts.Python` holds the Python formatting helpers.

Three findings from reading deepeval and the fixtures shaped this design:

- **Cost seeding.** deepeval's `prepare_measure` seeds `evaluation_cost` and the token counts with `0` for a *native* LLM, or with `None` for a custom one. Under `system_one` no LLM is built and the seed counts as native (`initialize_model` returns `(None, True)`). `_accrue_cost` keeps `None` once it is `None`. The fixtures depend on all of this:
  - `tool_correctness_hybrid`: `evaluationCost` null, `inputTokenCount` 1000, model `exploding-llm`.
  - `*_hybrid_fallback`: no token keys at all.
  - `batch_system_one_down`: 0.0, 0 and 0.
  - `faithfulness_system_one_strict`: 0.0 with 0 tokens.
  - `jev_eval_strict_not_applicable`: cost null with 0 tokens.

  DeepEvalEx has no notion of a native adapter today.
- **Where the budget is checked.** deepeval checks the budget only in the whole-chain runner (`system_one.py`), the batch, and `TypeSafeModel.decide`. The hybrid helpers in `decision.py` never pre-check it. A token is estimated by `len()` over code points, a bare string is not JSON-encoded, and the separators are `json.dumps`'s `", "` and `": "`. The fixture text contains non-ASCII characters (`18°C`, `café`).
- **Which errors are handled.** Only "System One errors" are caught (`DeepEvalError`, `RetryError`, `ConnectionError`, `TimeoutError`, `ImportError`, `TypeSafeError`). Anything else, such as a `KeyError`, propagates even in `hybrid`. `TypeSafeModel` maps a context overflow only when `body.detail.error_type == "max_tokens_exceeded"`; a bare 422 is re-raised.

## Decision

Build System One as a small subsystem, `DeepEvalEx.SystemOne.*`, shaped like `DeepEvalEx.LLM.*`. It has four layers:

1. **The provider contract.** `SystemOne.Adapter` is a two-callback behaviour (`decide/3` and `model_name/1`) plus optional callbacks. Jev is just the default adapter, `Adapters.TypeSafe`, and `Adapters.Mock` ports deepeval's test fakes.
2. **The facade.** `SystemOne.decide/3` is the single call site for every provider call. It handles telemetry, rescuing System One errors, stamping usage and the `{:error, _}` normalisation. Providers never handle modes, fallback, confidence, batching or cost splitting.
3. **Orchestration.** It is made of:
   - `SystemOne.Mode`, which resolves the eval mode;
   - `SystemOne.Context`, the resolved mode, model and LLM presence carried in opts;
   - `SystemOne.Ledger`, which holds per-measure confidence, fallback reasons and the disabled flag;
   - `SystemOne.Decision`, the hybrid decision points, which return `{:ok, v} | :llm`;
   - `SystemOne.Runner`, the whole-chain path;
   - `SystemOne.Batch`, a batching prefetch in the Evaluator.
4. **Metric-side specs.** These are plain structs (`EvalSpec`, `Spec.Verdicts`, `Spec.Binary`, `Spec.Choice`, `Spec.Score`) built inside metric modules. A metric declares one optional `BaseMetric` callback, `system_one_eval_spec/2`.

The rest of this section gives the rules that pin down behaviour.

### 1. Provider contract

```elixir
defmodule DeepEvalEx.SystemOne.Adapter do
  alias DeepEvalEx.SystemOne.{Answers, Error, Question}
  alias DeepEvalEx.LLM.Usage

  @type state :: Jason.OrderedObject.t() | map() | list() | String.t() | number() | boolean() | nil
  @typedoc "Ordered like a Python dict; keys are opaque to the provider."
  @type questions :: [{key :: String.t(), Question.t()}]
  @type opts :: keyword()

  @doc "Answer every question about `state`. Return {:error, _} for provider/transport failures; raise only on bugs."
  @callback decide(state(), questions(), opts()) ::
              {:ok, Answers.t(), Usage.t() | nil} | {:error, Error.t() | Exception.t()}

  @doc "Reported as evaluationModel under :system_one and in 'Decided by ...' reasons."
  @callback model_name(opts()) :: String.t()

  @doc "Construction-time check (key present, deps loaded). Runs before any measure."
  @callback init(opts()) :: {:ok, opts()} | {:error, Error.t()}

  @doc "{state, request} token limits for the Runner/Batch pre-check. Default: Jev's {32_000, 64_000}."
  @callback context_budget(opts()) :: {pos_integer(), pos_integer()} | :unbounded

  @optional_callbacks init: 1, context_budget: 1

  defmacro __using__(_) # injects @behaviour + defaults: init/1 -> {:ok, opts}, context_budget/1 -> Jev limits
end
```

- deepeval's `decide`/`a_decide` pair becomes one synchronous `decide/3`. Concurrency comes from Tasks.
- **Usage is returned, not recorded.** This differs from `LLM.Adapter`, which records usage itself. It is needed so that `Batch` can split one request's cost before booking it. `nil` means unpriced: deepeval's `cost=None`, which voids the summed cost. A bare float cost (no tokens) is expressed as `%Usage{cost: f, input_tokens: nil, output_tokens: nil}`, and `EvaluationCost{value, in, out}` maps onto the `Usage` fields one to one.
- A model is resolved by `SystemOne.Model.resolve/1` into `%Model{adapter, opts, name}`. It accepts:
  - `nil`, which means the configured default and then TypeSafe;
  - a string, which is a TypeSafe model name, as deepeval's `str` argument;
  - the aliases `:typesafe`, `:jev` and `:mock`;
  - a module;
  - `{module, opts}`.

  This mirrors `LLM.Adapter.get_adapter/1`.

### 2. Question and answer types

Wire questions (what a provider sees) are kept separate from scored questions (weights, Choice credits and not-applicable options), which never leave DeepEvalEx.

```elixir
defmodule DeepEvalEx.SystemOne.Question do
  @type t :: Noul.t() | Choice.t() | Score.t()
  defmodule Noul,   do: defstruct([:instructions, true: nil, false: nil])      # schema.py NoulQuestion
  defmodule Choice, do: defstruct([:instructions, options: []])              # [{name, description | nil}]
  defmodule Score,  do: defstruct([:instructions, levels: []])               # [String.t()], 2..10
  @doc "SDK shape (TypeSafeModel._to_sdk_questions): %{type, instructions, criteria?} as OrderedObject"
  @spec to_wire(t()) :: Jason.OrderedObject.t()
end
```

`to_wire/1` behaves as follows:

- A Noul drops `criteria` when both `true` and `false` are nil; otherwise it sends `criteria: {true, false}`.
- A Choice sends `criteria: {name: description | null}`, in option order. Credits are never sent.
- A Score sends `criteria: [levels...]`.
- An empty question list raises deepeval's "requires at least one question" `DeepEvalError`, inside TypeSafe.

`instructions` is any JSON-able term. QAG verdict questions send `{<item_key>: item, question: ...}`.

```elixir
defmodule DeepEvalEx.SystemOne.Answers do
  defstruct nouls: %{}, choices: %{}, scores: %{}
  defmodule Noul,   do: defstruct([:probability])                         # confidence = abs(2 * p - 1)
  defmodule Choice, do: defstruct([:choice, :probabilities, :confidence]) # probabilities: [{name, p}] ordered
  defmodule Score,  do: defstruct([:score, :probabilities, :confidence])  # probabilities: [{level_index :: integer, p}]
  @spec confidence(Noul.t() | Choice.t() | Score.t()) :: float()
  @spec normalized(Score.t(), levels :: pos_integer()) :: float()
  @spec min_confidence(t()) :: float() | nil
  @spec take_prefix(t(), String.t()) :: t()       # batch: "m1.q_0" -> "q_0"
  @spec to_dump(t()) :: Jason.OrderedObject.t()   # SystemOneAnswers.model_dump shape (Score keys as strings)
end
```

Probabilities stay ordered lists because deepeval iterates them when it builds reasons, logs and alternatives. A Noul's confidence uses the same float operations as Python, so `abs(2*0.6-1)` gives `0.19999999999999996`.

The scored question primitives live in `SystemOne.Scored.{Noul, Score, Choice, Outcome}`, ported from `jev_eval/questions.py`:

- Each has a weight greater than 0.
- A Score has 2–10 unique levels.
- A Choice has at least two options, credits in 0..1 or nil (nil means not applicable), and at least one credited option.
- Validation uses deepeval's messages, through `new!/1`.
- `to_question/1` turns a scored question into its wire question.
- `Scored.parse!/1` is `parse_questions`. It decodes a rendered `_experimental_system_one_questions` JSON array with ordered objects.

### 3. Eval-mode resolution

`SystemOne.Mode` ports `config/eval_mode.py`:

1. `resolve/1` uses the metric's `:eval_mode` option first. An invalid value raises `ArgumentError` with "Unsupported eval_mode 'x'. Valid values: llm, hybrid, system_one."
2. Otherwise it uses `Config.get(:eval_mode)`: app config, then `DEEPEVAL_EVAL_MODE`, trimmed and case-insensitive. An invalid setting reads as nil and is ignored.
3. Otherwise it uses `:llm`.

The module also has:

- `for_classifier/1`, where `:hybrid` becomes `:llm` (`resolve_classifier_eval_mode`).
- `uses_system_one?/1`, which is `mode != :llm`.
- `effective/2`, the port of `effective_eval_mode` plus `has_whole_metric_form`. `:system_one` becomes `:hybrid` when the metric module does not export `system_one_eval_spec/2`. Exporting the callback counts even when it returns nil. That is how ToolCorrectness stays `system_one`, with no LLM built, its tool-selection Score as its only Jev call, and `evaluationModel` `fake-jev`. The `whole_chain?` flag in the P3-6 brief is therefore dropped.

**Context.** `SystemOne.Context.resolve!(module, opts)` returns `%Context{mode, model, llm?}` and is stored in `opts[:system_one]`. It ports `initialize_model`/`initialize_system_one_model`:

- Under `:llm`, `model` is nil.
- Otherwise the model is resolved and `init/1` is called. A failure raises `DeepEvalError` with deepeval's text.
- Under `:system_one`, the LLM adapter is not resolved, so no LLM key is needed.

The Evaluator runs `resolve!` for every metric before any task starts, which matches deepeval's failure at construction time. `measure/2` runs it again for direct calls.

### 4. How metrics declare System One

**Whole chain (`system_one`).** A metric exports the optional `BaseMetric` callback and calls the runner from its own `do_measure/2`, as deepeval's `measure()` calls `run_system_one_eval`:

```elixir
@callback system_one_eval_spec(TestCase.t(), keyword()) :: DeepEvalEx.SystemOne.EvalSpec.t() | nil
@optional_callbacks system_one_eval_spec: 2

defmodule DeepEvalEx.SystemOne.EvalSpec do
  defstruct evaluation_params: [], questions: [], extra_state: []   # questions: [Scored.t()]
end

# Faithfulness
@impl true
def system_one_eval_spec(%TestCase{multimodal: true}, _opts), do: nil
def system_one_eval_spec(_tc, _opts) do
  %EvalSpec{evaluation_params: [:actual_output, :retrieval_context],
            questions: Scored.parse!(Template.system_one_questions())}
end

@impl true
def do_measure(tc, opts) do
  case SystemOne.Runner.run(__MODULE__, tc, opts) do
    {:ok, result} -> {:ok, result}
    :continue -> llm_chain(tc, opts)          # :llm / :hybrid (and the per-decision helpers below)
  end
end
```

`Runner.run/3` ports `run_system_one_eval` (`_prepare`, `_request_for`, `_decide` and `_populate`):

- It returns `:continue` unless the effective mode is `:system_one`.
- If the spec is nil and the context has no LLM, it raises `DeepEvalError` "... cannot judge this test case".
- The state is `{test_case: {params in spec order, nil/empty dropped, structs dumped as pydantic model_dump(exclude_none)}}` plus the non-nil `extra_state`. An empty `test_case` is dropped, and the questions are keyed `q_<i>`.
- The budget is checked with the adapter's `context_budget/1`, which defaults to Jev's limits. Overflow raises `ContextWindowExceededError` with deepeval's "could not run on System One: ... Switch this metric back to the LLM ..." text.
- It calls `SystemOne.decide/3`, or uses the batch prefetch when one is present.
- Any other error propagates.
- `populate/4` books the usage and records confidence, then computes the outcomes, then applies `mark_strict`/`aggregate_strict` or `aggregate`. It then sets:
  - `score_breakdown`, with outcome maps in deepeval's key order;
  - `confidence = min_confidence(outcomes)`;
  - the deterministic reason (`Scoring.reason/3`: verbalised bands, `leaning`, `weight=2` via `:g`, `strict=pass`);
  - `verbose_logs`, "Decided by System One (<name>); no LLM call was made." and so on;
  - `evaluation_model` = the System One `model_name`;
  - `strict_applied: true`, so that `BaseMetric.apply_metric_semantics/2` does not clamp Jev's float `0.0` to the integer `0` (`faithfulness_system_one_strict`).

A metric can keep its own Jev decisions without a whole form, as ToolCorrectness does. It exports the callback returning nil and never calls `Runner.run/3`. No sentinel atom is needed.

**Hybrid decision points.** `SystemOne.Decision` ports `decision.py` and the System One section of `qag.py`. Every helper returns `{:ok, value} | :llm`, and the metric runs its unchanged LLM branch on `:llm`:

```elixir
defmodule DeepEvalEx.SystemOne.Spec do
  defmodule Verdicts, do: defstruct([:instructions, :items, :item_key, state: [], criteria: nil, build_verdict: nil])
  defmodule Binary,   do: defstruct([:instructions, state: []])
  defmodule Choice,   do: defstruct([:instructions, :options, state: []])
  defmodule Score,    do: defstruct([:instructions, :levels, state: []])
end

defmodule DeepEvalEx.SystemOne.Decision do
  @spec verdicts(Spec.Verdicts.t() | nil, [QAG.verdict()], keyword()) :: {:ok, [map()]} | :llm
  @spec probability(Spec.Binary.t() | nil, keyword()) :: {:ok, float()} | :llm      # key "verdict"
  @spec choice(Spec.Choice.t() | nil, keyword()) :: {:ok, Answers.Choice.t()} | :llm
  @spec score(Spec.Score.t() | nil, keyword()) :: {:ok, float()} | :llm             # normalized 0..1
  @spec verdict_from_probability(float(), [QAG.verdict()]) :: QAG.verdict()        # >0.65 yes, <0.35 no, else borderline; no borderline: >=0.5
  @spec split_sentences(String.t()) :: [String.t()]                                 # ~r/(?<=[.!?])\s+/
  @spec format_reason(keyword(), String.t(), float()) :: String.t()                 # "Decided by X: what 0.75, confidence 0.25."
end

# Faithfulness (hybrid)
spec = %Spec.Verdicts{instructions: Template.system_one_verdict(), items: claims,
                      item_key: "claim", state: [retrieval_context: truths]}
case Decision.verdicts(spec, QAG.yes_no_borderline(), opts) do
  {:ok, verdicts} -> {:ok, verdicts}                    # reasons "P(yes)=0.91"
  :llm -> llm_verdicts(claims, truths, opts)
end
```

A helper takes the System One path only when all of these hold: the spec is non-nil, the mode uses System One, and `Ledger.disabled?()` is false. If the mode uses System One but no model is configured, it raises deepeval's "routes decisions to a System One model, but X has none configured" error.

`Spec.Verdicts` builds its request like this: the state is `{..spec.state, "<item_key>s" => items}`, keeping order; the questions are `<item_key>_<i>`; and an empty item list makes no call. **Hybrid helpers do not run the budget pre-check**; only Jev's own `decide` does, as in deepeval. GEval's rubric score has no System One branch.

### 5. Hybrid fallback and error handling

Providers report failures as `%DeepEvalEx.SystemOne.Error{}`:

```elixir
defexception [:reason, :type, :message, :estimated_tokens, :limit_tokens, permanent?: false]
# reason :: :context_limit | :timeout | :connection | :rate_limited | :auth | :http | :invalid_response | :missing_dependency
# type   :: deepeval-facing class name, e.g. "ConnectionError", "SystemOneContextLimitError"
@spec describe(t()) :: String.t()  # hybrid fallback text
@spec format(Exception.t()) :: String.t()  # format_error_text: "Type: msg"
```

The facade handles a "System One error" whether it is returned or raised. The handled types are `SystemOne.Error`, `DeepEvalEx.DeepEvalError` (which includes the not-configured and parse errors), `Req.TransportError` and timeouts. This is the port of `_system_one_error_types`. Everything else propagates, including `KeyError` from a missing answer key: the facade does **not** add an answer-completeness check that would turn a crash into a silent fallback.

`Decision.handle_failure/2` does the following:

- **`:hybrid`.** `Ledger.note_fallback(Error.describe(e))` adds to the reason, joining with `"; "`. The text is one of:
  - `context limit (N est. tokens > L)`;
  - `context limit (rejected by Jev)` when `limit_tokens` is nil;
  - `timeout (msg)`;
  - otherwise `<type>: <msg>`, e.g. `ConnectionError: Jev is down`.

  When `permanent?` is set (auth, permission denied, missing key or dependency), it also calls `Ledger.disable()` for the rest of the measure. It returns `:llm`.
- **`:system_one`.** A `:context_limit` error is raised as `ContextWindowExceededError` with the switch-to-llm text. Anything else is re-raised unchanged, so `measure.json` `raised` is `ConnectionError: Jev is down`.

For `raised.type` parity, the name is `error.type` for a `SystemOne.Error`, otherwise the exception module's last segment (`DeepEvalError`, `ContextWindowExceededError`).

### 6. Confidence and per-measure state

`SystemOne.Ledger` is process-scoped, opened by `BaseMetric.measure/2` next to the `Usage` scope (`reset_system_one_state`). It holds:

- the running minimum confidence across every request in the measure (`_record_confidence`);
- the fallback reasons;
- the disabled flag.

`Usage.async/await` fork the Ledger into tasks and join it back, because Faithfulness already extracts concurrently. The Runner overwrites the confidence with the minimum over the outcomes, as deepeval does. `Result` gains the in-memory fields `confidence`, `system_one_fallback_reason` and `score_breakdown`. **None of them is exported**, so `MetricData` and `test_run.json` stay byte-identical.

### 7. Export semantics: evaluationModel, cost, tokens

- `Usage` gains `source: :llm | :system_one | :seed`. The facade stamps `:system_one` on provider usage. `Usage.summarize/1` takes `evaluation_model` only from `:llm` usages; otherwise `BaseMetric` falls back to the Context. That fallback is the LLM's `model_name` when `llm?` is set, else the System One `model_name`, which is deepeval's `(self.model or self.system_one_model).get_model_name()`. It gives:
  - `exploding-llm` in `tool_correctness_hybrid`, even though only Jev was called;
  - `fake-jev` under `system_one`;
  - `jev-latest (TypeSafe AI)` in production.
- **Seed.** At measure start the wrapper records one `:seed` usage. This is deepeval's `prepare_measure`:
  - `{cost: 0.0, input: 0, output: 0}` when there is no LLM (`system_one`, JevEval) or the LLM adapter is native;
  - `{cost: nil, input: nil, output: nil}` for a non-native (custom, Mock or scripted) LLM. The nil cost voids the summed cost (`_accrue_cost`), and the nil tokens add nothing (`summarize` ignores nil counts).

  "Native" becomes an optional `LLM.Adapter` callback, `native?/0`. It defaults to `false` and is `true` for the OpenAI, Anthropic and Ollama adapters. The resulting fixture values:

  | Fixture | Cost | Tokens |
  |---|---|---|
  | `faithfulness_system_one` | 4.2e-05 | 1000/0 |
  | `batch_system_one_down` | 0.0 | 0/0 |
  | `faithfulness_system_one_strict` | 0.0 | 0/0 |
  | `jev_eval_strict_not_applicable` | null | 0/0 |
  | `tool_correctness_hybrid` / `faithfulness_hybrid` | null | input 1000 |
  | `*_hybrid_fallback` | null | no token keys |
- Jev cost is `input_tokens × price`, with output free. Pricing is the provider's job and is not looked up in `LLM.Pricing`, but `Pricing` gains `jev-*` entries for display.

### 8. Batching

`SystemOne.Batch.prefetch/3` ports `system_one_batch.py` and is called from `Evaluator.run_single/3` before the per-metric `Task.async_stream`:

- **Candidates** match deepeval's `_candidates` exactly:
  - the test case is an LLM test case and not multimodal;
  - the metric's effective mode is `:system_one`;
  - it has no cached result. DeepEvalEx has no cache yet, so this check is always false.

  Spec-less metrics such as ToolCorrectness **count toward the ≥ 2 threshold**, then drop out in `_setup` and run their own `measure`.
- **`_setup`** validates the params, builds the spec and request, and resets the ledger. A setup failure is recorded with `Error.format/1` (deepeval's `_fail` uses `format_error_text`).
- **`_pack`** admits entries greedily when they share the same `model_name`, their states merge (`test_case` and `turns` deep-merge; any other differing top-level key refuses) and the request stays within budget. Question keys are prefixed `m<j>.`.
- **Requests** run under `Task.async_stream`, bounded by the test case's deadline.
- **`_split_cost`** computes `fraction = w / whole` before multiplying. **`_apportion`** splits integer tokens with Python round-half-even, so 3001 splits as 1000/1001/1000 and 0.000126 as 4.2e-05 each.
- **Settle by prefetch.** Each metric gets `opts[:system_one_prefetched]` (`@doc false`):
  - `{:answers, Answers.take_prefix(a, "m<j>."), usage_share}` on success;
  - `{:error, %Batch.Error{message: Error.format(e), original: e}}` on failure.

  The metric then runs its normal `measure/2`, so populate, strict handling, Usage, the Ledger, telemetry and timeouts stay a single path. A failure is recorded as `ConnectionError: Jev is down` under `ignore_errors: true` and re-raised as the original under `false`. A context-limit failure of a single-entry request is rewrapped as `ContextWindowExceededError`. Nothing falls back.

### 9. Telemetry

The facade wraps every provider call in `:telemetry.span([:deep_eval_ex, :system_one, :request], ...)`:

- metadata: `model`, `mode`, `metrics` (a list of names; one for an unbatched call), `question_count`, `batched?`;
- measurements: `duration`, `input_tokens`, `output_tokens`, `cost`.

`[:deep_eval_ex, :system_one, :fallback]` carries `%{metric, reason}`. Together these replace deepeval's rich Jev progress line.

### Module map

| Module | Ports | Unit |
|---|---|---|
| `DeepEvalEx.SystemOne` (facade: `decide/3`, `noul/3`, `choice/3`, `score/3`) | `DeepEvalBaseSystemOneModel.noul/choice/score` | P3-1 |
| `SystemOne.Adapter`, `SystemOne.Model` | `DeepEvalBaseSystemOneModel` | P3-1 |
| `SystemOne.Question`, `SystemOne.Answers` | `models/system_one/schema.py` | P3-1 |
| `SystemOne.Error`, `DeepEvalEx.DeepEvalError`, `DeepEvalEx.ContextWindowExceededError` | `errors.py`, `SystemOneContextLimitError` | P3-1 |
| `SystemOne.Mode`, `SystemOne.Context` | `config/eval_mode.py`, `metrics/utils/models.py` | P3-2, P3-6 |
| `SystemOne.Limits` | `limits.py`, `constants.py` | P3-3 |
| `SystemOne.Adapters.Mock`, `SystemOne.AdapterCase` | `tests/test_metrics/system_one_fakes.py` | P3-4 |
| `SystemOne.Adapters.TypeSafe` | `typesafe_model.py` | P3-5 |
| `SystemOne.Ledger`; `BaseMetric` callback, seed, `strict_applied`; `Usage.source`; `LLM.Adapter.native?/0` | `base_metric.py` fields, `indicator.start_measure`, `prepare_measure` | P3-6, P3-11 |
| `SystemOne.Decision`, `SystemOne.Spec.*` | `metrics/utils/decision.py`, `qag.py` (System One section) | P3-7, P3-8 |
| `SystemOne.Scored.*` (incl. `parse!/1`) | `jev_eval/questions.py`, `system_one.parse_questions` | P3-9 |
| `SystemOne.EvalSpec`, `SystemOne.Runner`, `SystemOne.State`, `SystemOne.Scoring` | `system_one.py`, `jev_eval/utils.py` | P3-10 |
| `Prompts.Python.format_g/1`, `round/2` | CPython `format(x, "g")`, `round(x, n)` | P3-12 (new) |
| `SystemOne.Batch` | `system_one_batch.py` | P4-7 |
| `DeepEvalEx.Metrics.JevEval` | `jev_eval/jev_eval.py` | P4-6 |
| Telemetry events | progress indicator | P4-8 |

`State.dump/1` uses a `DeepEvalEx.SystemOne.Dumpable` protocol (pydantic `model_dump(mode="json", exclude_none=True)`: field names, declaration order, nils dropped), which `ToolCall` and similar implement. Classifiers (P8) ask one Choice keyed `label`, resolve their mode with `Mode.for_classifier/1`, and build their reason with `Scoring.classification_reason/2`.

## Generic provider

A provider is one module that ignores modes, metrics, batching, fallback and confidence:

```elixir
defmodule MyApp.LogprobJudge do
  use DeepEvalEx.SystemOne.Adapter          # defaults: init/1 passthrough, Jev budget

  alias DeepEvalEx.SystemOne.{Answers, Error, Question}
  alias DeepEvalEx.LLM.Usage

  @impl true
  def model_name(opts), do: "logprob-" <> Keyword.get(opts, :model, "v1")

  @impl true
  def init(opts) do
    if opts[:api_key], do: {:ok, opts},
      else: {:error, %Error{reason: :auth, type: "DeepEvalError", permanent?: true,
                            message: "MyApp.LogprobJudge needs :api_key"}}
  end

  @impl true
  def context_budget(_opts), do: {100_000, 200_000}

  @impl true
  def decide(state, questions, opts) do
    with {:ok, body} <- MyApp.Client.ask(state, Enum.map(questions, fn {k, q} -> {k, Question.to_wire(q)} end), opts) do
      answers =
        Enum.reduce(questions, %Answers{}, fn
          {key, %Question.Noul{}}, acc ->
            put_in(acc.nouls[key], %Answers.Noul{probability: body["p"][key]})
          {key, %Question.Choice{options: opts}}, acc ->
            probs = for {name, _} <- opts, do: {name, body["dist"][key][name]}
            {best, p} = Enum.max_by(probs, &elem(&1, 1))
            put_in(acc.choices[key], %Answers.Choice{choice: best, probabilities: probs, confidence: p})
          {key, %Question.Score{levels: levels}}, acc ->
            probs = for i <- 0..(length(levels) - 1), do: {i, body["dist"][key][Integer.to_string(i)]}
            {best, p} = Enum.max_by(probs, &elem(&1, 1))
            put_in(acc.scores[key], %Answers.Score{score: best, probabilities: probs, confidence: p})
        end)

      {:ok, answers, Usage.new(model_name(opts), body["input_tokens"], 0)}
    else
      {:error, :timeout} -> {:error, %Error{reason: :timeout, type: "TimeoutError", message: "logprob judge timed out"}}
      {:error, other} -> {:error, %Error{reason: :connection, type: "ConnectionError", message: inspect(other)}}
    end
  end
end
```

A provider is selected in one of three ways:

- per metric: `{Faithfulness, eval_mode: :hybrid, system_one_model: {MyApp.LogprobJudge, api_key: k}}`;
- per run: `DeepEvalEx.evaluate(cases, metrics, eval_mode: :system_one, system_one_model: MyApp.LogprobJudge)`;
- globally: `config :deep_eval_ex, system_one_model: {MyApp.LogprobJudge, ...}`.

The provider gets the following for free:

- the budget pre-check, in the Runner and Batch only;
- telemetry;
- error normalisation;
- hybrid fallback and permanent disabling;
- confidence aggregation;
- batching (which only merges requests whose `model_name/1` is equal, so mixing providers is safe);
- the cost split;
- deterministic reasons;
- the export.

`DeepEvalEx.SystemOne.AdapterCase` is an ExUnit case template that a provider `use`s to check its own contract. It checks that:

- every key is answered under its own type;
- probabilities are in 0..1;
- Score indices are integers within range;
- Choice and Score confidences are in [0, 1];
- usage is a `Usage` or nil;
- errors are well-formed;
- an `init/1` failure surfaces at `Context.resolve!`.

## Jev / TypeSafe adapter outline

`DeepEvalEx.SystemOne.Adapters.TypeSafe` is built on Req.

- **Wire format.** deepeval calls `typesafe_sdk` `client.system_one(state, sdk_questions, model=name)`. `sdk_questions` is `Question.to_wire/1` per key, which the fixtures confirm. The response has `nouls[key].noul`, `choices[key].{choice, probabilities, confidence}`, `scores[key].{score, probabilities (string keys → cast to int), confidence}` and an optional `usage.{input_tokens, output_tokens}` (missing means 0).
- **Auth.** A Bearer `TYPESAFE_API_KEY`, or `api_key:` in the options. `init/1` fails without a key, with deepeval's "set TYPESAFE_API_KEY" `DeepEvalError`, which is permanent.
- **Model.** `model:` from the options, else `TYPESAFE_MODEL_NAME`, else `"jev-latest"`. `model_name/1` returns `"<name> (TypeSafe AI)"`. The registry is jev-1.13.0, jev-latest and jev-preview.
- **Pricing.** Cost is `input_tokens × (TYPESAFE_COST_PER_INPUT_TOKEN || 0.042e-6)`, and output is free. A negative price raises "TYPESAFE_COST_PER_INPUT_TOKEN must be >= 0." Note that `Config` currently validates this setting as `> 0`; deepeval accepts `0`.
- **Limits.** `Limits.check/3` runs before sending: state plus the longest question must be ≤ 32,000 and the whole request ≤ 64,000. `estimate_tokens` is `ceil(String.length(text) / 3)`, where a bare string is used as is and anything else is dumped as Python `json.dumps(ensure_ascii=False, default=str)` with `", "` and `": "` separators.
- **Errors.**
  - Only a response whose `detail.error_type == "max_tokens_exceeded"` maps to `%Error{reason: :context_limit, limit_tokens: nil, estimated_tokens: estimate(state)}` with deepeval's "Jev rejected the request as too large ..." text. A bare 422 is **not** a context limit; it becomes `:http`.
  - 401 and 403 become `:auth`, which is permanent.
  - Transport errors become `:connection`, with type `ConnectionError`.
  - Timeouts become `:timeout`.
- **Retry.** A new `LLM.Retry` provider `:typesafe` retries 429, 5xx and transport errors, never 401, 403 or 422.

**Unverified, because `typesafe-sdk` is not installed.** The following are taken from the SDK call shape and must be confirmed by the P4-9 live check:

- the HTTP endpoint (assumed `POST https://api.typesafe.ai/v1/systemone`);
- the request body envelope (`{state, questions, model}`);
- the auth header;
- the error body shape (`{detail: {error_type}}`) and which status codes carry `max_tokens_exceeded`;
- the response field names at the HTTP level (`noul` vs `probability`, the `usage` location);
- the SDK's own retry and timeout defaults (`PS.TYPESAFE`).

**Settled by P4-9 (2026-10-26).** Checked against `jev-latest` (then `jev-1.14.0`) and TypeSafe's HTTP API reference (<https://docs.typesafe.ai/api>):

- the endpoint, the `{state, questions, model}` body and the `Authorization: Bearer` header were right;
- the response was wrong. The HTTP API returns `{model, answers, usage}`, with each answer under its question's key and tagged with its `type` (`noul`, `choice`, `score`, or `box` for images). `nouls`, `choices` and `scores` are only the SDK's response object. The adapter now reads `answers`;
- errors carry `{detail: {error_type, message}}`: `authentication_error` on 401 (bad key) and 403 (no key), `api_usage_error` on 400 (such as an unknown model), and `max_tokens_exceeded` on 400. A 422 carries a list of `{loc, msg, type}` validation errors;
- `usage.input_tokens` and `usage.output_tokens` are top level, as assumed.

The SDK's retry and timeout defaults remain unchecked; the adapter keeps deepeval's `:typesafe` retry policy.

## Testing strategy

1. **Mock provider.** `SystemOne.Adapters.Mock` ships in `lib`, like `LLM.Adapters.Mock`. It ports `FakeSystemOneModel` and `ExplodingSystemOneModel`:
   - canned `answers:`, an answers list consumed one per call, or an `answer_fn:`;
   - `raises:` an `%Error{}` or exception, either returned or raised;
   - `cost:` as nil, a float, a `Usage` or `{value, in, out}`;
   - `model:`.

   `Mock.new/1` returns a `{Mock, opts}` handle with its own Agent-backed call log, which `Mock.calls/1` reads. Logs are per handle, so concurrently measured metrics and async tests never interleave. `Mock.from_fixture/1` builds a handle from `input.json["system_one"]`, and a `raises: {type: "ConnectionError"}` becomes `%Error{type: "ConnectionError", reason: :connection}`. The helpers `noul_answers/1` and `answer_everything/2` are ported too.
2. **Fixture parity test.** `test/deep_eval_ex/system_one_parity_test.exs` runs over all 24 scenarios and replaces the structural assertions. For each scenario it builds the metrics or classifier from `input.json`, using the Mock handle and the scripted LLM from `responses`, or the exploding LLM when there are none. It then runs these facets:
   - **decide facet:** each metric is measured alone, and `Mock.calls` (state, `Question.to_wire`, `Answers.to_dump`, cost or error) is encoded with `DeepEvalEx.TestRun.JSON` (Python float repr and separators) and compared byte for byte with `decide.json["measure"]`. The `evaluate` block is compared too: exactly one `m<j>.`-prefixed call for batched scenarios.
   - **measure facet:** every field of `measure.json` is compared, including int vs float score, confidence, fallback reason, score_breakdown and `raised` (type and message).
   - **prompts facet:** compared for hybrid scenarios, with `assert_matches_fixture/2`.
   - **test_run facet:** the output of `evaluate_run/3` is compared with `test_run.json`, normalising only the run-level `runDuration`.
   - **classifier facet:** compared with `classifications.json`.
3. **Unit tests.** All run on the Mock with no network:
   - Mode precedence and invalid values;
   - Limits boundaries (exactly 32k passes, +1 fails), with expected values generated by CPython and including non-ASCII text;
   - `verdict_from_probability` at 0.35, 0.5 and 0.65;
   - `value_from_answer` for not-applicable mass at 0.5 and zero credited mass;
   - the verbalise bands and the 0.15 runner-up margin;
   - `apportion`/`split_cost`, with a StreamData property that the parts sum to the total, plus half-even cases;
   - `State.merge` conflicts;
   - `Error.describe`/`format`;
   - the Ledger across `Usage.async`;
   - a permanent failure disabling later calls;
   - Python `:g` / `round(v, 3)` / `:.2f` against a CPython-generated table.
4. **TypeSafe adapter.** It is tested against a `Req.Test` stub: body shape, Bearer header, integer score keys, the cost formula, `max_tokens_exceeded` becoming `:context_limit` with nil limit, a bare 422 *not* becoming a context limit, retries on 429, 5xx and transport errors, and no retry on 401 or 403. It also runs `AdapterCase`.
5. **Contract.** `AdapterCase` runs against the Mock, TypeSafe (stubbed) and a toy third-party provider. A test runs Faithfulness's `system_one` and `hybrid` paths on the toy provider to show nothing is Jev-specific.
6. **Live check (P4-9).** `test/deep_eval_ex/live_system_one_test.exs`, tagged and excluded by default, runs against `jev-latest` when `TYPESAFE_API_KEY` is set. As built, it asks Jev a Noul, a Choice and a Score directly, then evaluates every System One fixture scenario Jev decides alone with the real adapter, checking each test run's shape, score range, model name and cost. `hybrid` mode and Jev's own overflow rejection are not exercised live (an oversized request is stopped by `Limits.check/3` before it is sent); the overflow reply was confirmed with a raw request. It settled the wire details listed above.

## Mapping of P3/P4 units

| Unit | Scope under this design | Change from the brief |
|---|---|---|
| P3-1 | `SystemOne.Adapter`, `Model`, facade `decide/3` (telemetry, error rescue, usage stamping), `Question`, `Answers`, `Error`, `DeepEvalError`, `ContextWindowExceededError` | `decide/3` **returns** usage instead of reporting it through `Usage.record`; errors are `%Error{}` |
| P3-2 | `SystemOne.Mode` (`resolve`, `for_classifier`, `effective`, `uses_system_one?`) | `effective/2` moves here from P3-6 |
| P3-3 | `SystemOne.Limits` | Code-point estimate with Python separators; a bare string is not dumped |
| P3-4 | `Adapters.Mock` (per-handle log, `from_fixture/1`), `AdapterCase` | Adds the conformance template |
| P3-5 | `Adapters.TypeSafe`, `LLM.Retry :typesafe`, `Pricing` jev-* | Only `max_tokens_exceeded` maps to a context limit (not "422 or"); lists the unverified wire details; Config accepts a price ≥ 0 |
| P3-6 | `Context.resolve!` (with Evaluator preflight), `Ledger`, `system_one_eval_spec/2` callback, `Result` in-memory fields, `strict_applied` bypass, `Usage.async/await` carrying the Ledger | **Drops the `whole_chain?` flag**: exporting the callback is the signal, as in deepeval |
| P3-7 | `Decision.probability/choice/score`, `handle_failure`, `format_reason` | No budget pre-check in hybrid helpers |
| P3-8 | `Decision.verdicts/3`, `verdict_from_probability`, `split_sentences` | None |
| P3-9 | `Scored.*`, `Outcome`, `Scored.parse!/1` | None |
| P3-10 | `Runner`, `State` (+ `Dumpable` protocol), `Scoring` | The Runner is called from each metric's `do_measure` and honours the batch prefetch |
| P3-11 | Seed usage, `Usage.source`, `summarize` filter, `LLM.Adapter.native?/0`, golden test_run comparisons | Adds the native notion and the nil-seed rule |
| **P3-12 (new)** | `Prompts.Python.format_g/1`, Python `round/2`, CPython table test | Split out because the reasons depend on it and it is a risk to retire early |
| P4-1..P4-3 | Faithfulness, AnswerRelevancy, ContextualPrecision, ContextualRecall and Hallucination specs plus the `Runner.run` call | None |
| P4-4 | ToolCorrectness `Spec.Score` over TOOL_SELECTION_LEVELS; `system_one_eval_spec/2` returns nil | No `whole_chain?` flag |
| P4-5 | GEval and ExactMatch regression tests | None |
| P4-6 | `Metrics.JevEval` (always System One, seeds as no-LLM) | The trace state waits for P9; ConversationalJevEval is deferred |
| P4-7 | `Batch.prefetch/3` in `Evaluator.run_single/3` | Candidates counted as in deepeval (spec-less included); settled by prefetch; failures through `Error.format/1` |
| P4-8 | `:request` span and `:fallback` event | Emitted by the facade, so it covers batch and unbatched calls alike |
| P4-9 | Live check | Also confirms the TypeSafe wire details |
| P8 | Classifiers on `Mode.for_classifier/1` and one `label` Choice | None |

The order is: P3-1, P3-2, P3-3 and P3-12 first, in parallel; then P3-4 and P3-6; then P3-7 to P3-11; then P3-5 and P4-*. P3-5 depends only on P3-1 and P3-3.

## Consequences

### Positive

- **Providers are interchangeable.** Jev, the Mock and any third-party model implement the same two callbacks and are covered by the same `AdapterCase`. The provider surface is smaller than deepeval's (no `a_decide`, no `noul`/`choice`/`score` overrides).
- **It fits the codebase.** `SystemOne.*` mirrors `LLM.*` (behaviour, `use` defaults, alias resolution, a Mock in `lib`), and the Ledger mirrors `Usage`.
- **Parity rules are pinned down.** Seeding, `Usage.source`, where the budget is checked, the set of errors that are handled, and batch candidate counting each have a stated rule, and each is tied to the fixture that exercises it.
- **Batching does not fork the result path.** A batched metric still goes through `BaseMetric.measure/2`, so strict handling, telemetry, usage and timeouts behave the same.
- **Scoring can change freely.** Weights and credits never reach the provider, so scoring rules change without touching the contract.

### Negative

- **Process-scoped state.** The Ledger lives in the process dictionary. Metrics that spawn plain `Task`s instead of `Usage.async` lose confidence and fallback reasons.
- **Ordered pairs instead of maps.** Choice options, probabilities, questions and state are lists of pairs or `Jason.OrderedObject`, because deepeval iterates them in insertion order.
- **Asymmetric usage reporting.** `decide/3` returns usage, while LLM adapters record it themselves.
- **Python names in strings.** `Error.type` carries strings such as `"ConnectionError"` to reproduce deepeval's text, and some messages keep deepeval's wording (`deepeval set-eval-mode llm`, `TYPESAFE_API_KEY`).
- **A hidden prefetch option.** `:system_one_prefetched` is an internal option.
- **One line per metric.** Each whole-chain metric repeats the `Runner.run/3` call.

### Neutral

- `LLM.Adapter` gains `native?/0`, and `Usage` gains `source`, which affects llm-mode exports only when a native adapter makes zero calls (see decision 2).
- `Config`'s `TYPESAFE_COST_PER_INPUT_TOKEN` validation changes from `> 0` to `>= 0`.
- Later phases (P5, P7, P9) add a `system_one_eval_spec/2` and specs per metric, and P9 adds `compact_trace` and multi-turn state.

## Alternatives Considered

### Faithful port: one Elixir module per deepeval module

`Config.EvalMode`, `Models.BaseSystemOneModel`, `Metrics.Utils.Decision`/`SystemOne`/`SystemOneBatch`, `{answers, cost}` returns and Python-named exception modules.

- **Kept from it:**
  - the per-metric `run_system_one_eval` call site, which avoids a sentinel for ToolCorrectness;
  - the `_system_one_error_types` filter;
  - the budget check placed only where deepeval places it;
  - the byte-for-byte decide facet.
- **Rejected as the overall shape:**
  - about 20 Python-named modules sit apart from the `LLM.*` layout;
  - there are two cost representations (`EvaluationCost` and `Usage`);
  - its estimator counted bytes, not code points;
  - its seed rule (seed only when native or absent) gives 4.2e-05 instead of null in `tool_correctness_hybrid`.

### Minimal provider surface with the Runner in the BaseMetric wrapper

A layered facade with `primitives/1` and a `:chain` sentinel for ToolCorrectness.

- **Kept from it:**
  - the wire/scored question split;
  - the conformance case template;
  - the per-handle Mock log;
  - the code-point estimator.
- **Rejected:**
  - running the Runner in the wrapper needs a sentinel (`:chain`/`:decisions_only`), and if that sentinel is mis-set, deepeval's "cannot judge" rule breaks ToolCorrectness;
  - its facade-level budget check and answer-completeness `DeepEvalError` change hybrid behaviour: a fallback where deepeval would call the model or crash;
  - `primitives/1` produces a fallback reason that deepeval never produces;
  - mapping a bare 422 to a context limit is wrong;
  - it left the hybrid seed open.

### Pure idiomatic design with batch candidates restricted to whole-form metrics

This is the base of this ADR.

- **Changed:** candidates are counted as deepeval counts them, the budget check moves out of the facade, `:decisions_only` is dropped in favour of the per-metric call, and the bare-422 mapping is dropped.
- **Its seed via `Pricing.cost(model, 0, 0)`** was replaced by an explicit `native?/0`. The pricing trick conflates "unpriced" with "custom", and it gives zero-token seeds that would add `inputTokenCount: 0` to the `*_hybrid_fallback` exports.

### Batch settling results directly (deepeval's `_settle`)

- **Rejected:** a second result-building path next to `measure/2` would drift on strict handling, telemetry and usage. The prefetch gives the same output through one path.

## Decisions

The maintainer accepted every recommended option below (2026-10-22).

### Decisions Needed From the Maintainer (resolved)

1. **Where the whole-chain runner is called.**
   - (a) Each metric calls `Runner.run/3` in `do_measure` (one `case` per metric).
   - (b) The BaseMetric wrapper calls it, with a sentinel return for ToolCorrectness.

   **Recommended: (a)**, because it mirrors deepeval's `measure()` exactly and needs no sentinel.
2. **The native-LLM notion for the cost seed, and whether it applies in `:llm` mode.**
   - (a) An optional `LLM.Adapter.native?/0` (default false; true for OpenAI, Anthropic and Ollama), seeding in every mode.
   - (b) The same, seeding only in `:hybrid`/`:system_one`.
   - (c) The `Pricing.cost(model, 0, 0)` trick.

   **Recommended: (a)**, after re-running the existing llm-mode parity fixtures. Fall back to (b) if any of them changes.
3. **How System One usage is kept from setting evaluationModel.**
   - (a) A `Usage.source` field, with `summarize` taking the model from `:llm` only.
   - (b) System One usages carry `model: nil`.

   **Recommended: (a)**, because it is typed and also labels the seed.
4. **The provider error contract.**
   - (a) A single `%SystemOne.Error{reason, type, permanent?}` with `describe/1` and `format/1`.
   - (b) Python-named exception modules (`Errors.ConnectionError`, ...).

   **Recommended: (a).** Also accept raised System One errors, and take `raised.type` from `error.type` or the module's last segment.
5. **The default `system_one_model` in app config** (`config :deep_eval_ex, system_one_model: {Mod, opts}`), which has no deepeval counterpart.
   - (a) Allow it as an Elixir-only extension.
   - (b) Keep it per metric or per run only.

   **Recommended: (a)**, defaulting to TypeSafe when unset.
6. **When construction-time failure happens.**
   - (a) An Evaluator preflight (`Context.resolve!` for every metric before any task) plus a check in `measure/2` for direct calls.
   - (b) A `Metric.new!/1` constructor.

   **Recommended: (a).** Struct metrics (GEval, JevEval) also validate in `new/1`.
7. **The optional `context_budget/1` callback.**
   - (a) Include it, defaulting to Jev's 32k/64k, which keeps parity.
   - (b) Hard-wire Jev's limits.

   **Recommended: (a).**
8. **A `primitives/1` capability callback for partial providers.**
   - (a) Defer it.
   - (b) Include it now.

   **Recommended: (a).** It is YAGNI, and it creates a fallback reason deepeval never produces.
9. **Wording of the deepeval messages** ("set TYPESAFE_API_KEY", "`deepeval set-eval-mode llm`", "rejected by Jev").
   - (a) Keep them literal for parity.
   - (b) Adapt them to Elixir (the `:eval_mode` option, config) and name the provider.

   **Recommended: (a)** for now. No fixture captures these texts, so revisit once parity is green.
10. **Where the System One Mock lives.**
    - (a) In `lib`, like `LLM.Adapters.Mock`, usable downstream.
    - (b) In `test/support`.

    **Recommended: (a).**
11. **How the Ledger travels across tasks.**
    - (a) Extend `Usage.async/await` to carry it.
    - (b) Introduce a general `DeepEvalEx.MeasureScope.async/await` now.

    **Recommended: (a)**, with a measure-scope helper as a follow-up when a third scope appears.
12. **Batch request timeout.**
    - (a) Bound requests by the test case's deadline.
    - (b) Use the minimum of the batched metrics' timeouts.
    - (c) Add a separate `system_one_timeout`.

    **Recommended: (a).**
13. **ConversationalJevEval and multi-turn state.**
    - (a) Defer them to P9 with the trace-state path.
    - (b) Include function heads now.

    **Recommended: (a).**
14. **TypeSafe 422 handling while the SDK is unverified.**
    - (a) Map only `detail.error_type == "max_tokens_exceeded"`, as deepeval does, and confirm with the live check.
    - (b) Also treat a bare 422 as a context limit.

    **Recommended: (a).**

## References

- deepeval 4.3.1 (`_ref/deepeval`):
  - `deepeval/config/eval_mode.py`
  - `deepeval/models/base_model.py`
  - `deepeval/models/system_one/{schema,limits,constants,typesafe_model}.py`
  - `deepeval/metrics/utils/{decision,qag,system_one,system_one_batch,models,test_case}.py`
  - `deepeval/metrics/jev_eval/*`
  - `deepeval/classifiers/base_classifier.py`
  - `tests/test_metrics/system_one_fakes.py`
- P0-3 fixtures: `test/fixtures/deepeval/system_one/` and the "System One fixtures" section of `test/fixtures/deepeval/README.md`
- [ADR-0001](0001-behaviour-based-plugin-architecture.md) Behaviour-Based Plugin Architecture
- [ADR-0003](0003-telemetry-first-observability.md) Telemetry-First Observability
- [ADR-0004](0004-concurrent-evaluation-with-task-async-stream.md) Concurrent Evaluation with Task.async_stream
- [ADR-0007](0007-basemetric-macro-for-instrumentation.md) BaseMetric Macro for Automatic Instrumentation
