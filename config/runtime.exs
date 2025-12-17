import Config

# Runtime configuration - loaded at runtime, not compile time
# This is where API keys and secrets should be configured

if config_env() == :prod do
  config :deep_eval_ex,
    openai_api_key: System.get_env("OPENAI_API_KEY"),
    anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
end

# Allow runtime override of default model
if model = System.get_env("DEEP_EVAL_DEFAULT_MODEL") do
  config :deep_eval_ex, default_model: {:openai, model}
end
