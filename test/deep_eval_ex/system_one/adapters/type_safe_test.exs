defmodule DeepEvalEx.SystemOne.Adapters.TypeSafeTest do
  # Mutates the TYPESAFE_* environment and application config, so it cannot
  # run concurrently.
  use ExUnit.Case, async: false

  alias DeepEvalEx.{DeepEvalError, TestRun}
  alias DeepEvalEx.LLM.Usage
  alias DeepEvalEx.SystemOne
  alias DeepEvalEx.SystemOne.Adapters.TypeSafe
  alias DeepEvalEx.SystemOne.{Answers, Context, Error, Limits, Model, Question}
  alias DeepEvalEx.Test.RetryStub
  alias Jason.OrderedObject

  import RetryStub, only: [no_backoff: 1]

  @stub TypeSafe
  @opts [api_key: "ts-test", req_options: [plug: {Req.Test, @stub}, retry: false]]
  @retry_opts [api_key: "ts-test", req_options: [plug: {Req.Test, @stub}]]

  @vars ~w(TYPESAFE_API_KEY TYPESAFE_MODEL_NAME TYPESAFE_COST_PER_INPUT_TOKEN)
  @keys ~w(typesafe_api_key typesafe_model_name typesafe_cost_per_input_token)a

  @state OrderedObject.new([
           {"input", "Weather?"},
           {"actual_output", "18°C at the café."}
         ])

  @questions [
    {"claim_0", %Question.Noul{instructions: "Is `actual_output` supported?"}},
    {"claim_1", %Question.Noul{instructions: "x", true: "yes", false: nil}},
    {"tone",
     %Question.Choice{instructions: "Tone?", options: [{"warm", "Friendly"}, {"cold", nil}]}},
    {"q_s", %Question.Score{instructions: "Grounded?", levels: ["No", "Partly", "Fully"]}}
  ]

  # The HTTP API's reply (https://docs.typesafe.ai/api), as Jev sent it in
  # the live check: every answer under `answers` by its question's key,
  # tagged with its type.
  @reply %{
    "model" => "jev-1.14.0",
    "answers" => %{
      "claim_0" => %{"type" => "noul", "noul" => 0.9},
      "claim_1" => %{"type" => "noul", "noul" => 0.2},
      "tone" => %{
        "type" => "choice",
        "choice" => "cold",
        "confidence" => 0.4,
        "probabilities" => %{"warm" => 0.3, "cold" => 0.7}
      },
      "q_s" => %{
        "type" => "score",
        "score" => 2.0,
        "confidence" => 0.5,
        "legend" => %{"0" => "No", "1" => "Partly", "2" => "Fully"},
        "probabilities" => %{"0" => 0.1, "1" => 0.2, "2" => 0.7}
      }
    },
    "usage" => %{"input_tokens" => 1000, "output_tokens" => 12}
  }

  setup do
    saved_env = Map.new(@vars, &{&1, System.get_env(&1)})
    saved_config = Map.new(@keys, &{&1, Application.get_env(:deep_eval_ex, &1)})

    Enum.each(@vars, &System.delete_env/1)
    Enum.each(@keys, &Application.delete_env(:deep_eval_ex, &1))

    on_exit(fn ->
      Enum.each(saved_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      Enum.each(saved_config, fn
        {key, nil} -> Application.delete_env(:deep_eval_ex, key)
        {key, value} -> Application.put_env(:deep_eval_ex, key, value)
      end)
    end)

    :ok
  end

  # Stubs the endpoint with `reply` (a JSON body, or `{status, body}`) and
  # sends the captured request back to the test process.
  defp stub_reply(reply) do
    test_pid = self()
    {status, body} = if is_tuple(reply), do: reply, else: {200, reply}

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, raw})
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp stub_raw(status, body) do
    Req.Test.stub(@stub, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.text(body)
    end)
  end

  describe "model_name/1" do
    test "is the model with TypeSafe AI's suffix, from the option, config or jev-latest" do
      assert TypeSafe.model_name([]) == "jev-latest (TypeSafe AI)"

      System.put_env("TYPESAFE_MODEL_NAME", "jev-preview")
      assert TypeSafe.model_name([]) == "jev-preview (TypeSafe AI)"

      assert TypeSafe.model_name(model: "jev-1.13.0") == "jev-1.13.0 (TypeSafe AI)"
    end

    test "is the resolved name of a model given as a TypeSafe model name" do
      assert Model.resolve("jev-preview").name == "jev-preview (TypeSafe AI)"
      assert Model.resolve(:jev).name == "jev-latest (TypeSafe AI)"
    end
  end

  describe "init/1" do
    test "fails permanently without an API key, with deepeval's text" do
      assert {:error, %Error{} = error} = TypeSafe.init([])
      assert error.reason == :auth
      assert error.type == "DeepEvalError"
      assert error.permanent?

      assert error.message ==
               "TypeSafe AI API key is not configured. Set TYPESAFE_API_KEY in your " <>
                 "environment or pass `api_key` to TypeSafeModel(...)."
    end

    test "fails on an empty API key" do
      assert {:error, %Error{message: message, permanent?: true}} = TypeSafe.init(api_key: "")
      assert message == "TypeSafe AI API key is empty. Please configure a valid key."
    end

    test "takes the key, model and price from the options, then the TYPESAFE_* settings" do
      System.put_env("TYPESAFE_API_KEY", "env-key")
      System.put_env("TYPESAFE_MODEL_NAME", "jev-preview")
      System.put_env("TYPESAFE_COST_PER_INPUT_TOKEN", "0.5")

      assert {:ok, opts} = TypeSafe.init([])
      assert opts[:api_key] == "env-key"
      assert opts[:model] == "jev-preview"
      assert opts[:cost_per_input_token] == 0.5

      assert {:ok, opts} = TypeSafe.init(api_key: "k", model: "jev-latest")
      assert opts[:api_key] == "k"
      assert opts[:model] == "jev-latest"
    end

    test "raises deepeval's DeepEvalError for a negative price" do
      assert_raise DeepEvalError, "TYPESAFE_COST_PER_INPUT_TOKEN must be >= 0.", fn ->
        TypeSafe.init(api_key: "k", cost_per_input_token: -1.0e-6)
      end
    end

    test "a missing key fails the metric when its context is resolved, before any measure" do
      error =
        assert_raise DeepEvalError, fn ->
          Context.resolve!(DeepEvalEx.Metrics.Faithfulness,
            eval_mode: :hybrid,
            system_one_model: :typesafe
          )
        end

      assert error.message =~ "routes metric decisions to TypeSafe AI Jev, but it is not usable"
      assert error.message =~ "Set TYPESAFE_API_KEY"
    end

    test "a missing key is no error under the llm eval mode" do
      assert %Context{mode: :llm, model: nil} =
               Context.resolve!(DeepEvalEx.Metrics.Faithfulness,
                 eval_mode: :llm,
                 system_one_model: :typesafe
               )
    end
  end

  describe "decide/3 request" do
    test "posts the state, the SDK-shaped questions and the model with a Bearer key" do
      stub_reply(@reply)

      assert {:ok, %Answers{}, _usage} = TypeSafe.decide(@state, @questions, @opts)

      assert_received {:request, conn, raw}
      assert conn.method == "POST"

      assert "#{conn.scheme}://#{conn.host}#{conn.request_path}" ==
               "https://api.typesafe.ai/v1/systemone"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ts-test"]

      assert TestRun.JSON.encode!(Jason.decode!(raw, objects: :ordered_objects)) ==
               TestRun.JSON.encode!(
                 OrderedObject.new([
                   {"state", @state},
                   {"questions", Question.to_wire_map(@questions)},
                   {"model", "jev-latest"}
                 ])
               )
    end

    test "drops a Noul's criteria only when it has neither true nor false" do
      stub_reply(@reply)
      TypeSafe.decide(@state, @questions, @opts)

      assert_received {:request, _conn, raw}
      questions = Jason.decode!(raw)["questions"]
      refute Map.has_key?(questions["claim_0"], "criteria")
      assert questions["claim_1"]["criteria"] == %{"true" => "yes", "false" => nil}
      assert questions["tone"]["criteria"] == %{"warm" => "Friendly", "cold" => nil}
      assert questions["q_s"]["criteria"] == ["No", "Partly", "Fully"]
    end

    test "sends the configured model, and the key from TYPESAFE_API_KEY" do
      System.put_env("TYPESAFE_API_KEY", "env-key")
      stub_reply(@reply)

      TypeSafe.decide(@state, @questions,
        model: "jev-preview",
        req_options: [plug: {Req.Test, @stub}]
      )

      assert_received {:request, conn, raw}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer env-key"]
      assert Jason.decode!(raw)["model"] == "jev-preview"
    end

    test "fails permanently without an API key, sending nothing" do
      assert {:error, %Error{reason: :auth, permanent?: true}} =
               TypeSafe.decide(@state, @questions, req_options: [plug: {Req.Test, @stub}])
    end

    test "fails with deepeval's DeepEvalError when asked no questions" do
      assert {:error,
              %DeepEvalError{message: "TypeSafeModel.decide requires at least one question."}} =
               TypeSafe.decide(@state, [], @opts)
    end

    test "checks the context budget before sending" do
      state = String.duplicate("x", 3 * 32_000)

      assert {:error, %Error{reason: :context_limit, limit_tokens: 32_000}} =
               TypeSafe.decide(state, @questions, @opts)

      refute_received {:request, _, _}
    end

    test "checks the budget the :context_budget option sets instead of Jev's" do
      stub_reply(@reply)
      state = String.duplicate("x", 3 * 32_000)

      assert {:ok, %Answers{}, _usage} =
               TypeSafe.decide(state, @questions, [context_budget: :unbounded] ++ @opts)

      assert_received {:request, _conn, _raw}

      assert {:error, %Error{reason: :context_limit, limit_tokens: 20}} =
               TypeSafe.decide(@state, @questions, [context_budget: {20, 100}] ++ @opts)

      refute_received {:request, _, _}
    end
  end

  describe "context_budget/1" do
    test "is Jev's budget unless the :context_budget option sets one" do
      assert TypeSafe.context_budget([]) == {32_000, 64_000}
      assert TypeSafe.context_budget(context_budget: {100, 200}) == {100, 200}
      assert TypeSafe.context_budget(context_budget: :unbounded) == :unbounded

      assert Model.context_budget(Model.resolve({:typesafe, context_budget: :unbounded})) ==
               :unbounded
    end
  end

  describe "decide/3 answers" do
    test "splits the reply into Noul, Choice and Score answers with integer score levels" do
      stub_reply(@reply)

      assert {:ok, answers, _usage} = TypeSafe.decide(@state, @questions, @opts)

      assert answers.nouls == %{
               "claim_0" => %Answers.Noul{probability: 0.9},
               "claim_1" => %Answers.Noul{probability: 0.2}
             }

      assert %Answers.Choice{choice: "cold", confidence: 0.4} = answers.choices["tone"]
      assert Enum.sort(answers.choices["tone"].probabilities) == [{"cold", 0.7}, {"warm", 0.3}]

      assert answers.scores["q_s"] == %Answers.Score{
               score: 2.0,
               probabilities: [{0, 0.1}, {1, 0.2}, {2, 0.7}],
               confidence: 0.5
             }
    end

    test "keeps the reply's order of Choice and Score probabilities" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"answers": {"tone": {"type": "choice",
          "choice": "warm", "confidence": 0.2, "probabilities": {"warm": 0.6, "cold": 0.4}},
          "q_s": {"type": "score", "score": 0, "confidence": 0.7,
          "probabilities": {"2": 0.1, "0": 0.8, "1": 0.1}}}}))
      end)

      questions = Enum.drop(@questions, 2)
      assert {:ok, answers, _usage} = TypeSafe.decide(@state, questions, @opts)
      assert answers.choices["tone"].probabilities == [{"warm", 0.6}, {"cold", 0.4}]
      assert answers.scores["q_s"].probabilities == [{2, 0.1}, {0, 0.8}, {1, 0.1}]
    end

    test "rejects a reply that is not System One answers" do
      stub_raw(200, "not json")

      assert {:error, %Error{reason: :invalid_response, type: "TypeSafeError"}} =
               TypeSafe.decide(@state, @questions, @opts)

      answers = @reply["answers"]
      put = fn key, answer -> %{@reply | "answers" => Map.put(answers, key, answer)} end
      drop = fn answer, field -> Map.delete(answers[answer], field) end

      for reply <- [
            # No answers at all, or none of the questions answered.
            %{"usage" => %{"input_tokens" => 1}},
            %{@reply | "answers" => %{}},
            # The SDK's response object, which the HTTP API never sends.
            %{"nouls" => %{"claim_0" => %{"noul" => 0.9}}},
            put.("claim_0", %{"type" => "noul", "p" => 0.9}),
            put.("claim_0", %{"noul" => 0.9}),
            put.("q_s", %{"type" => "box", "box" => %{"top" => 0.1}}),
            put.("q_s", Map.put(answers["q_s"], "probabilities", %{"high" => 1.0})),
            # A question left unanswered, answered under another type, or
            # an answer to a question not asked.
            %{@reply | "answers" => Map.delete(answers, "claim_1")},
            put.("claim_1", answers["tone"]),
            put.("extra", %{"type" => "noul", "noul" => 0.5}),
            # An answer missing a field deepeval's answer models require.
            put.("tone", drop.("tone", "choice")),
            put.("tone", drop.("tone", "confidence")),
            put.("q_s", drop.("q_s", "score")),
            put.("q_s", Map.put(answers["q_s"], "score", nil)),
            put.("q_s", drop.("q_s", "confidence")),
            put.("tone", put_in(answers["tone"], ["probabilities", "warm"], nil)),
            put.("tone", Map.put(answers["tone"], "choice", 1)),
            put.("q_s", put_in(answers["q_s"], ["probabilities", "1"], nil)),
            put.("q_s", put_in(answers["q_s"], ["probabilities", "1"], "0.2"))
          ] do
        stub_reply(reply)

        assert {:error, %Error{reason: :invalid_response}} =
                 TypeSafe.decide(@state, @questions, @opts),
               "accepted #{inspect(reply)}"
      end
    end
  end

  describe "decide/3 usage" do
    test "prices input tokens only, at Jev's 0.042 USD per 1M tokens" do
      stub_reply(@reply)

      assert {:ok, _answers, usage} = TypeSafe.decide(@state, @questions, @opts)

      # CPython: 1000 * (0.042 / 1e6) == 4.2000000000000004e-05
      assert usage == %Usage{
               model: "jev-latest (TypeSafe AI)",
               input_tokens: 1000,
               output_tokens: 12,
               cost: 4.2000000000000004e-05
             }
    end

    test "counts missing usage as zero tokens" do
      stub_reply(Map.delete(@reply, "usage"))

      assert {:ok, _answers, %Usage{input_tokens: 0, output_tokens: 0, cost: +0.0}} =
               TypeSafe.decide(@state, @questions, @opts)
    end

    test "uses TYPESAFE_COST_PER_INPUT_TOKEN, or the :cost_per_input_token option, zero included" do
      stub_reply(@reply)

      System.put_env("TYPESAFE_COST_PER_INPUT_TOKEN", "1e-06")
      assert {:ok, _, %Usage{cost: 0.001}} = TypeSafe.decide(@state, @questions, @opts)

      assert {:ok, _, %Usage{cost: +0.0, input_tokens: 1000}} =
               TypeSafe.decide(@state, @questions, [cost_per_input_token: 0] ++ @opts)
    end

    test "is unpriced (nil) for a model outside Jev's registry without a configured price" do
      stub_reply(@reply)

      assert {:ok, _answers, nil} =
               TypeSafe.decide(@state, @questions, [model: "jev-custom"] ++ @opts)

      assert {:ok, _answers, %Usage{cost: 0.002}} =
               TypeSafe.decide(
                 @state,
                 @questions,
                 [model: "jev-custom", cost_per_input_token: 2.0e-6] ++ @opts
               )
    end

    test "is stamped as System One's by the facade" do
      stub_reply(@reply)

      assert {:ok, _answers, %Usage{source: :system_one, model: "jev-latest (TypeSafe AI)"}} =
               SystemOne.decide(@state, @questions, system_one_model: {TypeSafe, @opts})
    end
  end

  describe "decide/3 errors" do
    test "maps max_tokens_exceeded to a context limit Jev rejected" do
      stub_reply({422, %{"detail" => %{"error_type" => "max_tokens_exceeded"}}})

      assert {:error, %Error{} = error} = TypeSafe.decide(@state, @questions, @opts)
      assert error.reason == :context_limit
      assert error.type == "SystemOneContextLimitError"
      assert error.limit_tokens == nil
      assert error.estimated_tokens == Limits.estimate_tokens(@state)

      assert error.message ==
               "Jev rejected the request as too large for its context window. " <>
                 "Send less state or use an LLM instead."

      assert Error.describe(error) == "context limit (rejected by Jev)"
    end

    test "maps max_tokens_exceeded under any status" do
      stub_reply({400, %{"detail" => %{"error_type" => "max_tokens_exceeded"}}})

      assert {:error, %Error{reason: :context_limit}} =
               TypeSafe.decide(@state, @questions, @opts)
    end

    test "does not take a bare 422 for a context limit" do
      stub_reply({422, %{"detail" => "Unprocessable"}})

      assert {:error, %Error{reason: :http, type: "TypeSafeError", permanent?: false} = error} =
               TypeSafe.decide(@state, @questions, @opts)

      assert error.message =~ "422"
      assert error.message =~ "Unprocessable"
    end

    test "reports a 422's validation errors by location" do
      # As Jev answers a request with no questions.
      stub_reply(
        {422,
         %{
           "detail" => [
             %{
               "type" => "too_short",
               "loc" => ["body", "questions"],
               "msg" => "Dictionary should have at least 1 item after validation, not 0",
               "input" => "{}",
               "ctx" => %{"field_type" => "Dictionary", "min_length" => 1, "actual_length" => 0}
             },
             %{"type" => "missing", "loc" => ["body", "items", 0], "msg" => "Field required"}
           ]
         }}
      )

      assert {:error, %Error{reason: :http, type: "TypeSafeError"} = error} =
               TypeSafe.decide(@state, @questions, @opts)

      assert error.message ==
               "TypeSafe API returned HTTP 422: body.questions: " <>
                 "Dictionary should have at least 1 item after validation, not 0; " <>
                 "body.items.0: Field required"
    end

    test "reports the raw body of a 422 whose detail is not a list of validation errors" do
      stub_reply({422, %{"detail" => [%{"msg" => "no location"}]}})

      assert {:error, %Error{reason: :http} = error} =
               TypeSafe.decide(@state, @questions, @opts)

      assert error.message ==
               ~s(TypeSafe API returned HTTP 422: {"detail":[{"msg":"no location"}]})
    end

    test "reports the message of an error_type detail" do
      stub_reply(
        {400, %{"detail" => %{"error_type" => "api_usage_error", "message" => "Unknown model"}}}
      )

      assert {:error, %Error{reason: :http} = error} =
               TypeSafe.decide(@state, @questions, @opts)

      assert error.message == "TypeSafe API returned HTTP 400: Unknown model"
    end

    test "maps 401 and 403 to permanent authentication errors" do
      # As Jev answers a wrong key (401) and a missing one (403).
      stub_reply(
        {401,
         %{
           "detail" => %{
             "error_type" => "authentication_error",
             "message" => "Cannot authenticate with the server."
           }
         }}
      )

      assert {:error,
              %Error{reason: :auth, type: "TypeSafeAuthenticationError", permanent?: true}} =
               TypeSafe.decide(@state, @questions, @opts)

      stub_reply(
        {403,
         %{
           "detail" => %{
             "error_type" => "authentication_error",
             "message" => "Must supply an API key!"
           }
         }}
      )

      assert {:error,
              %Error{reason: :auth, type: "TypeSafePermissionDeniedError", permanent?: true}} =
               TypeSafe.decide(@state, @questions, @opts)
    end

    test "maps 429 to a rate limit and 5xx to a server error" do
      stub_reply({429, %{}})

      assert {:error, %Error{reason: :rate_limited, type: "TypeSafeRateLimitError"}} =
               TypeSafe.decide(@state, @questions, @opts)

      stub_reply({503, %{}})

      assert {:error, %Error{reason: :http, type: "TypeSafeInternalServerError"}} =
               TypeSafe.decide(@state, @questions, @opts)
    end

    test "maps transport errors to ConnectionError and timeouts to TimeoutError" do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{reason: :connection, type: "ConnectionError"}} =
               TypeSafe.decide(@state, @questions, @opts)

      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{reason: :timeout, type: "TimeoutError"}} =
               TypeSafe.decide(@state, @questions, @opts)
    end
  end

  describe "decide/3 retries" do
    @describetag :capture_log
    setup :no_backoff

    test "retries 429, 5xx and transport errors" do
      for failure <- [{429, %{}}, {500, %{}}, {529, %{}}, {:transport_error, :econnrefused}] do
        counter = RetryStub.stub_replies(@stub, [failure, {200, @reply}])
        assert {:ok, _answers, _usage} = TypeSafe.decide(@state, @questions, @retry_opts)
        assert RetryStub.attempts(counter) == 2
      end
    end

    test "never retries 401, 403 or 422" do
      for status <- [401, 403, 422] do
        counter = RetryStub.stub_replies(@stub, [{status, %{}}, {200, @reply}])
        assert {:error, %Error{}} = TypeSafe.decide(@state, @questions, @retry_opts)
        assert RetryStub.attempts(counter) == 1
      end
    end

    test "does not retry a context limit" do
      exceeded = %{"detail" => %{"error_type" => "max_tokens_exceeded"}}
      counter = RetryStub.stub_replies(@stub, [{503, exceeded}, {200, @reply}])

      assert {:error, %Error{reason: :context_limit}} =
               TypeSafe.decide(@state, @questions, @retry_opts)

      assert RetryStub.attempts(counter) == 1
    end
  end
