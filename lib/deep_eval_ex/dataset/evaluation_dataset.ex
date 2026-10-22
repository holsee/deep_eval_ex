defmodule DeepEvalEx.Dataset.EvaluationDataset do
  @moduledoc """
  A dataset of goldens and test cases, deepeval 4.3.1's `EvaluationDataset`
  (`dataset/dataset.py`), as an immutable struct.

  deepeval's dataset is a mutable object; here `add_golden/2`,
  `put_goldens/2`, `add_test_case/2` and `put_test_cases/2` return a new
  dataset and leave the one given unchanged.

  ## Fields

  - `:goldens` - The `DeepEvalEx.Dataset.Golden`s, in the order added
  - `:test_cases` - The `DeepEvalEx.TestCase`s, in the order added, each
    with its `:dataset_rank` set
  - `:alias`, `:id`, `:version` - The dataset's alias, id and version, which
    deepeval sets when it pulls a dataset from Confident AI and writes into
    a test run as `datasetAlias`, `datasetId` and `datasetVersion`. `nil`
    unless given to `new/2`

  ## Dataset rank

  Each test case added gets its position among the dataset's test cases as
  its `:dataset_rank`, as deepeval sets `_dataset_rank`. Evaluating test
  cases takes the rank as each test case's `order` and `"test_case_<order>"`
  name, so a test case keeps its dataset name when only some of the
  dataset's test cases are evaluated, or they are evaluated out of order.

  deepeval also ranks goldens, but `EvaluationDataset(goldens=...)` and the
  `goldens` setter give every golden the number of goldens as its rank, and
  `add_golden` none; goldens carry no rank here.
  `DeepEvalEx.Dataset.Golden.convert_goldens_to_test_cases/1` ranks the test
  cases it builds by position, as deepeval's does.

  ## Single-turn only

  deepeval's dataset holds either single-turn goldens and test cases or
  multi-turn (conversational) ones, never both. DeepEvalEx has no
  conversational goldens or test cases yet, so a dataset is single-turn and
  takes only `DeepEvalEx.Dataset.Golden` and `DeepEvalEx.TestCase`.

  ## Enumerable

  A dataset enumerates its goldens, in order, so `Enum` and `Stream`
  functions work on it directly (deepeval's dataset is not iterable; its
  `evals_iterator` yields the goldens).

  ## Examples

      iex> alias DeepEvalEx.Dataset.{EvaluationDataset, Golden}
      iex> dataset =
      ...>   EvaluationDataset.new([Golden.new!(input: "What is 2 + 2?")])
      ...>   |> EvaluationDataset.add_golden(Golden.new!(input: "What is 3 + 3?"))
      iex> Enum.map(dataset, & &1.input)
      ["What is 2 + 2?", "What is 3 + 3?"]
      iex> dataset = EvaluationDataset.put_test_cases(dataset, Golden.convert_goldens_to_test_cases(dataset.goldens))
      iex> Enum.map(dataset.test_cases, &{&1.input, &1.dataset_rank})
      [{"What is 2 + 2?", 0}, {"What is 3 + 3?", 1}]
  """

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.TestCase

  @type t :: %__MODULE__{
          goldens: [Golden.t()],
          test_cases: [TestCase.t()],
          alias: String.t() | nil,
          id: String.t() | nil,
          version: String.t() | nil
        }

  defstruct goldens: [], test_cases: [], alias: nil, id: nil, version: nil

  @doc """
  Creates a dataset of `goldens`, as deepeval's `EvaluationDataset(goldens=...)`.

  Raises `ArgumentError` when an item is not a `DeepEvalEx.Dataset.Golden`,
  as deepeval raises `TypeError`.

  ## Options

  - `:alias`, `:id`, `:version` - The dataset's alias, id and version
  """
  @spec new([Golden.t()], keyword()) :: t()
  def new(goldens \\ [], opts \\ []) do
    %__MODULE__{
      goldens: validate_goldens!(goldens),
      alias: Keyword.get(opts, :alias),
      id: Keyword.get(opts, :id),
      version: Keyword.get(opts, :version)
    }
  end

  @doc """
  Appends `golden` to the dataset, as deepeval's `add_golden`.

  Raises `ArgumentError` when `golden` is not a `DeepEvalEx.Dataset.Golden`.
  """
  @spec add_golden(t(), Golden.t()) :: t()
  def add_golden(%__MODULE__{goldens: goldens} = dataset, %Golden{} = golden),
    do: %{dataset | goldens: goldens ++ [golden]}

  def add_golden(%__MODULE__{}, other), do: raise_not_golden(other)

  @doc """
  Replaces the dataset's goldens, as deepeval's `goldens` setter.

  Raises `ArgumentError`, leaving nothing changed, when an item is not a
  `DeepEvalEx.Dataset.Golden`.
  """
  @spec put_goldens(t(), [Golden.t()]) :: t()
  def put_goldens(%__MODULE__{} = dataset, goldens),
    do: %{dataset | goldens: validate_goldens!(goldens)}

  @doc """
  Appends `test_case` to the dataset, as deepeval's `add_test_case`, with
  its position among the dataset's test cases as its `:dataset_rank`.

  Raises `ArgumentError` when `test_case` is not a `DeepEvalEx.TestCase`.
  """
  @spec add_test_case(t(), TestCase.t()) :: t()
  def add_test_case(%__MODULE__{test_cases: test_cases} = dataset, %TestCase{} = test_case) do
    %{dataset | test_cases: test_cases ++ [%{test_case | dataset_rank: length(test_cases)}]}
  end

  def add_test_case(%__MODULE__{}, other) do
    raise ArgumentError,
          "Your test cases must be instances of DeepEvalEx.TestCase, got: #{inspect(other)}"
  end

  @doc """
  Replaces the dataset's test cases, as deepeval's `test_cases` setter,
  ranking them by position from 0.

  As deepeval's setter, items that are not `DeepEvalEx.TestCase`s are
  skipped, not rejected.
  """
  @spec put_test_cases(t(), [TestCase.t() | term()]) :: t()
  def put_test_cases(%__MODULE__{} = dataset, test_cases) when is_list(test_cases) do
    ranked =
      test_cases
      |> Enum.filter(&is_struct(&1, TestCase))
      |> Enum.with_index()
      |> Enum.map(fn {test_case, rank} -> %{test_case | dataset_rank: rank} end)

    %{dataset | test_cases: ranked}
  end

  defp validate_goldens!(goldens) when is_list(goldens) do
    case Enum.find(goldens, &(not is_struct(&1, Golden))) do
      nil -> goldens
      other -> raise_not_golden(other)
    end
  end

  defp raise_not_golden(other) do
    raise ArgumentError,
          "Your goldens must be instances of DeepEvalEx.Dataset.Golden, got: #{inspect(other)}"
  end

  defimpl Enumerable do
    def count(%{goldens: goldens}), do: {:ok, length(goldens)}

    def member?(%{goldens: goldens}, element), do: {:ok, Enum.member?(goldens, element)}

    def slice(%{goldens: goldens}), do: {:ok, length(goldens), fn _dataset -> goldens end}

    def reduce(%{goldens: goldens}, acc, fun), do: Enumerable.reduce(goldens, acc, fun)
  end
end
