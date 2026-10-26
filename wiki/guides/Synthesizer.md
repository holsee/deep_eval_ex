# Synthesizer

`DeepEvalEx.Synthesizer` generates synthetic goldens with an LLM: inputs,
and expected outputs, for a dataset you do not have yet. It is deepeval
4.3.1's `Synthesizer`, with the same prompts byte for byte, from three
sources:

- **contexts**: lists of chunks your application retrieves, such as
  passages of your documentation
- **scratch**: a description of who asks what, and in which form
- **goldens**: existing goldens, from their contexts or, without any, from
  the styling of their inputs

## From contexts

```elixir
synthesizer = DeepEvalEx.Synthesizer.new(adapter: :openai, model: "gpt-4.1")

contexts = [
  ["The Eiffel Tower was completed in 1889.", "It is 330 metres tall."],
  ["The Louvre opens at 9am.", "It is closed on Tuesdays."]
]

{:ok, synthesizer} =
  DeepEvalEx.Synthesizer.generate_goldens_from_contexts(synthesizer, contexts,
    max_goldens_per_context: 2
  )

dataset = DeepEvalEx.Dataset.EvaluationDataset.new(synthesizer.synthetic_goldens)
```

For each context the model writes up to `:max_goldens_per_context` inputs.
Each input is then:

1. **filtered**: a critic scores its clarity from 0 to 1, and it is
   rewritten from the critic's feedback while it scores below the
   threshold, up to `:max_quality_retries` times
2. **evolved**: rewritten `:num_evolutions` times into a harder input, by
   evolutions drawn at random
3. **styled**: rewritten to fit the styling's scenario, task and input
   format, when any is set
4. **answered**: the model writes its expected output from the context,
   unless `include_expected_output: false`

Each golden keeps its context, and its `additional_metadata` records the
evolutions applied (`"evolutions"`), the critic's last score
(`"synthetic_input_quality"`) and the source files (`"context_source_files"`,
`"used_source_files"`).

Pass `:source_files` (one per context) to name each context's file, which
becomes the golden's `:source_file`. A context built from several files
can label its chunks with `:context_chunk_source_files`: with a list of
two or more files in `:source_files`, the model is asked for inputs that
combine them (at least `:target_files_per_context` of them) and reports
the files each input used.

## From scratch

Without contexts, the styling must say who asks, what the application does
and the form of the inputs:

```elixir
synthesizer =
  DeepEvalEx.Synthesizer.new(
    styling_config: [
      scenario: "Non-technical staff querying the sales database",
      task: "Answering questions about sales with SQL",
      input_format: "A question in plain English"
    ]
  )

{:ok, synthesizer} = DeepEvalEx.Synthesizer.generate_goldens_from_scratch(synthesizer, 10)
```

The inputs are evolved as above (without the Multi-context evolution,
which needs a context), and have no expected output.

## From goldens

```elixir
{:ok, synthesizer} =
  DeepEvalEx.Synthesizer.generate_goldens_from_goldens(synthesizer, dataset.goldens,
    max_goldens_per_golden: 2
  )
```

Goldens with a context are generated from as contexts; when none has one,
`max_goldens_per_golden` goldens per golden are generated from scratch.
Unless the synthesizer was built with a `:styling_config`, the styling is
first extracted from up to ten of the goldens' inputs and kept on the
returned synthesizer's `:styling_config`.

## Configuration

| Option               | Struct                                   | Fields (defaults)                                                                                   |
| -------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `:styling_config`    | `DeepEvalEx.Synthesizer.StylingConfig`    | `:scenario`, `:task`, `:input_format`, `:expected_output_format` (all `nil`)                        |
| `:evolution_config`  | `DeepEvalEx.Synthesizer.EvolutionConfig`  | `:num_evolutions` (`1`), `:evolutions` (all seven, `1/7` each)                                      |
| `:filtration_config` | `DeepEvalEx.Synthesizer.FiltrationConfig` | `:synthetic_input_quality_threshold` (`0.5`), `:max_quality_retries` (`3`), `:critic_model`, `:critic_adapter` |

Each takes the struct or a keyword list of its fields. The evolutions are
`:reasoning`, `:multi_context`, `:concretizing`, `:constrained`,
`:comparative`, `:hypothetical` and `:in_breadth`
(`DeepEvalEx.Synthesizer.Evolution`), weighted relative to each other:

```elixir
DeepEvalEx.Synthesizer.new(
  evolution_config: [num_evolutions: 2, evolutions: [reasoning: 2, comparative: 1]],
  filtration_config: [synthetic_input_quality_threshold: 0.7, critic_model: "gpt-4.1-mini"]
)
```

Without a `:filtration_config` the synthesizer's own model is the critic;
a filtration config without a critic uses the configured default model,
as deepeval does.

`:max_concurrent` (default `100`) bounds how many contexts, and inputs of
a context, are worked on at once. A generation returns
`{:error, reason}` for the first model call that fails or answers outside
its schema. `:synthesis_cost` is the generation's cost with a native model
(`nil` otherwise); `cost_tracking: true` prints it after generating from
contexts.

## Testing with the Mock adapter

The scripted `DeepEvalEx.LLM.Adapters.Mock` replays answers per step, in
call order, so run the synthesizer one call at a time and give a single
evolution its whole weight:

```elixir
DeepEvalEx.LLM.Adapters.Mock.script(%{
  "data" => [%{"data" => [%{"input" => "How tall is the Eiffel Tower?"}]}],
  "feedback,score" => [%{"feedback" => "Clear.", "score" => 0.9}],
  "response" => [%{"response" => "Why is it 330 metres tall?"}, %{"response" => "330 metres."}]
})

synthesizer =
  DeepEvalEx.Synthesizer.new(
    adapter: :mock,
    max_concurrent: 1,
    evolution_config: [evolutions: [reasoning: 1]]
  )

{:ok, synthesizer} =
  DeepEvalEx.Synthesizer.generate_goldens_from_contexts(synthesizer, [["It is 330 metres tall."]],
    max_goldens_per_context: 1
  )
```

## Not ported

Generating from documents (chunking, embeddings and context construction),
conversational goldens, text-to-SQL goldens, `save_as` (use
`DeepEvalEx.Dataset.EvaluationDataset.save_as/4`), `to_pandas`, progress
bars and Confident AI uploads.
