defmodule DeepEvalEx.MCPResourceCall do
  @moduledoc """
  A read of an MCP server's resource, deepeval 4.3.1's `MCPResourceCall`
  (`test_case/mcp.py`), as a test case's or turn's `:mcp_resources_called`.

  ## Fields

  - `:uri` - The resource's URI, a string normalised as deepeval's pydantic
    `AnyUrl` writes it (required, see "URIs" below)
  - `:result` - What the server returned, shaped as the MCP spec's
    `ReadResourceResult`: a map holding a `"contents"` list (required, see
    "Results" in `DeepEvalEx.MCP`)

  ## URIs

  As pydantic's `AnyUrl`, `new/1` takes an absolute URI (one with a
  scheme), lowercases its scheme and, for the special schemes (`http`,
  `https`, `ws`, `wss`, `ftp` and `file`), its host, drops their default
  port and gives an empty path as `/`: `"HTTPS://Example.COM"` is
  `"https://example.com/"`. A special scheme other than `file` needs a
  host. Unlike `AnyUrl`, it does not percent-encode characters or convert
  international domain names, and rejects a URI that `URI.new/1` does not
  parse (one with a space, for instance).

  ## Examples

      iex> {:ok, call} =
      ...>   DeepEvalEx.MCPResourceCall.new(
      ...>     uri: "HTTPS://Example.COM",
      ...>     result: %{"contents" => [%{"uri" => "https://example.com/", "text" => "Hi"}]}
      ...>   )
      iex> call.uri
      "https://example.com/"
  """

  alias DeepEvalEx.MCP
  alias Jason.OrderedObject

  @type t :: %__MODULE__{uri: String.t(), result: MCP.result()}

  @enforce_keys [:uri, :result]
  defstruct [:uri, :result]

  # The WHATWG URL standard's special schemes and their default ports, which
  # pydantic's AnyUrl (the Rust url crate) normalises.
  @special_schemes %{
    "http" => 80,
    "https" => 443,
    "ws" => 80,
    "wss" => 443,
    "ftp" => 21,
    "file" => nil
  }

  @doc """
  Builds a resource call from a keyword list or a map with atom or string
  keys; other keys are dropped. Returns `{:error, message}` when `:uri` is
  not an absolute URI (see "URIs" above) or `:result` not a
  `ReadResourceResult`-shaped map.
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = call), do: {:ok, call}

  def new(attrs) do
    with {:ok, attrs} <- take_keys(attrs),
         {:ok, uri} <- normalize_uri(attrs["uri"]),
         :ok <- MCP.check_result(attrs["result"], :contents, "ReadResourceResult") do
      {:ok, %__MODULE__{uri: uri, result: attrs["result"]}}
    end
  end

  @doc """
  Builds a resource call like `new/1`, raising `ArgumentError` on error.
  """
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, call} -> call
      {:error, message} -> raise ArgumentError, "Invalid MCP resource call: " <> message
    end
  end

  @doc """
  The call as deepeval's `model_dump()` gives it: `uri` (as a string,
  where deepeval's Python-mode dump holds an `AnyUrl`) and `result`, the
  result as given.
  """
  @spec model_dump(t()) :: OrderedObject.t()
  def model_dump(%__MODULE__{} = call),
    do: OrderedObject.new([{"uri", call.uri}, {"result", call.result}])

  @doc false
  # Peri custom validator for one of a test case's or turn's
  # :mcp_resources_called.
  @spec cast(term()) :: {:ok, t()} | {:error, String.t(), keyword()}
  def cast(value) do
    case new(value) do
      {:ok, call} -> {:ok, call}
      {:error, message} -> {:error, "%{message}", [message: message]}
    end
  end

  defp take_keys(attrs) do
    case MCP.take_keys(attrs, ~w(uri result)) do
      {:ok, attrs} ->
        {:ok, attrs}

      :error ->
        {:error,
         "'mcp_resources_called' must be a list of MCPResourceCall, or of the attributes " <>
           "MCPResourceCall.new/1 takes, got " <> inspect(attrs)}
    end
  end

  defp normalize_uri(uri) when is_binary(uri) do
    with {:ok, %URI{scheme: scheme} = parsed} when is_binary(scheme) <- URI.new(uri),
         parsed = %{parsed | scheme: String.downcase(scheme)},
         {:ok, parsed} <- normalize_special(parsed) do
      {:ok, URI.to_string(parsed)}
    else
      _ -> invalid_uri(uri)
    end
  end

  defp normalize_uri(uri), do: invalid_uri(uri)

  defp normalize_special(%URI{scheme: scheme, host: host})
       when is_map_key(@special_schemes, scheme) and scheme != "file" and host in [nil, ""],
       do: :error

  defp normalize_special(%URI{scheme: scheme} = uri) when is_map_key(@special_schemes, scheme) do
    default_port = Map.fetch!(@special_schemes, scheme)

    {:ok,
     %{
       uri
       | host: uri.host && String.downcase(uri.host),
         port: if(uri.port == default_port, do: nil, else: uri.port),
         path: if(uri.path in [nil, ""], do: "/", else: uri.path)
     }}
  end

  defp normalize_special(uri), do: {:ok, uri}

  defp invalid_uri(uri),
    do: {:error, "'uri' must be an absolute URI, got #{inspect(uri)}"}
end
