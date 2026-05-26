# NullPantry

NullPantry is the headless, agent-native knowledge base for the Null ecosystem.

It stores sources, artifacts, memory atoms, entities, relations, context packs, and a NullClaw-compatible remote memory surface. UI belongs in NullHub/NullDesk; this repository exposes storage, retrieval, lifecycle, and API primitives.

## Quick Start

```sh
zig build test
zig build nullclaw-contract
zig build run -- --db .nullpantry/nullpantry.db
```

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.

Postgres mode requires a Postgres database with `pgvector` available and a `psql` binary in `PATH`:

```sh
NULLPANTRY_DATABASE_URL='postgres://user:pass@host:5432/nullpantry' NULLPANTRY_TOKEN=prod-secret NULLPANTRY_SCOPES='["admin"]' NULLPANTRY_CAPABILITIES='["read","write","propose","verify","delete","export","feed_apply"]' zig build run -- --backend postgres
```

Set `NULLPANTRY_PSQL_BIN=/path/to/psql` when `psql` is not on `PATH`.

`--actor-scopes` / `NULLPANTRY_SCOPES` defines the server-side scopes granted to the configured token. `--actor-capabilities` / `NULLPANTRY_CAPABILITIES` defines what that token can do: `read`, `propose`, `write`, `verify`, `delete`, `export`, and `feed_apply`. Read scopes and write scopes are separate: `["project:nullpantry"]` can read/propose in that project, while mutations require `["write:project:nullpantry"]`; verification/deletion can be narrowed with `verify:<scope>` and `delete:<scope>`. Local/dev without a token uses `["admin"]`; once `--token` or `NULLPANTRY_TOKEN` is set, the default is read-only `["public"]` until explicit scopes/capabilities are configured.

For NullClaw remote memory, `agent:nullclaw` grants access to the compatibility memory surface. Session/history endpoints additionally require `session:<id>` or `session:*` for reads and `write:session:<id>` or `write:session:*` for writes. A single trusted NullClaw service token can use `["agent:nullclaw","session:*","write:session:*"]`; multi-agent deployments should issue narrower per-agent/session scopes.

Reverse proxies can pass `X-NullPantry-Actor-Id`, `X-NullPantry-Actor-Scopes`, and `X-NullPantry-Actor-Capabilities`. Non-admin tokens can only narrow their configured scopes/capabilities; they cannot escalate through headers or request bodies.

Provider-backed embeddings and Ask generation are optional. Without these variables, NullPantry uses the local deterministic embedding fallback and extractive citation-backed answers:

```sh
export NULLPANTRY_EMBEDDING_BASE_URL="https://api.example.com/v1"
export NULLPANTRY_EMBEDDING_MODEL="text-embedding-model"
export NULLPANTRY_EMBEDDING_API_KEY="..."
export NULLPANTRY_EMBEDDING_DIMENSIONS=1536

export NULLPANTRY_LLM_BASE_URL="https://api.example.com/v1"
export NULLPANTRY_LLM_MODEL="chat-model"
export NULLPANTRY_LLM_API_KEY="..."
```

Provider endpoints and API keys are server-side configuration only; request bodies cannot override provider `base_url`, `api_key`, model, or timeout fields. If no embedding provider is configured, NullPantry uses deterministic local embeddings. If a provider is configured and fails, embedding operations fail closed instead of silently mixing fallback vectors into the index.

The built-in worker loop runs every 5 seconds by default. Set `NULLPANTRY_WORKER_INTERVAL_MS=0` to disable it, or call `POST /v1/workers/run` manually.

NullClaw can use the compatibility surface with:

```sh
export NULLPANTRY_TOKEN="dev-secret"
export NULLPANTRY_SCOPES='["agent:nullclaw"]'
export NULLPANTRY_CAPABILITIES='["read","write","delete"]'
```

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

Native API lives under `/v1`: spaces, policy scopes, sources, artifacts, memory atoms, entities, relations, search, ask, context packs, remember, forget, verify, and mark-stale.

NullClaw compatibility lives under `/v1/nullclaw` and supports remote API memory, session messages, usage, history, and health endpoints.

Native memory writes always end with provenance. If a caller omits `source_ids` or `evidence_ranges`, NullPantry creates an internal `Source` with the same scope/permissions and attaches an evidence range for the saved text. NullClaw compatibility writes do the same through `agent_observation` sources.

Additional agent-memory surfaces:

- `GET /v1/capabilities`, `GET /v1/connectors`, `GET /v1/artifact-types`, and `GET /v1/sdk/manifest` describe the headless service contract for agents and NullHub/NullDesk consumers.
- `GET|POST /v1/spaces` and `GET|POST /v1/policy-scopes` make Shelves/Spaces and scope policy first-class records instead of plain strings, with the same ACL filtering used by retrieval.
- `POST /v1/ingest` and `POST /v1/extract-memory` implement the first deterministic ingestion pipeline: create a source, derive an artifact, extract structured memory lines such as `Decision:`, `Constraint:`, `Action:`, `Question:`, and `Risk:`, resolve Null ecosystem entities, write citation-backed atoms, and enqueue vector chunks.
- Transcript extraction accepts timestamp/speaker-prefixed lines such as `[00:01:04] Alice: Decision: ...`, records evidence ranges, and chunks long source/artifact text into multiple permission-filtered vector chunks instead of indexing only one whole-document vector.
- `GET|POST /v1/jobs`, `POST /v1/jobs/:id/run`, and `POST /v1/workers/run` persist and execute extraction, hygiene, conflict scan, and vector-outbox jobs with scoped visibility.
- `GET /v1/conflicts` and `POST /v1/conflicts/scan` detect contradictory visible memory atoms, keeping inaccessible scopes out of conflict summaries.
- `GET /v1/engines` exposes the NullClaw memory engine registry: `sqlite`, `markdown`, `memory_lru`, `lucid`, `postgres`, `redis`, `clickhouse`, `lancedb`, and `kg`.
- `POST /v1/vector/embed`, `POST /v1/vector/upsert`, `POST /v1/vector/search`, `GET /v1/vector/outbox`, and `POST /v1/vector/outbox/run` provide the server-side vector layer with deterministic local embeddings, optional OpenAI-compatible embeddings, permission-filtered vector chunks, ANN-style prefiltering, final cosine rerank, local `indexed_local` outbox acknowledgements, and schema contracts for Qdrant/pgvector style adapters.
- `POST /v1/retrieval/plan` exposes retrieval planning primitives for keyword, vector, graph, query expansion, MMR/RRF, temporal decay, adaptive retrieval, and reranking.
- `/v1/search`, `/v1/ask`, `/v1/context-packs`, and `POST /v1/retrieval/search` use the same hybrid retrieval path: ACL first, scoped keyword/global candidates, deterministic query expansion, configured query embeddings, vector ANN search, RRF fusion, temporal quality rerank, embedding MMR for local-deterministic embeddings with token-diversity fallback for external embedding spaces, citation-safe result assembly, staleness warnings, optional visible conflict warnings, and grouped results for memory atoms, sources, artifacts, entities, relations, context packs, feed events, compat memories, and guarded session messages. Ask lists existing visible conflicts by default; callers with `write` or `verify` can pass `"scan_conflicts": true` to update conflict records during the request.
- `GET|POST /v1/memory/feed` and `POST /v1/memory/apply` provide cross-memory feed/apply events inspired by NullClaw PR #711, with scope checks before event visibility or apply. Apply validates memory payloads before reserving dedupe keys, reserves keys before writing memory, returns the original applied event on retry, and releases stale in-progress reservations after the retry window.
- `GET /v1/lifecycle/diagnostics`, `POST /v1/lifecycle/snapshot`, `POST /v1/lifecycle/hygiene`, `POST /v1/lifecycle/summarize`, and `POST /v1/lifecycle/rollout` expose lifecycle runtime operations.
- `POST /v1/lifecycle/cache/put`, `POST /v1/lifecycle/cache/get`, `POST /v1/lifecycle/semantic-cache/put`, and `POST /v1/lifecycle/semantic-cache/search` expose response and semantic cache operations backed by SQLite tables.
- `/v1/search` and `/v1/ask` participate in the lifecycle cache path. They read exact response-cache entries by default and, when called with `cache_ttl_ms` by a writer, persist cache entries. `/v1/ask` can also use semantic cache with `use_semantic_cache=true`. Response and semantic cache entries store the generating actor/scope set and are only returned to callers that can see every cached scope.

## Storage Status

SQLite is the working local/dev/test backend and includes relational tables, FTS5 indexes, first-class spaces/policy scopes, lifecycle status, audit events, first-class artifact type contracts, context packs, permission-filtered vector chunks, ANN-style local vector search, executable vector outbox, response/semantic caches, lifecycle snapshots/hygiene, idempotent cross-memory feed events, ingestion/extraction jobs, conflict records, and the NullClaw compatibility projection.

Postgres is implemented through a `psql`-backed runtime adapter. On startup it applies the Postgres DDL, then all storage operations execute SQL and consume JSON results through `psql`: primitives, search, vectors, lifecycle/cache, NullClaw compatibility, sessions/history, jobs, and conflicts. Multi-step NullClaw compatibility writes run as a single Postgres transaction. This avoids silently falling back to SQLite and keeps the deployment dependency explicit; a native Zig/libpq adapter with connection pooling is still the expected transport for high-concurrency production deployments and can replace this transport later without changing the `Store` contract.

## Build System

NullPantry uses `nullbuilder` for GitHub CI, nightly artifacts, and tagged releases through reusable workflows in `.github/workflows`. SQLite is vendored under `vendor/sqlite3` so nullbuilder can cross-compile release binaries without relying on host system libraries.
