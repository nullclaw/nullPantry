# NullPantry

NullPantry is the headless, agent-native knowledge base for the Null ecosystem.

It stores sources, artifacts, memory atoms, entities, relations, context packs, and isolated native agent memory. UI belongs in NullHub/NullDesk; this repository exposes storage, retrieval, lifecycle, and API primitives.

The product architecture is documented in [docs/product-architecture.md](docs/product-architecture.md): NullPantry is a Confluence-like knowledge base, long-term memory, RAG system, knowledge graph, and context serving API for people and agents.

## Product Boundary

NullClaw should stay small: `none`, in-process `memory`, local `sqlite`, and `markdown` are enough for standalone/runtime-local usage. Anything that implies shared state, central policy, indexing, lifecycle, graph traversal, vector databases, analytics, cross-agent sync, or production storage belongs in NullPantry.

That makes the split explicit:

- NullClaw owns local execution and minimal local memory.
- NullPantry owns central memory, permissions, source-backed knowledge, retrieval, context packs, sync/feed, vector/graph/lifecycle services, Redis-backed shared agent memory, and Postgres production storage.

The intended migration path is therefore not to keep cloning every advanced memory engine into NullClaw. NullClaw should call NullPantry when it needs more than local baseline storage.

## Quick Start

```sh
zig build test
zig build run -- --db .nullpantry/nullpantry.db
```

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.

To run NullPantry as the shared agent-memory service for several NullClaw agents while keeping the knowledge base itself on SQLite/Postgres, move the agent-memory/session plane to Redis or another NullPantry-compatible API. For local parity and tests, the same runtime plane also accepts `NULLPANTRY_AGENT_MEMORY_BACKEND=memory`, `memory_lru`, or `none`:

```sh
NULLPANTRY_AGENT_MEMORY_BACKEND=redis \
NULLPANTRY_REDIS_URL='redis://:password@redis.internal:6379/0' \
zig build run -- --backend postgres --postgres-url "$NULLPANTRY_DATABASE_URL"
```

With token principals, each agent keeps private memory under its own `actor_id`; explicit scopes such as `team:alpha` or `project:nullpantry` create shared logical memory owners.

One NullClaw can also address several named runtime stores through the same NullPantry service. Configure them with repeated CLI flags or a JSON env var, then pass `store:"scratch"`, `store:"team"`, or `store:"archive"` per request:

```sh
NULLPANTRY_AGENT_MEMORY_BACKEND=redis \
NULLPANTRY_REDIS_URL='redis://redis.internal:6379/0' \
NULLPANTRY_AGENT_MEMORY_STORES='[
  {"name":"scratch","backend":"memory_lru"},
  {"name":"team","redis_url":"redis://redis.internal:6379/1","key_prefix":"team-memory"}
]' \
zig build run -- --backend postgres --postgres-url "$NULLPANTRY_DATABASE_URL"
```

To move ANN vector indexing/search out of the canonical SQLite/Postgres record store, configure an external vector backend. NullPantry still hydrates and ACL-filters every external ANN candidate against its canonical Source/Artifact/MemoryAtom rows before returning text or citations:

```sh
NULLPANTRY_VECTOR_BACKEND=qdrant \
NULLPANTRY_VECTOR_BASE_URL='http://qdrant.internal:6333' \
NULLPANTRY_VECTOR_COLLECTION='nullpantry_vectors' \
zig build run -- --backend postgres --postgres-url "$NULLPANTRY_DATABASE_URL"
```

The same vector runtime boundary supports a real LanceDB SDK process adapter. Use `NULLPANTRY_VECTOR_BACKEND=lancedb` with `NULLPANTRY_LANCEDB_URI` and, when needed, `NULLPANTRY_LANCEDB_COMMAND=python3` or a custom adapter executable. `NULLPANTRY_LANCEDB_TABLE` or `NULLPANTRY_VECTOR_COLLECTION` selects the table. The old HTTP adapter shape is explicit as `NULLPANTRY_VECTOR_BACKEND=lancedb_http` or `NULLPANTRY_LANCEDB_URL`.

For high-volume audit/feed history, configure ClickHouse as the analytics export plane:

```sh
NULLPANTRY_ANALYTICS_BACKEND=clickhouse \
NULLPANTRY_ANALYTICS_BASE_URL='http://clickhouse.internal:8123' \
NULLPANTRY_ANALYTICS_TABLE='nullpantry_events' \
zig build run -- --backend postgres --postgres-url "$NULLPANTRY_DATABASE_URL"
```

To use Lucid as an optional semantic projection, keep SQLite/Postgres as the canonical NullPantry record store and enable the Lucid CLI projection plane:

```sh
NULLPANTRY_LUCID_ENABLED=true \
NULLPANTRY_LUCID_WORKSPACE='/srv/null-workspace' \
NULLPANTRY_LUCID_PROJECT_SCOPES='["public"]' \
zig build run -- --backend postgres --postgres-url "$NULLPANTRY_DATABASE_URL"
```

Lucid projection is asynchronous and durable: eligible Sources, Artifacts, Entities, Relations, MemoryAtoms, AgentMemory rows, and persisted ContextPacks enqueue `lucid_projection` jobs when their scope/permissions are allowed by `NULLPANTRY_LUCID_PROJECT_SCOPES`. Lifecycle changes enqueue matching `put` or `delete` projection jobs, worker failures are visible in diagnostics, `GET /v1/lifecycle/lucid/status` reports projection health, and `POST /v1/lifecycle/lucid/rebuild` can replay visible canonical results into Lucid. Lucid recall is still returned only through NullPantry's configured result scope and permissions.

Postgres mode requires a Postgres database with `pgvector` available and `libpq` available at runtime:

```sh
NULLPANTRY_DATABASE_URL='postgres://user:pass@host:5432/nullpantry' NULLPANTRY_TOKEN=prod-secret NULLPANTRY_SCOPES='["admin"]' NULLPANTRY_CAPABILITIES='["read","write","propose","verify","delete","export","feed_apply"]' zig build run -- --backend postgres
```

The Postgres transport is native `libpq`, loaded dynamically so nullbuilder release builds do not need a link-time libpq dependency. Set `NULLPANTRY_LIBPQ_PATH=/path/to/libpq` when the runtime library is not in a standard loader path, and `NULLPANTRY_POSTGRES_POOL_SIZE=16` to tune the idle libpq connection pool. Subprocess database execution is intentionally not a runtime adapter.

Run the required production storage contract against a real Postgres/pgvector database with:

```sh
NULLPANTRY_TEST_POSTGRES_URL='postgres://user:pass@host:5432/nullpantry_test' zig build postgres-contract --summary all
```

Run the Redis agent-memory/session contract against a real Redis with:

```sh
NULLPANTRY_TEST_REDIS_URL='redis://:password@localhost:6379/0' zig build redis-contract --summary all
```

Run external runtime contracts against real services with:

```sh
NULLPANTRY_TEST_QDRANT_URL='http://localhost:6333' zig build qdrant-contract --summary all
NULLPANTRY_TEST_CLICKHOUSE_URL='http://localhost:8123' zig build clickhouse-contract --summary all
NULLPANTRY_TEST_LANCEDB_URI='.nullpantry/lancedb-contract' zig build lancedb-contract --summary all
NULLPANTRY_TEST_LANCEDB_URL='https://your-compatible-vector-service' zig build lancedb-contract --summary all
zig build lucid-contract --summary all
```

`zig build runtime-contracts --summary all` is the aggregate gate for the concrete runtime planes: Postgres, Redis, Qdrant, LanceDB, ClickHouse, and Lucid. It expects the corresponding `NULLPANTRY_TEST_*` URLs/URIs to be configured, except Lucid, which uses a fake CLI contract.

`lancedb-contract` prefers the SDK adapter when `NULLPANTRY_TEST_LANCEDB_URI` is set. The default command is `python3` and expects the official `lancedb` Python package to be installed; `NULLPANTRY_TEST_LANCEDB_COMMAND` can point at a custom executable that implements `upsert <uri> <table>`, `search <uri> <table> <limit>`, `delete <uri> <table>`, and `reset <uri> <table>`, reading row/search/delete JSON from stdin where applicable. `NULLPANTRY_TEST_LANCEDB_URL` remains available only for explicit `lancedb_http` adapter-service deployments. NullPantry keeps canonical text/provenance/ACL in SQLite/Postgres in both modes.

Startup migrations target the current native NullPantry schema. Because this product is not in production yet and backward compatibility is intentionally not supported, obsolete compatibility tables, old `compat.memory` projections, and actorless legacy session rows are removed instead of being preserved under synthetic actors.

`--actor-scopes` / `NULLPANTRY_SCOPES` defines the server-side scopes granted to the configured token. `--actor-capabilities` / `NULLPANTRY_CAPABILITIES` defines what that token can do: `read`, `propose`, `write`, `verify`, `delete`, `export`, and `feed_apply`. Read scopes and write scopes are separate: `["project:nullpantry"]` can read/propose in that project, while mutations require `["write:project:nullpantry"]`; verification/deletion can be narrowed with `verify:<scope>` and `delete:<scope>`. Local/dev without a token uses `["admin"]`; once `--token` or `NULLPANTRY_TOKEN` is set, the default is read-only `["public"]` until explicit scopes/capabilities are configured.

