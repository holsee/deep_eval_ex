# ADR-0010: Test Runner, Console Report, Test-Run Cache, Classifiers and Expectations

## Status

Proposed

## Date

2026-10-23

## Context

Phase P8 covers the parts of deepeval 4.3.1 that sit around the evaluator rather than inside a metric:

- **`deepeval test run`** (`cli/test/command.py`) plus the pytest plugin (`plugins/plugin.py`) and `TestRunManager` (`test_run/test_run.py`). Together they collect every `assert_test` in a pytest session into one test run, wrap it up, print the results table and summary, and save it.
- **The console report** (`evaluate/console_report.py`, `EvaluationConsoleReport`), which `evaluate()` prints when `DisplayConfig.print_results` is true, and `display_results_table`, which the CLI prints.
- **The test-run cache** (`test_run/cache.py`), stored as `.deepeval/.deepeval-cache.json`, and its use in `evaluate/execute`.
- **Classifiers** (`deepeval/classifiers/*`): `BaseClassifier`, the generic `Classifier`, 13 built-ins, `Classification` rows and `TestCase.expected_labels`.
- **Expectations** (`dataset/expectations.py`, `evaluate/expectations.py`): must/must_not conditions judged by a private `_ExpectationEvaluator` and exported as `expectationsData`.

The P8 unit briefs are:

| Unit | Brief |
|---|---|
| P8-1 | Console report: `console_report.py` and `display_results_table`; all/failing/passing, `truncate_passing_cases`, summary (pass rate, cost, time) |
| P8-2 | ExUnit test-run collector plus `mix deep_eval.test`; flags `--repeat`, `-c`, `-i`, `-s`, `--identifier`, `-d`; one test run with `testFile`; `[:deep_eval_ex, :test_run, :stop]` as `on_test_run_end` |
| P8-3 | Test-run cache, interoperable file format, `evaluation_model` in the key, cost 0 for hits, batching skips cached metrics |
| P8-4 | Classifier framework and `expected_labels`, llm and system_one modes |
| P8-5 | Expectations and the expectation evaluator, `expectationsData` export |

Three designs were drawn up and judged:

- **A, faithful CLI.** It ports a subset of Rich for byte-exact terminal output, adds Manager and Cache GenServer singletons, and runs the wrap-up in the mix task after `mix test`.
- **B, ExUnit-native.** A formatter wraps `ExUnit.CLIFormatter` and owns the wrap-up. A Collector walks `$callers`. CLI flags go into a `:persistent_term` override layer, report parity is checked on the cell model, and the cache is byte-compatible.
- **C, minimal library-first.** It has a pure Report and Cache, a formatter that is also the collector, and a thin mix task. It rejects `--repeat`.

B scored best on balance. This ADR takes B as its base and grafts in A's flag surface and C's pure functions, with corrections from checking the reference and the toolchain.

Facts checked while writing this ADR:

