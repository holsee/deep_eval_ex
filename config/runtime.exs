import Config

# Runtime configuration - loaded at runtime, not compile time
# This is where API keys and secrets should be configured

# Reads an environment variable, treating a blank value as unset so an empty
# variable never lands in config as an empty key or model name
present_env = fn name ->
  value = String.trim(System.get_env(name) || "")
  if value != "", do: value
end

if config_env() == :prod do
  for {key, var} <- [openai_api_key: "OPENAI_API_KEY", anthropic_api_key: "ANTHROPIC_API_KEY"],
      value = present_env.(var) do
    config :deep_eval_ex, [{key, value}]
  end
end

# Allow runtime override of default model
if model = present_env.("DEEP_EVAL_DEFAULT_MODEL") do
  config :deep_eval_ex, default_model: {:openai, model}
end
