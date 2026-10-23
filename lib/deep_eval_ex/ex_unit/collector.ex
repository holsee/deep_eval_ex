# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/plugins/plugin.py (pytest_sessionstart,
# pytest_runtest_protocol), deepeval/test_run/test_run.py
# (TestRunManager.create_test_run, update_test_run) and
# deepeval/test_run/hyperparameters.py (log_hyperparameters)
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.ExUnit.Collector do
  @moduledoc """
  Collects the assertions of a `mix deep_eval.test` run into one test run,
  as deepeval 4.3.1's pytest plugin and `TestRunManager` collect every
  `assert_test` of a `deepeval test run` session.

  `Mix.Tasks.DeepEval.Test` starts one collector, registered under this
  module's name, before running the tests and drains it afterwards; nothing
  starts one under plain `mix test`, so assertions then record nothing, as
  under plain pytest. It holds:

  - the run being collected (`DeepEvalEx.TestRun.Manager.new/1`), to which
    `record/1` adds each evaluated test case, as `update_test_run`;
  - the tests of the run: the `use DeepEvalEx.ExUnit` setup registers each
    one (`register/1`) for its process, and `lookup/0` finds the test of the
    calling process, or of the process it was started from (a `Task`), as
    deepeval reads the running test's name from `PYTEST_RUN_TEST_NAME`;
  - the run's hyperparameters (`log_hyperparameters/1`) and test-run cache
    (`DeepEvalEx.TestRun.Cache.Store`);
  - the skipped tests `DeepEvalEx.ExUnit.Formatter` reports, and the
    warnings of failing flaky test cases.
  """

  use GenServer

  alias DeepEvalEx.Config
  alias DeepEvalEx.TestRun
  alias DeepEvalEx.TestRun.Manager

  @typedoc "A registered test: its full ExUnit name, module, file and tags."
  @type test_info :: %{test: String.t(), module: module(), file: String.t() | nil, tags: map()}

  @typedoc "A drained run (see `drain/0`)."
  @type drained :: %{
          cases: [TestRun.TestCase.t() | TestRun.ConversationalTestCase.t()],
          hyperparameters: [{String.t(), String.t()}] | nil,
          identifier: String.t() | nil,
          test_file: String.t() | nil,
          prompts: nil,
          skipped: [{String.t(), String.t()}],
          warnings: [{String.t() | nil, String.t()}]
        }

  @doc """
  Starts the run's collector, registered under this module's name (deepeval's
  `create_test_run`).

  ## Options

  - `:identifier` - The run's identifier
  - `:test_file` - The test path the run was given (its `testFile`)
  - `:cache` - The run's `DeepEvalEx.TestRun.Cache.Store`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    state = %{
      # `deepeval test run` never sets the run's prompts.
      run: Manager.new(identifier: opts[:identifier], test_file: opts[:test_file], prompts: nil),
      cache: opts[:cache],
      tests: %{},
      skipped: [],
      warnings: []
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @doc "Stops the collector."
  @spec stop() :: :ok
  def stop, do: GenServer.stop(__MODULE__)

  @doc """
  Whether a `mix deep_eval.test` run is collecting, deepeval's
  `get_is_running_deepeval()`: the `:running` setting is on and a collector
  is alive.
  """
  @spec active?() :: boolean()
  def active?, do: Config.get(:running) == true and is_pid(Process.whereis(__MODULE__))

  @doc """
  Registers the calling process as running the test of `context` (an
  ExUnit test context). Does nothing when no run is active.
  """
  @spec register(map()) :: :ok
  def register(%{test: test} = context) do
    if active?() do
      info = %{
        test: Atom.to_string(test),
        module: context[:module],
        file: context[:file],
        tags: context
      }

      call({:register, self(), info})
    else
      :ok
    end
  end

  @doc """
  The test the calling process runs, or `nil`: the one registered for this
  process, else for the first of its `$callers` (the processes that started
  it, such as a `Task`'s) that has one.
  """
  @spec lookup() :: test_info() | nil
  def lookup do
    if alive?(), do: call({:lookup, [self() | Process.get(:"$callers", [])]})
  end

  @doc """
  The name of the test the calling process runs (see `lookup/0`), or `nil`.
  """
  @spec test_name() :: String.t() | nil
  def test_name do
    case lookup() do
      %{test: test} -> test
      nil -> nil
    end
  end

  @doc """
  Adds an evaluated test case to the run, as deepeval's `update_test_run`
  (see `DeepEvalEx.TestRun.Manager.add/2`: a test case without metric data
  is left out).
  """
  @spec record(TestRun.TestCase.t() | TestRun.ConversationalTestCase.t()) :: :ok
  def record(api_test_case), do: call({:record, api_test_case})

  @doc """
  Sets the run's hyperparameters, as deepeval's `@log_hyperparameters`
  under `deepeval test run`: they are saved with the run and are part of
  every cache key of the run's test cases. Takes what
  `DeepEvalEx.TestRun.process_hyperparameters/1` takes. Does nothing when
  no collector is alive, as plain pytest keeps no run.
  """
  @spec log_hyperparameters(keyword() | map() | nil) :: :ok
  def log_hyperparameters(hyperparameters) do
    processed = TestRun.process_hyperparameters(hyperparameters)
    if alive?(), do: call({:hyperparameters, processed}), else: :ok
  end

  @doc """
  The run's hyperparameters as a map, the form cache keys use, or `nil`.
  """
  @spec cache_hyperparameters() :: %{String.t() => String.t()} | nil
  def cache_hyperparameters do
    case alive?() && call(:hyperparameters) do
      falsy when falsy in [nil, false] -> nil
      pairs -> Map.new(pairs)
    end
  end

  @doc "The run's test-run cache, or `nil`."
  @spec cache() :: GenServer.server() | nil
  def cache, do: if(alive?(), do: call(:cache))

  @doc """
  Notes a skipped test, `id` being its `<file>::<test name>`, for deepeval's
  `Test <id> was skipped. Reason: <reason>` line. Does nothing when no
  collector is alive.
  """
  @spec note_skipped(String.t(), String.t()) :: :ok
  def note_skipped(id, reason) do
    if alive?(), do: call({:skipped, id, reason}), else: :ok
  end

  @doc """
  Notes a warning of the calling process's test (a failing flaky test case),
  printed after the run with `--show-warnings`.
  """
  @spec warn(String.t()) :: :ok
  def warn(message) do
    id =
      case lookup() do
        %{file: file, test: test} when is_binary(file) ->
          "#{Path.relative_to_cwd(file)}::#{test}"

        %{test: test} ->
          test

        nil ->
          nil
      end

    call({:warning, id, message})
  end

  @doc """
  The run collected so far, with the skipped tests and warnings in the order
  they came: a `DeepEvalEx.TestRun.Manager` run to wrap up.
  """
  @spec drain() :: drained()
  def drain, do: call(:drain)

  defp alive?, do: is_pid(Process.whereis(__MODULE__))

  defp call(request), do: GenServer.call(__MODULE__, request, :infinity)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, pid, info}, _from, state) do
    unless Map.has_key?(state.tests, pid), do: Process.monitor(pid)
    {:reply, :ok, put_in(state.tests[pid], info)}
  end

  def handle_call({:lookup, pids}, _from, state) do
    {:reply, Enum.find_value(pids, &Map.get(state.tests, &1)), state}
  end

  def handle_call({:record, api_test_case}, _from, state) do
    {:reply, :ok, %{state | run: Manager.add(state.run, api_test_case)}}
  end

  def handle_call({:hyperparameters, processed}, _from, state) do
    {:reply, :ok, put_in(state.run.hyperparameters, processed)}
  end

  def handle_call(:hyperparameters, _from, state),
    do: {:reply, state.run.hyperparameters, state}

  def handle_call(:cache, _from, state), do: {:reply, state.cache, state}

  def handle_call({:skipped, id, reason}, _from, state),
    do: {:reply, :ok, %{state | skipped: [{id, reason} | state.skipped]}}

  def handle_call({:warning, id, message}, _from, state),
    do: {:reply, :ok, %{state | warnings: [{id, message} | state.warnings]}}

  def handle_call(:drain, _from, state) do
    drained =
      Map.merge(state.run, %{
        skipped: Enum.reverse(state.skipped),
        warnings: Enum.reverse(state.warnings)
      })

    {:reply, drained, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | tests: Map.delete(state.tests, pid)}}
end
