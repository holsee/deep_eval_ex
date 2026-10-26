# Test-Run Cache

A run with unchanged test cases and metrics need not pay for the same LLM
or System One calls twice. Like deepeval 4.3.1, DeepEvalEx keeps the
results of the last run in a cache file and, when you ask it to, reuses
them instead of measuring again.

## Writing and reading the cache

Every `DeepEvalEx.evaluate_run/3` (and `DeepEvalEx.evaluate/3`) writes the
cache, as deepeval's `evaluate()` does by default:

```elixir
DeepEvalEx.evaluate_run(test_cases, metrics)
#=> writes .deepeval/.deepeval-cache.json
```

Pass `use_cache: true` to reuse it:

```elixir
{results, test_run, _path} = DeepEvalEx.evaluate_run(test_cases, metrics, use_cache: true)
```

A metric whose result is cached for the same test case and configuration
is not measured: its result is the cached one, with `evaluation_cost: 0.0`
and no token counts, and `[:deep_eval_ex, :metric, :cache_hit]` is emitted
(see the [Telemetry](Telemetry.md) guide). A classifier with a cached
classification is not asked either; its verdict is checked again against
the test case's expected label.

## What is cached

An entry is keyed by the test case's `input`, `actual_output`,
`expected_output`, `context` and `retrieval_context`, the run's
hyperparameters, and its expectations with the evidence they are judged
on. The order of `context` does not matter; `name`, `tags` and tool calls
are not keyed.

Each entry holds the error-free results of that test case's metrics, each
with its configuration. A cached result is reused only by a metric of the
same name whose configuration matches: threshold, strict mode, judge,
`include_reason`, and the metric's own settings, such as GEval's criteria
or evaluation steps. The judge is part of it, so a result decided by a
System One model never stands in for the LLM's, nor the other way round.

Errored results are never cached, and conversational test cases are never
cached at all, as in deepeval.

## The files

The cache lives in the cache folder (`.deepeval/` by default; the
`:cache_folder` option, `config :deep_eval_ex, cache_folder:` or
`DEEPEVAL_CACHE_FOLDER`):

- `.deepeval-cache.json` is deepeval's file, byte for byte, so Python and
  Elixir runs can share the folder and reuse each other's results
- `.temp-deepeval-cache.json` holds the running run's entries, and is
  deleted when the run ends

As in deepeval, after a run the cache file holds only that run's entries:
a test case left out of a run is no longer cached. `write_cache: false`
neither reads nor writes the cache, and deletes both files. On a read-only
file system (`DEEPEVAL_FILE_SYSTEM=READ_ONLY`) nothing is read or written.

## Differences from deepeval

- deepeval 4.3.1 fails reading a cached expectations result back (its
  evaluator has no verdicts to rebuild). DeepEvalEx reuses it, with the
  cached `expectationsData`.
- `ENABLE_DEEPEVAL_CACHE` is not read by `evaluate_run/3`, as deepeval's
  `evaluate()` does not read it; pass `use_cache: true`.

See `DeepEvalEx.TestRun.Cache` and `DeepEvalEx.TestRun.Cache.Store`.
