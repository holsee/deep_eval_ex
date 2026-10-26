import Config

# Test-specific configuration
config :deep_eval_ex,
  # Use mock adapter in tests
  default_model: {:mock, "test-model"},

  # Lower timeouts for faster tests
  default_timeout: 5_000,

  # evaluate_run/3 prints deepeval's report and summary by default; keep
  # test output clean
  print_results: false,

  # Keep the latest-run snapshots out of the project's .deepeval/
  cache_folder: Path.expand("../tmp/deepeval_cache", __DIR__)
