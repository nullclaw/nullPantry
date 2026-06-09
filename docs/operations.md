# Operations

This guide covers the commands and configuration needed to build, run, and operate NullPantry. It avoids listing every environment variable twice; use `zig build --help` for build options and `zig build run -- --help` for the full runtime flag list.

## Requirements

- Zig `0.16.0` or compatible `0.16.x`
- Vendored SQLite from `vendor/sqlite3`
- Optional `libpq` at runtime for Postgres
- Optional service dependencies for the backend you enable: Redis, ClickHouse, Qdrant, LanceDB Python package or HTTP adapter, Weaviate, Chroma, OpenSearch, Neo4j, FalkorDB, Lucid CLI, or vendor API credentials

## Build

```sh
# Default local NullClaw-compatible profile.
zig build

# Smaller local profile.
zig build -Dengine-profile=minimal

# Compile every backend/runtime adapter.
zig build -Dengine-profile=full

# Compile only selected backend families.
zig build -Dengine-profile=custom \
  -Drecords=postgres \
  -Dagent-memory=redis,api \
  -Dvectors=qdrant,pgvector
```

Build selection is compile-time. A runtime flag cannot activate a backend that was not compiled into the binary.

Profiles:

| Profile | Use When | Includes |
| --- | --- | --- |
| `nullclaw` | Default local development and NullClaw compatibility | SQLite records, Markdown compatibility, hybrid descriptor, `memory_lru`, `none` |
| `minimal` | Small local smoke binaries | SQLite records, `memory_lru`, `none` |
| `full` | Integration and release validation | Every record, memory, vector, graph, analytics, provider, and connector adapter |
| `custom` | Production-specific binaries | Only explicit `-Drecords`, `-Dagent-memory`, `-Dvectors`, or `-Denable-*` choices |

## Container Image

Tagged releases publish a multi-architecture GHCR image:

```sh
docker pull ghcr.io/nullclaw/nullpantry:latest
docker pull ghcr.io/nullclaw/nullpantry:v2026.06.09
docker pull ghcr.io/nullclaw/nullpantry:2026.06.09
```

The image runs as a non-root user, stores local state under `/var/lib/nullpantry`, and listens on `0.0.0.0:8765` so Docker port publishing works. Because non-loopback binds require authentication, provide `NULLPANTRY_TOKEN` or `NULLPANTRY_TOKEN_PRINCIPALS` unless you intentionally set `NULLPANTRY_ALLOW_NO_AUTH_NON_LOOPBACK=true` for a trusted local-only environment.

```sh
docker run --rm \
  -p 8765:8765 \
  -e NULLPANTRY_TOKEN=prod-secret \
  -v nullpantry-data:/var/lib/nullpantry \
  ghcr.io/nullclaw/nullpantry:latest
```

## Runtime Home

Use `--home PATH`, `--home=PATH`, or `NULLPANTRY_HOME=PATH` when one local directory should hold NullPantry's default files:

```sh
NULLPANTRY_HOME="$HOME/nullhub/nullpantry" \
zig build run
```

Home mode changes only defaults. It uses `PATH/nullpantry.db` for SQLite records, `PATH/files` for filesystem import/export, `PATH/markdown` for the Markdown memory workspace, `PATH/holographic_memory.db` for holographic memory, `PATH/lancedb` for LanceDB command mode, and `PATH/lucid` for Lucid. If no explicit config is supplied, NullPantry also loads `PATH/nullpantry.json` when it exists. Existing home directories must be owned by the service user and must not be group- or world-writable; a missing home directory is created with private permissions before local storage is opened.

Explicit config, environment variables, and CLI flags still win over home-derived defaults. For example, `--db`, `NULLPANTRY_DB_PATH`, or `records.db_path` replace `PATH/nullpantry.db`.

## Runtime Config File

Runtime config can be supplied from a JSON file with `--config PATH`, `--config=PATH`, `-c PATH`, or `NULLPANTRY_CONFIG=PATH`.

Config precedence is:

```text
defaults < home defaults < config file < environment variables < CLI flags
```

