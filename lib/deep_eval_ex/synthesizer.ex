# Copyright 2025 Steven Holdsworth (@holsee)
# SPDX-License-Identifier: Apache-2.0
#
# Ported from deepeval/synthesizer/synthesizer.py
# Original: https://github.com/confident-ai/deepeval

defmodule DeepEvalEx.Synthesizer do
  @moduledoc """
  Generates synthetic goldens with an LLM, deepeval 4.3.1's `Synthesizer`:
  from contexts, from scratch, or from existing goldens.

      synthesizer =
        DeepEvalEx.Synthesizer.new(
          adapter: :openai,
          model: "gpt-4.1",
          evolution_config: [num_evolutions: 2, evolutions: [reasoning: 1, comparative: 1]]
        )

      {:ok, synthesizer} =
        DeepEvalEx.Synthesizer.generate_goldens_from_contexts(synthesizer, [
          ["The Eiffel Tower was completed in 1889.", "It is 330 metres tall."]
        ])

      synthesizer.synthetic_goldens
      #=> [%DeepEvalEx.Dataset.Golden{input: "...", expected_output: "...", ...}, ...]

  Each generation returns `{:ok, synthesizer}`, the synthesizer with the
  goldens as `:synthetic_goldens` and their cost as `:synthesis_cost`, as
  deepeval keeps them on the `Synthesizer`, or `{:error, reason}` for the
  first LLM call that failed or answered outside its schema. The goldens
  can go straight into a `DeepEvalEx.Dataset.EvaluationDataset`.

  ## From contexts

  `generate_goldens_from_contexts/3` asks the model for up to
  `:max_goldens_per_context` inputs per context
  (`DeepEvalEx.Synthesizer.SynthesizerTemplate`), keeping that many. Each
  input then goes through:

  1. filtration: the critic scores it and it is rewritten while it scores
     below the threshold (`DeepEvalEx.Synthesizer.FiltrationConfig`)
  2. evolution: it is rewritten `:num_evolutions` times by evolutions drawn
     from the distribution (`DeepEvalEx.Synthesizer.EvolutionConfig`)
  3. styling: when the `DeepEvalEx.Synthesizer.StylingConfig` sets a
     scenario, task or input format, it is restyled to fit them
  4. expected output: with `include_expected_output: true` (the default),
     the model answers it from the context

  Each golden has the context, the input's first source file as
  `:source_file`, and `:additional_metadata` with `"evolutions"` (the
  evolutions' values, in order), `"synthetic_input_quality"` (the critic's
  last score), `"context_source_files"` and `"used_source_files"`.

  ## From scratch

  `generate_goldens_from_scratch/3` asks the model for `num_goldens` inputs
  fitting the styling config's scenario, task and input format (all
  three are required) and evolves each without a context (no
  `:multi_context`). The goldens have only an input and their
  `"evolutions"`.

  ## From goldens

  `generate_goldens_from_goldens/3` generates from the contexts of the
  given goldens, or from scratch when none has one. Unless the synthesizer
  was built with a `:styling_config`, the styling is first extracted from
  up to ten of the goldens' inputs, picked at random, and kept on the
  returned synthesizer.

  ## Concurrency

  Contexts, and the inputs of each context, are processed concurrently,
  up to `:max_concurrent` at a time each (deepeval's two semaphores);
  goldens keep the order of their contexts and inputs. The scripted
  `DeepEvalEx.LLM.Adapters.Mock` answers each step in call order, so tests
  replaying a script set `max_concurrent: 1`.

  ## Model calls and cost

  As in deepeval, schema answers are asked with
  `DeepEvalEx.LLM.Adapter.generate_with_schema/3`. Free-text answers
  (evolutions and expected outputs) are plain `generate/2` calls for a
  native model; a custom one is asked for deepeval's `Response` schema
  when it supports structured outputs, else with `generate/2`, as
  deepeval falls back for a model that takes no schema.

  `:synthesis_cost` is the summed cost of the native calls of the last
  generation, `nil` when the synthesizer's model is not native (see
  `DeepEvalEx.LLM.Adapter.native?/1`) or a call was not priced. With
  `cost_tracking: true`, generating from contexts prints it, as deepeval's
  `💰 API cost: ...`. The calls' usage is also recorded in the caller's
  `DeepEvalEx.LLM.Usage` scope, if any.

  ## Not ported

  Generating from documents (chunking, embeddings and context
  construction), the conversational and text-to-SQL generators,
  `save_as` and `to_pandas` (see `DeepEvalEx.Dataset.EvaluationDataset`),
  progress bars and Confident AI uploads. deepeval's `async_mode=False`
  path, which keeps every input the model returns and records
  `"context_quality"`, is not ported: DeepEvalEx behaves as deepeval's
  default `async_mode=True`.
  """

  alias DeepEvalEx.Dataset.Golden
  alias DeepEvalEx.LLM.{Adapter, Usage}
  alias DeepEvalEx.Prompts.Python

  alias DeepEvalEx.Synthesizer.{
    Evolution,
    EvolutionConfig,
    ExtractionTemplate,
    FilterTemplate,
    FiltrationConfig,
    PromptSynthesizerTemplate,
    Schema,
    StylingConfig,
    SynthesizerTemplate
  }

  @type t :: %__MODULE__{
          model: term(),
          adapter: term(),
          max_concurrent: pos_integer(),
          filtration_config: FiltrationConfig.t(),
          evolution_config: EvolutionConfig.t(),
          styling_config: StylingConfig.t(),
          set_styling_config: boolean(),
          cost_tracking: boolean(),
          synthetic_goldens: [Golden.t()],
          synthesis_cost: float() | nil
        }

  defstruct model: nil,
            adapter: nil,
            max_concurrent: 100,
            filtration_config: %FiltrationConfig{},
            evolution_config: %EvolutionConfig{},
            styling_config: %StylingConfig{},
            set_styling_config: false,
            cost_tracking: false,
            synthetic_goldens: [],
            synthesis_cost: nil

  @scratch_styling_error "`scenario`, `task`, and `input_format` in `styling_config` must not be None when generation goldens from scratch."

  @new_options [
    :model,
    :adapter,
    :max_concurrent,
    :filtration_config,
    :evolution_config,
    :styling_config,
    :cost_tracking
  ]

  @doc """
  Builds a synthesizer, deepeval's `Synthesizer(...)`.

  ## Options

  - `:model`, `:adapter` - the model generating the goldens, as a metric's
    (default: the configured default model)
  - `:max_concurrent` - contexts, and inputs per context, processed at
    once (default: `100`)
  - `:filtration_config` - a `DeepEvalEx.Synthesizer.FiltrationConfig` or
    its fields (default: the defaults, with this synthesizer's model as
    the critic)
  - `:evolution_config` - a `DeepEvalEx.Synthesizer.EvolutionConfig` or
    its fields (default: one evolution, any of the seven)
  - `:styling_config` - a `DeepEvalEx.Synthesizer.StylingConfig` or its
    fields (default: none set; `generate_goldens_from_goldens/3` then
    extracts one)
  - `:cost_tracking` - print the cost of generating from contexts
    (default: `false`)

  Raises `ArgumentError` for an unknown option or an invalid config.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    case Keyword.keys(opts) -- @new_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown synthesizer options: #{inspect(unknown)}"
    end

    max_concurrent = Keyword.get(opts, :max_concurrent, 100)

    unless is_integer(max_concurrent) and max_concurrent > 0 do
      raise ArgumentError,
            "max_concurrent must be a positive integer, got: #{inspect(max_concurrent)}"
    end

    filtration_config =
      case Keyword.fetch(opts, :filtration_config) do
        {:ok, config} when not is_nil(config) ->
          FiltrationConfig.new(config)

        _ ->
          %FiltrationConfig{critic_model: opts[:model], critic_adapter: opts[:adapter]}
      end

    styling_config = Keyword.get(opts, :styling_config)

    %__MODULE__{
      model: opts[:model],
      adapter: opts[:adapter],
      max_concurrent: max_concurrent,
      filtration_config: filtration_config,
      evolution_config: EvolutionConfig.new(Keyword.get(opts, :evolution_config) || []),
      styling_config: StylingConfig.new(styling_config || []),
      set_styling_config: not is_nil(styling_config),
      cost_tracking: Keyword.get(opts, :cost_tracking, false)
    }
  end

  # ---------------------------------------------------------------------------
  # From contexts

  @doc """
  Generates goldens from `contexts`, each a list of chunks (strings),
  deepeval's `generate_goldens_from_contexts`. See "From contexts".

  ## Options

  - `:include_expected_output` - generate each golden's expected output
    (default: `true`)
  - `:max_goldens_per_context` - inputs to generate per context
    (default: `2`)
  - `:source_files` - per context, its source file (a string) or files (a
    list of strings); a list of two or more asks for cross-file inputs
  - `:context_chunk_source_files` - per context, the source file of each
    chunk; chunks from two or more files are labelled `[SOURCE: file]`
  - `:target_files_per_context` - how many source files each cross-file
    input must combine

  Any other option is passed to the LLM adapter.
  """
  @spec generate_goldens_from_contexts(t(), [[String.t()]], keyword()) ::
          {:ok, t()} | {:error, term()}
  def generate_goldens_from_contexts(%__MODULE__{} = synthesizer, contexts, opts \\ []) do
    {args, llm_opts} =
      Keyword.split(opts, [
        :include_expected_output,
        :max_goldens_per_context,
        :source_files,
        :context_chunk_source_files,
        :target_files_per_context
      ])

    args = Keyword.merge([include_expected_output: true, max_goldens_per_context: 2], args)
    check_distribution!(synthesizer.evolution_config.evolutions, synthesizer.evolution_config)

    result =
      with_cost(synthesizer, llm_opts, fn ->
        contexts
        |> Enum.with_index()
        |> concurrently(synthesizer, fn {context, index} ->
          generate_from_context(synthesizer, context, index, args, llm_opts)
        end)
        |> map_ok(&Enum.concat/1)
      end)

    with {:ok, goldens, cost} <- result do
      print_cost(synthesizer, llm_opts, cost)
      {:ok, %{synthesizer | synthetic_goldens: goldens, synthesis_cost: cost}}
    end
  end

  defp generate_from_context(synthesizer, context, index, args, llm_opts) do
    max_goldens = Keyword.fetch!(args, :max_goldens_per_context)
    source = args |> Keyword.get(:source_files) |> at(index)
    styling = synthesizer.styling_config

    formatted_context =
      format_context_with_sources(
        context,
        args |> Keyword.get(:context_chunk_source_files) |> at(index)
      )

    prompt =
      SynthesizerTemplate.generate_synthetic_inputs(
        context: formatted_context,
        max_goldens_per_context: max_goldens,
        scenario: styling.scenario,
        task: styling.task,
        input_format: styling.input_format,
        available_source_files: if(is_list(source), do: source),
        target_files_per_context: Keyword.get(args, :target_files_per_context)
      )

    with {:ok, inputs} <- generate_inputs(prompt, model_opts(synthesizer, llm_opts)),
         {:ok, qualified} <-
           rewrite_inputs(
             synthesizer,
             formatted_context,
             Enum.take(inputs, max_goldens),
             llm_opts
           ) do
      context_source_files =
        cond do
          is_list(source) -> source
          source in [nil, ""] -> []
          true -> [source]
        end

      origin = %{
        context: context,
        formatted_context: formatted_context,
        source_files: context_source_files
      }

      concurrently(qualified, synthesizer, fn {data, score} ->
        golden_from_input(synthesizer, data, score, origin, args, llm_opts)
      end)
    end
  end

  # One qualified input of a context evolved, styled and answered: its
  # golden. `origin` holds the context, as given and as formatted, and its
  # source files.
  defp golden_from_input(synthesizer, data, score, origin, args, llm_opts) do
    %{context: context, formatted_context: formatted_context, source_files: source_files} = origin
    opts = model_opts(synthesizer, llm_opts)
    styling = synthesizer.styling_config
    evolutions = synthesizer.evolution_config

    with {:ok, input, evolutions_used} <-
           evolve_input(
             data.input,
             formatted_context,
             evolutions.num_evolutions,
             evolutions.evolutions,
             opts
           ),
         {:ok, input} <- style_input(styling, input, opts),
         {:ok, expected_output} <- expected_output(styling, input, context, args, opts) do
      {:ok,
       %Golden{
         input: input,
         context: context,
         expected_output: expected_output,
         source_file: List.first(source_files),
         additional_metadata: %{
           "evolutions" => evolutions_used,
           "synthetic_input_quality" => score,
           "context_source_files" => source_files,
           "used_source_files" => data.used_source_files || []
         }
       }}
    end
  end

  defp style_input(styling, input, opts) do
    if StylingConfig.style?(styling) do
      prompt =
        SynthesizerTemplate.rewrite_evolved_input(
          input_format: styling.input_format,
          evolved_input: input,
          scenario: styling.scenario,
          task: styling.task
        )

      with {:ok, data} <-
             generate_schema(
               prompt,
               Schema.synthetic_data(),
               &Schema.parse_synthetic_data/1,
               opts
             ),
           do: {:ok, data.input}
    else
      {:ok, input}
    end
  end

  defp expected_output(styling, input, context, args, opts) do
    if Keyword.fetch!(args, :include_expected_output) do
      SynthesizerTemplate.generate_synthetic_expected_output(
        input: input,
        context: Enum.join(context, "\n"),
        expected_output_format: styling.expected_output_format
      )
      |> generate_text(opts)
    else
      {:ok, nil}
    end
  end

  # deepeval's _format_context_with_sources: chunks labelled with their
  # source file only when the context spans two or more files.
  defp format_context_with_sources(context, chunk_source_files) do
    if is_list(chunk_source_files) and chunk_source_files != [] and
         length(chunk_source_files) == length(context) and
         chunk_source_files |> Enum.uniq() |> length() >= 2 do
      Enum.zip_with(chunk_source_files, context, &"[SOURCE: #{&1}] #{&2}")
    else
      context
    end
  end

  # deepeval's _a_rewrite_inputs: each input scored by the critic and
  # rewritten while below the threshold, up to max_quality_retries times.
  defp rewrite_inputs(synthesizer, context, inputs, llm_opts) do
    config = synthesizer.filtration_config
    critic_opts = critic_opts(synthesizer, llm_opts)
    opts = model_opts(synthesizer, llm_opts)

    Enum.reduce_while(inputs, {:ok, []}, fn data, {:ok, acc} ->
      case rewrite_input(
             data.input,
             0.0,
             config.max_quality_retries,
             config,
             context,
             critic_opts,
             opts
           ) do
        {:ok, input, score} -> {:cont, {:ok, [{%{data | input: input}, score} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> map_ok(&Enum.reverse/1)
  end

  defp rewrite_input(input, score, 0, _config, _context, _critic_opts, _opts),
    do: {:ok, input, score}

  defp rewrite_input(input, _score, retries, config, context, critic_opts, opts) do
    prompt = FilterTemplate.evaluate_synthetic_inputs(query: input)

    with {:ok, {score, feedback}} <-
           generate_schema(
             prompt,
             Schema.input_feedback(),
             &Schema.parse_input_feedback/1,
             critic_opts
           ) do
      if score >= config.synthetic_input_quality_threshold do
        {:ok, input, score}
      else
        prompt =
          SynthesizerTemplate.rewrite_synthetic_inputs(
            context: context,
            original_query: input,
            feedback: feedback
          )

        with {:ok, rewritten} <-
               generate_schema(
                 prompt,
                 Schema.rewritten_input(),
                 &Schema.parse_rewritten_input/1,
                 opts
               ) do
          rewrite_input(rewritten, score, retries - 1, config, context, critic_opts, opts)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # From scratch

  @doc """
  Generates `num_goldens` goldens from scratch, deepeval's
  `generate_goldens_from_scratch`. See "From scratch".

  The styling config's `:scenario`, `:task` and `:input_format` must all be
  set: otherwise raises `ArgumentError` with deepeval's message (deepeval
  raises a `TypeError`). The model may return more or fewer inputs than
  asked; all are kept, as deepeval keeps them.

  Options are passed to the LLM adapter.
  """
  @spec generate_goldens_from_scratch(t(), non_neg_integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def generate_goldens_from_scratch(%__MODULE__{} = synthesizer, num_goldens, opts \\ []) do
    styling = synthesizer.styling_config

    if Enum.any?([styling.scenario, styling.task, styling.input_format], &is_nil/1) do
      raise ArgumentError, @scratch_styling_error
    end

    evolutions = synthesizer.evolution_config
    distribution = EvolutionConfig.prompt_distribution(evolutions.evolutions)
    check_distribution!(distribution, evolutions)
    model_opts = model_opts(synthesizer, opts)

    prompt =
      PromptSynthesizerTemplate.generate_synthetic_prompts(
        scenario: styling.scenario,
        task: styling.task,
        input_format: styling.input_format,
        num_goldens: num_goldens
      )

    result =
      with_cost(synthesizer, opts, fn ->
        with {:ok, inputs} <- generate_inputs(prompt, model_opts) do
          concurrently(inputs, synthesizer, fn data ->
            with {:ok, input, evolutions_used} <-
                   evolve_input(
                     data.input,
                     :none,
                     evolutions.num_evolutions,
                     distribution,
                     model_opts
                   ) do
              {:ok,
               %Golden{input: input, additional_metadata: %{"evolutions" => evolutions_used}}}
            end
          end)
        end
      end)

    with {:ok, goldens, cost} <- result do
      {:ok, %{synthesizer | synthetic_goldens: goldens, synthesis_cost: cost}}
    end
  end

  # ---------------------------------------------------------------------------
  # From goldens

  @doc """
  Generates goldens from existing `goldens`, deepeval's
  `generate_goldens_from_goldens`. See "From goldens".

  The goldens with a context (`:context` not `nil`) are generated from
  with `generate_goldens_from_contexts/3`, their `:source_file` as the
  context's source file; when none has one, `max_goldens_per_golden`
  goldens per golden are generated with `generate_goldens_from_scratch/3`.

  ## Options

  - `:max_goldens_per_golden` - goldens to generate per golden
    (default: `2`)
  - `:include_expected_output` - as for `generate_goldens_from_contexts/3`
    (default: `true`)

  Any other option is passed to the LLM adapter.
  """
  @spec generate_goldens_from_goldens(t(), [Golden.t()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def generate_goldens_from_goldens(%__MODULE__{} = synthesizer, goldens, opts \\ []) do
    {max_per_golden, opts} = Keyword.pop(opts, :max_goldens_per_golden, 2)
    {include_expected_output, opts} = Keyword.pop(opts, :include_expected_output, true)
    with_context = Enum.reject(goldens, &is_nil(&1.context))

    with {:ok, synthesizer} <- extract_styling(synthesizer, goldens, opts) do
      if with_context == [] do
        generate_goldens_from_scratch(synthesizer, length(goldens) * max_per_golden, opts)
      else
        generate_goldens_from_contexts(
          synthesizer,
          Enum.map(with_context, & &1.context),
          [
            include_expected_output: include_expected_output,
            max_goldens_per_context: max_per_golden,
            source_files: Enum.map(with_context, & &1.source_file)
          ] ++ opts
        )
      end
    end
  end

  defp extract_styling(%__MODULE__{set_styling_config: true} = synthesizer, _goldens, _opts),
    do: {:ok, synthesizer}

  defp extract_styling(synthesizer, goldens, opts) do
    inputs = goldens |> Enum.map(& &1.input) |> Enum.take_random(10)
    prompt = ExtractionTemplate.extract_prompt_structure_from_inputs(inputs: inputs)

    with {:ok, styling} <-
           generate_schema(
             prompt,
             Schema.prompt_styling(),
             &Schema.parse_prompt_styling/1,
             model_opts(synthesizer, opts)
           ) do
      {:ok, %{synthesizer | styling_config: StylingConfig.new(styling)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Evolution

  # deepeval's _a_evolve_input: num_evolutions rewrites in a row, each by an
  # evolution drawn from the distribution.
  defp evolve_input(input, context, num_evolutions, distribution, opts) do
    Enum.reduce_while(1..num_evolutions//1, {:ok, input, []}, fn _, {:ok, input, used} ->
      evolution = EvolutionConfig.pick(distribution)

      case evolution |> Evolution.prompt(input, context) |> generate_text(opts) do
        {:ok, evolved} -> {:cont, {:ok, evolved, [Evolution.value(evolution) | used]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, input, used} -> {:ok, input, Enum.reverse(used)}
      error -> error
    end
  end

  # Raises in the caller, before any task starts, where deepeval's
  # random.choices raises for every input.
  defp check_distribution!(distribution, %EvolutionConfig{num_evolutions: num_evolutions}) do
    if num_evolutions > 0 and distribution |> Enum.map(&elem(&1, 1)) |> Enum.sum() <= 0 do
      raise ArgumentError, "Total of weights must be greater than zero"
    end
  end

  # ---------------------------------------------------------------------------
  # Model calls

  defp generate_inputs(prompt, opts) do
    generate_schema(
      prompt,
      Schema.synthetic_data_list(),
      &Schema.parse_synthetic_data_list/1,
      opts
    )
  end

  # deepeval's _a_generate_schema.
  defp generate_schema(prompt, schema, parse, opts) do
    result = costed(opts, fn -> Adapter.generate_with_schema(prompt, schema, opts) end)
    with {:ok, answer} <- result, do: parse.(answer)
  end

  # deepeval's _a_generate: text from a native model, the Response schema
  # from a custom one that takes a schema.
  defp generate_text(prompt, opts) do
    cond do
      Adapter.native?(opts) ->
        costed(opts, fn -> Adapter.generate(prompt, opts) end)

      adapter_module(opts).supports_structured_outputs?() ->
        generate_schema(prompt, Schema.response(), &Schema.parse_response/1, opts)

      true ->
        costed(opts, fn -> Adapter.generate(prompt, opts) end)
    end
  end

  # Runs one call, keeping its usage in the caller's scope; a custom
  # model's calls add nothing to the synthesis cost, as in deepeval.
  defp costed(opts, fun) do
    {result, usages} = Usage.track(fun)

    usages =
      if Adapter.native?(opts),
        do: usages,
        else: Enum.map(usages, &%{&1 | cost: 0.0})

    Usage.record_all(usages)
    result
  end

  defp adapter_module(opts) do
    case Keyword.get(opts, :adapter) do
      nil -> elem(Adapter.default_adapter(), 0)
      {provider, _model} -> Adapter.get_adapter(provider)
      adapter -> Adapter.get_adapter(adapter)
    end
  end

  defp model_opts(synthesizer, llm_opts),
    do: judge_opts(llm_opts, synthesizer.adapter, synthesizer.model)

  defp critic_opts(synthesizer, llm_opts) do
    config = synthesizer.filtration_config
    judge_opts(llm_opts, config.critic_adapter, config.critic_model)
  end

  defp judge_opts(llm_opts, adapter, model) do
    llm_opts
    |> Keyword.drop([:adapter, :model])
    |> put_present(:adapter, adapter)
    |> put_present(:model, model)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # Runs fun in a usage scope: {:ok, goldens, synthesis_cost}, the cost
  # nil unless the synthesizer's model is native. The usages are passed on
  # to the caller's scope.
  defp with_cost(synthesizer, llm_opts, fun) do
    {result, usages} = Usage.track(fun)
    Usage.record_all(usages)

    with {:ok, goldens} <- result do
      cost =
        if Adapter.native?(model_opts(synthesizer, llm_opts)) do
          costs = Enum.map(usages, & &1.cost)
          if Enum.any?(costs, &is_nil/1), do: nil, else: Enum.sum([0.0 | costs])
        end

      {:ok, goldens, cost}
    end
  end

  defp print_cost(%__MODULE__{cost_tracking: true}, _llm_opts, cost) when is_float(cost),
    do: IO.puts("💰 API cost: #{Python.format_fixed(cost, 6)}")

  defp print_cost(_synthesizer, _llm_opts, _cost), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers

  # Runs fun over items, up to max_concurrent at once, keeping their order
  # and their usage; the first error stops the rest.
  defp concurrently(items, synthesizer, fun) do
    items
    |> Task.async_stream(fn item -> Usage.track(fn -> fun.(item) end) end,
      max_concurrency: synthesizer.max_concurrent,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn {:ok, {result, usages}}, {:ok, acc} ->
      Usage.record_all(usages)

      case result do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> map_ok(&Enum.reverse/1)
  end

  defp map_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_ok(error, _fun), do: error

  defp at(nil, _index), do: nil
  defp at(list, index), do: Enum.at(list, index)
end
