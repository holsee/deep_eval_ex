defmodule DeepEvalEx.Dataset.Expectations do
  @moduledoc """
  The required and prohibited behaviour of a golden or test case, deepeval
  4.3.1's `Expectations` (`dataset/expectations.py`), kept as plain data.

  An expectations map has deepeval's four fields:

  - `:must` - Conditions the output must meet (strings, default `[]`)
  - `:must_not` - Conditions the output must not meet (strings, default `[]`)
  - `:model` - The model name to judge them with, or `nil`
  - `:eval_mode` - `:llm`, `:system_one` or `nil`

  DeepEvalEx carries expectations from goldens to test cases and back, as
  deepeval does; no metric judges them yet. deepeval also takes a live
  `DeepEvalBaseLLM` as `model`, but serialises only a model name, so
  `:model` is a string here.

  `cast/1` validates as deepeval's pydantic model does (see its doc).
  """

  @typedoc "Expectations, as deepeval's `Expectations` model."
  @type t :: %{
          model: String.t() | nil,
          eval_mode: :llm | :system_one | nil,
          must: [String.t()],
          must_not: [String.t()]
        }

  # deepeval's validation keys; must_not is listed before its mustNot alias
  @key_aliases [
    model: ["model"],
    eval_mode: ["eval_mode"],
    must: ["must"],
    must_not: ["must_not", "mustNot"]
  ]

  @known_keys @key_aliases |> Keyword.values() |> List.flatten()

  @eval_modes %{"llm" => :llm, "system_one" => :system_one}

  @doc """
  Validates expectations given as a map or keyword list with atom or string
  keys, and returns them with deepeval's defaults filled in.

  As deepeval's model (`extra="forbid"`), any key other than `model`,
  `eval_mode`, `must`, `must_not` and its alias `mustNot` is an error, and
  so is `mustNot` alongside `must_not`. Each condition must be a string
  that is not blank, and is stripped of surrounding whitespace. `eval_mode`
  must be `"llm"` or `"system_one"` (exactly, or as an atom).

  `nil` (deepeval's `None`, no expectations) is returned as it is. Errors
  have the shape of a Peri custom validator's, so a schema can call it.

  ## Examples

      iex> DeepEvalEx.Dataset.Expectations.cast(%{"must" => [" Cite a source "]})
      {:ok, %{model: nil, eval_mode: nil, must: ["Cite a source"], must_not: []}}
  """
  @spec cast(term()) :: {:ok, t() | nil} | {:error, String.t(), keyword()}
  def cast(nil), do: {:ok, nil}

  def cast(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: cast(Map.new(attrs)), else: invalid(attrs)
  end

  def cast(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {key_string(k), v} end)

    with :ok <- check_keys(attrs),
         {:ok, model} <- cast_model(field(attrs, :model, nil)),
         {:ok, eval_mode} <- cast_eval_mode(field(attrs, :eval_mode, nil)),
         {:ok, must} <- cast_conditions(field(attrs, :must, []), "must"),
         {:ok, must_not} <- cast_conditions(field(attrs, :must_not, []), "must_not") do
      {:ok, %{model: model, eval_mode: eval_mode, must: must, must_not: must_not}}
    end
  end

  def cast(attrs), do: invalid(attrs)

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: key

  # The value of the first key naming the field, or the default when none is
  # given; a given nil stays nil, as pydantic does not default it
  defp field(attrs, field, default) do
    case Enum.find(Keyword.fetch!(@key_aliases, field), &Map.has_key?(attrs, &1)) do
      nil -> default
      key -> Map.fetch!(attrs, key)
    end
  end

  defp check_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @known_keys)) do
      [] when is_map_key(attrs, "must_not") and is_map_key(attrs, "mustNot") ->
        {:error, "expectations take must_not or mustNot, not both", []}

      [] ->
        :ok

      unknown ->
        {:error, "expectations do not take %{keys}", [keys: inspect(unknown)]}
    end
  end

  defp cast_model(model) when is_nil(model) or is_binary(model), do: {:ok, model}

  defp cast_model(model) do
    {:error, "expectations model must be a model name, got %{model}", [model: inspect(model)]}
  end

  defp cast_eval_mode(nil), do: {:ok, nil}
  defp cast_eval_mode(mode) when mode in [:llm, :system_one], do: {:ok, mode}

  defp cast_eval_mode(mode) when is_map_key(@eval_modes, mode),
    do: {:ok, Map.fetch!(@eval_modes, mode)}

  defp cast_eval_mode(mode) do
    {:error, "expectations eval_mode must be 'llm' or 'system_one', got %{mode}",
     [mode: inspect(mode)]}
  end

  defp cast_conditions(conditions, field) when is_list(conditions) do
    if Enum.all?(conditions, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.map(conditions, &String.trim/1)}
    else
      {:error, "expectations %{field} must contain non-empty conditions", [field: field]}
    end
  end

  defp cast_conditions(conditions, field) do
    {:error, "expectations %{field} must be a list of conditions, got %{value}",
     [field: field, value: inspect(conditions)]}
  end

  defp invalid(value) do
    {:error, "expectations must be a map, got %{value}", [value: inspect(value)]}
  end
end