Use structured sections for stable config and the `env` section when you want exact runtime environment compatibility. Structured sections are strict and reject unknown fields or wrong section types, so typos fail during startup instead of being ignored. The `env` section accepts only known runtime `NULLPANTRY_*` keys and rejects unknown keys, including typos with the right prefix. `NULLPANTRY_HOME` and `NULLPANTRY_CONFIG` select paths before the config file is loaded, so they must be supplied by the real process environment or a CLI flag.

```sh
zig build run -- --home "$HOME/nullhub/nullpantry"

zig build run -- --config .nullpantry/nullpantry.json

NULLPANTRY_CONFIG=/etc/nullpantry/nullpantry.json \
NULLPANTRY_VECTOR_BACKEND=qdrant \
zig build run -- --vector-collection hotfix_vectors
```

In the second command, the process environment overrides the file, and the CLI flag overrides both.
When `--config` and `NULLPANTRY_CONFIG` are absent, `${NULLPANTRY_HOME}/nullpantry.json` is auto-loaded only if that file exists, is not a symlink, is owned by the service user, and neither the home directory nor the config file is group- or world-writable.

Example:

```json
{
  "server": {
    "host": "127.0.0.1",
    "port": 8765,
    "instance_id": "nullpantry-prod"
  },
  "records": {
    "backend": "postgres",
    "postgres_url": "postgres://user:pass@postgres.internal:5432/nullpantry"
  },
  "auth": {
    "token_principals": {
      "agent-a-token": {
        "actor_id": "agent:a",
        "scopes": ["project:nullpantry", "write:project:nullpantry"],
        "capabilities": ["read", "write", "propose", "delete"]
      }
    }
  },
  "worker": {
    "interval_ms": 5000,
    "scopes": ["admin"],
    "capabilities": ["read", "write", "verify", "feed_apply"]
  },
  "agent_memory": {
    "backend": "redis",
    "redis": {
      "url": "redis://redis.internal:6379/0",
      "key_prefix": "nullpantry"
    }
  },
  "vector": {
    "backend": "pgvector",
    "pgvector": {
      "url": "postgres://user:pass@postgres.internal:5432/nullpantry_vectors",
      "table": "nullpantry_vectors"
    }
  },
  "provider": {
    "embedding": {
      "provider": "openai-compatible",
      "base_url": "https://provider.internal/v1",
      "model": "text-embedding-3-small"
    },
    "llm": {
      "base_url": "https://llm.internal/v1",
      "model": "chat-model"
    }
  },
  "env": {
    "NULLPANTRY_VECTOR_TIMEOUT_SECS": 10,
    "NULLPANTRY_LUCID_ENABLED": true
  }
}
```

Every current runtime setting `NULLPANTRY_*` variable except `NULLPANTRY_HOME` and `NULLPANTRY_CONFIG` can be represented in the config file by putting the exact key under `env`. Prefer structured sections for readability, and keep deployment-specific secrets in the real process environment when they should override the checked-in config.

## Run Locally

```sh
zig build run -- --db .nullpantry/nullpantry.db
```

Defaults:

| Setting | Default |
| --- | --- |
| host | `127.0.0.1` |
| port | `8765` |
| SQLite path | `.nullpantry/nullpantry.db` |
| auth | optional on loopback |
| record store | SQLite |

Useful local variants:

```sh
# Explicit host and port.
zig build run -- --host 127.0.0.1 --port 8765 --db .nullpantry/dev.db

# Token-protected local run.
NULLPANTRY_TOKEN='dev-token' \
NULLPANTRY_SCOPES='["admin"]' \
NULLPANTRY_CAPABILITIES='["read","write","propose","verify","delete","export","feed_apply"]' \
zig build run -- --db .nullpantry/dev.db

# Live NullClaw-style Markdown memory workspace.
NULLPANTRY_AGENT_MEMORY_BACKEND=markdown \
NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE=/path/to/workspace \
zig build run -- --db .nullpantry/dev.db
```

## Run With Postgres

Postgres is the production canonical record store. It requires a database URL and `libpq` available at runtime.

```sh
NULLPANTRY_DATABASE_URL='postgres://user:pass@host:5432/nullpantry' \
NULLPANTRY_TOKEN='prod-secret' \
NULLPANTRY_SCOPES='["admin"]' \
NULLPANTRY_CAPABILITIES='["read","write","propose","verify","delete","export","feed_apply"]' \
zig build run -- --backend postgres
```