end

defmodule DeepEvalEx.SystemOne.AdapterCase.TypeSafeTest do
  # The TypeSafe adapter keeps the provider contract against a stubbed API
  # that answers every question it is sent.
  use DeepEvalEx.SystemOne.AdapterCase,
    async: true,
    failing_model:
      {DeepEvalEx.SystemOne.Adapters.TypeSafe,
       api_key: "ts-test",
       req_options: [plug: &Req.Test.transport_error(&1, :econnrefused), retry: false]},
    init_failure: {DeepEvalEx.SystemOne.Adapters.TypeSafe, api_key: ""}

  alias DeepEvalEx.SystemOne.Adapters.TypeSafe

  setup do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, answer_all(Jason.decode!(raw)["questions"]))
    end)

    %{
      system_one_model:
        {TypeSafe, api_key: "ts-test", req_options: [plug: {Req.Test, __MODULE__}, retry: false]}
    }
  end

  defp answer_all(questions) do
    %{"answers" => Map.new(questions, fn {key, question} -> {key, answer(question)} end)}
  end

  defp answer(%{"type" => "noul"}), do: %{"type" => "noul", "noul" => 0.8}

  defp answer(%{"type" => "choice", "criteria" => options}) do
    [first | _] = names = Map.keys(options)
    p = 1.0 / length(names)

    %{
      "type" => "choice",
      "choice" => first,
      "confidence" => 0.0,
      "probabilities" => Map.new(names, &{&1, p})
    }
  end

  defp answer(%{"type" => "score", "criteria" => levels}) do
    top = length(levels) - 1

    %{
      "type" => "score",
      "score" => top,
      "confidence" => 1.0,
      "probabilities" =>
        Map.new(0..top, &{Integer.to_string(&1), if(&1 == top, do: 1.0, else: 0.0)})
    }
  end
end
