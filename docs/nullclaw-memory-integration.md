# NullClaw Memory Integration

This guide describes how to connect NullClaw memory to NullPantry across the supported deployment shapes:

- one local agent with private memory;
- many agents sharing one NullPantry service while keeping private memory isolated;
- family, team, project, and organization shared memory;
- private plus shared memory in the same request flow;
- named runtime stores and federated routing;
- Redis, ClickHouse, API, Markdown, Holographic, vendor, and in-process memory runtimes;
- sessions, usage, history, feed/apply/checkpoint, and prompt bootstrap;
- RAG, knowledge graph, and context serving on top of agent memory.

NullPantry should be treated as the central memory and knowledge service. NullClaw should stay small and use local `none`, in-process `memory`, local `sqlite`, or `markdown` only for standalone/local baseline usage.

## Recommended NullClaw Path

For the current NullClaw `api` memory engine, point NullClaw at the NullPantry adapter namespace:

```text
url       = http://127.0.0.1:8765
namespace = /v1/agent
token     = <agent bearer token>
```

Use the exact NullClaw-side config syntax that matches the current NullClaw release, but keep these values. The `/v1/agent` namespace is the deterministic NullClaw adapter. It exposes the CRUD, list, search, session, history, feed, checkpoint, and apply surface expected by NullClaw `ApiMemory`.

Do not point a NullClaw `ApiMemory` feed client at root `/v1/feed` unless it is intentionally consuming native NullPantry primitive events. Root `/v1/feed` is broader than NullClaw memory and includes Source, Artifact, MemoryAtom, Entity, Relation, lifecycle, policy, and other NullPantry events.

## Build Selection

The default `zig build` profile is `nullclaw`, which keeps the binary close to NullClaw's local baseline:

- SQLite canonical records.
- Markdown live agent-memory runtime.
- `memory_lru` and `none`.
- The NullClaw adapter namespace enabled.

For all memory engines:

```sh
zig build -Dengine-profile=full
```

For a smaller production binary, compile only the required backends:

```sh
zig build \
  -Dengine-profile=custom \
  -Drecords=postgres \
  -Dagent-memory=redis,clickhouse,api \
  -Dvectors=pgvector
```

The `agent_memory` build option accepts:

```text
none, memory, redis, clickhouse, api, supermemory, openviking, honcho,
mem0, hindsight, retaindb, byterover, holographic
```

These are agent-memory runtime backends. They are not the Confluence-like knowledge store. The canonical knowledge store is selected through `records=sqlite|postgres`.

## Integration Surfaces

NullPantry exposes three memory surfaces that serve different callers.

| Surface | Best use | Notes |
| --- | --- | --- |
| `/v1/agent` | NullClaw `api` memory engine | Recommended NullClaw namespace. Includes memory, sessions, history, feed, checkpoint, and apply compatibility. |
| `/v1/memory` | NullClaw CLI-shaped commands and migration tools | Command-style `store`, `get`, `list`, `search`, `delete`, `export-jsonl`, hygiene, parity, and memory feed aliases. |
| `/v1/agent-memory` plus `/v1/agent-sessions` | Native NullPantry agent API | Actor-aware memory and session APIs for NullHub, gateways, custom agents, tests, and direct service clients. |

All three surfaces use the same actor-aware core. Private/shared ownership, ACL filtering, storage selectors, and backend routing are shared.

## Actor And Scope Model

Use one token principal per agent or user in multi-agent deployments. A token principal binds a bearer token to an `actor_id`, scopes, and capabilities:

```sh
export NULLPANTRY_TOKEN_PRINCIPALS='{
  "agent-a-token": {
    "actor_id": "agent:a",
    "scopes": [
      "session:*",
      "write:session:*",
      "team:alpha",
      "write:team:alpha",
      "family:home",
      "write:family:home"
    ],
    "capabilities": ["read", "write", "propose", "delete", "feed_apply"]
  },
  "agent-b-token": {
    "actor_id": "agent:b",
    "scopes": [
      "session:*",
      "write:session:*",
      "team:alpha",
      "write:team:alpha",
      "family:home",
      "write:family:home"
    ],
    "capabilities": ["read", "write", "propose", "delete", "feed_apply"]
  },
  "nullhub-reader": {
    "actor_id": "user:nullhub-reader",
    "scopes": ["public", "team:alpha"],
    "capabilities": ["read", "export"]
  }
}'
```