Use these when the platform needs them:

```sh
export NULLPANTRY_LIBPQ_PATH=/path/to/libpq
export NULLPANTRY_POSTGRES_POOL_SIZE=16
```

Startup migrations target the current native schema. The project is not preserving legacy compatibility tables yet; obsolete actorless compatibility state can be removed during migration.

## Auth And Actors

For one local token:

```sh
NULLPANTRY_TOKEN='agent-token' \
NULLPANTRY_SCOPES='["project:nullpantry","write:project:nullpantry","session:*","write:session:*"]' \
NULLPANTRY_CAPABILITIES='["read","write","propose","delete","export"]' \
zig build run -- --db .nullpantry/dev.db
```

For multiple agents or users, prefer token principals:

```sh
export NULLPANTRY_TOKEN_PRINCIPALS='{
  "agent-a-token": {
    "actor_id": "agent:a",
    "scopes": ["project:nullpantry", "write:project:nullpantry", "session:*", "write:session:*"],
    "capabilities": ["read", "write", "propose", "delete"]
  },
  "reader-token": {
    "actor_id": "user:reader",
    "scopes": ["public", "project:nullpantry"],
    "capabilities": ["read", "export"]
  }
}'
```

Capabilities are `read`, `propose`, `write`, `verify`, `delete`, `export`, and `feed_apply`. Read scopes and write scopes are separate; `project:nullpantry` does not imply `write:project:nullpantry`.

Actor headers:

- `X-NullPantry-Actor-Id`
- `X-NullPantry-Actor-Scopes`
- `X-NullPantry-Actor-Capabilities`

Headers can narrow token principal permissions. Use `--trust-actor-headers` or `NULLPANTRY_TRUST_ACTOR_HEADERS=1` only behind a trusted internal auth gateway.

## Agent Memory Backends

Agent memory is exact actor/session/key memory and session state. It is separate from canonical knowledge records.

| Backend | Typical Use | Minimal Config |
| --- | --- | --- |
| `memory_lru` | process-local dev and tests | `NULLPANTRY_AGENT_MEMORY_BACKEND=memory_lru` |
| `markdown` | live NullClaw workspace files | `NULLPANTRY_AGENT_MEMORY_BACKEND=markdown`, `NULLPANTRY_AGENT_MEMORY_MARKDOWN_WORKSPACE=/path` |
| `redis` | shared low-latency agent memory and sessions | `NULLPANTRY_AGENT_MEMORY_BACKEND=redis`, `NULLPANTRY_REDIS_URL=redis://...` |
| `clickhouse` | durable event/history-oriented memory runtime | `NULLPANTRY_AGENT_MEMORY_BACKEND=clickhouse`, `NULLPANTRY_AGENT_MEMORY_CLICKHOUSE_URL=http://...` |
| `api` | proxy to another NullPantry-compatible service | `NULLPANTRY_AGENT_MEMORY_BACKEND=api`, `NULLPANTRY_AGENT_MEMORY_API_URL=https://...` |
| vendor profiles | external memory projection services | backend-specific URL/API key variables |
| `holographic` | local SQLite/FTS associative memory | `NULLPANTRY_AGENT_MEMORY_BACKEND=holographic`, `NULLPANTRY_AGENT_MEMORY_HOLOGRAPHIC_DB_PATH=.nullpantry/holographic.db` |

Vendor and graph memory profiles:

