# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for DeepEvalEx.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences. ADRs help teams understand why certain decisions were made and provide historical context for future maintainers.

## ADR Index

| ID | Title | Status | Date |
|----|-------|--------|------|
| [ADR-0001](0001-behaviour-based-plugin-architecture.md) | Behaviour-Based Plugin Architecture | Accepted | 2024-12-25 |
| [ADR-0002](0002-ecto-schemas-without-database.md) | Ecto Embedded Schemas Without Database | Accepted | 2024-12-25 |
| [ADR-0003](0003-telemetry-first-observability.md) | Telemetry-First Observability | Accepted | 2024-12-25 |
| [ADR-0004](0004-concurrent-evaluation-with-task-async-stream.md) | Concurrent Evaluation with Task.async_stream | Accepted | 2024-12-25 |
| [ADR-0005](0005-multi-step-prompting-for-rag-metrics.md) | Multi-Step Prompting for RAG Metrics | Accepted | 2024-12-25 |
| [ADR-0006](0006-json-schema-for-structured-outputs.md) | JSON Schema Mode for Structured LLM Outputs | Accepted | 2024-12-25 |
| [ADR-0007](0007-basemetric-macro-for-instrumentation.md) | BaseMetric Macro for Automatic Instrumentation | Accepted | 2024-12-25 |

## ADR Template

New ADRs should follow the template in [template.md](template.md).

## Statuses

- **Proposed** - Under discussion
- **Accepted** - Approved and implemented
- **Deprecated** - No longer valid, superseded by another ADR
- **Superseded** - Replaced by a newer ADR (link to replacement)

## Contributing

When making significant architectural decisions:

1. Copy `template.md` to a new file with the next sequential number
2. Fill in all sections
3. Submit for review
4. Update the index once accepted
