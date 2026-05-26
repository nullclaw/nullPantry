#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${NULLPANTRY_BIN:-$ROOT_DIR/zig-out/bin/nullpantry}"
PORT="${NULLPANTRY_CONTRACT_PORT:-18765}"
TOKEN="${NULLPANTRY_CONTRACT_TOKEN:-contract-secret}"
DB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nullpantry-contract.XXXXXX")"
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

NULLPANTRY_TOKEN="$TOKEN" \
NULLPANTRY_SCOPES='["agent:nullclaw"]' \
NULLPANTRY_CAPABILITIES='["read","write","delete"]' \
NULLPANTRY_WORKER_INTERVAL_MS=0 \
"$BIN" --host 127.0.0.1 --port "$PORT" --db "$DB_PATH" >/tmp/nullpantry-contract.log 2>&1 &
SERVER_PID="$!"

i=0
while [ "$i" -lt 50 ]; do
  if curl --silent --fail "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done

auth_header="Authorization: Bearer $TOKEN"

curl --silent --fail \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"content":"Use Zig examples","category":"core","session_id":null}' \
  "$BASE_URL/memories/pref.lang" >/dev/null

curl --silent --fail \
  --header "$auth_header" \
  "$BASE_URL/memories/pref.lang" | grep '"content":"Use Zig examples"' >/dev/null

curl --silent --fail \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"role":"user","content":"hello"}' \
  "$BASE_URL/sessions/sess_contract/messages" >/dev/null

curl --silent --fail \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"total_tokens":123}' \
  "$BASE_URL/sessions/sess_contract/usage" >/dev/null

curl --silent --fail \
  --header "$auth_header" \
  "$BASE_URL/sessions/sess_contract/messages" | grep '"content":"hello"' >/dev/null

curl --silent --fail \
  --header "$auth_header" \
  "$BASE_URL/history?limit=10&offset=0" | grep '"session_id":"sess_contract"' >/dev/null

curl --silent --fail \
  --header "$auth_header" \
  "$BASE_URL/history/sess_contract?limit=10&offset=0" | grep '"content":"hello"' >/dev/null

curl --silent --fail \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/memories/pref.lang" >/dev/null

if curl --silent --header "$auth_header" "$BASE_URL/memories/pref.lang" | grep '"entry"' >/dev/null; then
  echo "deleted memory was still returned" >&2
  exit 1
fi

echo "NullClaw API compatibility contract passed"
