#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NULLCLAW_REPO="${NULLCLAW_REPO:-$ROOT_DIR/../nullclaw}"
CLONED_NULLCLAW_DIR=""
SERVER_PID=""
DB_DIR=""
CURL_TIMEOUT_ARGS="--connect-timeout 2 --max-time 5"

cleanup() {
  if [ "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ "${DB_DIR:-}" ]; then
    rm -rf "$DB_DIR"
  fi
  if [ "$CLONED_NULLCLAW_DIR" ]; then
    rm -rf "$CLONED_NULLCLAW_DIR"
  fi
}
trap cleanup EXIT INT TERM

if ! git -C "$NULLCLAW_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$NULLCLAW_REPO/nullclaw" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    NULLCLAW_REPO="$NULLCLAW_REPO/nullclaw"
  elif git -C "$ROOT_DIR/../nullClaw/nullclaw" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    NULLCLAW_REPO="$ROOT_DIR/../nullClaw/nullclaw"
  fi
fi

if ! git -C "$NULLCLAW_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "${NULLPANTRY_ALLOW_NULLCLAW_RUNTIME_SKIP:-0}" = "1" ]; then
    echo "NullClaw runtime contract skipped by NULLPANTRY_ALLOW_NULLCLAW_RUNTIME_SKIP=1." >&2
    exit 0
  fi
  CLONED_NULLCLAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nullclaw-runtime-contract.XXXXXX")"
  git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone --depth 1 "${NULLCLAW_GIT_URL:-https://github.com/nullclaw/nullclaw.git}" "$CLONED_NULLCLAW_DIR" >/dev/null 2>&1
  NULLCLAW_REPO="$CLONED_NULLCLAW_DIR"
fi

if [ "${NULLCLAW_REF:-}" ]; then
  git -C "$NULLCLAW_REPO" fetch --depth 1 origin "$NULLCLAW_REF" >/dev/null 2>&1 || true
  git -C "$NULLCLAW_REPO" checkout "$NULLCLAW_REF" >/dev/null 2>&1
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

echo "NullClaw runtime source contract passed; running live NullPantry compatibility smoke." >&2

BIN="${NULLPANTRY_BIN:-$ROOT_DIR/zig-out/bin/nullpantry}"
PORT="${NULLPANTRY_RUNTIME_CONTRACT_PORT:-18766}"
TOKEN="${NULLPANTRY_RUNTIME_CONTRACT_TOKEN:-runtime-contract-secret}"
DB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nullpantry-nullclaw-runtime.XXXXXX")"
DB_PATH="$DB_DIR/nullpantry.db"
BASE_URL="http://127.0.0.1:$PORT/v1/nullclaw"
AUTH_HEADER="Authorization: Bearer $TOKEN"

NULLPANTRY_TOKEN_PRINCIPALS="{\"$TOKEN\":{\"actor_id\":\"nullclaw-runtime-contract\",\"scopes\":[\"agent:nullclaw\",\"session:*\",\"write:session:*\"],\"capabilities\":[\"read\",\"write\",\"delete\"]}}" \
NULLPANTRY_WORKER_INTERVAL_MS=0 \
"$BIN" --host 127.0.0.1 --port "$PORT" --db "$DB_PATH" >/tmp/nullpantry-nullclaw-runtime.log 2>&1 &
SERVER_PID="$!"

i=0
while [ "$i" -lt 50 ]; do
  if curl --silent --fail $CURL_TIMEOUT_ARGS "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

if ! curl --silent --fail $CURL_TIMEOUT_ARGS "$BASE_URL/health" >/dev/null 2>&1; then
  echo "NullClaw runtime contract failed: NullPantry did not become healthy." >&2
  tail -100 /tmp/nullpantry-nullclaw-runtime.log >&2 || true
  exit 1
fi

curl_json() {
  method="$1"
  url="$2"
  data="${3:-}"
  if [ "$data" ]; then
    curl --silent --fail $CURL_TIMEOUT_ARGS -H "$AUTH_HEADER" -H "Content-Type: application/json" -X "$method" "$url" --data "$data"
  else
    curl --silent --fail $CURL_TIMEOUT_ARGS -H "$AUTH_HEADER" -X "$method" "$url"
  fi
}

curl_json PUT "$BASE_URL/memories/runtime.pref" '{"content":"Runtime contract memory","category":"core","session_id":null}' | grep -F '"ok":true' >/dev/null
curl_json GET "$BASE_URL/memories/runtime.pref" | grep -F 'Runtime contract memory' >/dev/null
curl_json POST "$BASE_URL/memories/search" '{"query":"Runtime contract","limit":5}' | grep -F 'Runtime contract memory' >/dev/null
curl_json GET "$BASE_URL/memories/count" | grep -F '"count":' >/dev/null
curl_json POST "$BASE_URL/sessions/sess_runtime/messages" '{"role":"user","content":"hello"}' | grep -F '"ok":true' >/dev/null
curl_json PUT "$BASE_URL/sessions/sess_runtime/usage" '{"total_tokens":42}' | grep -F '"ok":true' >/dev/null
curl_json GET "$BASE_URL/sessions/sess_runtime/messages" | grep -F '"content":"hello"' >/dev/null
curl_json GET "$BASE_URL/sessions/sess_runtime/usage" | grep -F '"total_tokens":42' >/dev/null
curl_json GET "$BASE_URL/history?limit=10&offset=0" | grep -F '"session_id":"sess_runtime"' >/dev/null

if [ "${NULLPANTRY_RUN_NULLCLAW_TESTS:-0}" != "1" ]; then
  echo "NullClaw live compatibility smoke passed. Set NULLPANTRY_RUN_NULLCLAW_TESTS=1 to also run nullclaw's Zig test suite against memory.backend=api." >&2
  exit 0
fi

(
  cd "$NULLCLAW_REPO"
  env \
    NULLCLAW_MEMORY_BACKEND=api \
    NULLCLAW_MEMORY_API_URL="$BASE_URL" \
    NULLCLAW_MEMORY_API_BASE_URL="$BASE_URL" \
    NULLCLAW_MEMORY_API_TOKEN="$TOKEN" \
    NULLCLAW_API_MEMORY_URL="$BASE_URL" \
    NULLCLAW_API_MEMORY_TOKEN="$TOKEN" \
    zig build test --summary all &
  TEST_PID="$!"
  elapsed=0
  timeout_secs="${NULLPANTRY_NULLCLAW_TEST_TIMEOUT_SECS:-180}"
  while kill -0 "$TEST_PID" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$timeout_secs" ]; then
      kill "$TEST_PID" >/dev/null 2>&1 || true
      wait "$TEST_PID" >/dev/null 2>&1 || true
      echo "NullClaw runtime contract failed: nullclaw test suite timed out after ${timeout_secs}s. Set NULLPANTRY_RUN_NULLCLAW_TESTS=0 for source-shape mode." >&2
      exit 1
    fi
    elapsed=$((elapsed + 1))
    sleep 1
  done
  wait "$TEST_PID"
)
