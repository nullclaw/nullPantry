# NullPantry

NullPantry is the headless, agent-native knowledge base for the Null ecosystem.

It stores sources, artifacts, memory atoms, entities, relations, context packs, and a NullClaw-compatible remote memory surface. UI belongs in NullHub/NullDesk; this repository exposes storage, retrieval, lifecycle, and API primitives.

## Quick Start

```sh
zig build test
zig build run -- --db .nullpantry/nullpantry.db --token dev-secret
```

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.

Postgres mode requires a Postgres database with `pgvector` available and a `psql` binary in `PATH`:

```sh
NULLPANTRY_DATABASE_URL='postgres://user:pass@host:5432/nullpantry' zig build run -- --backend postgres --token prod-secret
```

Set `NULLPANTRY_PSQL_BIN=/path/to/psql` when `psql` is not on `PATH`.

`--actor-scopes` / `NULLPANTRY_SCOPES` defines the server-side scopes granted to the configured token. `--actor-capabilities` / `NULLPANTRY_CAPABILITIES` defines what that token can do: `read`, `propose`, `write`, `verify`, `delete`, `export`, and `feed_apply`. The default local/dev scope is `["admin"]`; shared deployments should set explicit scopes and capabilities such as `["workspace","agent:nullclaw","project:nullpantry"]` plus `["read","propose"]`.

Reverse proxies can pass `X-NullPantry-Actor-Id`, `X-NullPantry-Actor-Scopes`, and `X-NullPantry-Actor-Capabilities`. Non-admin tokens can only narrow their configured scopes/capabilities; they cannot escalate through headers or request bodies.

NullClaw can use the compatibility surface with:

```json
{
  "memory": {
    "backend": "api",
    "api": {
      "url": "http://127.0.0.1:8765",
      "namespace": "/v1/nullclaw",
      "api_key": "dev-secret"
    }
  }
}
```

## API Surface

Native API lives under `/v1`: sources, artifacts, memory atoms, entities, relations, search, ask, context packs, remember, forget, verify, and mark-stale.

NullClaw compatibility lives under `/v1/nullclaw` and supports remote API memory, session messages, usage, history, and health endpoints.

Additional agent-memory surfaces:

- `GET /v1/capabilities`, `GET /v1/connectors`, and `GET /v1/sdk/manifest` describe the headless service contract for agents and NullHub/NullDesk consumers.
- `POST /v1/ingest` and `POST /v1/extract-memory` implement the first deterministic ingestion pipeline: create a source, derive an artifact, extract structured memory lines such as `Decision:`, `Constraint:`, `Action:`, `Question:`, and `Risk:`, resolve Null ecosystem entities, write citation-backed atoms, and enqueue vector chunks.
- `GET|POST /v1/jobs` and `POST /v1/jobs/:id/run` persist ingestion/extraction job state with scoped visibility.
- `GET /v1/conflicts` and `POST /v1/conflicts/scan` detect contradictory visible memory atoms, keeping inaccessible scopes out of conflict summaries.
- `GET /v1/engines` exposes the NullClaw memory engine registry: `sqlite`, `markdown`, `memory_lru`, `lucid`, `postgres`, `redis`, `clickhouse`, `lancedb`, and `kg`.
- `POST /v1/vector/embed`, `POST /v1/vector/upsert`, `POST /v1/vector/search`, and `GET /v1/vector/outbox` provide the server-side vector layer with a deterministic local embedding fallback, permission-filtered SQLite vector chunks, ANN-style prefiltering, final cosine rerank, and schema contracts for Qdrant/pgvector style adapters.
- `POST /v1/retrieval/plan` exposes retrieval planning primitives for keyword, vector, graph, query expansion, MMR/RRF, temporal decay, adaptive retrieval, and reranking.
- `/v1/search`, `/v1/ask`, `/v1/context-packs`, and `POST /v1/retrieval/search` use the same hybrid retrieval path: ACL first, scoped keyword/global candidates, deterministic query expansion, vector ANN search, RRF fusion, citation-safe result assembly, and grouped results for memory atoms, sources, artifacts, entities, relations, context packs, feed events, compat memories, and guarded session messages.
- `GET|POST /v1/memory/feed` and `POST /v1/memory/apply` provide cross-memory feed/apply events inspired by NullClaw PR #711, with scope checks before event visibility or apply.
- `GET /v1/lifecycle/diagnostics`, `POST /v1/lifecycle/snapshot`, `POST /v1/lifecycle/hygiene`, `POST /v1/lifecycle/summarize`, and `POST /v1/lifecycle/rollout` expose lifecycle runtime operations.
- `POST /v1/lifecycle/cache/put`, `POST /v1/lifecycle/cache/get`, `POST /v1/lifecycle/semantic-cache/put`, and `POST /v1/lifecycle/semantic-cache/search` expose response and semantic cache operations backed by SQLite tables.

## Storage Status

SQLite is the working local/dev/test backend and includes relational tables, FTS5 indexes, lifecycle status, audit events, context packs, permission-filtered vector chunks, ANN-style local vector search, vector outbox, response/semantic caches, lifecycle snapshots/hygiene, idempotent cross-memory feed events, ingestion/extraction jobs, conflict records, and the NullClaw compatibility projection.

Postgres is implemented through a `psql`-backed runtime adapter. On startup it applies the Postgres DDL, then all storage operations execute SQL and consume JSON results through `psql`: primitives, search, vectors, lifecycle/cache, NullClaw compatibility, sessions/history, jobs, and conflicts. This avoids silently falling back to SQLite and keeps the deployment dependency explicit; a native Zig/libpq adapter can replace this transport later without changing the `Store` contract.

## Build System

NullPantry uses `nullbuilder` for GitHub CI, nightly artifacts, and tagged releases through reusable workflows in `.github/workflows`. SQLite is vendored under `vendor/sqlite3` so nullbuilder can cross-compile release binaries without relying on host system libraries.
