# NullPantry

NullPantry is the headless, agent-native knowledge base for the Null ecosystem.

It stores sources, artifacts, memory atoms, entities, relations, context packs, and a NullClaw-compatible remote memory surface. UI belongs in NullHub/NullDesk; this repository exposes storage, retrieval, lifecycle, and API primitives.

## Quick Start

```sh
zig build test
zig build run -- --db .nullpantry/nullpantry.db --token dev-secret
```

CI, nightly, and release builds are delegated to `nullclaw/nullbuilder`.

`--actor-scopes` or `NULLPANTRY_SCOPES` defines the server-side scopes granted to the configured token. The default local/dev scope is `["admin"]`; production deployments should set explicit scopes such as `["workspace","agent:nullclaw","project:nullpantry"]`.

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

## Storage Status

SQLite is the working local/dev/test backend and includes relational tables, FTS5 indexes, lifecycle status, audit events, context packs, and the NullClaw compatibility projection.

Postgres DDL is included for the production schema with relational tables, full-text `tsvector` indexes, and `pgvector` storage. The runtime CRUD adapter is intentionally still thin until the repo chooses a native Postgres client or a deployment contract for `libpq`.

## Build System

NullPantry uses `nullbuilder` for GitHub CI, nightly artifacts, and tagged releases through reusable workflows in `.github/workflows`. SQLite is vendored under `vendor/sqlite3` so nullbuilder can cross-compile release binaries without relying on host system libraries.
