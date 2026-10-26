defmodule DeepEvalEx.Contestant do
  @moduledoc """
  One contestant of a `DeepEvalEx.ArenaTestCase`, deepeval 4.3.1's
  `Contestant` (`test_case/arena_test_case.py`): a named version of an
  application, with the test case it produced.

  ## Fields

  - `:name` - The contestant's name, unique within its arena test case
    (required)
  - `:test_case` - The `DeepEvalEx.TestCase` the contestant produced
    (required)
  - `:hyperparameters` - The settings that produced it, a map of string
    keys to strings, integers or floats, or `nil`

  deepeval's hyperparameter values may also be a `Prompt`, which DeepEvalEx
  does not port; name the prompt's alias or version as a string instead.

  ## Examples

      iex> {:ok, contestant} =
      ...>   DeepEvalEx.Contestant.new(
      ...>     name: "gpt-4o",
      ...>     test_case: [input: "What is 2 + 2?", actual_output: "4"],
      ...>     hyperparameters: [temperature: 0.7]
      ...>   )
      iex> {contestant.name, contestant.hyperparameters}
      {"gpt-4o", %{"temperature" => 0.7}}
  """

  alias DeepEvalEx.{MCP, TestCase}

  @type hyperparameter :: String.t() | integer() | float()

  @type t :: %__MODULE__{
          name: String.t(),
          test_case: TestCase.t(),
          hyperparameters: %{optional(String.t()) => hyperparameter()} | nil
        }

  @enforce_keys [:name, :test_case]
  defstruct [:name, :test_case, :hyperparameters]

  @keys ~w(name test_case hyperparameters)

  @doc """
  Builds a contestant from a keyword list or a map with atom or string
  keys; other keys are dropped, as deepeval's pydantic model drops them.

  `:test_case` may be a `DeepEvalEx.TestCase` or the attributes
  `DeepEvalEx.TestCase.new/1` takes. `:hyperparameters` may be a keyword
  list or a map with atom or string keys, kept as a map with string keys.
  As pydantic's `Union[str, int, float, ...]`, a boolean value becomes `1`
  or `0`.

  Returns `{:error, message}` when the name is not a string, the test case
  is missing or invalid, or a hyperparameter is not a string or a number.
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = contestant), do: {:ok, contestant}

  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         :ok <- check_name(attrs["name"]),
         {:ok, test_case} <- cast_test_case(attrs["test_case"]),
         {:ok, hyperparameters} <- cast_hyperparameters(attrs["hyperparameters"]) do
      {:ok,
       %__MODULE__{name: attrs["name"], test_case: test_case, hyperparameters: hyperparameters}}
    end
  end

  @doc """
  Builds a contestant like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, contestant} -> contestant
      {:error, message} -> raise ArgumentError, "Invalid contestant: " <> message
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, @keys) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error,
         "a contestant must be a Contestant, or the attributes Contestant.new/1 takes, got " <>
           inspect(attrs)}
    end
  end

  defp check_name(name) when is_binary(name), do: :ok
  defp check_name(name), do: {:error, "'name' must be a string, got #{inspect(name)}"}

  defp cast_test_case(%TestCase{} = test_case), do: {:ok, test_case}

  defp cast_test_case(attrs) when is_map(attrs) and not is_struct(attrs),
    do: build_test_case(attrs)

  defp cast_test_case([{key, _} | _] = attrs) when is_atom(key) do
    if Keyword.keyword?(attrs), do: build_test_case(attrs), else: test_case_error(attrs)
  end

  defp cast_test_case(other), do: test_case_error(other)

  defp build_test_case(attrs) do
    case TestCase.new(attrs) do
      {:ok, test_case} -> {:ok, test_case}
      {:error, errors} -> {:error, "'test_case' is invalid: " <> inspect(errors)}
    end
  end

  defp test_case_error(other) do
    {:error,
     "'test_case' must be a DeepEvalEx.TestCase, or the attributes TestCase.new/1 takes, got " <>
       inspect(other)}
  end

  defp cast_hyperparameters(nil), do: {:ok, nil}

  defp cast_hyperparameters(hyperparameters)
       when (is_map(hyperparameters) and not is_struct(hyperparameters)) or
              is_list(hyperparameters) do
    Enum.reduce_while(hyperparameters, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) or (is_atom(key) and not is_nil(key)) ->
        case cast_hyperparameter(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, to_string(key), value)}}
          :error -> {:halt, hyperparameter_error(key, value)}
        end

      entry, _acc ->
        {:halt, {:error, "'hyperparameters' keys must be strings, got #{inspect(entry)}"}}
    end)
  end

  defp cast_hyperparameters(other) do
    {:error, "'hyperparameters' must be a map, got #{inspect(other)}"}
  end

  defp cast_hyperparameter(true), do: {:ok, 1}
  defp cast_hyperparameter(false), do: {:ok, 0}

  defp cast_hyperparameter(value) when is_binary(value) or is_number(value),
    do: {:ok, value}

  defp cast_hyperparameter(_value), do: :error

  defp hyperparameter_error(key, value) do
    {:error,
     "'hyperparameters' values must be strings, integers or floats, got " <>
       "#{inspect(value)} for #{inspect(to_string(key))}"}
  end
end
