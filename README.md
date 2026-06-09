# NullPantry

NullPantry is the headless knowledge and memory service for the Null ecosystem. It owns the canonical storage, permissions, retrieval, lifecycle, graph, vector, context-pack, and agent-memory APIs that NullHub, NullDesk, NullClaw, and other agents can use.

UI belongs outside this repository. NullPantry is the service boundary for governed knowledge.

## Quick Start

Requirements:

- Zig `0.16.0` or newer compatible `0.16.x`
- No system SQLite dependency; SQLite is vendored under `vendor/sqlite3`
- Optional runtime services only when the matching backend is enabled and configured

```sh
zig build
zig build test
zig build run -- --db .nullpantry/nullpantry.db
```

The server listens on `http://127.0.0.1:8765` by default. Use `--help` for the complete runtime flag list:

```sh
zig build run -- --help
```

Runtime settings can also live in a JSON config file:

```sh
zig build run -- --config .nullpantry/nullpantry.json
```

Use `--home` or `NULLPANTRY_HOME` when the default local files should live under one directory:

```sh
NULLPANTRY_HOME="$HOME/nullhub/nullpantry" zig build run
```

Environment variables override the config file, and CLI flags override both. See [Operations](docs/operations.md#runtime-home) for home layout and [Runtime Config File](docs/operations.md#runtime-config-file) for the structured config format and exact `NULLPANTRY_*` compatibility block.

## Common Commands

```sh
# Fast local feedback.
zig build test

# Full local API/storage/runtime suite.
zig build test-local --summary all

# One area while developing.
zig build test-api
zig build test-agent-memory
zig build test-vector

# Default local NullClaw-compatible profile.
zig build

# Compile every backend/runtime adapter.
zig build -Dengine-profile=full

# Production-style canonical store.
NULLPANTRY_DATABASE_URL='postgres://user:pass@host:5432/nullpantry' \
NULLPANTRY_TOKEN='prod-secret' \
NULLPANTRY_SCOPES='["admin"]' \
NULLPANTRY_CAPABILITIES='["read","write","propose","verify","delete","export","feed_apply"]' \
zig build run -- --backend postgres
```

## Documentation

Start with the task you are doing:

- [Operations](docs/operations.md): install, build, run, configure auth, choose backends, operate workers, and run backend contracts.
- [Testing](docs/testing.md): fast, directional, matrix, and external contract test commands.
- [NullClaw Memory Integration](docs/nullclaw-memory-integration.md): connect one or more NullClaw agents to NullPantry memory, sessions, feed/checkpoint/apply, named stores, and scoped sharing.
- [Product Architecture](docs/product-architecture.md): product boundary, primitives, retrieval contract, lifecycle, and Null ecosystem split.
- [Documentation Index](docs/README.md): map of the docs and rules for keeping them maintainable.

## Runtime Surface

NullPantry exposes route groups for:

- canonical knowledge: sources, artifacts, memory atoms, entities, relations, lifecycle, snapshots, diagnostics, and feed
- agent memory: `/v1/agent`, `/v1/memory`, `/v1/agent-memory`, `/v1/agent-sessions`
- retrieval: `/v1/search`, `/v1/ask`, `/v1/context-packs`, `/v1/vector/*`
- integrations: QMD ingest, Markdown import/export, prompt bootstrap, providers, OpenAPI manifest
- projections: external vector stores, graph projections, ClickHouse analytics, Lucid projection

Detailed setup lives in [docs/operations.md](docs/operations.md). The running service also publishes its API manifest at `/v1/openapi.json`.

## Backend Model

Build-time selection controls what code is compiled into the binary. Runtime configuration controls which compiled backend is active.

- `records`: canonical Source, Artifact, MemoryAtom, Entity, Relation, ACL, lifecycle, feed, and migration storage. Supported canonical stores are `sqlite` and `postgres`.
- `agent_memory`: exact actor/session/key agent memory and session state. Supported runtime families include `none`, `memory_lru`, `markdown`, `redis`, `clickhouse`, `api`, Supermemory, OpenViking, Honcho, Mem0, Hindsight, RetainDB, ByteRover, Holographic, Zep, and FalkorDB.
- `vectors`: rebuildable ANN/search indexes derived from canonical records. Supported runtime families include local SQLite vectors, `pgvector`, `qdrant`, `lancedb`, `lancedb_http`, Weaviate, Chroma, and OpenSearch.
- `graph_projection`: optional graph projections such as Neo4j or FalkorDB; canonical entities and relations still live in the record store.
- `analytics`: optional ClickHouse audit/feed export; it is history storage, not the canonical knowledge store.

The default profile is `nullclaw`: SQLite records, Markdown compatibility, hybrid descriptor, in-process memory, and no-op memory support. Use `minimal` for the smallest local profile and `full` for all adapters.

```sh
zig build -Dengine-profile=minimal
zig build -Dengine-profile=full
zig build -Dengine-profile=custom -Drecords=postgres -Dagent-memory=redis -Dvectors=qdrant
```

## Security Defaults

- Binding without auth is only accepted on loopback unless `NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK` or `--allow-no-auth-non-loopback` is set intentionally.
- Use `NULLPANTRY_TOKEN_PRINCIPALS` for multi-agent or multi-user deployments. Token principals bind `actor_id`, scopes, and capabilities to each bearer token.
- Request actor headers can narrow delegated requests. They cannot escalate token principal scopes or spoof token-bound actors.
- `--trust-actor-headers` is for a trusted upstream auth gateway, not for direct internet exposure.
- Provider, vector, analytics, graph, and agent-memory HTTP URLs must use HTTPS unless they are local loopback or explicitly allow insecure HTTP.
- Prefer environment variables or protected config files for secrets; avoid passing tokens and database URLs as CLI flags in production.
- External CLI integrations run with a sanitized child environment and do not inherit `NULLPANTRY_*` secrets.

## Project Boundary

NullClaw stays small: local execution and baseline local memory. NullPantry owns shared state, central policy, indexing, lifecycle, vector/graph projections, analytics, cross-agent sync, and production storage.

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.