Rules:

- Omitted `scope` creates actor-private memory owned by the token principal's `actor_id`.
- Explicit `scope` creates shared logical memory owned as `shared:<scope>`, for example `shared:team:alpha` or `shared:family:home`.
- Session memory requires `session:<id>` or `session:*` for reads and `write:session:<id>` or `write:session:*` for writes.
- Agent-created scoped memory is proposed by default unless a separate verification flow promotes it.
- Request headers can narrow token scopes and capabilities. They cannot escalate or spoof a token-bound actor id.
- `--trust-actor-headers` / `NULLPANTRY_TRUST_ACTOR_HEADERS=1` is only for trusted internal gateway deployments.

## Scenario Matrix

| Scenario | NullPantry setup | NullClaw setup | Storage and permission behavior |
| --- | --- | --- | --- |
| One local agent, private memory | Default build, SQLite canonical store, optional `memory_lru` or Markdown runtime | Use `/v1/agent` with one bearer token, or local NullClaw memory for standalone mode | Omit `scope`. Keys are private to the token actor. |
| Several agents, isolated private memory | Token principals per agent, same NullPantry service | Each NullClaw instance uses its own bearer token | The same key can exist once per actor. Lists/searches only expose visible actor/shared rows. |
| Shared family/team/project memory | Grant every participant `scope` and `write:<scope>` as needed | Include `scope` in writes and exact reads/deletes | Shared keys live under `shared:<scope>` and remain auditable through `created_by_actor_id`. |
| Private plus shared memory | Same as multi-agent/shared | Omit `scope` for private preference, pass `scope` for exact shared memory | `GET` without `scope` prefers the caller's private row when private and shared rows share a key. |
| Several stores behind one service | Configure `NULLPANTRY_AGENT_MEMORY_STORES` or repeated `--agent-memory-store` | Pass `store`, `stores`, or `storage` in requests | Route to `native`, default runtime, named stores, subsets, or `all`. |
| Cross-service/federated memory | Use `api` runtime or a named API store pointing at another NullPantry-compatible service | Still point NullClaw to the local `/v1/agent` | The local service forwards actor, scopes, and capabilities to the upstream service. |
| Durable shared runtime memory | Use Redis or ClickHouse runtime, optionally Postgres canonical records | NullClaw remains on `/v1/agent` | Redis/ClickHouse store exact memory, sessions, usage, and feed-peer state. |
| Filesystem parity with a workspace | Use Markdown runtime with a workspace path | NullClaw can keep workspace prompt/memory files while NullPantry reads/appends them live | Markdown is live and durable for memory files, but it is not a session/feed/lifecycle store. |
| Vendor-backed exact memory | Compile and configure Supermemory, OpenViking, Honcho, Mem0, Hindsight, RetainDB, or ByteRover | NullClaw still talks to NullPantry, not directly to vendors | NullPantry maps exact memory to the vendor and re-filters results through NullPantry ACLs. |
| Local associative recall | Use Holographic runtime with a local DB path | NullClaw stays on `/v1/agent` | Holographic stores exact actor/scoped memory with local recall scoring, not sessions or feed authority. |
| RAG and context serving | Configure canonical records and optional vectors | NullClaw or other agents call search/ask/context pack APIs through NullPantry | Retrieval is ACL-aware and can include sources, artifacts, memory atoms, graph, vectors, and visible runtime memory. |

## Backend Capabilities

