defmodule DeepEvalEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Rate limiter for LLM API calls (future)
      # {DeepEvalEx.RateLimiter, []}
    ]

    opts = [strategy: :one_for_one, name: DeepEvalEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