| Backend | Required Runtime Config |
| --- | --- |
| `supermemory` | `NULLPANTRY_AGENT_MEMORY_BACKEND=supermemory`, `NULLPANTRY_SUPERMEMORY_API_KEY` |
| `openviking` | `NULLPANTRY_AGENT_MEMORY_BACKEND=openviking`, `NULLPANTRY_OPENVIKING_API_KEY`, optional `NULLPANTRY_OPENVIKING_URL` |
| `honcho` | `NULLPANTRY_AGENT_MEMORY_BACKEND=honcho`, `NULLPANTRY_HONCHO_API_KEY`, optional `NULLPANTRY_HONCHO_WORKSPACE_ID` |
| `mem0` | `NULLPANTRY_AGENT_MEMORY_BACKEND=mem0`, `NULLPANTRY_MEM0_API_KEY` |
| `hindsight` | `NULLPANTRY_AGENT_MEMORY_BACKEND=hindsight`, `NULLPANTRY_HINDSIGHT_API_KEY`, `NULLPANTRY_HINDSIGHT_BANK_ID` |
| `retaindb` | `NULLPANTRY_AGENT_MEMORY_BACKEND=retaindb`, `NULLPANTRY_RETAINDB_API_KEY`, optional `NULLPANTRY_RETAINDB_PROJECT` |
| `byterover` | `NULLPANTRY_AGENT_MEMORY_BACKEND=byterover`, installed `brv`, optional `NULLPANTRY_BYTEROVER_PROJECT_DIR` |
| `zep` | `NULLPANTRY_AGENT_MEMORY_BACKEND=zep`, `NULLPANTRY_ZEP_URL`, `NULLPANTRY_ZEP_API_KEY`, `NULLPANTRY_ZEP_GRAPH_ID` |
| `falkordb` | `NULLPANTRY_AGENT_MEMORY_BACKEND=falkordb`, `NULLPANTRY_FALKORDB_URL`, `NULLPANTRY_FALKORDB_GRAPH`, optional `NULLPANTRY_FALKORDB_API_KEY` |

Redis example:

```sh
NULLPANTRY_AGENT_MEMORY_BACKEND=redis \
NULLPANTRY_REDIS_URL='redis://:password@redis.internal:6379/0' \
NULLPANTRY_RECORDS_BACKEND=postgres \
NULLPANTRY_DATABASE_URL='postgres://user:pass@postgres.internal:5432/nullpantry' \
zig build run
```

Named runtime stores let callers route a request to `store:"scratch"` or `stores:["scratch","archive"]`:

```sh
export NULLPANTRY_AGENT_MEMORY_STORES='[
  {"name":"scratch","backend":"memory_lru"},
  {"name":"team","backend":"redis","redis_url":"redis://redis.internal:6379/1","key_prefix":"team-memory"},
  {"name":"remote-team","backend":"api","api_url":"https://pantry.remote/v1","api_token":"gateway","api_storage":"team:alpha"}
]'
```

Reserved route names include `primary`, `native`, `runtime`, `markdown`, `redis`, `clickhouse`, `api`, `all`, and `federated`.

See [NullClaw Memory Integration](nullclaw-memory-integration.md) for route selectors, feed/checkpoint/apply, sessions, shared scopes, and migration paths.

## Vector Indexes

Canonical text, provenance, and ACLs stay in SQLite/Postgres. Vector indexes are rebuildable projections.

| Backend | Required Runtime Config |
| --- | --- |
| local SQLite vectors | no external service |
| `pgvector` | `NULLPANTRY_VECTOR_BACKEND=pgvector`, `NULLPANTRY_PGVECTOR_URL` or `NULLPANTRY_VECTOR_POSTGRES_URL` |
| `qdrant` | `NULLPANTRY_VECTOR_BACKEND=qdrant`, `NULLPANTRY_VECTOR_BASE_URL` or `NULLPANTRY_QDRANT_URL` |
| `lancedb` | `NULLPANTRY_VECTOR_BACKEND=lancedb`, `NULLPANTRY_LANCEDB_URI`, optional `NULLPANTRY_LANCEDB_COMMAND` |
| `lancedb_http` | `NULLPANTRY_VECTOR_BACKEND=lancedb_http`, `NULLPANTRY_LANCEDB_URL` or `NULLPANTRY_VECTOR_BASE_URL` |
| `weaviate` | `NULLPANTRY_VECTOR_BACKEND=weaviate`, `NULLPANTRY_WEAVIATE_URL` |
| `chroma` | `NULLPANTRY_VECTOR_BACKEND=chroma`, `NULLPANTRY_CHROMA_URL` |
| `opensearch` | `NULLPANTRY_VECTOR_BACKEND=opensearch`, `NULLPANTRY_OPENSEARCH_URL` |