| Backend | Best use | Exact memory | Sessions and usage | Feed peer | Important limits |
| --- | --- | --- | --- | --- | --- |
| Native SQLite/Postgres | Canonical source of truth, provenance, ACL, lifecycle, retrieval | Yes | Yes | Yes, through native feed | Canonical store for knowledge primitives. |
| `memory_lru` / `memory` | Tests, local development, short-lived service memory | Yes | Yes | Yes | Process-local unless checkpointed/applied. Subject to TTL/LRU limits. |
| Markdown | NullClaw workspace file parity | Yes | No | No | Live-reads and appends memory files; no delete/status/session/usage/feed authority. |
| Redis | Shared low-latency runtime memory | Yes | Yes | Yes | Runtime projection; keep SQLite/Postgres for canonical knowledge and provenance. |
| ClickHouse | Durable high-volume runtime memory and event history | Yes | Yes | Yes | Runtime backend for exact memory/session/feed; canonical knowledge remains SQLite/Postgres. |
| API | Federation to another NullPantry-compatible service | Depends on upstream | Depends on upstream | Yes when upstream supports it | Forwards actor/scopes/capabilities; configure storage target deliberately. |
| Supermemory, OpenViking, Honcho, Mem0, Hindsight, RetainDB, ByteRover | Vendor/projected exact memory | Yes | Backend-specific projection only | No NullPantry feed authority | NullPantry re-filters returned data through ACLs and metadata. |
| Holographic | Local associative exact memory | Yes | No | No | Durable local memory projection; no session history or usage counters. |
| `none` | Disabled runtime backend | No | No | No | Useful as an explicit no-op backend or fallback. |

## Start Examples

Single local service with SQLite canonical records and in-process agent memory:

```sh
export NULLPANTRY_TOKEN_PRINCIPALS='{
  "local-agent-token": {
    "actor_id": "agent:local",
    "scopes": ["session:*","write:session:*","public","write:public"],
    "capabilities": ["read","write","propose","delete","feed_apply"]
  }
}'

zig build run -- \
  --db .nullpantry/nullpantry.db \
  --agent-memory-backend memory
```

Shared NullPantry service for several NullClaw agents with Postgres canonical records and Redis runtime memory:

```sh
export NULLPANTRY_RECORDS_BACKEND=postgres
export NULLPANTRY_DATABASE_URL='postgres://user:pass@postgres.internal:5432/nullpantry'
export NULLPANTRY_AGENT_MEMORY_BACKEND=redis
export NULLPANTRY_REDIS_URL='redis://:password@redis.internal:6379/0'
export NULLPANTRY_TOKEN_PRINCIPALS='{
  "agent-a-token": {
    "actor_id": "agent:a",
    "scopes": ["session:*","write:session:*","team:alpha","write:team:alpha"],
    "capabilities": ["read","write","propose","delete","feed_apply"]
  },
  "agent-b-token": {
    "actor_id": "agent:b",
    "scopes": ["session:*","write:session:*","team:alpha","write:team:alpha","family:home","write:family:home"],
    "capabilities": ["read","write","propose","delete","feed_apply"]
  }
}'

zig build run
```

Named stores for scratch, team, archive, and local associative memory:

```sh
export NULLPANTRY_AGENT_MEMORY_BACKEND=redis
export NULLPANTRY_REDIS_URL='redis://redis.internal:6379/0'
export NULLPANTRY_AGENT_MEMORY_STORES='[
  {"name":"scratch","backend":"memory_lru","max_entries":2000},
  {"name":"team","backend":"redis","redis_url":"redis://redis.internal:6379/1"},
  {"name":"archive","backend":"clickhouse","clickhouse_url":"http://clickhouse:8123","clickhouse_table":"np_agent_archive","clickhouse_allow_insecure_http":true},
  {"name":"assoc","backend":"holographic","holographic_db_path":".nullpantry/assoc.db"}
]'
```

Store a private preference:

```sh
curl -sS \
  -H 'Authorization: Bearer agent-a-token' \
  -H 'Content-Type: application/json' \
  -X PUT \
  http://127.0.0.1:8765/v1/agent/memories/preference.editor \
  -d '{"content":"Prefer concise Zig examples."}'
```

Store shared family memory:

