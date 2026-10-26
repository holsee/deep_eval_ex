defmodule DeepEvalEx.SystemOne.Model do
  @moduledoc """
  A resolved System One model: its adapter module, the adapter's options
  and its `model_name/1`. Built with `resolve/1` from any of the ways a
  System One model can be given, as `DeepEvalEx.LLM.Adapter.get_adapter/1`
  resolves an LLM adapter.

  ## Model specs

  - `nil` - the `:system_one_model` application config, else Jev through
    `DeepEvalEx.SystemOne.Adapters.TypeSafe`
  - a string - a TypeSafe model name, as deepeval's
    `system_one_model="jev-latest"`
  - `:typesafe` or `:jev` - `DeepEvalEx.SystemOne.Adapters.TypeSafe`
  - `:mock` - `DeepEvalEx.SystemOne.Adapters.Mock`
  - a module implementing `DeepEvalEx.SystemOne.Adapter`
  - `{module_or_alias, opts}` - the same, with the adapter's options

  For example:

      config :deep_eval_ex, system_one_model: {MyApp.LogprobJudge, api_key: "..."}

  The application config has no deepeval counterpart: deepeval takes the
  System One model per metric only.
  """

  alias DeepEvalEx.SystemOne.{Adapter, Error}

  @type t :: %__MODULE__{adapter: module(), opts: keyword(), name: String.t()}

  @typedoc "Anything `resolve/1` accepts."
  @type spec :: t() | String.t() | atom() | {atom(), keyword()} | nil

  @enforce_keys [:adapter, :name]
  defstruct [:adapter, :name, opts: []]

  @typesafe DeepEvalEx.SystemOne.Adapters.TypeSafe
  @mock DeepEvalEx.SystemOne.Adapters.Mock

  @doc """
  Resolves a model spec into a `%Model{}`, named by its adapter's
  `model_name/1`. A `%Model{}` is returned as it is.

  Raises `ArgumentError` for a spec that is none of the above or names a
  module that is not a loaded System One adapter.
  """
  @spec resolve(spec()) :: t()
  def resolve(%__MODULE__{} = model), do: model

  def resolve(spec) do
    {adapter, opts} = spec(spec)

    unless adapter?(adapter) do
      raise ArgumentError,
            "#{inspect(adapter)} is not a System One adapter: it must be a loaded module " <>
              "implementing DeepEvalEx.SystemOne.Adapter's decide/3 and model_name/1"
    end

    %__MODULE__{adapter: adapter, opts: opts, name: adapter.model_name(opts)}
  end

  @doc """
  The `{adapter, opts}` a model spec stands for, without loading the
  adapter.

  ## Examples

      iex> DeepEvalEx.SystemOne.Model.spec("jev-preview")
      {DeepEvalEx.SystemOne.Adapters.TypeSafe, [model: "jev-preview"]}

      iex> DeepEvalEx.SystemOne.Model.spec({:mock, model: "fake-jev"})
      {DeepEvalEx.SystemOne.Adapters.Mock, [model: "fake-jev"]}
  """
  @spec spec(spec()) :: {module(), keyword()}
  def spec(%__MODULE__{adapter: adapter, opts: opts}), do: {adapter, opts}

  def spec(nil) do
    case Application.get_env(:deep_eval_ex, :system_one_model) do
      nil -> {@typesafe, []}
      configured -> spec(configured)
    end
  end

  def spec(model) when is_binary(model), do: {@typesafe, model: model}
  def spec(adapter) when is_atom(adapter), do: {adapter(adapter), []}

  def spec({adapter, opts}) when is_atom(adapter) and is_list(opts), do: {adapter(adapter), opts}

  def spec(other) do
    raise ArgumentError,
          "invalid System One model: #{inspect(other)}; expected nil, a model name, " <>
            ":typesafe, :jev, :mock, an adapter module or {adapter, opts}"
  end

  @doc """
  The adapter module an alias stands for; any other module is returned as
  it is.

  ## Examples

      iex> DeepEvalEx.SystemOne.Model.adapter(:jev)
      DeepEvalEx.SystemOne.Adapters.TypeSafe
  """
  @spec adapter(atom()) :: module()
  def adapter(:typesafe), do: @typesafe
  def adapter(:jev), do: @typesafe
  def adapter(:mock), do: @mock
  def adapter(module) when is_atom(module), do: module

  defp adapter?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :decide, 3) and
      function_exported?(module, :model_name, 1)
  end

  @doc """
  Runs the adapter's `c:DeepEvalEx.SystemOne.Adapter.init/1`, which checks
  its options before any measure, and keeps the options it returns. An
  adapter without `init/1` accepts its options unchanged.
  """
  @spec init(t()) :: {:ok, t()} | {:error, Error.t()}
  def init(%__MODULE__{adapter: adapter, opts: opts} = model) do
    if function_exported?(adapter, :init, 1) do
      with {:ok, opts} <- adapter.init(opts) do
        {:ok, %{model | opts: opts, name: adapter.model_name(opts)}}
      end
    else
      {:ok, model}
    end
  end

  @doc """
  The token limits of a request to the model, its adapter's
  `c:DeepEvalEx.SystemOne.Adapter.context_budget/1`, else Jev's
  (`DeepEvalEx.SystemOne.Adapter.jev_budget/0`).
  """
  @spec context_budget(t()) :: Adapter.budget()
  def context_budget(%__MODULE__{adapter: adapter, opts: opts}) do
    if function_exported?(adapter, :context_budget, 1),
      do: adapter.context_budget(opts),
      else: Adapter.jev_budget()
  end
end
