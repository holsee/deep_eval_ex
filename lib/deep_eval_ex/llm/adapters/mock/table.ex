defmodule DeepEvalEx.LLM.Adapters.Mock.Table do
  @moduledoc false

  # Owns the Mock adapter's named ETS table of configured responses and
  # recorded prompts, so the table outlives the processes that use it: an
  # ETS table dies with its owner, and a test process, Task or async_stream
  # worker that happened to create it would take every response and prompt
  # with it. Started by DeepEvalEx.Application; ensure/0 starts it
  # unsupervised when the application is not running.

  use GenServer

  @table :deep_eval_ex_mock_responses

  @spec start_link(term()) :: GenServer.on_start() | :ignore
  def start_link(_opts) do
    # Started on first use before the application? It keeps the table.
    case GenServer.start_link(__MODULE__, nil, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      started -> started
    end
  end

  # The table, created by its owner the first time it is needed. Only the
  # owner creates it, one request at a time, so racing first users cannot
  # create it twice.
  @spec ensure() :: atom()
  def ensure do
    case :ets.whereis(@table) do
      :undefined -> GenServer.call(owner(), :ensure_table)
      _ref -> @table
    end
  end

  defp owner do
    case GenServer.start(__MODULE__, nil, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(nil) do
    create_table()
    {:ok, nil}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, @table, state}
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end
  end
end
