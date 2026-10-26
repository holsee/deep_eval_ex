# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/models/system_one/typesafe_model.py and
# deepeval/models/system_one/constants.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.SystemOne.Adapters.TypeSafe do
  @moduledoc """
  TypeSafe AI's System One model, Jev: the default
  `DeepEvalEx.SystemOne.Adapter`, a port of deepeval 4.3.1's
  `TypeSafeModel` on `Req`.

  Pick it with `system_one_model: :typesafe` (or `:jev`), a Jev model name
  such as `system_one_model: "jev-preview"`, or by leaving
  `:system_one_model` unset (see `DeepEvalEx.SystemOne.Model`).

  ## Configuration

  Each option falls back to a `DeepEvalEx.Config` setting, then to
  deepeval's default:

  | Option | Setting | Environment variable | Default |
  |--------|---------|----------------------|---------|
  | `:api_key` | `:typesafe_api_key` | `TYPESAFE_API_KEY` | none: required |
  | `:model` | `:typesafe_model_name` | `TYPESAFE_MODEL_NAME` | `"jev-latest"` |
  | `:cost_per_input_token` | `:typesafe_cost_per_input_token` | `TYPESAFE_COST_PER_INPUT_TOKEN` | Jev's price |

  `init/1`, which `DeepEvalEx.SystemOne.Context.resolve!/2` runs when a
  metric's eval mode uses System One, fails without an API key, so a
  missing key fails the evaluation before any measure, as deepeval fails
  when the metric is built. Under the `:llm` eval mode the key is never
  needed. A negative price raises `DeepEvalEx.DeepEvalError`.

  Other options:

  - `:base_url` - the API's base URL (default `"https://api.typesafe.ai"`)
  - `:timeout` - receive timeout in milliseconds (default `60_000`)
  - `:req_options` - extra `Req` options merged into the request, e.g.
    `[plug: {Req.Test, DeepEvalEx.SystemOne.Adapters.TypeSafe}]` in tests

  `model_name/1` is `"<model> (TypeSafe AI)"`, deepeval's
  `get_model_name()`, which a metric decided by System One alone reports as
  its evaluation model.

  ## Requests

  `decide/3` posts the state, the questions in the SDK's shape
  (`DeepEvalEx.SystemOne.Question.to_wire/1` under each key) and the model
  name to `POST {base_url}/v1/systemone` with the key as a Bearer token.
  Before sending, it fails with deepeval's `DeepEvalError` when there are
  no questions, then checks the request fits in Jev's context
  (`DeepEvalEx.SystemOne.Limits.check/3`).

  The reply's `answers` hold each answer under its question's key, tagged
  with a `type` of `noul`, `choice` or `score`; they become
  `DeepEvalEx.SystemOne.Answers`, keeping the reply's order of
  probabilities, with a Score's level keys cast to integers. A reply
  without `answers`, or with an answer of another type, is invalid.

  deepeval calls the `typesafe-sdk` client rather than the HTTP API. These
  wire details follow TypeSafe's HTTP API reference
  (<https://docs.typesafe.ai/api>) and were checked against Jev itself: the
  endpoint, the request body (`{state, questions, model}`), the Bearer
  header, the reply (`{model, answers, usage}`) and the error bodies
  (`{"detail": {"error_type": ..., "message": ...}}`, or a 422's list of
  `{loc, msg, type}` validation errors).

  ## Usage and cost

  The reply's `usage.input_tokens` and `usage.output_tokens` (`0` when
  missing) are returned as a `DeepEvalEx.LLM.Usage` priced as
  `input_tokens * cost_per_input_token`; output tokens are free. Jev's
  registered models (`jev-1.13.0`, `jev-latest` and `jev-preview`) cost
  0.042 USD per 1M input tokens. Any other model without a configured price
  is unpriced: the usage is `nil`, as deepeval's `calculate_cost` returns
  `None`.

  ## Errors

  Failures are returned as `DeepEvalEx.SystemOne.Error`s:

  - a reply whose `detail.error_type` is `"max_tokens_exceeded"`, under any
    status, is `reason: :context_limit` (`SystemOneContextLimitError`,
    `limit_tokens: nil`) with deepeval's "Jev rejected the request as too
    large ..." text. A bare `422` is not a context limit
  - `401` and `403` are `reason: :auth`, permanent
  - `429` is `reason: :rate_limited`
  - any other status is `reason: :http`
  - a timeout is `reason: :timeout` (`TimeoutError`) and any other
    transport error `reason: :connection` (`ConnectionError`)
  - a reply that is not System One answers is `reason: :invalid_response`

  ## Retries

  Requests are retried as deepeval retries TypeSafe calls (the `:typesafe`
  policy of `DeepEvalEx.LLM.Retry`): transport errors, `429` and `5xx`, up
  to `DEEPEVAL_RETRY_MAX_ATTEMPTS` attempts. Authentication, permission and
  other client errors, and context limits, are never retried.
  """

  use DeepEvalEx.SystemOne.Adapter

  alias DeepEvalEx.{Config, DeepEvalError}
  alias DeepEvalEx.LLM.{Retry, Usage}
  alias DeepEvalEx.SystemOne.{Answers, Error, Limits, Question}
  alias Jason.OrderedObject

  @default_base_url "https://api.typesafe.ai"
  @path "/v1/systemone"
  @default_model "jev-latest"

  # deepeval's _JEV_INPUT_PRICE, computed as it computes it (0.042 / 1e6),
  # so a cost is the same float.
  @jev_input_price 0.042 / 1.0e6
  @jev_models ~w(jev-1.13.0 jev-latest jev-preview)

  @context_limit_message "Jev rejected the request as too large for its context " <>
                           "window. Send less state or use an LLM instead."

  @impl true
  def model_name(opts), do: "#{model(opts)} (TypeSafe AI)"

  @doc """
  Resolves the API key, model and price from the options and settings,
  deepeval's `TypeSafeModel` construction.

  Returns the options with `:api_key`, `:model` and, when one is
  configured, `:cost_per_input_token` filled in, or a permanent
  `DeepEvalEx.SystemOne.Error` (`reason: :auth`) with deepeval's text when
  there is no API key or it is empty. Raises `DeepEvalEx.DeepEvalError` for
  a negative price.
  """
  @impl true
  def init(opts) do
    with {:ok, api_key} <- api_key(opts) do
      opts =
        opts
        |> Keyword.put(:api_key, api_key)
        |> Keyword.put(:model, model(opts))

      case configured_price(opts) do
        nil -> {:ok, opts}
        price -> {:ok, Keyword.put(opts, :cost_per_input_token, price)}
      end
    end
  end

  @impl true
  def decide(_state, [], _opts) do
    {:error, %DeepEvalError{message: "TypeSafeModel.decide requires at least one question."}}
  end

  def decide(state, questions, opts) do
    wire = Question.to_wire_map(questions)

    with :ok <- Limits.check(state, wire, context_budget(opts)),
         {:ok, api_key} <- api_key(opts),
         {:ok, body} <- post(state, wire, api_key, opts) do
      from_reply(body, opts)
    end
  end

  defp model(opts) do
    Keyword.get(opts, :model) || Config.get(:typesafe_model_name) || @default_model
  end

  # deepeval's require_secret_api_key, with its text.
  defp api_key(opts) do
    case Keyword.get(opts, :api_key) || Config.get(:typesafe_api_key) do
      nil ->
        key_error(
          "TypeSafe AI API key is not configured. Set TYPESAFE_API_KEY in your " <>
            "environment or pass `api_key` to TypeSafeModel(...)."
        )

      "" ->
        key_error("TypeSafe AI API key is empty. Please configure a valid key.")

      api_key ->
        {:ok, api_key}
    end
  end

  defp key_error(message) do
    {:error, %Error{reason: :auth, type: "DeepEvalError", message: message, permanent?: true}}
  end

  defp configured_price(opts) do
    case Keyword.get(opts, :cost_per_input_token) || Config.get(:typesafe_cost_per_input_token) do
      nil ->
        nil

      price when is_number(price) and price >= 0 ->
        price * 1.0

      _negative ->
        raise DeepEvalError, message: "TYPESAFE_COST_PER_INPUT_TOKEN must be >= 0."
    end
  end

  # The configured price, else Jev's for a registered model, else nil
  # (deepeval's default_model_data has no price).
  defp price(opts) do
    configured_price(opts) || if(model(opts) in @jev_models, do: @jev_input_price)
  end

  defp post(state, wire, api_key, opts) do
    body =
      OrderedObject.new([
        {"state", state},
        {"questions", wire},
        {"model", model(opts)}
      ])

    req_opts =
      [
        json: body,
        auth: {:bearer, api_key},
        receive_timeout: Keyword.get(opts, :timeout, 60_000),
        # Decoded here, keeping the order of the reply's probabilities.
        decode_body: false
      ]
      |> Keyword.merge(Retry.req_options(:typesafe))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(base_url(opts) <> @path, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{} = response} ->
        {:error, http_error(response, state)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp base_url(opts) do
    opts |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")
  end

  defp transport_error(%Req.TransportError{reason: :timeout} = exception),
    do: %Error{reason: :timeout, type: "TimeoutError", message: Exception.message(exception)}

  defp transport_error(exception),
    do: %Error{
      reason: :connection,
      type: "ConnectionError",
      message: Exception.message(exception)
    }

  # deepeval's _jev_max_tokens_as_context_limit, then the SDK's error
  # classes by status.
  defp http_error(%Req.Response{status: status, body: body}, state) do
    detail = detail(body)

    if match?(%{"error_type" => "max_tokens_exceeded"}, detail) do
      %Error{
        reason: :context_limit,
        type: "SystemOneContextLimitError",
        message: @context_limit_message,
        estimated_tokens: Limits.estimate_tokens(state),
        limit_tokens: nil
      }
    else
      {reason, type, permanent?} = classify(status)

      %Error{
        reason: reason,
        type: type,
        message: "TypeSafe API returned HTTP #{status}: #{detail_text(detail, body)}",
        permanent?: permanent?
      }
    end
  end

  defp classify(401), do: {:auth, "TypeSafeAuthenticationError", true}
  defp classify(403), do: {:auth, "TypeSafePermissionDeniedError", true}
  defp classify(429), do: {:rate_limited, "TypeSafeRateLimitError", false}
  defp classify(status) when status in 500..599, do: {:http, "TypeSafeInternalServerError", false}
  defp classify(_status), do: {:http, "TypeSafeError", false}

  defp detail(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"detail" => detail}} -> detail
      _ -> nil
    end
  end

  defp detail(_body), do: nil

  defp detail_text(detail, _body) when is_binary(detail), do: detail
  defp detail_text(%{"message" => message}, _body) when is_binary(message), do: message

  # A 422's validation errors, each as `loc: msg`.
  defp detail_text([_ | _] = errors, body) do
    if Enum.all?(errors, &match?(%{"loc" => [_ | _], "msg" => msg} when is_binary(msg), &1)) do
      Enum.map_join(errors, "; ", fn %{"loc" => loc, "msg" => msg} ->
        Enum.join(loc, ".") <> ": " <> msg
      end)
    else
      detail_text(nil, body)
    end
  end

  defp detail_text(_detail, body) when is_binary(body), do: String.trim(body)
  defp detail_text(_detail, body), do: inspect(body)

  # deepeval's _from_sdk_response and calculate_cost, reading the HTTP
  # API's reply: each answer under `answers` by its question's key, tagged
  # with its type.
  defp from_reply(body, opts) do
    with {:ok, %OrderedObject{} = reply} <- Jason.decode(body, objects: :ordered_objects),
         {:ok, answers} <- read(reply["answers"]) do
      {:ok, answers, usage(reply["usage"], opts)}
    else
      _invalid ->
        {:error,
         %Error{
           reason: :invalid_response,
           type: "TypeSafeError",
           message: "TypeSafe API returned an unexpected response: #{String.slice(body, 0, 200)}"
         }}
    end
  end

  defp read(%OrderedObject{} = answers) do
    Enum.reduce_while(answers, {:ok, %Answers{}}, fn {key, answer}, {:ok, acc} ->
      case answer(answer) do
        {:ok, field, built} -> {:cont, {:ok, Map.update!(acc, field, &Map.put(&1, key, built))}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp read(_answers), do: :error

  defp answer(%OrderedObject{} = answer) do
    case answer["type"] do
      "noul" -> tag(:nouls, noul(answer))
      "choice" -> tag(:choices, choice(answer))
      "score" -> tag(:scores, score(answer))
      _ -> :error
    end
  end

  defp answer(_answer), do: :error

  defp tag(field, {:ok, built}), do: {:ok, field, built}
  defp tag(_field, :error), do: :error

  defp noul(%OrderedObject{} = answer) do
    case answer["noul"] do
      probability when is_number(probability) -> {:ok, %Answers.Noul{probability: probability}}
      _ -> :error
    end
  end

  defp choice(%OrderedObject{} = answer) do
    case answer["probabilities"] do
      %OrderedObject{values: probabilities} ->
        {:ok,
         %Answers.Choice{
           choice: answer["choice"],
           probabilities: probabilities,
           confidence: answer["confidence"]
         }}

      _ ->
        :error
    end
  end

  defp score(%OrderedObject{} = answer) do
    with %OrderedObject{values: probabilities} <- answer["probabilities"],
         {:ok, probabilities} <- levels(probabilities) do
      {:ok,
       %Answers.Score{
         score: answer["score"],
         probabilities: probabilities,
         confidence: answer["confidence"]
       }}
    else
      _ -> :error
    end
  end

  # The SDK's level keys are strings; deepeval casts them with int().
  defp levels(probabilities) do
    Enum.reduce_while(Enum.reverse(probabilities), {:ok, []}, fn {level, p}, {:ok, acc} ->
      case Integer.parse(level) do
        {index, ""} -> {:cont, {:ok, [{index, p} | acc]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp usage(usage, opts) do
    input_tokens = tokens(usage, "input_tokens")
    output_tokens = tokens(usage, "output_tokens")

    case price(opts) do
      nil ->
        nil

      price ->
        %Usage{
          model: model_name(opts),
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost: input_tokens * price
        }
    end
  end

  defp tokens(%OrderedObject{} = usage, key) do
    case usage[key] do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  defp tokens(_usage, _key), do: 0
end