For multi-agent or multi-user deployments, prefer `NULLPANTRY_TOKEN_PRINCIPALS` or `--token-principals` over a single shared token. The value is a JSON object keyed by bearer token:

```sh
export NULLPANTRY_TOKEN_PRINCIPALS='{
  "agent-a-token": {
    "actor_id": "agent:a",
    "scopes": ["session:*", "write:session:*", "project:nullpantry", "write:project:nullpantry"],
    "capabilities": ["read", "write", "propose", "delete"]
  },
  "nullhub-reader": {
    "actor_id": "user:nullhub-reader",
    "scopes": ["public", "project:nullpantry"],
    "capabilities": ["read", "export"]
  }
}'
```

When a token principal matches, its `actor_id`, `scopes`, and `capabilities` are authoritative. Request headers can narrow scopes/capabilities for delegated requests, but cannot escalate them or spoof the token-bound actor id.

Native agent memory lives under `/v1/agent-memory`, and session/history state lives under `/v1/agent-sessions`. Multi-agent deployments should issue one bearer token principal per agent with a stable unique `actor_id`; keyed global memories with the same key can coexist for different agents, and session state additionally requires `session:<id>` or `session:*` for reads plus `write:session:<id>` or `write:session:*` for writes. Agent-created scoped knowledge is stored as `proposed` unless a separate verification flow promotes it.

Reverse proxies can pass `X-NullPantry-Actor-Id`, `X-NullPantry-Actor-Scopes`, and `X-NullPantry-Actor-Capabilities`. Non-admin tokens can only narrow their configured scopes/capabilities; they cannot escalate through headers or request bodies. `X-NullPantry-Actor-Id` is ignored when a bearer token maps to a token principal, so one agent cannot spoof another agent through request headers. To trust actor ids from an upstream auth gateway without token principals, start with `--trust-actor-headers` or `NULLPANTRY_TRUST_ACTOR_HEADERS=1`, and only expose that mode behind a trusted internal proxy.

Provider-backed embeddings, Ask generation, and LLM reranking are optional. Without these variables, NullPantry uses the local deterministic embedding fallback and extractive citation-backed answers:

```sh
export NULLPANTRY_EMBEDDING_BASE_URL="https://api.example.com/v1"
export NULLPANTRY_EMBEDDING_MODEL="text-embedding-model"
export NULLPANTRY_EMBEDDING_API_KEY="..."
export NULLPANTRY_EMBEDDING_DIMENSIONS=1536

export NULLPANTRY_LLM_BASE_URL="https://api.example.com/v1"
export NULLPANTRY_LLM_MODEL="chat-model"
export NULLPANTRY_LLM_API_KEY="..."
```

Provider endpoints and API keys are server-side configuration only; request bodies cannot override provider `base_url`, `api_key`, model, or timeout fields. If no embedding provider is configured, NullPantry uses deterministic local embeddings. Explicit embedding/indexing operations fail closed when the configured provider fails. Retrieval endpoints degrade to permission-filtered keyword/global/entity search by default so `/v1/search`, `/v1/ask`, and `/v1/context-packs` remain usable during provider outages; pass `"strict_vector": true` to fail the request instead. `/v1/ask` remains extractive by default even when an LLM provider is configured; callers must pass `"use_llm": true` to send retrieved evidence to the provider. `GET /v1/providers` exposes the concrete and compatible provider contracts for agents and deployment tooling.

The built-in worker loop runs every 5 seconds by default with its own service principal. By default the worker uses `["admin"]` so token-principal deployments do not strand queued project/team jobs behind a read-only request token. Narrow it with `NULLPANTRY_WORKER_SCOPES` and `NULLPANTRY_WORKER_CAPABILITIES`, set `NULLPANTRY_WORKER_INTERVAL_MS=0` to disable it, or call `POST /v1/workers/run` manually with the caller's request principal.

An agent can use native memory with:

```sh
export NULLPANTRY_TOKEN="dev-secret"
export NULLPANTRY_SCOPES='["session:*","write:session:*","project:nullpantry","write:project:nullpantry"]'
export NULLPANTRY_CAPABILITIES='["read","write","propose","delete"]'
```

```json
{
  "put": "PUT http://127.0.0.1:8765/v1/agent-memory/preference.key",
  "body": {
    "content": "Use concise Zig examples.",
    "session_id": "optional-session-id",
    "scope": "project:nullpantry"
  }
}
```

## API Surface

Native API lives under `/v1`: agent-memory, spaces, policy scopes, sources, artifacts, memory atoms, entities, relations, graph, search, ask, context packs, remember, forget, verify, and mark-stale.