```sh
# Qdrant.
NULLPANTRY_VECTOR_BACKEND=qdrant \
NULLPANTRY_VECTOR_BASE_URL='http://127.0.0.1:6333' \
NULLPANTRY_VECTOR_ALLOW_INSECURE_HTTP=true \
NULLPANTRY_VECTOR_COLLECTION='nullpantry_vectors' \
zig build run -- --db .nullpantry/dev.db

# Standalone pgvector index while canonical records live elsewhere.
NULLPANTRY_VECTOR_BACKEND=pgvector \
NULLPANTRY_PGVECTOR_URL='postgres://localhost/nullpantry_vectors' \
NULLPANTRY_PGVECTOR_TABLE='nullpantry_vectors' \
zig build run -- --db .nullpantry/dev.db

# LanceDB SDK adapter.
NULLPANTRY_VECTOR_BACKEND=lancedb \
NULLPANTRY_LANCEDB_URI='.nullpantry/lancedb' \
NULLPANTRY_LANCEDB_TABLE='nullpantry_vectors' \
zig build run -- --db .nullpantry/dev.db
```

Named vector stores fan out the vector outbox to multiple sinks:

```sh
export NULLPANTRY_VECTOR_STORES='[
  {"name":"ann","backend":"qdrant","url":"http://qdrant.internal:6333","collection":"np_vectors","allow_insecure_http":true},
  {"name":"pg","backend":"pgvector","postgres_url":"postgres://postgres.internal/nullpantry","table":"np_vectors"}
]'
```

Maintenance routes include `/v1/vector/status`, `/v1/vector/reconcile`, `/v1/vector/rebuild`, `/v1/vector/delete`, and `/v1/vector/search`.

## Providers

Provider-backed embeddings, Ask generation, and reranking are optional. Without provider config, NullPantry uses deterministic local embeddings and extractive citation-backed answers.

```sh
export NULLPANTRY_EMBEDDING_PROVIDER=openai-compatible
export NULLPANTRY_EMBEDDING_BASE_URL=https://api.example.com/v1
export NULLPANTRY_EMBEDDING_MODEL=text-embedding-model
export NULLPANTRY_EMBEDDING_API_KEY=...

export NULLPANTRY_LLM_BASE_URL=https://api.example.com/v1
export NULLPANTRY_LLM_MODEL=chat-model
export NULLPANTRY_LLM_API_KEY=...
```

Fallbacks and route hints are server-side JSON:

```sh
export NULLPANTRY_EMBEDDING_FALLBACKS='[
  {"provider":"voyage","api_key":"..."},
  {"provider":"ollama","base_url":"http://127.0.0.1:11434"},
  {"provider":"local-deterministic"}
]'
```

Request bodies cannot override provider URL, API key, timeout, response-byte limits, or insecure-HTTP policy.

## Graph, Analytics, And Lucid

Graph projections keep canonical Entity/Relation rows in the record store:

| Backend | Required Runtime Config |
| --- | --- |
| `neo4j` | `NULLPANTRY_GRAPH_BACKEND=neo4j`, `NULLPANTRY_NEO4J_URL` |
| `falkordb` | `NULLPANTRY_GRAPH_BACKEND=falkordb`, `NULLPANTRY_GRAPH_FALKORDB_URL`, `NULLPANTRY_GRAPH_FALKORDB_NAME` |

```sh
NULLPANTRY_GRAPH_BACKEND=neo4j \
NULLPANTRY_NEO4J_URL='http://127.0.0.1:7474' \
NULLPANTRY_GRAPH_ALLOW_INSECURE_HTTP=true \
zig build run -- --db .nullpantry/dev.db
```

ClickHouse analytics exports audit/feed history:

```sh
NULLPANTRY_ANALYTICS_BACKEND=clickhouse \
NULLPANTRY_ANALYTICS_BASE_URL='http://127.0.0.1:8123' \
NULLPANTRY_ANALYTICS_ALLOW_INSECURE_HTTP=true \
NULLPANTRY_ANALYTICS_TABLE='nullpantry_events' \
zig build run -- --db .nullpantry/dev.db
```

Lucid is an optional semantic projection:

