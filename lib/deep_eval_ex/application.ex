defmodule DeepEvalEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Open traces and their spans (DeepEvalEx.Tracing)
      DeepEvalEx.Tracing.Store,
      # Owner of the Mock adapter's configured responses and recorded prompts
      DeepEvalEx.LLM.Adapters.Mock.Table,
      # Judge scripts of the Mock adapter's scripted mode, per process
      {Registry, keys: :unique, name: DeepEvalEx.LLM.Adapters.Mock.Scripts}
      # Rate limiter for LLM API calls (future)
      # {DeepEvalEx.RateLimiter, []}
    ]

    opts = [strategy: :one_for_one, name: DeepEvalEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
