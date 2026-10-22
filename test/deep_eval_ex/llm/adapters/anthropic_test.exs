defmodule DeepEvalEx.LLM.Adapters.AnthropicTest do
  # Mutates application and OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.LLM.Adapters.Anthropic
  alias DeepEvalEx.LLM.Usage

  @stub Anthropic
  @base_opts [api_key: "sk-ant-test", req_options: [plug: {Req.Test, @stub}, retry: false]]

  setup do
    saved_env = Map.new(~w(ANTHROPIC_BASE_URL ANTHROPIC_API_KEY), &{&1, System.get_env(&1)})

    saved_config =
      Map.new(~w(anthropic_base_url anthropic_api_key anthropic_temperature)a, &{&1, app_env(&1)})

    Enum.each(saved_env, fn {key, _} -> System.delete_env(key) end)
    Enum.each(saved_config, fn {key, _} -> Application.delete_env(:deep_eval_ex, key) end)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(saved_config, fn
        {key, nil} -> Application.delete_env(:deep_eval_ex, key)
        {key, value} -> Application.put_env(:deep_eval_ex, key, value)
      end)
    end)

    :ok
  end

  defmodule AnswerSchema do
    @moduledoc false
    def json_schema, do: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}
  end

  defp app_env(key), do: Application.get_env(:deep_eval_ex, key)

  # Stubs the endpoint with a Messages API response carrying `content` blocks
  # (and `extra` top-level fields) and sends the captured request back to the
  # test process.
  defp stub_message(content, extra \\ %{}) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(raw)})

      Req.Test.json(
        conn,
        Map.merge(
          %{"type" => "message", "role" => "assistant", "content" => content},
          extra
        )
      )
    end)
  end

  defp stub_text(text), do: stub_message([%{"type" => "text", "text" => text}])

  defp request_url(conn) do
    "#{conn.scheme}://#{conn.host}#{conn.request_path}"
  end

  test "is the adapter for :anthropic" do
    assert Adapter.get_adapter(:anthropic) == Anthropic
  end

  describe "base URL" do
    test "defaults to the public Anthropic API" do
      stub_text("hi")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert conn.method == "POST"
      assert request_url(conn) == "https://api.anthropic.com/v1/messages"
    end

    test "uses :base_url opt and strips a trailing slash" do
      stub_text("hi")
      opts = [{:base_url, "https://gateway.example.com/anthropic/"} | @base_opts]

      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://gateway.example.com/anthropic/v1/messages"
    end

    test "falls back to :anthropic_base_url config" do
      stub_text("hi")
      Application.put_env(:deep_eval_ex, :anthropic_base_url, "https://config.example.com")
      System.put_env("ANTHROPIC_BASE_URL", "https://env.example.com")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://config.example.com/v1/messages"
    end

    test "falls back to ANTHROPIC_BASE_URL env var" do
      stub_text("hi")
      System.put_env("ANTHROPIC_BASE_URL", "https://env.example.com/")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://env.example.com/v1/messages"
    end

    test "accepts a base URL that already ends in the API version" do
      stub_text("hi")
      opts = [{:base_url, "https://gateway.example.com/anthropic/v1/"} | @base_opts]

      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://gateway.example.com/anthropic/v1/messages"
    end

    test "treats a blank ANTHROPIC_BASE_URL as unset" do
      stub_text("hi")
      System.put_env("ANTHROPIC_BASE_URL", "")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://api.anthropic.com/v1/messages"
    end

    test "treats a blank :anthropic_base_url config as unset" do
      stub_text("hi")
      Application.put_env(:deep_eval_ex, :anthropic_base_url, "")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://api.anthropic.com/v1/messages"
    end

    test ":base_url opt wins over config and env" do
      stub_text("hi")
      Application.put_env(:deep_eval_ex, :anthropic_base_url, "https://config.example.com")
      System.put_env("ANTHROPIC_BASE_URL", "https://env.example.com")
      opts = [{:base_url, "https://opt.example.com"} | @base_opts]

      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://opt.example.com/v1/messages"
    end
  end

  describe "API key" do
    @no_key_opts [req_options: [plug: {Req.Test, @stub}, retry: false]]

    defp sent_api_key(opts) do
      stub_text("hi")
      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, conn, _body}
      Plug.Conn.get_req_header(conn, "x-api-key")
    end

    test ":api_key opt wins over config and env" do
      Application.put_env(:deep_eval_ex, :anthropic_api_key, "sk-ant-config")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env")

      assert sent_api_key([{:api_key, "sk-ant-opt"} | @no_key_opts]) == ["sk-ant-opt"]
    end

    test "falls back to :anthropic_api_key config, then ANTHROPIC_API_KEY" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env")
      assert sent_api_key(@no_key_opts) == ["sk-ant-env"]

      Application.put_env(:deep_eval_ex, :anthropic_api_key, "sk-ant-config")
      assert sent_api_key(@no_key_opts) == ["sk-ant-config"]
    end

    test "treats a blank ANTHROPIC_API_KEY as unset" do
      System.put_env("ANTHROPIC_API_KEY", "")

      assert_raise RuntimeError, ~r/ANTHROPIC_API_KEY/, fn ->
        Anthropic.generate("hello", @no_key_opts)
      end
    end

    test "treats a blank :anthropic_api_key config as unset" do
      Application.put_env(:deep_eval_ex, :anthropic_api_key, "")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env\n")

      assert sent_api_key(@no_key_opts) == ["sk-ant-env"]
    end

    test "raises when no key is configured" do
      assert_raise RuntimeError, ~r/ANTHROPIC_API_KEY/, fn ->
        Anthropic.generate("hello", @no_key_opts)
      end
    end
  end

  describe "request" do
    test "sends the API key, API version and JSON content type" do
      stub_text("hi")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-test"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "defaults to deepeval's model and max_tokens" do
      stub_text("hi")

      assert {:ok, "hi"} = Anthropic.generate("hello", @base_opts)
      assert_received {:request, _conn, body}
      assert body["model"] == "claude-opus-5"
      assert body["max_tokens"] == 8192
      assert body["messages"] == [%{"role" => "user", "content" => "hello"}]
      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "tool_choice")
    end

    test "caps max_tokens at 4096 for Claude 3 models, which reject more" do
      stub_text("hi")

      for model <- ~w(claude-3-opus-20240229 claude-3-sonnet claude-3-haiku-20240307) do
        assert {:ok, "hi"} = Anthropic.generate("hello", [{:model, model} | @base_opts])
        assert_received {:request, _conn, body}
        assert body["max_tokens"] == 4096, "expected 4096 for #{model}"
      end

      assert {:ok, "hi"} =
               Anthropic.generate("hello", [{:model, "claude-3-5-haiku-20241022"} | @base_opts])

      assert_received {:request, _conn, body}
      assert body["max_tokens"] == 8192
    end

    test "sends :max_tokens given via opts" do
      stub_text("hi")
      opts = [model: "claude-3-haiku-20240307", max_tokens: 256] ++ @base_opts

      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["max_tokens"] == 256
    end

    test "omits temperature unless configured, like deepeval's AnthropicModel" do
      stub_text("hi")

      assert {:ok, "hi"} =
               Anthropic.generate("hello", [{:model, "claude-sonnet-4-6"} | @base_opts])

      assert_received {:request, _conn, body}
      refute Map.has_key?(body, "temperature")
    end

    test "sends an explicit temperature of 0.0" do
      stub_text("hi")
      opts = [model: "claude-sonnet-4-6", temperature: 0.0] ++ @base_opts

      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.0
    end

    test "sends temperature given via opts over :anthropic_temperature config" do
      stub_text("hi")
      Application.put_env(:deep_eval_ex, :anthropic_temperature, 0.3)

      assert {:ok, "hi"} =
               Anthropic.generate("hello", [{:model, "claude-haiku-4-5"} | @base_opts])

      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.3

      opts = [model: "claude-haiku-4-5", temperature: 0.7] ++ @base_opts
      assert {:ok, "hi"} = Anthropic.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["temperature"] == 0.7
    end

    test "omits temperature for models that reject it" do
      stub_text("hi")

      for model <-
            ~w(claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-opus-5-5 claude-sonnet-5 claude-fable-5 claude-fable-5-1) do
        opts = [model: model, temperature: 0.0] ++ @base_opts

        assert {:ok, "hi"} = Anthropic.generate("hello", opts)
        assert_received {:request, _conn, body}
        refute Map.has_key?(body, "temperature"), "expected no temperature for #{model}"
      end
    end

    test "disables thinking only for models that support it" do
      stub_text("hi")

      for model <- ~w(claude-opus-5 claude-sonnet-4-5-20250929 claude-3-7-sonnet-latest) do
        assert {:ok, "hi"} = Anthropic.generate("hello", [{:model, model} | @base_opts])
        assert_received {:request, _conn, body}
        assert body["thinking"] == %{"type" => "disabled"}, "expected thinking off for #{model}"
      end

      for model <- ~w(claude-3-haiku-20240307 claude-opus-5-5 claude-fable-5 my-proxy-model) do
        assert {:ok, "hi"} = Anthropic.generate("hello", [{:model, model} | @base_opts])
        assert_received {:request, _conn, body}
        refute Map.has_key?(body, "thinking"), "expected no thinking for #{model}"
      end
    end
  end

  describe "generate/2" do
    test "concatenates the text blocks and skips other blocks" do
      stub_message([
        %{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"},
        %{"type" => "text", "text" => "Hello, "},
        %{"type" => "text", "text" => "world"}
      ])

      assert {:ok, "Hello, world"} = Anthropic.generate("hello", @base_opts)
    end

    test "returns unexpected_response when there is no text block" do
      response = %{"type" => "message", "role" => "assistant", "content" => []}
      Req.Test.stub(@stub, &Req.Test.json(&1, response))

      assert {:error, {:unexpected_response, ^response}} = Anthropic.generate("hello", @base_opts)
    end
  end

  describe "generate_with_schema/3" do
    @schema %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"]
    }

    defp stub_tool_use(input) do
      stub_message([
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "response", "input" => input}
      ])
    end

    test "forces a single response tool and returns its input" do
      stub_tool_use(%{"answer" => "4"})

      assert {:ok, %{"answer" => "4"}} =
               Anthropic.generate_with_schema("What is 2+2?", @schema, @base_opts)

      assert_received {:request, _conn, body}

      assert [%{"name" => "response", "input_schema" => @schema} = tool] = body["tools"]
      assert is_binary(tool["description"])
      assert body["tool_choice"] == %{"type" => "tool", "name" => "response"}
      assert body["model"] == "claude-opus-5"
      assert body["max_tokens"] == 8192
      assert body["messages"] == [%{"role" => "user", "content" => "What is 2+2?"}]
    end

    test "uses a schema module's json_schema/0" do
      stub_tool_use(%{"n" => 4})

      assert {:ok, %{"n" => 4}} = Anthropic.generate_with_schema("2+2?", AnswerSchema, @base_opts)
      assert_received {:request, _conn, body}
      assert [%{"input_schema" => %{"properties" => %{"n" => _}}}] = body["tools"]
    end

    test "returns unexpected_response when no response tool was used" do
      response = %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "4"}]
      }

      Req.Test.stub(@stub, &Req.Test.json(&1, response))

      assert {:error, {:unexpected_response, ^response}} =
               Anthropic.generate_with_schema("2+2?", @schema, @base_opts)
    end
  end

  describe "errors" do
    test "maps non-200 responses to api_error" do
      error = %{
        "type" => "error",
        "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
      }

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(error)
      end)

      assert {:error, {:api_error, 401, ^error}} = Anthropic.generate("hello", @base_opts)
    end

    test "maps transport failures to request_failed" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:request_failed, %Req.TransportError{reason: :econnrefused}}} =
               Anthropic.generate("hello", @base_opts)
    end
  end

  describe "usage" do
    test "records input and output tokens priced for the requested model" do
      stub_message([%{"type" => "text", "text" => "hi"}], %{
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 500}
      })

      {result, usages} =
        Usage.track(fn ->
          Anthropic.generate("hello", [{:model, "claude-sonnet-4-6"} | @base_opts])
        end)

      assert result == {:ok, "hi"}

      assert [%Usage{model: "claude-sonnet-4-6", input_tokens: 1_000, output_tokens: 500} = usage] =
               usages

      assert_in_delta usage.cost, 0.0105, 1.0e-12
    end

    test "records usage for structured output requests on the default model" do
      stub_message(
        [%{"type" => "tool_use", "id" => "t", "name" => "response", "input" => %{"a" => 1}}],
        %{"usage" => %{"input_tokens" => 3, "output_tokens" => 2}}
      )

      {result, usages} =
        Usage.track(fn -> Anthropic.generate_with_schema("hello", %{}, @base_opts) end)

      assert result == {:ok, %{"a" => 1}}
      assert [%Usage{model: "claude-opus-5", input_tokens: 3, output_tokens: 2} = usage] = usages
      assert_in_delta usage.cost, (3 * 5.0 + 2 * 25.0) / 1_000_000, 1.0e-15
    end

    test "records nothing when the response carries no usage" do
      stub_text("hi")

      assert {{:ok, "hi"}, []} = Usage.track(fn -> Anthropic.generate("hello", @base_opts) end)
    end
  end

  describe "capabilities" do
    test "supports structured outputs but not log probs" do
      assert Anthropic.supports_structured_outputs?()
      refute Anthropic.supports_log_probs?()
      assert Anthropic.model_name([]) == "claude-opus-5"
      assert Anthropic.model_name(model: "claude-haiku-4-5") == "claude-haiku-4-5"
    end
  end
end