```sh
NULLPANTRY_LUCID_ENABLED=true \
NULLPANTRY_LUCID_WORKSPACE='/srv/null-workspace' \
NULLPANTRY_LUCID_PROJECT_SCOPES='["public","project:nullpantry"]' \
zig build run -- --db .nullpantry/dev.db
```

Relevant status routes include `/v1/lifecycle/analytics/status` and `/v1/lifecycle/lucid/status`.

## Content And API Surfaces

Use the route group that matches the workflow:

| Workflow | Routes |
| --- | --- |
| NullClaw-compatible memory | `/v1/agent`, `/v1/memory` |
| Native agent memory and sessions | `/v1/agent-memory`, `/v1/agent-sessions` |
| Source-backed knowledge | sources, artifacts, memory atoms, entities, relations, lifecycle routes |
| Retrieval and context | `/v1/search`, `/v1/ask`, `/v1/context-packs`, `/v1/vector/*` |
| Prompt bootstrap | `/v1/bootstrap/prompts` |
| QMD ingestion | `/v1/connectors/qmd/ingest` |
| Provider metadata | `/v1/providers` |
| Manifest | `/v1/openapi.json` |

Markdown has two roles: live agent-memory runtime for NullClaw-style workspace files, and governed import/export where files become canonical Sources/Artifacts.

## Workers And Diagnostics

Background workers handle extraction, vector outbox operations, projection jobs, lifecycle tasks, analytics export, and maintenance flows.

```sh
export NULLPANTRY_WORKER_INTERVAL_MS=1000
export NULLPANTRY_WORKER_SCOPES='["admin"]'
export NULLPANTRY_WORKER_CAPABILITIES='["read","write","verify","delete","export","feed_apply"]'
```

Use status/diagnostic endpoints before trusting a deployment:

```sh
curl -sS -H 'Authorization: Bearer prod-secret' http://127.0.0.1:8765/v1/agent/health
curl -sS -H 'Authorization: Bearer prod-secret' http://127.0.0.1:8765/v1/vector/status
curl -sS -H 'Authorization: Bearer prod-secret' http://127.0.0.1:8765/v1/openapi.json
```

## External Contracts

Backend contracts are opt-in because they require real services.

```sh
NULLPANTRY_TEST_POSTGRES_URL='postgres://localhost/nullpantry_test' zig build postgres-contract --summary all
NULLPANTRY_TEST_REDIS_URL='redis://:password@localhost:6379/0' zig build redis-contract --summary all
NULLPANTRY_TEST_QDRANT_URL='http://localhost:6333' zig build qdrant-contract --summary all
NULLPANTRY_TEST_PGVECTOR_URL='postgres://localhost/nullpantry_test' zig build pgvector-contract --summary all
NULLPANTRY_TEST_CLICKHOUSE_URL='http://localhost:8123' zig build clickhouse-contract --summary all
NULLPANTRY_TEST_LANCEDB_URI='.nullpantry/lancedb-contract' NULLPANTRY_TEST_LANCEDB_COMMAND="$(command -v python3)" zig build lancedb-contract --summary all
zig build lucid-contract --summary all
```

`zig build runtime-contracts --summary all` aggregates the concrete runtime contracts and expects the corresponding `NULLPANTRY_TEST_*` values where a real backend is required.

## Security Checklist

- Require a token or token principals before binding to a non-loopback host.
- Use one token principal per agent or user in shared deployments.
- Keep write, verify, delete, export, and feed-apply capabilities separate.
- Keep provider/API/vector/analytics/graph URLs server-side; do not accept them from request bodies.
- Prefer HTTPS for non-local HTTP backends. Enable insecure HTTP only for intentional internal deployments.
- Prefer environment variables or protected config files for secrets; avoid passing tokens and database URLs as CLI flags because argv can be exposed by process listings and shell history.
- Keep files referenced by `NULLPANTRY_HOME` and `NULLPANTRY_CONFIG` service-owned and not group- or world-writable; avoid world-readable config files when they contain secrets.
- External CLI integrations such as ByteRover, LanceDB command mode, and Lucid run with a sanitized child environment. Use explicit command paths and service-local tool config instead of relying on inherited `NULLPANTRY_*` variables.
- Treat external memory, vector, graph, analytics, and Lucid systems as projections unless the docs explicitly call the backend canonical.
