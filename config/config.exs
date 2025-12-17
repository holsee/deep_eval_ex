import Config

config :deep_eval_ex,
  # Default LLM provider and model
  # Options: {:openai, model}, {:anthropic, model}, {:ollama, model}
  default_model: {:openai, "gpt-4o-mini"},

  # Default threshold for pass/fail (0.0 - 1.0)
  default_threshold: 0.5,

  # Maximum concurrent evaluations
  max_concurrency: 10,

  # Default timeout per metric evaluation (ms)
  default_timeout: 60_000

# Import environment specific config
import_config "#{config_env()}.exs"