```sh
curl -sS \
  -H 'Authorization: Bearer agent-a-token' \
  -H 'Content-Type: application/json' \
  -X PUT \
  http://127.0.0.1:8765/v1/agent/memories/family.calendar \
  -d '{"content":"School pickup is at 15:30 on Thursdays.","scope":"family:home"}'
```

Read exactly from a shared scope:

```sh
curl -sS \
  -H 'Authorization: Bearer agent-b-token' \
  'http://127.0.0.1:8765/v1/agent/memories/family.calendar?scope=family:home'
```

Write to two named stores and then search across them:

```sh
curl -sS \
  -H 'Authorization: Bearer agent-a-token' \
  -H 'Content-Type: application/json' \
  -X PUT \
  'http://127.0.0.1:8765/v1/agent/memories/project.note?stores=scratch,team' \
  -d '{"content":"The release gate depends on vector rebuild completion.","scope":"team:alpha"}'

curl -sS \
  -H 'Authorization: Bearer agent-a-token' \
  -H 'Content-Type: application/json' \
  -X POST \
  http://127.0.0.1:8765/v1/agent/memories/search \
  -d '{"query":"release gate","stores":["scratch","team"],"scope":"team:alpha","limit":10}'
```

## Storage Selectors

Agent-memory requests can choose a backend per request through body fields `storage`, `store`, `target_store`, `stores`, or query parameters `storage`, `store`, `target_store`, `stores`.

Supported selector forms:

- `primary`: the configured default backend.
- `native`: canonical SQLite/Postgres agent memory.
- Runtime aliases: `runtime`, `none`, `memory`, `memory_lru`, `in_memory`, `markdown`, `md`, `filesystem`, `redis`, `clickhouse`, `api`, `http`, `nullpantry_api`.
- Named store ids configured through `--agent-memory-store` or `NULLPANTRY_AGENT_MEMORY_STORES`.
- `stores:["scratch","archive"]` or `?stores=scratch,archive`: route only to a subset.
- `all` or `federated`: route through native, default runtime, and named runtime stores.

Cross-backend writes are not a distributed transaction. Use `native` for canonical provenance and lifecycle; use runtime/named stores for exact agent memory projections and performance.

## Sessions, History, And Usage

The NullClaw adapter exposes:

- `GET|POST|DELETE /v1/agent/sessions/:id/messages`
- `POST /v1/agent/sessions/:id/compact`
- `GET|PUT|DELETE /v1/agent/sessions/:id/usage`
- `DELETE /v1/agent/sessions/:id`
- `POST /v1/agent/sessions/:id/terminate`
- `GET /v1/agent/history`
- `GET /v1/agent/history/:id`

Native NullPantry callers can use `/v1/agent-sessions` directly.

Session state is actor-isolated and scope-gated. Reusing the same session id across two agents does not merge private memory unless both actors write to an explicit shared scope and the caller has that scope.

## Feed, Checkpoint, And Apply

For NullClaw `ApiMemory`, use:

- `GET /v1/agent/memory/events`
- `GET /v1/agent/memory/status`
- `POST /v1/agent/memory/compact`
- `GET|POST /v1/agent/memory/checkpoint`
- `POST /v1/agent/memory/apply`

This namespace emits a NullClaw-compatible projection over NullPantry memory events. It supports replayable `agent_memory` operations such as `put`, `merge_object`, `merge_string_set`, `delete_scoped`, and `delete_all`, while richer NullPantry lifecycle events stay on native feed endpoints.

Redis, ClickHouse, API proxying, and `memory_lru` expose the runtime feed peer contract. Markdown, vendor profiles, ByteRover, and Holographic remain runtime memory/projection backends without NullPantry feed authority.

## Prompt Bootstrap

NullClaw prompt bootstrap files are available as first-class agent memory:

- `GET /v1/bootstrap/prompts`
- `PUT|GET|DELETE /v1/bootstrap/prompts/:filename`
- `GET /v1/bootstrap/prompts/:filename/exists`
- `GET /v1/bootstrap/prompts/fingerprint`
- `POST /v1/bootstrap/prompts/import-directory`
- `POST /v1/bootstrap/prompts/reset`

