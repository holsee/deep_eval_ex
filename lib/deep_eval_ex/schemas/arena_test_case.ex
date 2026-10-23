defmodule DeepEvalEx.ArenaTestCase do
  @moduledoc """
  Contestants answering the same input, to be compared head to head,
  deepeval 4.3.1's `ArenaTestCase` (`test_case/arena_test_case.py`).

  Each `DeepEvalEx.Contestant` names a version of an application (a model,
  a prompt, a set of hyperparameters) and holds the `DeepEvalEx.TestCase`
  it produced. As deepeval's `__post_init__`, `new/1` checks that:

  - the contestant names are unique,
  - every test case has the same `:input`, and
  - every test case has the same `:expected_output`,

  in that order, returning deepeval's message for the first that fails.

  ## Fields

  - `:contestants` - The contestants, a non-empty list of
    `DeepEvalEx.Contestant` (required)
  - `:multimodal` - Whether any contestant's test case holds images
    (default: `false`); `new/1` sets it when one does, and keeps
    `multimodal: true` given

  ## Examples

      iex> {:ok, arena} =
      ...>   DeepEvalEx.ArenaTestCase.new(
      ...>     contestants: [
      ...>       [name: "gpt-4o", test_case: [input: "What is 2 + 2?", actual_output: "4"]],
      ...>       [name: "claude", test_case: [input: "What is 2 + 2?", actual_output: "Four."]]
      ...>     ]
      ...>   )
      iex> Enum.map(arena.contestants, & &1.name)
      ["gpt-4o", "claude"]

      iex> DeepEvalEx.ArenaTestCase.new(
      ...>   contestants: [
      ...>     [name: "a", test_case: [input: "What is 2 + 2?", actual_output: "4"]],
      ...>     [name: "b", test_case: [input: "What is 3 + 3?", actual_output: "6"]]
      ...>   ]
      ...> )
      {:error, "All contestants must have the same 'input'."}
  """

  alias DeepEvalEx.{Contestant, MCP}

  @type t :: %__MODULE__{
          contestants: [Contestant.t(), ...],
          multimodal: boolean()
        }

  @enforce_keys [:contestants]
  defstruct contestants: nil, multimodal: false

  @keys ~w(contestants multimodal)

  @doc """
  Builds an arena test case from a keyword list or a map with atom or
  string keys; other keys are dropped.

  `:contestants` is a list of `DeepEvalEx.Contestant` structs, or of the
  attributes `DeepEvalEx.Contestant.new/1` takes.

  Returns `{:error, message}` when a contestant is invalid, there are no
  contestants (where deepeval raises an `IndexError`), or the contestants
  break one of the checks above, with deepeval's message:

  - `"All contestant names must be unique."`
  - `"All contestants must have the same 'input'."`
  - `"All contestants must have the same 'expected_output'."`
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         {:ok, contestants} <- cast_contestants(attrs["contestants"]),
         :ok <- check_unique_names(contestants),
         :ok <- check_shared(contestants, :input, "input"),
         :ok <- check_shared(contestants, :expected_output, "expected_output") do
      {:ok,
       %__MODULE__{
         contestants: contestants,
         multimodal:
           attrs["multimodal"] == true or Enum.any?(contestants, & &1.test_case.multimodal)
       }}
    end
  end

  @doc """
  Builds an arena test case like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, arena} -> arena
      {:error, message} -> raise ArgumentError, "Invalid arena test case: " <> message
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, @keys) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error, "an arena test case takes a keyword list or a map, got #{inspect(attrs)}"}
    end
  end

  defp cast_contestants([]), do: {:error, "'contestants' must not be empty"}

  defp cast_contestants(contestants) when is_list(contestants) do
    Enum.reduce_while(contestants, {:ok, []}, fn attrs, {:ok, acc} ->
      case Contestant.new(attrs) do
        {:ok, contestant} -> {:cont, {:ok, [contestant | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp cast_contestants(other) do
    {:error, "'contestants' must be a list of contestants, got #{inspect(other)}"}
  end

  defp check_unique_names(contestants) do
    names = Enum.map(contestants, & &1.name)

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, "All contestant names must be unique."}
  end

  defp check_shared([first | rest], field, name) do
    reference = Map.fetch!(first.test_case, field)

    if Enum.all?(rest, &(Map.fetch!(&1.test_case, field) == reference)),
      do: :ok,
      else: {:error, "All contestants must have the same '#{name}'."}
  end
end