`GET|POST /v1/agent-memory`, `PUT|GET|DELETE /v1/agent-memory/:key`, `POST /v1/agent-memory/search`, and `GET /v1/agent-memory/count` are the native key/session memory surface for agents. Omitted `scope` creates actor-private memory; `session_id` without `scope` creates actor-private session memory; explicit `scope` such as `team:alpha`, `project:nullpantry`, `org:null`, or `public` creates shared scoped memory under logical owner `shared:<scope>`. Reads, list/search/count, global search, ask, and context packs use ACL visibility instead of raw owner matching, so multiple NullClaw agents can share one database while still keeping private keys isolated. `GET` without `scope` prefers the caller's private row when a private and shared row use the same key; list/search dedupe the visible map the same way. Pass `?scope=...` for exact shared reads/deletes. Responses include `owner_id` for the logical memory owner and `created_by_actor_id` for the last real writer, so shared team memory remains auditable. All agent memory is backed by `Source` + `MemoryAtom` provenance so it participates in search, ask, context packs, lifecycle, and audit.

Agent-memory calls can choose the storage plane per request. Body fields `storage`, `store`, `target_store`, or exact array `stores`, and query params `?storage=...`, `?store=...`, `?target_store=...`, or comma-separated `?stores=scratch,archive`, accept `primary`, `native`, `redis`/`runtime`, any configured named store id, and `all`/`federated`. `primary` preserves the configured default plane: Redis or memory_lru runtime when `NULLPANTRY_AGENT_MEMORY_BACKEND` is configured, otherwise canonical SQLite/Postgres. `native` forces canonical SQLite/Postgres, `redis`/`runtime` forces the default runtime plane and returns `storage_unavailable` if it is not configured, a named store routes only to that runtime store, `stores:["scratch","archive"]` writes/reads only those selected stores, and `all` writes/deletes/federates canonical native, default runtime, and every named runtime with runtime results preferred over native duplicates. Cross-plane writes are intentionally not a distributed transaction; canonical storage remains the system of record for provenance, ACL, lifecycle, and retrieval.

The same selectors can be used when creating Sources, Artifacts, Entities, Relations, Memory Atoms, and persisted Context Packs. Those objects are always written to the canonical SQLite/Postgres record store first; the selector controls which runtime/named stores receive searchable mirrors. `storage:"native"` disables runtime mirroring, `store:"scratch"` mirrors only to that named store, `stores:["scratch","archive"]` mirrors to the selected stores, and `storage:"all"` mirrors to every configured runtime store. Missing explicit stores fail with `storage_unavailable` instead of falling back.

The same storage selectors are accepted by `/v1/search`, `/v1/ask`, `/v1/retrieval/search`, `/v1/context-packs`, and snapshot export. On retrieval endpoints, `primary` and `all` search canonical knowledge plus visible runtime stores, `native` searches only canonical SQLite/Postgres knowledge, `runtime` searches only the default runtime plane, a named store searches only that runtime store, and a `stores` subset searches exactly the selected planes. This lets one NullClaw process ask for private scratch memory, shared team memory, archive memory, or canonical NullPantry knowledge without changing service instances or credentials.

`GET /v1/agent-sessions`, `GET /v1/agent-sessions/:id`, `GET|POST|DELETE /v1/agent-sessions/:id/messages`, `GET|PUT|DELETE /v1/agent-sessions/:id/usage`, and `DELETE /v1/agent-sessions/auto-saved?session_id=:id` are the native session/history API. Multiple agents may reuse the same `session_id`; results are always filtered by token-bound `actor_id` before session scope checks.

Native memory writes always end with provenance. If a caller omits `source_ids` or `evidence_ranges`, NullPantry creates an internal `Source` with the same scope/permissions and attaches an evidence range for the saved text.

Additional agent-memory surfaces:

- `GET /v1/capabilities`, `GET /v1/openapi.json`, `GET /v1/providers`, `GET /v1/connectors`, `GET /v1/artifact-types`, and `GET /v1/sdk/manifest` describe the headless service contract for agents and NullHub/NullDesk consumers.
- `GET|POST /v1/spaces` and `GET|POST /v1/policy-scopes` make Shelves/Spaces and scope policy first-class records instead of plain strings, with the same ACL filtering used by retrieval.
- `POST /v1/ingest` and `POST /v1/extract-memory` are durable-first: they create a source plus queued job by default, and workers derive artifacts, extract structured memory lines such as `Decision:`, `Constraint:`, `Action:`, `Question:`, `Risk:`, ticket fields, PR/commit links, dependencies, incident symptoms, root causes, and mitigations, resolve Null ecosystem entities, and apply the extracted artifact/entities/atoms as one storage operation before indexing rebuildable vector chunks. Pass `run_now:true` only for tests or controlled one-shot imports.
- `POST /v1/connectors/:name/ingest` and `GET|POST /v1/connectors/:name/cursor` provide built-in push connector contracts for NullTickets, NullWatch, tickets, incidents, transcripts, git/PR imports, and manual sources. Connector cursors are permission-filtered first-class records, so sync state cannot leak across projects/teams, and connector ingests advance `next_cursor` only after every submitted item has imported successfully.
- `POST /v1/markdown/import`, `POST /v1/markdown/import-directory`, `POST /v1/markdown/export`, and `POST /v1/markdown/export-directory` provide the Markdown filesystem plane. Directory import recursively reads `.md` and `.markdown` files, parses NullPantry frontmatter, computes checksums, records source path metadata, creates Source + Artifact pairs, skips unchanged files by `raw_content_uri + scope + checksum` by default, and can queue or run extraction per file. Directory export writes permission-checked artifacts/sources to deterministic id-suffixed Markdown files and refuses to overwrite unless `overwrite:true` is set.
- Transcript extraction accepts timestamp/speaker-prefixed lines such as `[00:01:04] Alice: Decision: ...`, records evidence ranges, and chunks long source/artifact text into multiple permission-filtered vector chunks instead of indexing only one whole-document vector.
- `GET|POST /v1/jobs`, `POST /v1/jobs/:id/run`, and `POST /v1/workers/run` persist and execute extraction, hygiene, conflict scan, and vector-outbox jobs with scoped visibility.
- `GET /v1/conflicts` and `POST /v1/conflicts/scan` detect contradictory visible memory atoms, keeping inaccessible scopes out of conflict summaries.
- `GET /v1/graph/schema`, `POST /v1/graph/query`, `POST /v1/graph/neighbors`, and `POST /v1/graph/path` expose the native knowledge graph. Relation types are canonicalized through a built-in ontology (`depends_on`, `implements`, `produced`, `supersedes`, `documents`, `affected`, `fixes`, `belongs_to`, `owns`, `used_context_pack`, plus `related_to`), traversal supports `direction`, `relation_types`, `entity_types`, `min_confidence`, `depth`, and `include_deprecated`, and every hop re-checks relation ACL, endpoint entity ACL, source citation visibility, and lifecycle status. `PATCH|DELETE /v1/entities/:id` and `PATCH|DELETE /v1/relations/:id` provide lifecycle mutations for graph primitives instead of physical deletion.
- `GET /v1/engines` exposes runtime planes instead of a flat compatibility list: record storage, agent memory/session storage, vector, graph, projection, analytics/audit export, import/export, lifecycle, and feed. `sqlite` and `postgres` remain full system-of-record backends; `none`, `memory_lru`, and `redis` are runtime backends for disabled, in-process, and shared/isolated agent memory, session messages, and usage state; `kg` is native graph retrieval; `qdrant` and `lancedb` are runtime vector planes; `clickhouse` is the runtime analytics/event-history export plane; `lucid` is an optional durable CLI projection plane for semantic context.
- `GET /v1/vector/status`, `POST /v1/vector/embed`, `POST /v1/vector/upsert`, `POST /v1/vector/search`, `POST /v1/vector/delete`, `POST /v1/vector/rebuild`, `POST /v1/vector/reconcile`, `GET /v1/vector/outbox`, and `POST /v1/vector/outbox/run` provide the server-side vector layer with deterministic local embeddings, optional OpenAI-compatible embeddings, permission-filtered vector chunks, ANN-style prefiltering, final cosine rerank, local `indexed_local` outbox acknowledgements, dynamic pgvector dimensions in Postgres, Qdrant HTTP upsert/search/delete/reset, LanceDB SDK upsert/search/delete/reset, and an explicit LanceDB HTTP adapter-service contract. External vector search returns candidate vector IDs only; NullPantry hydrates those IDs from its canonical store and re-applies ACL/status checks before returning text. Delete emits external tombstones, reconcile replays canonical chunks into the configured vector plane, and rebuild can reset the external collection/table before replaying canonical truth. Direct `/v1/vector/search` accepts `strict_external`/`strict_vector` to fail closed when the configured external vector plane is unavailable; retrieval endpoints keep the existing graceful fallback unless strict vector retrieval is requested.
- `POST /v1/retrieval/plan` exposes retrieval planning primitives for keyword, vector, graph, query expansion, MMR/RRF, temporal decay, adaptive retrieval, and reranking.
- `/v1/search`, `/v1/ask`, `/v1/context-packs`, and `POST /v1/retrieval/search` use the same hybrid retrieval path: ACL first, scoped keyword/global candidates, deterministic query expansion, configured query embeddings, vector ANN search, optional Lucid projection augmentation when local hits are sparse, RRF fusion, temporal quality rerank, embedding MMR for local-deterministic embeddings with token-diversity fallback for external embedding spaces, optional provider-backed LLM rerank when `allow_reranker=true`, citation-safe result assembly, staleness warnings, optional visible conflict warnings, and grouped results for memory atoms, sources, artifacts, entities, relations, context packs, feed events, native agent memories, Lucid projections, and guarded session messages. Context packs return both the generated text summary and typed sections/citations/forbidden assumptions/suggested next steps for agent context serving. Read-only callers receive non-persisted context pack previews; durable context packs require `write` or `propose` and can be requested with `"persist": true`. Ask lists existing visible conflicts by default; callers with `write` or `verify` can pass `"scan_conflicts": true` to update conflict records during the request.
- `GET|POST /v1/memory/feed`, `GET|POST /v1/memory/events`, `GET /v1/memory/status`, `POST /v1/memory/compact`, `GET|POST /v1/memory/checkpoint`, and `POST /v1/memory/apply` provide native cross-memory feed/apply events. Feed visibility, pending restore, and apply use the same scope plus permissions checks as sources, artifacts, entities, relations, context packs, memory atoms, and agent memory. Apply validates payloads before reserving dedupe keys, preserves the event `actor_id` for admin/service restores, preserves agent-memory storage planes from event payloads (`native`, default `runtime`, named stores, subsets, or `all`), supports `put`, `delete`, `verify`, `mark_stale`, `supersede`, deterministic `merge_string_set`, and deterministic `merge_object`, returns the original applied event on retry, releases stale in-progress reservations after the retry window, exports cursor-floor checkpoints, redacts payloads that cite inaccessible objects, and returns `410 Gone` when a consumer asks for events below the compacted cursor floor.
- `GET /v1/lifecycle/diagnostics`, `POST /v1/lifecycle/snapshot`, `POST /v1/lifecycle/snapshot/export`, `POST /v1/lifecycle/snapshot/import`, `GET /v1/lifecycle/analytics/status`, `POST /v1/lifecycle/analytics/query`, `POST /v1/lifecycle/analytics/export`, `POST /v1/lifecycle/hygiene`, `POST /v1/lifecycle/summarize`, and `POST /v1/lifecycle/rollout` expose lifecycle runtime operations. Diagnostics include memory, stale memory, vector outbox, cache, queued/running/failed jobs, pending feed events, open conflicts, native agent memories, and session counts. Snapshot export is permission-aware and returns only visible search/context objects. `read + export` can produce a pure export without writing a lifecycle snapshot; persisted export snapshots require `write` or `propose`. Snapshot import preflights the batch and hydrates portable objects back as provenance-backed memory atoms through an atomic storage operation subject to the caller's write/propose/verify scopes. Analytics status/query/export are admin-only and use the configured ClickHouse plane for high-volume audit/feed history.
- `POST /v1/lifecycle/cache/put`, `POST /v1/lifecycle/cache/get`, `POST /v1/lifecycle/semantic-cache/put`, and `POST /v1/lifecycle/semantic-cache/search` expose response and semantic cache operations backed by SQLite/Postgres tables.
- `/v1/search` and `/v1/ask` participate in the lifecycle cache path. They read exact response-cache entries by default and, when called with `cache_ttl_ms` by a writer, persist cache entries. `/v1/ask` can also use semantic cache with `use_semantic_cache=true`. Response and semantic cache entries are keyed by `(actor_id, cache_key)`, store the generating actor/scope set, and are only returned to callers that match the cached actor and can see every cached scope.

