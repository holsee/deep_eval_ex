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

  ## Loading files

  `add_goldens_from_csv_file/3`, `add_goldens_from_json_file/3`,
  `add_goldens_from_jsonl_file/3`, `add_test_cases_from_csv_file/5` and
  `add_test_cases_from_json_file/5` port deepeval's loaders of the same
  names, with its argument names and defaults as options, and load the files
  deepeval's `save_as` writes as deepeval loads them:

  - CSV is read as pandas reads it for deepeval: pandas' missing-value
    markers (`""`, `NA`, `N/A`, `null`, `NULL`, `None`, `NaN`, ...) are
    `nil`, and the token cost and count columns are numbers
  - context and retrieval context cells are split on their delimiter
    (`"|"`), and retrieval context markers
    (`"deepeval_source=...,deepeval_context=..."`) become
    `DeepEvalEx.Schemas.RetrievedContextData` (see
    `DeepEvalEx.Dataset.Utils`); a context or tool column that is present
    gives `[]` for an empty cell, one that is absent (or named `nil`) gives
    `nil`
  - tool calls, metadata, custom columns and expectations are JSON cells,
    trailing commas tolerated. deepeval only falls back to splitting tool
    cells on the tool delimiter when they are not JSON, which its `Golden`
    then rejects, so the tool delimiter options are accepted but unused

  A file that cannot be read raises `File.Error`. Where deepeval raises
  `ValueError` (with its message), `TypeError` or a validation error, the
  loaders raise `ArgumentError`. A golden with a scenario is a multi-turn
  golden in deepeval; those are not supported yet and raise
  `ArgumentError`.

  Differences from deepeval: a text cell of digits stays a string, where
  pandas makes it a number that deepeval's `Golden` rejects; metadata
  cells must be JSON, where deepeval also reads Python literals (and its
  `add_test_cases_from_csv_file` only Python literals, so it cannot read
  JSON's `true`, `false` or `null`); `encoding_type` and the multi-turn
  options other than the scenario's are not ported.

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

  alias DeepEvalEx.Dataset.{Golden, Loader}
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

  ## Loading files

  @golden_columns [
    input_col_name: [type: {:or, [:string, nil]}, default: "input", doc: "The input column."],
    actual_output_col_name: [
      type: {:or, [:string, nil]},
      default: "actual_output",
      doc: "The actual output column."
    ],
    expected_output_col_name: [
      type: {:or, [:string, nil]},
      default: "expected_output",
      doc: "The expected output column."
    ],
    context_col_name: [
      type: {:or, [:string, nil]},
      default: "context",
      doc: "The context column, items joined on `:context_col_delimiter`."
    ],
    context_col_delimiter: [type: :string, default: "|", doc: "The context delimiter."],
    retrieval_context_col_name: [
      type: {:or, [:string, nil]},
      default: "retrieval_context",
      doc: "The retrieval context column, items joined on `:retrieval_context_col_delimiter`."
    ],
    retrieval_context_col_delimiter: [
      type: :string,
      default: "|",
      doc: "The retrieval context delimiter."
    ],
    tools_called_col_name: [
      type: {:or, [:string, nil]},
      default: "tools_called",
      doc: "The tool calls column, a JSON list of tool calls."
    ],
    tools_called_col_delimiter: [
      type: :string,
      default: ";",
      doc: "Accepted as deepeval's; unused (see \"Loading files\")."
    ],
    expected_tools_col_name: [
      type: {:or, [:string, nil]},
      default: "expected_tools",
      doc: "The expected tool calls column, a JSON list of tool calls."
    ],
    expected_tools_col_delimiter: [
      type: :string,
      default: ";",
      doc: "Accepted as deepeval's; unused (see \"Loading files\")."
    ]
  ]

  @golden_extra_columns [
    token_cost_col_name: [
      type: {:or, [:string, nil]},
      default: "token_cost",
      doc: "The token cost column."
    ],
    input_token_count_col_name: [
      type: {:or, [:string, nil]},
      default: "input_token_count",
      doc: "The input token count column."
    ],
    output_token_count_col_name: [
      type: {:or, [:string, nil]},
      default: "output_token_count",
      doc: "The output token count column."
    ],
    comments_key_name: [
      type: {:or, [:string, nil]},
      default: "comments",
      doc: "The comments column."
    ],
    name_key_name: [type: {:or, [:string, nil]}, default: "name", doc: "The name column."],
    source_file_col_name: [
      type: {:or, [:string, nil]},
      default: "source_file",
      doc: "The source file column."
    ],
    additional_metadata_col_name: [
      type: {:or, [:string, nil]},
      default: "additional_metadata",
      doc: "The additional metadata column, a JSON object."
    ],
    custom_column_key_values_col_name: [
      type: {:or, [:string, nil]},
      default: "custom_column_key_values",
      doc: "The custom columns column, a JSON object."
    ],
    scenario_col_name: [
      type: {:or, [:string, nil]},
      default: "scenario",
      doc: "The scenario column; a row with a scenario raises (see \"Loading files\")."
    ]
  ]

  @csv_goldens_opts NimbleOptions.new!(@golden_columns ++ @golden_extra_columns)

  @csv_test_cases_opts NimbleOptions.new!(
                         Keyword.drop(@golden_columns, [:input_col_name, :actual_output_col_name]) ++
                           [
                             additional_metadata_col_name: [
                               type: {:or, [:string, nil]},
                               default: "additional_metadata",
                               doc: "The metadata column, a JSON object."
                             ]
                           ]
                       )

  # The JSON keys of a golden, deepeval's add_goldens_from_json_file
  # *_key_name arguments with their defaults
  @golden_keys [
    input: "input",
    actual_output: "actual_output",
    expected_output: "expected_output",
    context: "context",
    retrieval_context: "retrieval_context",
    tools_called: "tools_called",
    expected_tools: "expected_tools",
    token_cost: "token_cost",
    input_token_count: "input_token_count",
    output_token_count: "output_token_count",
    comments: "comments",
    name: "name",
    source_file: "source_file",
    additional_metadata: "additional_metadata",
    custom_column_key_values: "custom_column_key_values",
    scenario: "scenario"
  ]

  @json_goldens_opts NimbleOptions.new!(
                       for {field, default} <- @golden_keys do
                         {:"#{field}_key_name",
                          [
                            type: {:or, [:string, nil]},
                            default: default,
                            doc: "The `#{field}` key."
                          ]}
                       end
                     )

  @jsonl_goldens_opts NimbleOptions.new!(
                        @json_goldens_opts.schema ++
                          [
                            context_col_delimiter: [
                              type: :string,
                              default: "|",
                              doc: "The delimiter of a context given as a string."
                            ],
                            retrieval_context_col_delimiter: [
                              type: :string,
                              default: "|",
                              doc: "The delimiter of a retrieval context given as a string."
                            ]
                          ]
                      )

  @json_test_cases_opts NimbleOptions.new!(
                          for field <- [
                                :expected_output,
                                :context,
                                :retrieval_context,
                                :tools_called,
                                :expected_tools,
                                :additional_metadata
                              ] do
                            {:"#{field}_key_name",
                             [
                               type: {:or, [:string, nil]},
                               default: nil,
                               doc:
                                 if(field == :additional_metadata,
                                   do: "Accepted as deepeval's; ignored, as deepeval ignores it.",
                                   else: "The `#{field}` key; not read when `nil`."
                                 )
                             ]}
                          end
                        )

  @doc """
  Appends the goldens read from a CSV file, as deepeval's
  `add_goldens_from_csv_file`. See "Loading files" in the module doc.

  Each row is one golden; the first row names the columns. A column that is
  absent, or whose option is `nil`, leaves its field `nil`. Raises
  `ArgumentError` on a row that does not make a valid golden.

  ## Options

  #{NimbleOptions.docs(@csv_goldens_opts)}
  """
  @spec add_goldens_from_csv_file(t(), Path.t(), keyword()) :: t()
  def add_goldens_from_csv_file(%__MODULE__{} = dataset, file_path, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @csv_goldens_opts)
    Enum.reduce(Loader.goldens_from_csv!(file_path, opts), dataset, &add_golden(&2, &1))
  end

  @doc """
  Appends the goldens read from a JSON file holding a list of objects, as
  deepeval's `add_goldens_from_json_file`. See "Loading files" in the
  module doc.

  ## Options

  #{NimbleOptions.docs(@json_goldens_opts)}
  """
  @spec add_goldens_from_json_file(t(), Path.t(), keyword()) :: t()
  def add_goldens_from_json_file(%__MODULE__{} = dataset, file_path, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @json_goldens_opts)
    Enum.reduce(Loader.goldens_from_json!(file_path, opts), dataset, &add_golden(&2, &1))
  end

  @doc """
  Appends the goldens read from a JSONL file, one JSON object per line, as
  deepeval's `add_goldens_from_jsonl_file`. See "Loading files" in the
  module doc.

  Blank lines are skipped. Context and retrieval context may be lists or
  strings joined on their delimiter, tool calls lists or JSON strings.

  ## Options

  #{NimbleOptions.docs(@jsonl_goldens_opts)}
  """
  @spec add_goldens_from_jsonl_file(t(), Path.t(), keyword()) :: t()
  def add_goldens_from_jsonl_file(%__MODULE__{} = dataset, file_path, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @jsonl_goldens_opts)
    Enum.reduce(Loader.goldens_from_jsonl!(file_path, opts), dataset, &add_golden(&2, &1))
  end

  @doc """
  Appends the test cases read from a CSV file, as deepeval's
  `add_test_cases_from_csv_file`, each ranked as `add_test_case/2` ranks
  it. See "Loading files" in the module doc.

  `input_col_name` and `actual_output_col_name` name the input and actual
  output columns. As deepeval, only the columns below are read; names,
  comments and token counts are not.

  ## Options

  #{NimbleOptions.docs(@csv_test_cases_opts)}
  """
  @spec add_test_cases_from_csv_file(t(), Path.t(), String.t(), String.t(), keyword()) :: t()
  def add_test_cases_from_csv_file(
        %__MODULE__{} = dataset,
        file_path,
        input_col_name,
        actual_output_col_name,
        opts \\ []
      ) do
    opts = NimbleOptions.validate!(opts, @csv_test_cases_opts)

    file_path
    |> Loader.test_cases_from_csv!(input_col_name, actual_output_col_name, opts)
    |> Enum.reduce(dataset, &add_test_case(&2, &1))
  end

  @doc """
  Appends the test cases read from a JSON file holding a list of objects,
  as deepeval's `add_test_cases_from_json_file`, each ranked as
  `add_test_case/2` ranks it. See "Loading files" in the module doc.

  Every object must have the `input_key_name` and `actual_output_key_name`
  keys, or `ArgumentError` is raised. The other keys are read only when
  named, except `"expectations"`. As deepeval, tool calls default to `[]`,
  not `nil`, and metadata is not read.

  ## Options

  #{NimbleOptions.docs(@json_test_cases_opts)}
  """
  @spec add_test_cases_from_json_file(t(), Path.t(), String.t(), String.t(), keyword()) :: t()
  def add_test_cases_from_json_file(
        %__MODULE__{} = dataset,
        file_path,
        input_key_name,
        actual_output_key_name,
        opts \\ []
      ) do
    opts = NimbleOptions.validate!(opts, @json_test_cases_opts)

    file_path
    |> Loader.test_cases_from_json!(input_key_name, actual_output_key_name, opts)
    |> Enum.reduce(dataset, &add_test_case(&2, &1))
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