The known prompt files are `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `CONFIG.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, and `MEMORY.md`.

Use this when a NullPantry-backed workspace should start from the same NullClaw bootstrap contract but store prompts under governed actor/scoped memory.

## RAG, Knowledge Graph, And Context Serving

NullPantry is broader than NullClaw memory. Once memory and sources are in NullPantry, agents can also use:

- `/v1/search` for ACL-aware keyword/vector/entity retrieval.
- `/v1/ask` for citation-backed answers over visible knowledge.
- `/v1/context-packs` for prepared task context.
- `/v1/graph/*` for entity and relation traversal.
- `/v1/remember`, `/v1/forget`, `/v1/verify`, and lifecycle endpoints for governed memory.

Search, Ask, and Context Packs must remain permission-aware. A caller should never receive source text, memory atoms, graph relations, vectors, summaries, or citations outside the actor's visible scopes.

## Migration From NullClaw Local Memory

Use these paths depending on the source:

- NullClaw API memory or remote runtime: configure NullClaw to `/v1/agent` and let feed/checkpoint/apply synchronize state.
- NullClaw CLI-shaped memory rows: use `/v1/memory` commands and `/v1/memory/export-jsonl`.
- NullClaw `brain.db`: use the lifecycle import route that accepts NullClaw memory rows and session state.
- Markdown workspace memory: configure Markdown runtime for live reads/appends, or import the workspace into canonical Sources and Artifacts for governed retrieval.

Migration should keep actor ids and scopes explicit. Avoid importing all agent memory as `public` unless it was intentionally public.

## Verification Checklist

After wiring NullClaw to NullPantry, verify the contract before relying on it:

```sh
curl -sS -H 'Authorization: Bearer agent-a-token' \
  http://127.0.0.1:8765/v1/agent/health

curl -sS -H 'Authorization: Bearer agent-a-token' \
  http://127.0.0.1:8765/v1/agent/memory/parity
```

Then test the scenarios that matter for the deployment:

- Private isolation: write the same key with two different agent tokens and confirm each token reads its own value.
- Shared scope: write with `scope:"team:alpha"` or `scope:"family:home"` and confirm another authorized token can read it with the same scope.
- Private plus shared precedence: write the same key privately and shared, then confirm unscoped `GET` returns the private value and scoped `GET` returns the shared value.
- Sessions: add messages under one session id and confirm another actor cannot read them without the required session scope.
- Storage routing: write with `store:"scratch"` or `stores:["scratch","team"]` and search/list using the same selector.
- Feed/checkpoint: call `/v1/agent/memory/events`, export a checkpoint, restore/apply it to another compatible service, and confirm memory/session state is replayed.
- RAG/context: create a Source or MemoryAtom, search for it through `/v1/search`, and request a context pack under the same visible scope.

## Implementation Coverage

The integration behavior is covered by tests in:

- [`src/api.zig`](../src/api.zig): `/v1/agent`, `/v1/memory`, native agent memory, token principals, scope enforcement, sessions/history, storage selectors, feed/apply/checkpoint, prompt bootstrap, migration, graph commands, manifest/openapi coverage.
- [`src/store.zig`](../src/store.zig): native agent memory, actor isolation, shared scoped ownership, runtime routing, fan-in/fan-out, context packs, lifecycle, feed visibility, canonical projections.
- [`src/agent_memory_runtime.zig`](../src/agent_memory_runtime.zig): runtime backend parsing, memory_lru contract, Redis/ClickHouse/API helpers, vendor profile mappings, Holographic runtime, named store validation, feed/checkpoint/apply behavior.
- [`src/storage_route.zig`](../src/storage_route.zig): `storage`, `store`, `target_store`, `stores`, reserved aliases, named stores, subset routing, percent-decoding, invalid selector rejection.
- [`build.zig`](../build.zig): engine profile and `-Dagent-memory` compile-time selection.