## Internal Architecture

The service is being kept headless and layered:

- `src/main.zig` owns process config, worker startup, and the HTTP socket loop.
- `src/api.zig` owns request routing and response assembly only.
- `src/auth.zig` owns bearer-token authorization, token-principal extraction, actor spoofing protection, and request scope/capability narrowing.
- `src/access.zig` owns reusable ACL primitives: actor matching, session visibility, permission openness, ACL coverage, agent-memory scope derivation, and the private-vs-shared logical owner rules.
- `src/redis.zig` owns the dependency-free RESP client used by runtime engine planes.
- `src/agent_memory_runtime.zig` owns switchable agent-memory/session backends. SQLite/Postgres can store native agent memory with full provenance; `none` disables the runtime plane, `memory_lru` provides in-process parity for simple NullClaw-style memory, Redis can be selected as a shared low-latency remote plane for multiple NullClaw agents, and `api` proxies agent memory/session/usage to another NullPantry-compatible `/v1` API.
- `src/markdown_adapter.zig` and `src/markdown_filesystem.zig` own Markdown frontmatter parsing/rendering and recursive filesystem import/export. API code only orchestrates ACL, storage, extraction, and response assembly.
- `src/vector_runtime.zig` owns switchable external ANN vector planes. Qdrant, LanceDB SDK, and explicit LanceDB HTTP adapter services are treated as candidate indexes with upsert/search/delete/reset hooks; canonical text, provenance, status, and ACL decisions remain in SQLite/Postgres, and reconcile/rebuild replay canonical chunks into the configured plane.
- `src/lucid_runtime.zig` owns optional Lucid CLI projection commands, while `store.zig` persists Lucid projection jobs and lifecycle retractions. It is a semantic augmentation plane only: canonical writes, provenance, ACL, lifecycle, and citations stay in SQLite/Postgres.
- `src/store.zig` is the storage facade plus concrete SQLite/Postgres implementations. It delegates agent-memory/session calls to `agent_memory_runtime.zig` when an external plane is configured, while keeping sources/artifacts/entities/relations/feed/lifecycle in the canonical record backend.
- `src/context_pack.zig` owns context-pack ordering, token budgeting, summary assembly, typed sections, required-scope calculation, and the static agent safety guidance shared by SQLite and Postgres.
- `src/retrieval.zig`, `src/vector.zig`, `src/lifecycle.zig`, `src/extraction.zig`, and `src/providers.zig` hold independent domain services with focused unit tests.

