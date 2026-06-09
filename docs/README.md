# NullPantry Documentation

NullPantry is the headless, agent-native knowledge base for the Null ecosystem:

```text
NullPantry = Confluence-like knowledge base + long-term memory + RAG + knowledge graph + context serving API
```

This directory keeps task-oriented documentation separate from the root README. The README is the entry point; operational setup, integration details, architecture, and tests live here.

## Documents

- [Operations](operations.md) covers installation prerequisites, build profiles, local and Postgres runs, auth, backend selection, providers, workers, diagnostics, and external backend contracts.
- [Testing](testing.md) documents fast, local, directional, matrix, and external contract test commands.
- [NullClaw Memory Integration](nullclaw-memory-integration.md) explains how to connect NullClaw to NullPantry for one agent, many agents, shared family/team memory, named stores, runtime backends, sessions, feed/checkpoint sync, and RAG/context serving.
- [Product Architecture](product-architecture.md) defines the product boundary, core primitives, lifecycle, retrieval contract, and Null ecosystem split.

## Documentation Rules

Use this structure for future docs:

- Keep the root README short: purpose, quick start, common commands, and links.
- Keep product concepts in architecture documents.
- Keep operational setup in `operations.md`.
- Keep endpoint lists close to the workflow they enable.
- Prefer examples that show permissions, scopes, actors, and storage selectors together.
- State backend limits explicitly. Do not imply that a projection backend is a canonical knowledge store.
- Prefer stable command examples over restating every CLI/environment option. Link to `--help` when a generated list is more accurate than hand-written prose.
- Link to the implementation or tests when a document describes a behavior that must stay contractually stable.
