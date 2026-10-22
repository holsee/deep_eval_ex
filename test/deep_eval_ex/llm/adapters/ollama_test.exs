defmodule DeepEvalEx.LLM.Adapters.OllamaTest do
  # Mutates application and OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.LLM.Adapter
  alias DeepEvalEx.LLM.Adapters.Ollama
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.Test.RetryStub

  @stub Ollama
  @retry_opts [model: "llama3.2", req_options: [plug: {Req.Test, @stub}]]
  @ok %{
    "model" => "llama3.2",
    "message" => %{"role" => "assistant", "content" => "hi"},
    "done" => true
  }
  @base_opts [model: "llama3.2", req_options: [plug: {Req.Test, @stub}, retry: false]]

  import RetryStub, only: [no_backoff: 1]

  setup do
    saved_env = %{"OLLAMA_HOST" => System.get_env("OLLAMA_HOST")}

    saved_config =
      Map.new(~w(ollama_base_url ollama_model ollama_temperature)a, &{&1, app_env(&1)})

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

  # Stubs /api/chat with a non-streaming response whose message content is
  # `content` (merged with `extra` top-level fields) and sends the captured
  # request back to the test process.
  defp stub_chat(content, extra \\ %{}) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(raw)})

      Req.Test.json(
        conn,
        Map.merge(
          %{
            "model" => "llama3.2",
            "message" => %{"role" => "assistant", "content" => content},
            "done" => true
          },
          extra
        )
      )
    end)
  end

  defp request_url(conn) do
    "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
  end

  test "is the adapter for :ollama" do
    assert Adapter.get_adapter(:ollama) == Ollama
  end

  describe "base URL" do
    test "defaults to a local Ollama server" do
      stub_chat("hi")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert conn.method == "POST"
      assert request_url(conn) == "http://localhost:11434/api/chat"
    end

    test "uses :base_url opt and strips a trailing slash" do
      stub_chat("hi")
      opts = [{:base_url, "https://gpu.example.com:8443/ollama/"} | @base_opts]

      assert {:ok, "hi"} = Ollama.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "https://gpu.example.com:8443/ollama/api/chat"
    end

    test "falls back to :ollama_base_url config" do
      stub_chat("hi")
      Application.put_env(:deep_eval_ex, :ollama_base_url, "http://config.example.com:11500")
      System.put_env("OLLAMA_HOST", "http://env.example.com:11600")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "http://config.example.com:11500/api/chat"
    end

    test "falls back to OLLAMA_HOST env var" do
      stub_chat("hi")
      System.put_env("OLLAMA_HOST", "http://env.example.com:11600/")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "http://env.example.com:11600/api/chat"
    end

    test "treats a blank OLLAMA_HOST as unset" do
      stub_chat("hi")
      System.put_env("OLLAMA_HOST", "")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "http://localhost:11434/api/chat"
    end

    test "treats a blank :ollama_base_url config as unset" do
      stub_chat("hi")
      Application.put_env(:deep_eval_ex, :ollama_base_url, " ")
      System.put_env("OLLAMA_HOST", "http://env.example.com:11600")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "http://env.example.com:11600/api/chat"
    end

    test "reads a bare OLLAMA_HOST as http, on Ollama's port when none is given" do
      stub_chat("hi")

      for {host, expected} <- [
            {"ollama.internal:9000", "http://ollama.internal:9000/api/chat"},
            {"ollama.internal", "http://ollama.internal:11434/api/chat"}
          ] do
        System.put_env("OLLAMA_HOST", host)

        assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
        assert_received {:request, conn, _body}
        assert request_url(conn) == expected, "expected #{expected} for #{host}"
      end
    end

    test ":base_url opt wins over config and env" do
      stub_chat("hi")
      Application.put_env(:deep_eval_ex, :ollama_base_url, "http://config.example.com")
      System.put_env("OLLAMA_HOST", "http://env.example.com")
      opts = [{:base_url, "http://opt.example.com:11434"} | @base_opts]

      assert {:ok, "hi"} = Ollama.generate("hello", opts)
      assert_received {:request, conn, _body}
      assert request_url(conn) == "http://opt.example.com:11434/api/chat"
    end
  end

  describe "request" do
    test "sends no credentials" do
      stub_chat("hi")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, conn, _body}
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "sends a non-streaming chat with deepeval's default temperature of 0.0" do
      stub_chat("hi")

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, _conn, body}

      assert body == %{
               "model" => "llama3.2",
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "stream" => false,
               "options" => %{"temperature" => 0.0}
             }
    end

    test "sends temperature given via opts over :ollama_temperature config" do
      stub_chat("hi")
      Application.put_env(:deep_eval_ex, :ollama_temperature, 0.3)

      assert {:ok, "hi"} = Ollama.generate("hello", @base_opts)
      assert_received {:request, _conn, body}
      assert body["options"] == %{"temperature" => 0.3}

      assert {:ok, "hi"} = Ollama.generate("hello", [{:temperature, 0.7} | @base_opts])
      assert_received {:request, _conn, body}
      assert body["options"] == %{"temperature" => 0.7}
    end

    test "merges :options into the model options, keeping the temperature" do
      stub_chat("hi")
      opts = [temperature: 0.2, options: %{num_ctx: 8192, temperature: 1.5}] ++ @base_opts

      assert {:ok, "hi"} = Ollama.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["options"] == %{"temperature" => 0.2, "num_ctx" => 8192}
    end

    test "falls back to the :ollama_model config" do
      stub_chat("hi")
      Application.put_env(:deep_eval_ex, :ollama_model, "qwen3:8b")
      opts = Keyword.delete(@base_opts, :model)

      assert {:ok, "hi"} = Ollama.generate("hello", opts)
      assert_received {:request, _conn, body}
      assert body["model"] == "qwen3:8b"
    end

    test "raises when no model is given or configured, as deepeval does" do
      opts = Keyword.delete(@base_opts, :model)

      assert_raise ArgumentError, ~r/:ollama_model/, fn -> Ollama.generate("hello", opts) end
    end
  end

  describe "generate/2" do
    test "returns the message content" do
      stub_chat("Hello, world")

      assert {:ok, "Hello, world"} = Ollama.generate("hello", @base_opts)
    end

    test "returns unexpected_response when there is no message content" do
      response = %{"model" => "llama3.2", "done" => true}
      Req.Test.stub(@stub, &Req.Test.json(&1, response))

      assert {:error, {:unexpected_response, ^response}} = Ollama.generate("hello", @base_opts)
    end
  end

  describe "generate_with_schema/3" do
    @schema %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"]
    }

    test "sends the JSON schema as format and decodes the content" do
      stub_chat(~s({"answer": "4"}))

      assert {:ok, %{"answer" => "4"}} =
               Ollama.generate_with_schema("What is 2+2?", @schema, @base_opts)

      assert_received {:request, _conn, body}

      assert body == %{
               "model" => "llama3.2",
               "messages" => [%{"role" => "user", "content" => "What is 2+2?"}],
               "stream" => false,
               "format" => @schema,
               "options" => %{"temperature" => 0.0}
             }
    end

    test "uses a schema module's json_schema/0" do
      stub_chat(~s({"n": 4}))

      assert {:ok, %{"n" => 4}} = Ollama.generate_with_schema("2+2?", AnswerSchema, @base_opts)
      assert_received {:request, _conn, body}
      assert %{"properties" => %{"n" => _}} = body["format"]
    end

    test "returns json_parse_error when the content is not JSON" do
      stub_chat("four")

      assert {:error, {:json_parse_error, %Jason.DecodeError{}, "four"}} =
               Ollama.generate_with_schema("2+2?", @schema, @base_opts)
    end

    test "returns unexpected_response when there is no message content" do
      response = %{"model" => "llama3.2", "done" => true}
      Req.Test.stub(@stub, &Req.Test.json(&1, response))

      assert {:error, {:unexpected_response, ^response}} =
               Ollama.generate_with_schema("2+2?", @schema, @base_opts)
    end
  end

  describe "errors" do
    test "maps non-200 responses to api_error" do
      error = %{"error" => "model \"nope\" not found, try pulling it first"}

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(error)
      end)

      assert {:error, {:api_error, 404, ^error}} = Ollama.generate("hello", @base_opts)
    end

    test "maps transport failures to request_failed" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:request_failed, %Req.TransportError{reason: :econnrefused}}} =
               Ollama.generate("hello", @base_opts)
    end
  end

  describe "retries" do
    @describetag :capture_log
    setup :no_backoff

    test "retries a transport error" do
      counter = RetryStub.stub_replies(@stub, [{:transport_error, :econnrefused}, {200, @ok}])

      assert {:ok, "hi"} = Ollama.generate("hello", @retry_opts)
      assert RetryStub.attempts(counter) == 2
    end

    test "does not retry an HTTP error status, as deepeval's Ollama policy" do
      counter = RetryStub.stub_replies(@stub, [{500, %{"error" => "boom"}}, {200, @ok}])

      assert {:error, {:api_error, 500, _}} = Ollama.generate("hello", @retry_opts)
      assert RetryStub.attempts(counter) == 1
    end
  end

  describe "usage" do
    test "records prompt and completion token counts at no cost, like deepeval" do
      stub_chat("hi", %{"prompt_eval_count" => 26, "eval_count" => 290})

      {result, usages} = Usage.track(fn -> Ollama.generate("hello", @base_opts) end)

      assert result == {:ok, "hi"}

      assert usages == [
               %Usage{model: "llama3.2", input_tokens: 26, output_tokens: 290, cost: 0.0}
             ]
    end

    test "records usage for structured output requests" do
      stub_chat(~s({"a": 1}), %{"prompt_eval_count" => 3, "eval_count" => 2})

      {result, usages} =
        Usage.track(fn -> Ollama.generate_with_schema("hello", %{}, @base_opts) end)

      assert result == {:ok, %{"a" => 1}}
      assert usages == [%Usage{model: "llama3.2", input_tokens: 3, output_tokens: 2, cost: 0.0}]
    end

    test "still costs nothing when the response omits token counts" do
      stub_chat("hi")

      assert {{:ok, "hi"}, [%Usage{model: "llama3.2", cost: +0.0} = usage]} =
               Usage.track(fn -> Ollama.generate("hello", @base_opts) end)

      assert usage.input_tokens == nil
      assert usage.output_tokens == nil
    end

    test "reports a zero evaluation cost through the Adapter" do
      stub_chat("hi", %{"prompt_eval_count" => 5, "eval_count" => 7})
      opts = [{:adapter, :ollama} | @base_opts]

      {result, usages} = Usage.track(fn -> Adapter.generate("hello", opts) end)

      assert result == {:ok, "hi"}

      assert %{evaluation_model: "llama3.2", evaluation_cost: +0.0} =
               Usage.summarize(usages)
    end
  end

  describe "capabilities" do
    test "supports structured outputs but not log probs" do
      assert Ollama.supports_structured_outputs?()
      refute Ollama.supports_log_probs?()
      assert Ollama.model_name(model: "llama3.2") == "llama3.2"
    end

    test "supports JSON mode and temperature" do
      assert Ollama.supports_json_mode?()
      assert Ollama.supports_temperature?(model: "llama3.2")
    end
  end
end