New cross-cutting rules should land in a small module with focused tests first, then be wired into API/store. `api.zig` and `store.zig` should keep shrinking toward routing and persistence boundaries rather than accumulating policy logic.

## Storage Status

SQLite is the working local/dev/test backend and includes relational tables, FTS5 indexes, schema version checks, first-class spaces/policy scopes, lifecycle status, audit events, first-class artifact type contracts, context packs, native agent memory and sessions, permission-filtered vector chunks, ANN-style local vector search, executable vector outbox, response/semantic caches, lifecycle snapshots/hygiene, idempotent cross-memory feed events, connector cursors, ingestion/extraction jobs, and conflict records.

Postgres is implemented through a native `libpq` runtime adapter behind a narrow transport boundary. On startup it applies the Postgres DDL, adds `connect_timeout` to Postgres URLs that do not already define one, then storage operations execute SQL with server-side `statement_timeout` through pooled libpq connections: primitives, hybrid search, dynamic-dimension pgvector, lifecycle/cache, native agent memory, sessions/history, jobs, connector cursors, and conflicts. Multi-step writes and snapshot imports run as single Postgres transaction scripts. Postgres vector search uses pgvector candidates and no longer silently falls back to an in-process 5000-row scan.

The agent-memory runtime plane supports `none`, bounded in-process `memory_lru`, Redis, NullPantry-compatible API proxying, and named runtime stores. Redis is implemented as a native RESP runtime plane, not via subprocesses or NullClaw compatibility routes. Configure the default runtime with `NULLPANTRY_AGENT_MEMORY_BACKEND=redis` plus `NULLPANTRY_REDIS_URL`, or CLI flags `--agent-memory-backend redis --redis-url redis://host:6379/0`. Configure API proxying with `NULLPANTRY_AGENT_MEMORY_API_URL` plus optional `NULLPANTRY_AGENT_MEMORY_API_TOKEN`, or CLI flags `--agent-memory-backend api --agent-memory-api-url https://pantry.internal --agent-memory-api-token TOKEN`. Configure additional named stores with repeated `--agent-memory-store scratch=memory_lru`, `--agent-memory-store team=redis://host:6379/1`, `--agent-memory-store remote=https://pantry.internal`, or `NULLPANTRY_AGENT_MEMORY_STORES` JSON such as `{"name":"remote","api_url":"https://pantry.internal/v1","api_token":"..."}`. The Redis, API, and memory_lru planes store exact actor/session/key agent memory, shared scoped memory through logical owners such as `shared:team:alpha`, session messages, and usage counters. `memory_lru` is process-local but now has real LRU eviction and TTL controls for entries, session messages, usage counters, and approximate heap bytes through `--memory-lru-max-entries`, `--memory-lru-max-messages`, `--memory-lru-max-usage-entries`, `--memory-lru-max-bytes`, `--memory-lru-ttl-seconds`, or the matching `NULLPANTRY_MEMORY_LRU_*` env vars; named memory stores can set the same limits in `NULLPANTRY_AGENT_MEMORY_STORES` JSON. Redis multi-key writes for memory/index/session/usage state use Redis transactions, and configured TTLs are applied to the affected runtime keys so shared remote memory can be ephemeral without leaving permanent session or index records. API proxying forwards `X-NullPantry-Actor-Id`, scopes, and capabilities per request; for multi-agent gateway deployments the remote NullPantry should trust actor headers for the gateway token or issue token principals per agent intentionally. Retrieval/search/ask/context-pack flows still pass through NullPantry ACL checks before runtime-backed agent memory is exposed.

