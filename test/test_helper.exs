ExUnit.start(exclude: [:live, :known_divergence])

# Configure test environment
Application.put_env(:deep_eval_ex, :default_model, {:mock, "test-model"})