1. **`mix test` returns to its caller after failures.** In Elixir 1.20.4, `lib/mix/lib/mix/tasks/test.ex:721-727` sets the failure exit status through `System.at_exit(fn _ -> exit({:shutdown, status}) end)`. A task that calls `Mix.Task.run("test", args)` therefore gets control back and can wrap up, which is exactly what `command.py` does after `pytest.main`. B's reason for a formatter-side wrap-up ("mix test exits on failure") does not hold.
2. **ExUnit's suite end is ordered.** `ExUnit.Runner` (`runner.ex:66-71`) sends `:suite_finished`, then calls `EventManager.stop/1`, which runs `GenServer.stop/3` on every formatter, and only then runs the `after_suite` callbacks. Anything printed after `Mix.Task.run("test")` returns comes after ExUnit's summary, so there is no interleaving and no need to wrap `CLIFormatter`.
3. **Under plain pytest, deepeval records nothing.** `pytest_sessionstart` creates the test run only when `get_is_running_deepeval()` is true, and only `command.py` calls `wrap_up_test_run`. Plain `pytest` prints "Running teardown with pytest sessionfinish..." and the skipped lines, but saves no run and writes no cache (`assert_test` uses `write_cache=get_is_running_deepeval()`).
4. **The test case name comes from the test.** `test_case/api.py:93` names an API test case `os.getenv(PYTEST_RUN_TEST_NAME, f"test_case_{order}")` when `test_case.name` is nil. The plugin sets that variable to the last nodeid segment, which is `test_foo[1-3]` under pytest-repeat, with no space before the bracket.
5. **Cache keys use the run's hyperparameters.** `cache.py` builds the key from input, actual_output, expected_output, context, retrieval_context (each `RetrievedContextData` flattened to `.context`) and `hyperparameters`. When the case has expectations it adds `expectations` and `expectation_evidence`. The key is `serialize(cache_dict)`. The hyperparameters are the test run's at execution time, so they are `None` under `evaluate()` and whatever `log_hyperparameters` set under the CLI.
6. **Cache reads and writes are tied together.** `get_cached_test_case` returns `None` when `disable_write_cache` is set, so `use_cache` without `write_cache` never hits. `wrap_up_cached_test_run` deletes both cache files when writes are disabled. Otherwise it writes the temp run (this run's entries) over the main file and deletes the temp file.
7. **`evaluate()` defaults.** `DisplayConfig` defaults to `print_results=True`, `display_option=ALL` and `truncate_passing_cases=True`, and `CacheConfig` defaults to `write_cache=True` and `use_cache=False`. `file_type`/`file_output_dir` are marked deprecated. `evaluate()` skips its own wrap-up in CLI mode.
8. **What DeepEvalEx already has.** `TestRun.JSON.encode!/2` already supports `ensure_ascii` (default true) with Python float repr. `Config.get/1` reads app config before the env (`config.ex:162`). `TestCase` already has `expected_labels` and `expectations`, and `TestResult.classifications` already exists as maps folded into success. `SystemOne.Batch.candidate?/3` documents "DeepEvalEx has no result cache". The `assert_test/3` behind `assert_evaluation/3` is private.

## Decision

P8 has five layers. Everything below the CLI is a library function that works without ExUnit.

1. **Evaluator-level features** (P8-4, P8-5, P8-3): classifiers, the expectations evaluator and the test-run cache. They are reached through options on `DeepEvalEx.evaluate/3`, `evaluate_run/3` and `assert_test`.
2. **A shared wrap-up** (`DeepEvalEx.TestRun.Manager.wrap_up/2`), a port of `wrap_up_test_run` used both by `evaluate_run/3` and by the CLI.
3. **The report** (P8-1): a pure row model whose cell strings match deepeval's byte for byte, a byte-exact Markdown export and summary text, and a small IO.ANSI renderer.
4. **The ExUnit collector** (P8-2): the `use DeepEvalEx.ExUnit` setup registers each test with a run-scoped Collector, and assertions record into it. A small sibling formatter forwards skipped-test events and prints nothing.
5. **The CLI** (P8-2): `mix deep_eval.test` ports `command.py`. It parses deepeval's flags, writes a run-scoped override layer, starts the Collector and a cache Store, calls `Mix.Task.run("test", args)` and then wraps up in the same order as deepeval.

The rules that pin down behaviour follow.

### 1. Run-scoped settings: the override layer

`DeepEvalEx.Config` gains a top-priority source, `put_run_overrides/1` and `clear_run_overrides/0`, stored in `:persistent_term` and checked before app config and env:

```elixir
def get(key) do
  {var, type, default} = setting!(key)

  with :error <- fetch_run_override(key),
       nil <- parse(config(key), type, "config :deep_eval_ex, #{inspect(key)}"),
       nil <- parse(env(var), type, var) do
    default
  end
  |> unwrap()
end
```

`Mix.Task.run("test")` reloads app config and `runtime.exs` after the task starts, so `Application.put_env` (design A) could be overwritten. The layer reproduces deepeval's in-process `set_should_*` edits, which beat `.env`.

New settings:

| Key | Env | Type | Default |
|---|---|---|---|
| `:running` | `DEEPEVAL` (`"YES"`) | boolean | `false` |
| `:repeat` | none | pos_integer | `nil` |
| `:display` | none | `:all \| :failing \| :passing` | `:all` |
| `:test_file` | none | string | `nil` |
| `:print_results` | none | boolean | `true` (see decision 3) |
| `:show_warnings` | none | boolean | `false` |

`:use_cache`, `:identifier`, `:ignore_errors`, `:skip_on_missing_params`, `:verbose_mode` and `:eval_mode` already exist and gain CLI reach. As in deepeval, the CLI always overrides `ignore_errors`, `skip_on_missing_params` and `verbose_mode` (false or nil when the flag is absent). It overrides `use_cache` with `use_cache and repeat == nil`, and sets `identifier` only when given.

### 2. `mix deep_eval.test`

```
mix deep_eval.test PATH[::TEST NAME | :LINE] [flags] [-- extra mix test args]
```

The task ports `command.py` step by step:

1. Parse argv with `DeepEvalEx.CLI.TestArgs.parse!/1`, which is pure. `-id` is found by a pre-scan, because OptionParser has no multi-letter short aliases.
2. Delete `<cache_folder>/.temp_test_run_data.json` and `<cache_folder>/.temp-deepeval-cache.json`.
3. Run `check_if_valid_file`: split on `::` and on a trailing `:<line>`, then raise `Mix.Error` with "Provided path is neither a valid file nor a directory."
4. Put the run overrides, including `running: true`.
5. If `--official` was given, print `Warning: --official requires a CONFIDENT_API_KEY environment variable to be set. Skipping.` verbatim. DeepEvalEx never has a Confident AI key.
6. Start the run: `Collector.start_link(identifier:, file_name: PATH)` and a cache `Store` for this run (section 6). Neither process is a permanent Application child, so library users do not pay for them.
7. Call `Mix.Task.run("test", TestArgs.mix_test_args(args))`, timing it with `System.monotonic_time/0` as deepeval times `pytest.main`.
8. Print the skipped-test lines the formatter collected: `Test <file>::<test name> was skipped. Reason: <reason>`. Only `{:skipped, reason}` tests count. `{:excluded, _}` tests (filtered by `--only`/`--exclude`) are not reported, just as pytest's skipped report ignores deselected items.
9. Call `TestRun.Manager.wrap_up(Collector.drain(), run_duration:, display_table: true, display:)`.
10. Emit `[:deep_eval_ex, :test_run, :stop]`, which stands in for `invoke_test_run_end_hook`.
11. Clear the overrides and stop the Collector and Store. Mix's own `at_exit` then sets the exit status (2 on failures by default; pytest uses 1).

The task requires `MIX_ENV=test`. If `Mix.env()` is not `:test`, it raises with a hint to add `def cli, do: [preferred_envs: ["deep_eval.test": :test]]` to mix.exs. It adds `--formatter DeepEvalEx.ExUnit.Formatter` and keeps `ExUnit.CLIFormatter`, unless the user passed formatters, in which case ours is appended to theirs.

**Flag mapping** (deepeval 4.3.1 `run` signature):

| deepeval | `mix deep_eval.test` | Effect |
|---|---|---|
| `test_file_or_directory` (required) | `PATH` (required) | `file::name` becomes `PATH --only test:"name"`; `file:line` passes through; `testFile` = PATH verbatim |
| `--color yes` | `--color yes\|no\|auto` | `yes` → `--color`, `no` → `--no-color`; also forces or disables colour in the renderer |
| `--durations 10` | `--durations N` (default 10) | `--slowest N`, passed by default as deepeval does; `0` omits it |
| `--pdb` | `--pdb` | raises with a hint: `iex -S mix deep_eval.test ... -- --breakpoints` |
| `-x/-X`, `--exit-on-first-failure` | same | `--max-failures 1` |
| `-w/-W`, `--show-warnings` | same | sets `:show_warnings`; flaky-failure warnings are printed after the table only when set, which mirrors `--disable-warnings` |
| `-id/--identifier` | same | `:identifier` override and `TestRun.identifier` |
| `-n/--num-processes` | same | `--max-cases N` (concurrency inside one VM, not OS processes) |
| `-r/--repeat` | same | `:repeat` override, read when the test files compile (section 4); `< 1` raises "The repeat argument must be at least 1."; disables `-c` |
| `-c/--use-cache` | same | `:use_cache` override |
| `-i/--ignore-errors` | same | `:ignore_errors` true/false |
| `-s/--skip-on-missing-params` | same | `:skip_on_missing_params` true/false |
| `-v/--verbose` | same | `:verbose_mode` true, otherwise nil; `--trace` is **not** added, because it changes concurrency |
| `-d/--display all\|failing\|passing` | same, case-insensitive | `:display` |
| `-m/--mark EXPR` | same | `tag` → `--only tag`, `not tag` → `--exclude tag`, `a or b` → `--only a --only b`; anything else (including `and`, which ExUnit filters cannot express) raises |
| `-o/--official` | same | prints the warning (step 5) |
| extra args | after `--`, or unknown options | appended to `mix test` (typer's `allow_extra_args`) |
| (none) | `--eval-mode llm\|hybrid\|system_one` | Elixir-only: `:eval_mode` override for the run (see decision 7) |

`TestArgs` is pure. It returns `{settings, mix_test_args, warnings}` and is table-tested against a fixture of the `pytest_args` deepeval builds for the same flags.

### 3. ExUnit integration: Collector, test names, formatter

`use DeepEvalEx.ExUnit` (which must come after `use ExUnit.Case`) injects:

- `import DeepEvalEx.ExUnit`;
- a `setup` that calls `Collector.register(context)` only when a run is active. It records `%{test: Atom.to_string(context.test), module:, file:, tags:}` for the test pid;
- the repeat-aware `test` macros (section 4).

`DeepEvalEx.ExUnit.Collector` is a GenServer, the in-memory counterpart of `TestRunManager.test_run` plus its temp file:

- `active?/0` is `Config.get(:running)` plus a live Collector. This is `get_is_running_deepeval()`.
- `lookup/1` resolves the calling test by walking `self()` and then `Process.get(:"$callers")`, so an assertion inside a `Task` still finds its test. This replaces the process-wide `PYTEST_RUN_TEST_NAME` variable.
- `record/2` is a synchronous `GenServer.call`. It receives the API test case (`TestRun.TestCase` or `TestRun.ConversationalTestCase`) and the run's evaluation cost. Like `update_test_run`, it drops a case whose `metricsData == []` (classifier-only) and appends in arrival order.
- `note_skipped/2` is called by the formatter.
- `log_hyperparameters/1` backs `DeepEvalEx.ExUnit.log_hyperparameters/1` (deepeval's `@log_hyperparameters`), which can be called from `test_helper.exs`. Those hyperparameters go into the run and into cache keys, as under `deepeval test run`.
- `drain/0` returns `%{cases, hyperparameters, identifier, test_file, skipped, warnings}`.

**Test case names.** When `test_case.name` is nil, the API name is the full ExUnit test name, for example `"test refund policy answer"`, `"test describe block refund policy answer"` or `"test refund policy answer[2-3]"`. Outside a run, the existing `test_case_<order>` fallback applies. See decision 4.

**Assertions.** `assert_test/2,3` becomes public and canonical. `assert_evaluation/3` and `assert_passes/3` delegate to it.

```elixir
defmacro assert_test(test_case, metrics, opts \\ [])   # opts: classifiers:, plus every evaluate/3 option
```

- Validation follows `validate_assert_test_inputs`: no metrics, no classifiers and no expectations raises the existing message. The threshold check is skipped when the case has expectations.
- Cache config follows `CacheConfig(write_cache=get_is_running_deepeval(), use_cache=should_use_cache())`: `write_cache: Collector.active?()`, `use_cache: Config.get(:use_cache)`, with the run's Store handle.
- Failure messages: the subject is "Metrics", "Classifiers" or "Metrics and classifiers", and a classification part reads `name (label: …, expected: …, error: …, reason: …)`. A flaky case warns instead of failing; inside a run the warning goes to `Collector` for `-w`, otherwise to `IO.warn` as today.
- `assert_fails/3` and `assert_score/4`, which have no deepeval counterpart, never record (decision 9).

`DeepEvalEx.ExUnit.Formatter` is a minimal GenServer formatter. It forwards `{:test_finished, %{state: {:skipped, reason}}}` to the Collector and ignores every other event. It prints nothing, so output order is fixed by the task.

**Plain `mix test`** keeps today's behaviour: assertions assert and nothing is recorded, saved or cached, as under plain pytest. deepeval's "Running teardown with pytest sessionfinish..." line is not printed (decision 6).

### 4. `--repeat`

pytest-repeat re-runs the whole test function, including the application call that produces `actual_output`. DeepEvalEx gets the same effect at compile time. `use DeepEvalEx.ExUnit` does `import ExUnit.Case, except: [test: 1, test: 2, test: 3]` and imports `DeepEvalEx.ExUnit.Repeat`, whose `test/1,2,3` macros:

- read `Config.get(:repeat)` when the macro expands. Test `.exs` files are compiled inside `mix test`, after the override is set;
- with `nil` or `1`, expand to exactly one `ExUnit.Case.test(name, ...)`, so nothing changes for normal runs;
- with `N > 1`, expand to N `ExUnit.Case.test("#{name}[#{i}-#{n}]", ...)` registrations, the pytest-repeat id with no space.

Design A's `@before_compile` expansion cannot work, because ExUnit has already turned test bodies into functions by then. Repeats apply only to modules that `use DeepEvalEx.ExUnit`, and they run concurrently under `async: true`, not back to back.

### 5. The shared wrap-up: `TestRun.Manager`

```elixir
defmodule DeepEvalEx.TestRun.Manager do
  @type collected :: %{cases: [TestRun.TestCase.t() | TestRun.ConversationalTestCase.t()],
                       hyperparameters: map() | nil, identifier: String.t() | nil,
                       test_file: String.t() | nil, evaluation_cost: float() | nil}

  @doc "Pure fold, TestRunManager.update_test_run; lets non-ExUnit runners build a run."
  @spec add(collected(), TestRun.TestCase.t() | TestRun.ConversationalTestCase.t()) :: collected()

  @doc "wrap_up_test_run minus Confident AI."
  @spec wrap_up(collected(), keyword()) :: {TestRun.t() | nil, Path.t() | nil}
  # opts: run_duration:, display_table: boolean, display: :all | :failing | :passing,
  #       cache: Cache.Store.t() | nil, device: IO.device(), read_only:, results_folder:, results_subfolder:
end
```

`wrap_up/2` follows deepeval's order:

1. "No test cases found, please try again." for an empty run.
2. The all-metrics-errored warning.
3. `runDuration`, then `calculate_test_passes_and_fails`, then `sort_test_cases` with `_assign_unique_orders`.
4. `Cache.Store.wrap_up/1`.
5. With `display_table`, `Report.ResultsTable`.
6. The hyperparameters and prompts warnings.
7. `LocalStore.write_rolling/write/write_latest`.
8. The completion summary.

The function returns the run and its path. `evaluate_run/3` is refactored to call it with `display_table: false`. When `Collector.active?()` it records into the Collector and does not wrap up, as `evaluate()` does in CLI mode. A classifier-only `evaluate_run/3` has no test run and returns `{results, nil, nil}`.

### 6. Test-run cache

**Pure part: `DeepEvalEx.TestRun.Cache`**

- `key(test_case, hyperparameters)` ports `utils.serialize` over `cache_dict`. Dicts are sorted recursively, lists are sorted by the `json.dumps` text of each item, and the result is encoded with `TestRun.JSON.encode!/2` (ensure_ascii, `", "`/`": "` separators, Python float repr). `RetrievedContextData` is flattened to `.context`. `expectations` (`model_dump(mode="json")`) and `expectation_evidence` are added only when the expectations are truthy.
- `CachedTestRun`, `CachedTestCase`, `CachedMetricData`, `MetricConfiguration`, `CachedClassification` and `ClassifierConfiguration` structs have `to_map/from_map` that match pydantic's by-alias, `exclude_none` dump in field order. `encode!/1` produces the bytes of `CachedTestRun.save`. `decode/1` treats a corrupt file as empty, as `create_cached_test_run` does.
- `metric_configuration(metric, opts)` ports `create_metric_configuration`. It calls a new optional `BaseMetric` callback, `cache_configuration(opts) :: map()`. The default derives these fields from the resolved opts:
  - `threshold` (after strict, stored as a float);
  - `evaluation_model`, the LLM adapter's model name in llm and hybrid, and the System One model name under `:system_one`, read from the `SystemOne.Context` resolved at preflight;
  - `strict_mode`, `include_reason` and `n`;
  - `evaluation_params` as deepeval enum strings.

  GEval, JevEval and DAG-like metrics override it for `criteria`, `evaluation_steps` and `assessment_questions`. `embeddings` is stored as a class name.
- `same_metric_config?/2` ports `same_metric_configs` including its quirks. `language` is compared but never stored, so a metric with `language` set always misses. `evaluation_steps` falls back to `criteria` for GEval.
- `metric_data/3` returns a hit only for an error-free row with a non-nil score. `classification/2` requires the same name, labels with descriptions, model, `include_reason` and `allow_none`, and no error. It recomputes `expected_label` and `success` from the current test case.

**Process part: `DeepEvalEx.TestRun.Cache.Store`**

This is a GenServer per run. It is not a global singleton, so concurrent `evaluate_run/3` calls in async tests do not share state.

```elixir
@spec start_link(write_cache: boolean(), folder: Path.t()) :: GenServer.on_start()
@spec lookup(t(), key :: String.t()) :: CachedTestCase.t() | nil   # nil when writes disabled or read-only
@spec put(t(), key :: String.t(), CachedTestCase.t()) :: :ok       # main map + fresh map; fresh written through
@spec wrap_up(t()) :: :ok                                           # main file := fresh; delete temp | delete both
```

- It loads the main file lazily on the first lookup.
- `put/3` updates the in-memory main map, so a duplicate test case later in the same run can hit, as `cache_test_case` does. It also updates the fresh map and writes it to `.temp-deepeval-cache.json` with a tmp-then-rename write.
- With `DEEPEVAL_FILE_SYSTEM=READ_ONLY` it is inert, which is deepeval's `portalocker is None`.
- `evaluate_run/3` starts a Store for its own call. The CLI starts one per run and the Collector hands it to assertions.

**Evaluator integration** (`Evaluator.run_single/3`, LLM test cases only; conversational cases are never cached):

1. If `use_cache`, look the key up once.
2. Hits become results through `TestRun.MetricData.to_result/1`, with `evaluationCost` 0, and emit `[:deep_eval_ex, :metric, :cache_hit]`.
3. Pass `cached: MapSet.new(hit_indices)` to `SystemOne.Batch.prefetch/3`. `candidate?/3` returns false for those indices *before* the at-least-two threshold, which fulfils ADR-0009 §8. Indices stay the original metric positions so the `m<j>.` prefixes are unchanged; the fixtures pin this.
4. Measure the remaining metrics, then run the classifiers (section 7), hydrating cached classifications.
5. In an `after` block, write a new `CachedTestCase` built from error-free `MetricData` with cost 0 (hits included) and error-free classifications.

Options on `evaluate/3`, `evaluate_run/3` and `assert_test`:

- `:use_cache` (default `Config.get(:use_cache)`);
- `:write_cache` (default `true` for `evaluate_run/3`, as `CacheConfig` has it, and `Collector.active?()` for assertions; see decision 2);
- `:cache` (`@doc false`, a Store handle).

For `evaluate_run/3` the key's hyperparameters are always nil, because deepeval attaches them after execution. Under the CLI they are `log_hyperparameters/1`'s value.

### 7. Classifiers

```elixir
defmodule DeepEvalEx.Classifier do
  defstruct [:name, :labels, :model, :system_one_model, :eval_mode, :template, :impl,
             include_reason: true, allow_none: false]
  @type label :: {name :: String.t(), description :: String.t() | nil}

  @spec new!(keyword()) :: t()          # normalize_labels: non-empty, NONE reserved, case-insensitive duplicates
  @spec classify(t(), TestCase.t() | ConversationalTestCase.t(), keyword()) :: DeepEvalEx.Classification.t()
  @spec success(DeepEvalEx.Classification.t(), expected :: String.t() | nil) :: boolean() | nil

  @doc "Optional: custom classifiers (deepeval subclasses of BaseClassifier)."
  @callback classify(t(), test_case :: struct(), keyword()) ::
              {:ok, %{label: String.t() | nil, reason: String.t() | nil}} | {:error, term()}
  @optional_callbacks classify: 3
end

defmodule DeepEvalEx.Classifiers do        # the 13 built-ins as constructors returning %Classifier{}
  def refusal(opts \\ []), do: ...
  # abstention/1, clarification/1, data_leakage/1, escalation/1, forbidden_commitments/1,
  # instruction_completeness/1, prompt_injection/1, required_disclosure/1 (disclosures:),
  # resolution/1, response_language/1, scope_adherence/1 (scope:), tone_adherence/1 (tone:)
end
```

- **Mode and context.** The mode comes from `SystemOne.Mode.for_classifier/1` (hybrid becomes llm). `SystemOne.Context.resolve!` runs in the Evaluator preflight, so `evaluation_model` is fixed before any task.
- **`:llm`.** One schema call over `classify_single_turn` or `classify_multi_turn`, returning `{label, reason}`.
- **`:system_one`.** One `SystemOne.choice/3` keyed `"label"`. The options are the labels (name ⇒ description), plus NONE when `allow_none`. The state comes from `construct_single_turn_state` or `construct_multi_turn_state`, and the reason from `Scoring.classification_reason/2`. Classifiers are not batched, matching deepeval.
- **Both modes** then apply `resolve_label` (exact match, then case-insensitive, then NONE) and `_finalize`, whose error text is "Judge returned 'x', which is not one of the declared labels (…)". Cost seeds follow ADR-0009: native gives 0, custom gives nil.
- **`DeepEvalEx.Classification`** is a struct with deepeval's fields: `name, label, expected_label, success, reason, evaluation_model, error, evaluation_cost, input_tokens, output_tokens`. It replaces today's maps on `TestResult.classifications`, folds into the case's success, appears in the cache and the console report, and **never** in `TestRun.to_map/1`.
- **`Classifier.Utils.validate!/2`** ports `validate_classifiers`: the struct check, unique names, invalid `expected_labels` values, and one aggregated `Logger.warning` for unknown keys. It runs at preflight and in `assert_test`.
- **`Prompts.Classifier`** holds `classify_single_turn`, `classify_multi_turn` and `_experimental_system_one_classify`.

### 8. Expectations

`DeepEvalEx.Metrics.Expectations` (`@moduledoc false`) ports `_ExpectationEvaluator`:

- It is named "Expectations", with threshold 1.0, strict.
- **Mode.** `Mode.for_classifier(Config.get(:eval_mode) || expectations.eval_mode)`. The env wins here, the reverse of metrics; this deepeval quirk is kept.
- **Cache separation.** `criteria` is `json.dumps({"eval_mode": …, "system_one_model": …}, sort_keys=True)`, so cache entries separate by mode and Jev model.
- **`:llm`.** A verdicts call, the ID check, "Unable to evaluate expectations: …", then the reason call.
- **`:system_one`.** `system_one_eval_spec/2` returns one Choice per condition (`pass` 1, `fail` 0, `unable_to_evaluate` 0) with `extra_state: %{observed_case: evidence}`, through `SystemOne.Runner`. It can therefore batch like any whole-form metric.
- **Injection.** The Evaluator adds it per case that has expectations (`with_expectation_evaluators`, `metrics_for_expectations`).
- **Export.** `TestRun.from_results/3` writes its row as the case's `expectationsData` (`success, score, reason, verdicts, evaluationModel, evaluationCost, error`). The cost update is copied from `update_metric_data`. The row is dropped from `metricsData` and `metricsScores` but still counts toward `valid_scores` (`test_run.py:273`).
- **Evidence.** `DeepEvalEx.Dataset.Expectations.evidence/1` ports `expectation_evidence` (`model_dump(mode="json", exclude_none=True)` over the fixed field set) and is shared with `Cache.key/2`.

### 9. Console report

There are two tiers, and neither ports Rich's layout engine:

- **A row model with byte parity.** `Report.Console.build(test_results, display:, truncate_passing_cases:) :: [section]` and `Report.ResultsTable.rows(test_run, display) :: [row]` return exactly the strings deepeval passes to Rich (panel titles, tree labels, `Table.add_row` cells), with markup kept as data (`{:style, "bold red", text}`). The ported rules are:
  - natural sort by index, then name;
  - the `display` filter, with the "All N test cases passed — no failing…" panels;
  - 47-character reason truncation plus "...";
  - `f"{x:.2f}"` and `round(x, 2)` through `Prompts.Python`;
  - statuses PASS/FAIL/ERROR/NONE in the report and PASSED/FAILED/ERRORED/NONE in the table;
  - flaky sub-counts, separator rows and conversational turn tables;
  - the Aggregate Metrics and Aggregate Classifiers tables, with label distribution and pass rate.

  Rows that only advertise Confident AI are tagged `:confident_ai` (decision 6).
- **Byte-exact text outside tables.** `Report.Summary` prints:
  - the hyperparameters warning with its 80-character `=` rule;
  - "No prompts logged.";
  - the all-errored warning;
  - `✓ Evaluation completed 🎉! (time taken: Xs | token cost: Y USD|None)`;
  - `» Test Results (N total tests):` and `» Pass Rate: P% | Passed: a | Failed: b`.

  `Report.Markdown` ports `export_to_markdown`, which is plain string building, and is reached through `file_output_dir:`.

`Report.Terminal` renders sections with box-drawing characters and IO.ANSI. It honours `IO.ANSI.enabled?/0`, `NO_COLOR`, `--color`, `COLUMNS` and `:io.columns/0` (default 80), and counts wide emoji and CJK as two cells. It looks like deepeval's output but is not byte-identical, and snapshot tests cover it.

`evaluate_run/3` prints the report and the summary when `print_results` is true. `DeepEvalEx.evaluate/3` never prints unless the caller passes `print_results: true` (decision 3). Further options are `display: :all | :failing | :passing`, `truncate_passing_cases: true` and `file_output_dir: nil`.

### 10. Telemetry

Following ADR-0003:

- `[:deep_eval_ex, :test_run, :stop]` carries measurements `%{duration: native, test_passed: n, test_failed: n}` and metadata `%{test_run: TestRun.t(), path: Path.t() | nil, identifier: String.t() | nil, source: :cli | :evaluate_run}`. It is emitted by the task and by `evaluate_run/3` and stands in for `@deepeval.on_test_run_end`.
- `[:deep_eval_ex, :metric, :cache_hit]` carries `%{metric: name, test_case: name}`.

No separate hook registry is added.

### Public API and user code

```elixir
# mix.exs
def cli, do: [preferred_envs: ["deep_eval.test": :test]]

# test/test_helper.exs
ExUnit.start()
DeepEvalEx.ExUnit.log_hyperparameters(%{"model" => "gpt-4.1", "prompt_version" => "v3"})

# test/evals/refund_eval_test.exs
defmodule MyApp.RefundEvalTest do
  use ExUnit.Case, async: true
  use DeepEvalEx.ExUnit                       # after ExUnit.Case

  alias DeepEvalEx.{Classifiers, TestCase}
  alias DeepEvalEx.Metrics.{AnswerRelevancy, Faithfulness}

  test "refund policy answer" do
    tc =
      TestCase.new!(
        input: "Can I get a refund on a used ticket?",
        actual_output: MyApp.Bot.answer("Can I get a refund on a used ticket?"),
        retrieval_context: MyApp.Docs.refund_policy(),
        expected_labels: %{"refusal" => "refused"},
        expectations: %{must: ["States the refund policy"], must_not: ["Promises a refund"]}
      )

    assert_test(tc, [Faithfulness, {AnswerRelevancy, threshold: 0.7}],
      classifiers: [Classifiers.refusal()]
    )
  end
end
```

```sh
mix deep_eval.test test/evals -c -i -d failing --identifier nightly -n 8 -m rag
mix deep_eval.test 'test/evals/refund_eval_test.exs::test refund policy answer' -r 3
DEEPEVAL_EVAL_MODE=system_one TYPESAFE_API_KEY=... mix deep_eval.test test/evals -c
mix deep_eval.test test/evals -- --seed 0
mix test                       # unchanged: assertions only, no run, no cache
```

In a `mix deep_eval.test` run the user sees ExUnit's dots and failure blocks, then any skipped lines, the `Test Results` table, the warnings and the summary. The run writes `.deepeval/.latest_run_full.json`, `.latest_test_run.json` and `.deepeval-cache.json`, plus `test_run_<ts>.json` when a results folder is set. With `-c`, a second run reads unchanged metrics from the cache at cost 0, makes no LLM or Jev calls for them, and leaves them out of the System One batch.

Library use:

```elixir
{results, test_run, path} =
  DeepEvalEx.evaluate_run(test_cases, [Faithfulness],
    classifiers: [Classifiers.refusal(), Classifiers.scope_adherence(scope: "billing")],
    use_cache: true, display: :failing, file_output_dir: "reports")

Report.Console.build(test_results, display: :all) |> Report.Terminal.render() |> IO.write()

:telemetry.attach("ci-upload", [:deep_eval_ex, :test_run, :stop], &MyCI.upload/4, nil)
```

### Module map

| Module | Ports | Unit |
|---|---|---|
| `DeepEvalEx.Classifier`, `Classifier.Utils`, `DeepEvalEx.Classification` | `base_classifier.py`, `classifier/classifier.py`, `utils.py`, `test_run/api.py` Classification | P8-4 |
| `DeepEvalEx.Classifiers` (13 constructors) | `classifiers/*.py` built-ins | P8-4 |
| `DeepEvalEx.Prompts.Classifier` | `classifier/templates` | P8-4 |
| `DeepEvalEx.Metrics.Expectations` (private) | `evaluate/expectations.py` | P8-5 |
| `Dataset.Expectations.evidence/1`, `TestRun.ExpectationsData` | `dataset/expectations.py`, `create_expectations_data` | P8-5 |
| `TestRun.Cache` (+ `Cached*`, `MetricConfiguration`, `ClassifierConfiguration`), `TestRun.Cache.Store` | `test_run/cache.py` | P8-3 |
| `BaseMetric.cache_configuration/1` (optional callback) | `create_metric_configuration` | P8-3 |
| `Evaluator` cache, classifier and expectations wiring; `SystemOne.Batch` `cached:` | `evaluate/execute`, `system_one_batch._candidates` | P8-3 (+ P8-4, P8-5 hooks) |
| `TestRun.Manager` (`add/2`, `wrap_up/2`) | `TestRunManager.update_test_run`, `wrap_up_test_run`, `sort_test_cases` | P8-1 |
| `Report.Console`, `Report.ResultsTable`, `Report.Summary`, `Report.Markdown`, `Report.Terminal` | `console_report.py`, `display_results_table`, wrap-up prints | P8-1 |
| `Config` run overrides and new settings | `set_should_*`, `set_is_running_deepeval` | P8-2 |
| `DeepEvalEx.CLI.TestArgs`, `Mix.Tasks.DeepEval.Test` | `cli/test/command.py` | P8-2 |
| `DeepEvalEx.ExUnit` (extended), `ExUnit.Collector`, `ExUnit.Repeat`, `ExUnit.Formatter` | `plugins/plugin.py`, `assert_test`, pytest-repeat | P8-2 |

## Parity mapping to deepeval 4.3.1

| deepeval | DeepEvalEx |
|---|---|
| `deepeval test run` | `mix deep_eval.test`, same flags (section 2); exit code is mix's (2), not pytest's (1) |
| `set_is_running_deepeval(True)`, `set_should_*`, `set_identifier` | `Config.put_run_overrides/1` |
| `pytest_sessionstart` → `create_test_run(identifier, file_name)` | `Collector.start_link/1` in the task, `testFile` = PATH |
| `pytest_runtest_protocol` → `PYTEST_RUN_TEST_NAME` | `use DeepEvalEx.ExUnit` setup plus the `$callers` lookup |
| `pytest_runtest_call` Observer/EvalSession | not ported (P9 trace scope) |
| `pytest_sessionfinish` "Running teardown…" | not printed (decision 6) |
| `pytest_terminal_summary` skipped lines | printed by the task from formatter events; `{:skipped, _}` only |
| `TEMP_FILE_PATH` | deleted at start for hygiene; run state lives in the Collector |
| `update_test_run` | `Collector.record/2` → `Manager.add/2` |
| `wrap_up_test_run(run_duration, display_table, display)` | `Manager.wrap_up/2` |
| `invoke_test_run_end_hook` | `[:deep_eval_ex, :test_run, :stop]` |
| `evaluate()` skips wrap-up when running deepeval | `evaluate_run/3` records into the Collector when `active?` |
| `DisplayConfig.print_results/display_option/truncate_passing_cases/file_output_dir` | `evaluate_run/3` options; `file_type="html"` not ported |
| `CacheConfig(write_cache, use_cache)` | `:write_cache`, `:use_cache` |
| `CACHE_FILE_NAME`, `TEMP_CACHE_FILE_NAME` | same names under `:cache_folder` |
| `serialize(cache_dict)` | `Cache.key/2` |
| `get_cached_test_case` returns None when writes disabled | `Store.lookup/2` returns nil |
| `cache_test_case` (main in memory + temp on disk) | `Store.put/3` |
| `wrap_up_cached_test_run` | `Store.wrap_up/1` (main := this run; delete both when disabled) |
| `same_metric_configs`, `create_metric_configuration` | `Cache.same_metric_config?/2`, `metric_configuration/2` via `cache_configuration/1` |
| `system_one_batch._candidates` cache check | `Batch.candidate?/3` honours `cached:` |
| `BaseClassifier`, `Classifier`, `Label`, `NONE_LABEL` | `%Classifier{}`, label tuples, `"NONE"` |
| built-in classifier classes | `DeepEvalEx.Classifiers.*` constructors |
| `resolve_classifier_eval_mode` | `Mode.for_classifier/1` |
| `SystemOneClassifySpec` | one `"label"` Choice |
| `copy_classifiers` | unnecessary (immutable structs) |
| `validate_classifiers` | `Classifier.Utils.validate!/2` |
| `_ExpectationEvaluator`, `with_expectation_evaluators`, `metrics_for_expectations` | `Metrics.Expectations` plus Evaluator injection |
| `construct_metrics_scores` skipping the expectations row | `TestRun.from_results/3` |
| `EvaluationConsoleReport.render_to_terminal` | `Report.Console` + `Report.Terminal` (row parity) |
| `export_to_markdown` / `export_to_html` | `Report.Markdown` (byte parity) / not ported |
| `display_results_table` | `Report.ResultsTable` (row parity) |
| `deepeval set-eval-mode` | not ported; `--eval-mode` on the task (decision 7) |

**Known divergences:**

- Terminal layout is not byte-identical to Rich.
- Exit codes differ.
- `-n` gives concurrency in one VM rather than OS processes.
- `-m` supports only `tag`, `not tag` and `or`.
- `--pdb` is rejected.
- Repeats run concurrently.
- `--eval-mode` is an extra flag.

## Dependencies

None.

- **Rendering.** It uses IO.ANSI and hand-drawn box characters. Owl and TableRex lay text out differently from Rich, so neither would give byte parity. Parity is pinned on the row model, which needs no library.
- **Locking.** Each run gets its own Store process, which serialises writes, and writes use tmp-then-rename. This replaces portalocker.
- **Repeats and parallelism.** pytest-repeat and xdist have no counterpart: the repeat macro and `--max-cases` cover them.
- **JSON.** It stays on Jason and `TestRun.JSON`, which already has `ensure_ascii`.

## Testing strategy

**1. Parity fixtures from real deepeval.** A new generator, `scripts/parity/generate_runner_fixtures.py`, runs in the devcontainer against deepeval 4.3.1 with stub metrics, the scripted LLM judge and the System One fakes. It writes `test/fixtures/deepeval/`:

- **`classifiers/<scenario>/`:**
  - prompt goldens for the three templates;
  - llm-mode scripted runs: exact label, case-insensitive match, NONE with and without `allow_none`, an undeclared-label error;
  - system_one runs (`decide.json`, reason, cost seed), with the existing `refusal_classifier_system_one` scenario wired into a real classifier facet;
  - the 13 built-ins' names, labels and descriptions;
  - `validate_classifiers` and `normalize_labels` errors as `raised.json`;
  - `assert_test` messages with classifier failures.
- **`expectations/<scenario>/`:**
  - llm runs (verdict and reason prompts);
  - system_one runs (`decide.json` with one Choice per condition and the `observed_case` state);
  - `unable_to_evaluate` as `raised.json`;
  - `test_run.json` with `expectationsData` and no Expectations row in `metricsData` or `metricsScores`.
- **`cache/<scenario>/`:**
  - `keys.json`: `serialize()` outputs for a corpus covering unicode, unsorted lists, nested dicts, retrieval context objects, hyperparameters and expectations with evidence;
  - `metric_configurations.json`: `create_metric_configuration` for every DeepEvalEx metric (default, strict, custom model, GEval criteria and steps, hybrid, system_one with a fake Jev), plus `same_metric_configs` truth tables;
  - two-run scenarios: a cold run writes `.deepeval-cache.json` (exact bytes), and a warm run with `use_cache` gives `test_run.json` (cost 0), the final cache bytes and the stub call log;
  - one of three system_one metrics cached (`decide.json` shows a two-metric batch with the original `m<j>.` prefixes) and two of three cached (one candidate, no batch);
  - errored metric, conversational case, cached classification, `write_cache=False` deleting both files, and a duplicate test case in one run hitting.

  The Elixir side also loads deepeval's warm-run input file and must hit.
- **`report/<scenario>/`:**
  - the generator monkeypatches `rich.table.Table.add_row`, `Panel.__init__` and `Tree.add` to capture `rows.json` and `sections.json`;
  - `Console(record=True, width=120, color_system=None)` captures `summary.txt`, with time normalised;
  - `export_to_markdown` writes `report.md` under a fixed filename.

  Scenarios: all passing, mixed, errored, score-only (NONE), flaky, conversational, classifiers with and without expected labels, display all/failing/passing, and truncation on and off.
- **`cli/<scenario>/`:**
  - `deepeval test run` over a small pytest file with stub metrics (one failing, one flaky, one skipped), under flag combinations (`-c`, `-i`, `-d failing`, `--identifier`, `-r 2`, `-o`, `-x`, `-m`);
  - it records the `pytest_args` (patched `pytest.main`), `.latest_test_run.json`, the cache bytes, the deepeval-owned stdout after the ExUnit/pytest summary, and the exit code.

**2. Elixir parity tests.**

- Classifier, expectations and cache facets run against the fixtures, encoding with `TestRun.JSON`.
- Report tests compare `build/2` and `rows/2` with `rows.json` and `sections.json`, compare `Report.Summary` and `Report.Markdown` byte for byte, and snapshot `Report.Terminal`.
- `CLI.TestArgs` is checked semantically against `pytest_args.json`.
- An `@tag :cli` integration test runs `System.cmd("mix", ["deep_eval.test", ...])` in a fixture project, `test/fixtures/projects/runner/`, that mirrors the pytest file. It compares `.latest_test_run.json` (only `runDuration` normalised) and the cache bytes, and checks that the exit status is non-zero on failure. The mirrored tests use `name:` on test cases, plus one unnamed case to pin the naming rule.

**3. Unit tests (no network, Mocks from ADR-0009).**

- **Config:** override precedence over app config and env.
- **TestArgs:** every flag, the `-id` pre-scan, `-x/-X` and `-w/-W` pairs, repeat versus cache, `repeat < 1`, `-m` translations and rejections.
- **Collector:** `$callers` lookup, 100 concurrent records, the classifier-only drop, `active?`.
- **Repeat:** the macro expands to N named tests and stays a single plain test when unset, checked with a compiled fixture module.
- **Formatter:** synthetic events.
- **Manager.wrap_up:** empty run, order assignment, metricsScores without the expectations row, telemetry shape, files in a tmp `:cache_folder`.
- **Store:** lazy load, a corrupt file read as empty, read-only inert, atomic writes, wrap-up replace and delete.
- **Evaluator:** a cached metric is never measured (Mock call count 0); a Jev result is never served to the same metric in llm mode.
- **Classifier:** label validation, `resolve_label`, mode resolution, success folding, and no classifications in `TestRun.to_map/1`.
- **Expectations:** injection only for cases with expectations, criteria per mode.

**4. Existing suites stay green.** `config/test.exs` sets `print_results: false`, and every cache default is inert until a unit opts in.

## Mapping of P8 units

The units are reordered so that the runner lands last, on a complete Evaluator. The cache key depends on `expectation_evidence` (P8-5) and stores classifications (P8-4), and the report shows both.

| Order | Unit | Scope under this design | Change from the brief | Effort |
|---|---|---|---|---|
| 1 | P8-4 Classifiers | `%Classifier{}`, `Classifiers.*` constructors, optional `classify/3` callback, `Classification` struct, `Utils`, `Prompts.Classifier`, Evaluator `:classifiers` option, assert messages | Built-ins are constructor functions, not modules; `Classification` becomes a struct | L |
| 2 | P8-5 Expectations | `Metrics.Expectations`, `Expectations.evidence/1`, `ExpectationsData` export, injection, `assert_test` accepting expectation-only cases | None | M |
| 3 | P8-3 Cache | `TestRun.Cache`, `Cache.Store` per run, `cache_configuration/1` callback, Evaluator hit/write path, `Batch` `cached:` | Store is per run, not a global singleton; same-run hits kept | L |
| 4 | P8-1 Report and wrap-up | `Report.*`, `TestRun.Manager.add/2` and `wrap_up/2`, `evaluate_run/3` refactor, `print_results`/`display`/`truncate_passing_cases`/`file_output_dir`, `:test_run, :stop` from `evaluate_run` | Takes the shared wrap-up from P8-2; row-model parity, not terminal bytes; Markdown export added | L |
| 5 | P8-2 CLI and collector | Config overrides, `CLI.TestArgs`, `mix deep_eval.test`, `Collector`, `Repeat`, `Formatter`, `log_hyperparameters/1`, public `assert_test`, fixture project | Wrap-up runs in the task after `mix test` returns; full flag surface | L |

P8-4 and P8-5 can proceed in parallel. P8-3 needs both. P8-1's row model can start alongside P8-3, but its classifier and expectations rows need P8-4 and P8-5. P8-2 comes last. If decision 7 chooses (b), a P8-6 unit adds `mix deep_eval.set_eval_mode`.

## Consequences

### Positive

- **Drop-in CLI.** Every `deepeval test run` flag is accepted with deepeval's meaning or a clear message. The wrap-up order, files and cache semantics match `command.py`, which keeps CI scripts portable.
- **No coupling to ExUnit internals.** The wrap-up after `Mix.Task.run("test")` relies only on documented behaviour (verified in Elixir 1.20.4). The formatter only forwards skip events and does not wrap `CLIFormatter`.
- **Cache interop.** `.deepeval-cache.json` is byte-compatible, so Python and Elixir teams can share `.deepeval/`. Cached metrics never reach a System One batch, which closes ADR-0009 §8.
- **Library-first.** Classifiers, expectations, the cache and the report work from `evaluate_run/3`, a script or Livebook. `Manager.add/2` lets other runners build a run.
- **Async-safe.** Per-run Store and Collector processes keep concurrent runs and async tests isolated.

### Negative

- **Terminal output only resembles deepeval's.** Byte parity holds for cell strings, summary text and Markdown, not for Rich's layout.
- **deepeval's cache surprises are inherited.**
  - The cache file holds only the last run.
  - `evaluate_run/3` writes the cache by default.
  - `write_cache: false` deletes it.
  - llm and hybrid results share entries.
  - A metric with `language` set always misses.
  - `retrieval_context` order is ignored.
- **Use order matters.** `use DeepEvalEx.ExUnit` must come after `use ExUnit.Case`, and it replaces the imported `test` macros.
- **The override layer is hidden state.** During `mix deep_eval.test` it silently outranks the user's `config/*.exs`, which is deepeval's semantics.
- **Exit codes** follow mix (2) rather than pytest (1, 2, 5).

### Neutral

- `TestResult.classifications` changes from maps to `%Classification{}` structs.
- `BaseMetric` gains an optional `cache_configuration/1` callback.
- `SystemOne.Batch.prefetch/3` gains a `cached:` option.
- The Python-named messages ("Provided path is neither…", the `--official` warning) stay literal, consistent with ADR-0009 decision 9.

## Alternatives Considered

### Faithful port with a Rich subset and global singletons (design A)

- **Kept from it:**
  - the full flag surface, including `--official`, `-w/-W`, `-x/-X`, `--durations`, `--color` and `-id`;
  - task-side wrap-up in deepeval's order;
  - `[i-N]` repeat naming;
  - the `TestArgs` pytest-args fixture;
  - the two-file cache model.
- **Rejected:**
  - Porting Rich's Table, Panel, Tree, `divide_line` wrapping and cell-width tables is the largest and most fragile piece, and it ties fixtures to Rich's version. The fixtures would also need width and colour pinned on both sides.
  - `Application.put_env` overrides can be overwritten when `mix test` loads config.
  - `@before_compile` cannot duplicate tests.
  - Process-dictionary test names break inside Tasks.
  - Feeding `evaluate(hyperparameters:)` into the cache key diverges from deepeval-written keys.
  - Manager and Cache singletons in the Application cost library users and break async test isolation.

### ExUnit-native formatter owning the lifecycle (design B, the base)

- **Kept from it:**
  - the `$callers` Collector;
  - the `:persistent_term` override layer;
  - the replacement `test` macro;
  - the byte-compatible cache with main and temp maps;
  - `log_hyperparameters/1`;
  - the `cached?` batch flag;
  - the unit reordering;
  - this ADR itself.
- **Changed:**
  - The wrap-up moves from the formatter to the task. B's reason ("mix test exits on failure") is wrong for Elixir 1.20.4, and wrapping `CLIFormatter` in-process couples to its private callbacks.
  - Repeat ids drop the space (`name[i-N]`).
  - `-w`, `-o`, `--color` and `--durations` are supported rather than rejected.
  - `@moduletag :deep_eval` is not added automatically.

### Minimal library-first surface (design C)

- **Kept from it:**
  - pure `Cache` and report functions;
  - `Manager.add/2` as a pure fold;
  - byte-exact Markdown;
  - `Classifiers.refusal/1`-style constructors;
  - the custom `classify/3` callback;
  - keeping `DeepEvalEx.evaluate/3` silent.
- **Rejected:**
  - An immutable cache threaded through concurrent tasks loses same-run hits and the crash-time temp file.
  - Sibling formatters that print can interleave with ExUnit's summary.
  - `__ENV__.function` test names break in helpers.
  - Rejecting `--repeat` and the display flags loses parity.

### Wrap-up in `ExUnit.after_suite/1`

`after_suite` callbacks run after every formatter has stopped (`runner.ex:66-71`), so the ordering would be correct, and plain `mix test` could produce runs. It was rejected as the default because deepeval does not wrap up under plain pytest. It remains a possible opt-in (decision 5).

## Decisions Needed From the Maintainer

1. **Cache retention semantics.**
   - (a) deepeval parity: after a run the file holds only that run's entries, and `write_cache: false` deletes both cache files.
   - (b) Merge and keep old rows (deepeval can still read the file).

   **Recommended: (a)**, documented in the CHANGELOG and the parity README, with a later Elixir-only `cache_merge: true` if users ask.
2. **Should `evaluate_run/3` write `.deepeval/.deepeval-cache.json` by default** (`CacheConfig.write_cache=True`)?
   - (a) Yes, for parity.
   - (b) Only when `use_cache` or `write_cache` is passed.

   **Recommended: (a).** `evaluate_run/3` already writes `.latest_run_full.json` there, `config/test.exs` points `cache_folder` at `tmp/`, and the CHANGELOG notes the new file.
3. **Printing by default.**
   - (a) `evaluate_run/3` prints the console report and summary (deepeval's `print_results=True`), `DeepEvalEx.evaluate/3` stays silent, and `config :deep_eval_ex, print_results: false` turns printing off globally.
   - (b) Silent by default everywhere, opt-in with an option.
   - (c) Both functions print.

   **Recommended: (a)**, with `print_results: false` in our own `config/test.exs` before any P8 unit lands.
4. **Test case naming in a run when `name` is nil.**
   - (a) The full ExUnit name (`"test describe refund policy answer[2-3]"`).
   - (b) Strip the `test ` prefix.
   - (c) A snake_case pytest-like name.

   **Recommended: (a).** It is unique, it keeps describe context, and the parity fixtures set names explicitly.
5. **Plain `mix test` producing a run.**
   - (a) No. Only `mix deep_eval.test` records and wraps up, matching plain pytest.
   - (b) Add an opt-in `DeepEvalEx.ExUnit.start_run/1` for `test_helper.exs` that registers an `ExUnit.after_suite/1` wrap-up.

   **Recommended: (a) for P8**, with (b) as a follow-up if asked for.
6. **Confident AI and pytest-isms in output.** These are the "Note: Use Confident AI…" table row, the "deepeval view" footer, the doc links in warnings, and "Running teardown with pytest sessionfinish...".
   - (a) Print them verbatim.
   - (b) Keep them in the row model, so parity fixtures still compare them, but do not render them; keep the warnings without links; never print the pytest teardown line.

   **Recommended: (b).** Keep the `--official` warning literal, because it is accurate.
7. **`deepeval set-eval-mode`.**
   - (a) Do not port it. Add `--eval-mode` to `mix deep_eval.test` and point users at `DEEPEVAL_EVAL_MODE` or `config :deep_eval_ex, eval_mode:`.
   - (b) Port `mix deep_eval.set_eval_mode` with `--save dotenv[:path]` plus a small dotenv loader for `mix deep_eval.*` tasks (new unit P8-6, S).

   **Recommended: (a).** Revisit ADR-0009 decision 9's literal "`deepeval set-eval-mode llm`" message together with the other wording once parity is green.
8. **Hybrid and llm sharing cache rows** (same `evaluation_model`).
   - (a) Keep parity.
   - (b) Add `eval_mode` to `MetricConfiguration`, which breaks hits on deepeval-written caches.

   **Recommended: (a)**, recorded as a known divergence candidate. Expectations already separate by mode through `criteria`.
9. **Do `assert_fails/3` and `assert_score/4` record into the run?**
   - (a) No; they stay local assertions.
   - (b) Yes.

   **Recommended: (a)**, because recording would show "failed" metrics for passing tests. Document it.
10. **Report parity depth.**
    - (a) Row model plus byte-exact summary and Markdown, with the IO.ANSI renderer covered by snapshots.
    - (b) Also port a Rich subset for terminal-byte parity at a fixed width and colour.

    **Recommended: (a).** (b) can be a later, separate unit if terminal-byte parity becomes a requirement.
11. **Custom classifiers in P8.**
    - (a) Include the optional `classify/3` callback (`impl:`).
    - (b) Only the label-set `Classifier`.

    **Recommended: (a)**, because it is cheap and mirrors subclassing `BaseClassifier`.
12. **`-m/--mark` coverage.**
    - (a) `tag`, `not tag` and `a or b` only; anything else raises with a message.
    - (b) A custom ExUnit filter that evaluates arbitrary pytest mark expressions against tags.

    **Recommended: (a).**
13. **Unit order.** P8-4, then P8-5, then P8-3, then P8-1, then P8-2. P8-1 absorbs the shared wrap-up.

    **Recommended: accept.** Update `units__P8-*.json` and add this ADR to the index as Proposed.

## References

- deepeval 4.3.1 (`_ref/deepeval`):
  - `deepeval/cli/test/command.py`
  - `deepeval/plugins/plugin.py`
  - `deepeval/evaluate/{evaluate,console_report,configs,expectations}.py`
  - `deepeval/evaluate/execute/*`
  - `deepeval/test_run/{test_run,cache,api}.py`
  - `deepeval/test_case/api.py`
  - `deepeval/classifiers/*`
  - `deepeval/dataset/expectations.py`
  - `deepeval/metrics/utils/system_one_batch.py`
- Elixir 1.20.4:
  - `lib/mix/lib/mix/tasks/test.ex:721-727` (failure exit via `System.at_exit`);
  - `lib/ex_unit/lib/ex_unit/runner.ex:66-71` (`suite_finished`, formatter stop, `after_suite`).
- Fixtures: `test/fixtures/deepeval/README.md`; new sets `classifiers/`, `expectations/`, `cache/`, `report/`, `cli/`.
- [ADR-0003](0003-telemetry-first-observability.md) Telemetry-First Observability
- [ADR-0004](0004-concurrent-evaluation-with-task-async-stream.md) Concurrent Evaluation with Task.async_stream
- [ADR-0007](0007-basemetric-macro-for-instrumentation.md) BaseMetric Macro for Automatic Instrumentation
- [ADR-0009](0009-system-one-models-and-eval-modes.md) System One Models and Eval Modes (§8 batching, classifiers note, decision 9)