Markdown is implemented as a filesystem knowledge-document plane, not just an in-memory compatibility parser. Single-file and recursive directory import/export preserve frontmatter for type, status, scope, permissions, owner, space, related entities, metadata, path, and checksum; imported files become canonical Sources and Artifacts, so they participate in FTS/vector indexing, extraction jobs, context packs, lifecycle, feed events, and ACL-aware retrieval.

Qdrant is implemented as a native HTTP vector runtime plane. Configure it with `NULLPANTRY_VECTOR_BACKEND=qdrant`, `NULLPANTRY_VECTOR_BASE_URL`, and `NULLPANTRY_VECTOR_COLLECTION`, or with the Qdrant-specific aliases. LanceDB is implemented as an SDK process adapter with `NULLPANTRY_VECTOR_BACKEND=lancedb`, `NULLPANTRY_LANCEDB_URI`, optional `NULLPANTRY_LANCEDB_COMMAND`, and `NULLPANTRY_LANCEDB_TABLE`/`NULLPANTRY_VECTOR_COLLECTION`; the CLI also accepts `--lancedb-table`. Explicit adapter-service deployments can use `NULLPANTRY_VECTOR_BACKEND=lancedb_http` plus `NULLPANTRY_VECTOR_BASE_URL` or `NULLPANTRY_LANCEDB_URL`. All external vector adapters receive vector IDs and metadata through the vector outbox, then `/v1/vector/search` hydrates candidates from canonical storage and returns only permission-checked NullPantry chunks. `/v1/vector/delete` writes tombstones for external sinks, `/v1/vector/reconcile` queues canonical upserts, `/v1/vector/rebuild` can reset the configured collection/table before replaying canonical chunks, and both maintenance calls accept `retry_failed:true` to move failed embedding/index/delete outbox entries back to pending. `GET /v1/vector/status` reports the active sink, collection/table, external enablement, canonical chunk count, and pending/running/failed outbox counts without exposing API keys or URLs.

ClickHouse is implemented as a native HTTP analytics runtime plane. Configure it with `NULLPANTRY_ANALYTICS_BACKEND=clickhouse`, `NULLPANTRY_ANALYTICS_BASE_URL`, and `NULLPANTRY_ANALYTICS_TABLE`, or with the ClickHouse-specific aliases. `POST /v1/lifecycle/analytics/export` creates the target `ReplacingMergeTree` table if needed and writes audit events plus permission-filtered feed events as JSONEachRow rows for long-term history and analytics without making ClickHouse the canonical knowledge store. Export uses independent audit/feed cursors (`audit_since_id`, `feed_since_id`) and can resume from the persisted cursor with `use_cursor` or persist the next cursor with `advance_cursor`, so a busy audit stream cannot skip lower-volume feed events. Re-exporting the same range checks existing `(event_source,event_id)` keys and skips duplicates. `GET /v1/lifecycle/analytics/status` returns row/max-id health, and `POST /v1/lifecycle/analytics/query` exposes an admin-only filtered read path over the ClickHouse history table.

Lucid is implemented as an optional CLI projection adapter. Configure it with `NULLPANTRY_LUCID_ENABLED=true` plus `NULLPANTRY_LUCID_WORKSPACE` or CLI flags `--lucid-enabled --lucid-workspace`. NullPantry enqueues durable `lucid_projection` jobs for eligible Sources, Artifacts, Entities, Relations, MemoryAtoms, AgentMemory rows, and persisted ContextPacks; workers execute `lucid store` for puts and `lucid delete` for lifecycle retractions. `GET /v1/lifecycle/lucid/status` exposes pending/failed projection state, `POST /v1/lifecycle/lucid/rebuild` replays visible canonical search results into Lucid, and sparse retrieval can still augment from `lucid context`. SQLite/Postgres remain the authoritative source for permissions, lifecycle, source provenance, vector chunks, feed events, and context packs.

## Build System

NullPantry uses `nullbuilder` for GitHub CI, nightly artifacts, and tagged releases through reusable workflows in `.github/workflows`. SQLite is vendored under `vendor/sqlite3` so nullbuilder can cross-compile release binaries without relying on host system libraries.
