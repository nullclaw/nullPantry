#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NULLCLAW_REPO="${NULLCLAW_REPO:-$ROOT_DIR/../nullclaw}"

if ! git -C "$NULLCLAW_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "NullClaw runtime contract skipped: set NULLCLAW_REPO to a git checkout of nullclaw." >&2
  exit 0
fi

API_ENGINE="$NULLCLAW_REPO/src/memory/engines/api.zig"
if [ ! -f "$API_ENGINE" ]; then
  echo "NullClaw runtime contract failed: missing src/memory/engines/api.zig in $NULLCLAW_REPO" >&2
  exit 1
fi

require_source_shape() {
  needle="$1"
  if ! grep -F "$needle" "$API_ENGINE" >/dev/null 2>&1; then
    echo "NullClaw runtime contract failed: api.zig does not contain expected shape: $needle" >&2
    exit 1
  fi
}

require_source_shape "/memories"
require_source_shape "/memories/search"
require_source_shape "/memories/count"
require_source_shape "/health"
require_source_shape "session_id"
require_source_shape "total_tokens"

if [ "${NULLPANTRY_RUN_NULLCLAW_TESTS:-0}" != "1" ]; then
  echo "NullClaw runtime source contract passed. Set NULLPANTRY_RUN_NULLCLAW_TESTS=1 to also run nullclaw's Zig test suite against memory.backend=api." >&2
  exit 0
fi

BIN="${NULLPANTRY_BIN:-$ROOT_DIR/zig-out/bin/nullpantry}"
PORT="${NULLPANTRY_RUNTIME_CONTRACT_PORT:-18766}"
TOKEN="${NULLPANTRY_RUNTIME_CONTRACT_TOKEN:-runtime-contract-secret}"
DB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nullpantry-nullclaw-runtime.XXXXXX")"
DB_PATH="$DB_DIR/nullpantry.db"
BASE_URL="http://127.0.0.1:$PORT/v1/nullclaw"

cleanup() {
  if [ "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$DB_DIR"
}
trap cleanup EXIT INT TERM

NULLPANTRY_TOKEN_PRINCIPALS="{\"$TOKEN\":{\"actor_id\":\"nullclaw-runtime-contract\",\"scopes\":[\"agent:nullclaw\",\"session:*\",\"write:session:*\"],\"capabilities\":[\"read\",\"write\",\"delete\"]}}" \
NULLPANTRY_WORKER_INTERVAL_MS=0 \
"$BIN" --host 127.0.0.1 --port "$PORT" --db "$DB_PATH" >/tmp/nullpantry-nullclaw-runtime.log 2>&1 &
SERVER_PID="$!"

i=0
while [ "$i" -lt 50 ]; do
  if curl --silent --fail "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

if ! curl --silent --fail "$BASE_URL/health" >/dev/null 2>&1; then
  echo "NullClaw runtime contract failed: NullPantry did not become healthy." >&2
  tail -100 /tmp/nullpantry-nullclaw-runtime.log >&2 || true
  exit 1
fi

(
  cd "$NULLCLAW_REPO"
  NULLCLAW_MEMORY_BACKEND=api \
  NULLCLAW_MEMORY_API_URL="$BASE_URL" \
  NULLCLAW_MEMORY_API_BASE_URL="$BASE_URL" \
  NULLCLAW_MEMORY_API_TOKEN="$TOKEN" \
  NULLCLAW_API_MEMORY_URL="$BASE_URL" \
  NULLCLAW_API_MEMORY_TOKEN="$TOKEN" \
  zig build test --summary all
)
