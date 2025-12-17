import Config

# Development-specific configuration
config :deep_eval_ex,
  # Use a faster/cheaper model in dev
  default_model: {:openai, "gpt-4o-mini"}
