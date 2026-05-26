# NullPantry

NullPantry is the headless, agent-native knowledge base for the Null ecosystem.

It stores sources, artifacts, memory atoms, entities, relations, context packs, and a NullClaw-compatible remote memory surface. UI belongs in NullHub/NullDesk; this repository exposes storage, retrieval, lifecycle, and API primitives.

## Quick Start

```sh
zig build test
zig build run -- --db .nullpantry/nullpantry.db --token dev-secret
```

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.

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

- `GET /v1/engines` exposes the NullClaw memory engine registry: `sqlite`, `markdown`, `memory_lru`, `lucid`, `postgres`, `redis`, `clickhouse`, `lancedb`, and `kg`.
- `POST /v1/vector/embed`, `POST /v1/vector/upsert`, `POST /v1/vector/search`, and `GET /v1/vector/outbox` provide the server-side vector layer with a deterministic local embedding fallback, permission-filtered brute-force local search today, and schema contracts for Qdrant/pgvector style adapters.
- `POST /v1/retrieval/plan` exposes retrieval planning primitives for keyword, vector, graph, query expansion, MMR/RRF, temporal decay, adaptive retrieval, and reranking.
- `GET|POST /v1/memory/feed` and `POST /v1/memory/apply` provide cross-memory feed/apply events inspired by NullClaw PR #711, with scope checks before event visibility or apply.
- `GET /v1/lifecycle/diagnostics` and `POST /v1/lifecycle/snapshot` expose lifecycle diagnostics and snapshot hooks.

## Storage Status

SQLite is the working local/dev/test backend and includes relational tables, FTS5 indexes, lifecycle status, audit events, context packs, permission-filtered vector chunks, vector outbox, lifecycle snapshots, idempotent cross-memory feed events, and the NullClaw compatibility projection.

Postgres DDL is included as the production schema contract with relational tables, full-text `tsvector` indexes, vector outbox/feed tables, lifecycle tables, and `pgvector` storage. The runtime Postgres adapter is gated and returns `PostgresAdapterIncomplete` until the repo adds a native Postgres client or a deliberate `libpq` deployment contract. Until then, runnable deployments should use SQLite-backed service mode.

## Build System

NullPantry uses `nullbuilder` for GitHub CI, nightly artifacts, and tagged releases through reusable workflows in `.github/workflows`. SQLite is vendored under `vendor/sqlite3` so nullbuilder can cross-compile release binaries without relying on host system libraries.
