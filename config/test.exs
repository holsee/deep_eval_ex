import Config

# Test-specific configuration
config :deep_eval_ex,
  # Use mock adapter in tests
  default_model: {:mock, "test-model"},

  # Lower timeouts for faster tests
  default_timeout: 5_000
