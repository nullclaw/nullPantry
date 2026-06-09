# Testing

NullPantry keeps the default test command fast and makes heavier suites explicit.

## Daily Loop

```sh
# Fast build/config/profile smoke tests.
zig build test

# Same fast suite with an explicit name.
zig build test-fast

# Full local suite that includes the server entrypoint, API, storage, worker,
# runtime, and skipped external contracts.
zig build test-local --summary all
```

Use `test-local` before pushing changes that touch request handling, API routes, storage, jobs, runtime configuration, or permissions. Use `test`/`test-fast` while iterating on small build-profile and module-boundary changes.

## Directional Suites

These targets run the server-entrypoint test binary with a focused Zig test filter:

```sh
zig build test-api
zig build test-store
zig build test-agent-memory
zig build test-vector
zig build test-retrieval
zig build test-worker
zig build test-provider
zig build test-runtime
```

They are meant for local feedback by area. They do not replace `test-local` when a change crosses boundaries, but they are much easier to run while working inside one subsystem.

For a narrower ad-hoc filter, use the underlying server test target directly:

```sh
zig build test-server -Dtest-filter='auth'
zig build test-server -Dtest-filter='sqlite vector'
```

## Local And Matrix Gates

```sh
# Fast + server-entrypoint tests.
zig build test-local

# Local suite plus aggregate import coverage.
zig build test-all-local

# Minimal, default nullclaw, and full engine profile matrix.
zig build test-matrix

# Full compile-time engine profile.
zig build test-full-engine
```

`zig build test -Dserver-tests=true` is still available when a script wants the old default behavior without changing the step name. `-Dfull-import-tests=true` adds aggregate import coverage to `zig build test`; it is ignored for `-Dengine-profile=minimal`.

## GitHub Gates

Pull requests into `main` run the required `CI` baseline matrix on Linux, macOS, and Windows. Each matrix job runs:

```sh
zig build test --summary all
zig build --summary all
```

These checks are intentionally small enough to stay required for every merge. Full engine import checks and external runtime contracts can be run without publishing artifacts from the manual `Contracts` workflow. The `Release` workflow runs the same verification on `v*` tags or manual dispatch before release artifacts are published.

## External Contracts

Concrete backend contracts stay opt-in because they require external services:

```sh
NULLPANTRY_TEST_POSTGRES_URL='postgres://localhost/nullpantry_test' zig build postgres-contract
NULLPANTRY_TEST_REDIS_URL='redis://:password@localhost:6379/0' zig build redis-contract
NULLPANTRY_TEST_QDRANT_URL='http://localhost:6333' zig build qdrant-contract
NULLPANTRY_TEST_PGVECTOR_URL='postgres://localhost/nullpantry_test' zig build pgvector-contract
NULLPANTRY_TEST_CLICKHOUSE_URL='http://localhost:8123' zig build clickhouse-contract
NULLPANTRY_TEST_LANCEDB_URI='.nullpantry/lancedb-contract' NULLPANTRY_TEST_LANCEDB_COMMAND="$(command -v python3)" zig build lancedb-contract
zig build lucid-contract
```

`zig build runtime-contracts` aggregates the concrete runtime contracts and expects the corresponding `NULLPANTRY_TEST_*` settings where the backend is not fakeable.
