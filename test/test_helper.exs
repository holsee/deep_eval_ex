ExUnit.start(exclude: [:live, :live_system_one, :known_divergence])

# Configure test environment
Application.put_env(:deep_eval_ex, :default_model, {:mock, "test-model"})
