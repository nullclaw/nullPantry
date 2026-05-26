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
NULLPANTRY_SCOPES='["agent:nullclaw","session:*","write:session:*"]' \
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

fail() {
  echo "$1" >&2
  if [ -f /tmp/nullpantry-contract.log ]; then
    tail -100 /tmp/nullpantry-contract.log >&2 || true
  fi
  exit 1
}

curl_ok() {
  curl --silent --show-error --fail "$@" || fail "curl request failed: $*"
}

curl_status() {
  curl --silent --show-error --output "$DB_DIR/response.json" --write-out "%{http_code}" "$@"
}

expect_contains() {
  body="$1"
  needle="$2"
  if ! printf '%s' "$body" | grep -F "$needle" >/dev/null; then
    fail "expected response to contain: $needle; body=$body"
  fi
}

expect_not_contains() {
  body="$1"
  needle="$2"
  if printf '%s' "$body" | grep -F "$needle" >/dev/null; then
    fail "expected response not to contain: $needle; body=$body"
  fi
}

expect_status() {
  expected="$1"
  shift
  status="$(curl_status "$@")"
  if [ "$status" != "$expected" ]; then
    body="$(cat "$DB_DIR/response.json" 2>/dev/null || true)"
    fail "expected HTTP $expected, got $status; body=$body"
  fi
}

health_body="$(curl_ok "$BASE_URL/health")"
expect_contains "$health_body" '"service":"nullpantry"'

curl_ok \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"content":"Global remote memory","category":"custom.cat","session_id":null}' \
  "$BASE_URL/memories/key%20with%20spaces" >/dev/null

curl_ok \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"content":"Scoped remote memory","category":"custom.cat","session_id":"sess id=1"}' \
  "$BASE_URL/memories/key%20with%20spaces" >/dev/null

global_body="$(curl_ok --header "$auth_header" "$BASE_URL/memories/key%20with%20spaces")"
expect_contains "$global_body" '"entry"'
expect_contains "$global_body" '"key":"key with spaces"'
expect_contains "$global_body" '"content":"Global remote memory"'
expect_contains "$global_body" '"category":"custom.cat"'
expect_contains "$global_body" '"session_id":null'
expect_contains "$global_body" '"score":'
expect_not_contains "$global_body" 'Scoped remote memory'

scoped_body="$(curl_ok --header "$auth_header" "$BASE_URL/memories/key%20with%20spaces?session_id=sess%20id%3D1")"
expect_contains "$scoped_body" '"content":"Scoped remote memory"'
expect_contains "$scoped_body" '"session_id":"sess id=1"'

scoped_list="$(curl_ok --header "$auth_header" "$BASE_URL/memories?category=custom.cat&session_id=sess%20id%3D1")"
expect_contains "$scoped_list" '"entries"'
expect_contains "$scoped_list" '"content":"Scoped remote memory"'
expect_not_contains "$scoped_list" 'Global remote memory'

scoped_search="$(curl_ok \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"query":"Scoped remote","limit":10,"session_id":"sess id=1"}' \
  "$BASE_URL/memories/search")"
expect_contains "$scoped_search" '"entries"'
expect_contains "$scoped_search" '"content":"Scoped remote memory"'
expect_not_contains "$scoped_search" 'Global remote memory'

count_body="$(curl_ok --header "$auth_header" "$BASE_URL/memories/count")"
expect_contains "$count_body" '"count":2'

expect_status 404 --header "$auth_header" "$BASE_URL/memories/session.only"
curl_ok \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"content":"Session only memory","category":"core","session_id":"sess_contract"}' \
  "$BASE_URL/memories/session.only" >/dev/null
expect_status 404 --header "$auth_header" "$BASE_URL/memories/session.only"
session_only="$(curl_ok --header "$auth_header" "$BASE_URL/memories/session.only?session_id=sess_contract")"
expect_contains "$session_only" '"content":"Session only memory"'

curl_ok \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"role":"user","content":"hello"}' \
  "$BASE_URL/sessions/agent%3Acoder/messages" >/dev/null
curl_ok \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"role":"autosave_user","content":"draft"}' \
  "$BASE_URL/sessions/agent%3Acoder/messages" >/dev/null
curl_ok \
  --request POST \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"role":"assistant","content":"world"}' \
  "$BASE_URL/sessions/agent%3Acoder/messages" >/dev/null

messages_body="$(curl_ok --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/messages")"
expect_contains "$messages_body" '"messages"'
expect_contains "$messages_body" '"role":"user"'
expect_contains "$messages_body" '"content":"hello"'
expect_contains "$messages_body" '"content":"draft"'

curl_ok \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"total_tokens":321}' \
  "$BASE_URL/sessions/agent%3Acoder/usage" >/dev/null
usage_body="$(curl_ok --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/usage")"
expect_contains "$usage_body" '"total_tokens":321'

history_body="$(curl_ok --header "$auth_header" "$BASE_URL/history?limit=10&offset=0")"
expect_contains "$history_body" '"session_id":"agent:coder"'
expect_contains "$history_body" '"message_count":3'
expect_contains "$history_body" '"first_message_at":"'
expect_contains "$history_body" '"last_message_at":"'

detail_body="$(curl_ok --header "$auth_header" "$BASE_URL/history/agent%3Acoder?limit=10&offset=0")"
expect_contains "$detail_body" '"session_id":"agent:coder"'
expect_contains "$detail_body" '"content":"hello"'
expect_contains "$detail_body" '"created_at":"'

expect_status 403 \
  --header "$auth_header" \
  --header 'X-NullPantry-Actor-Scopes: ["agent:nullclaw"]' \
  "$BASE_URL/sessions/agent%3Acoder/messages"

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/sessions/auto-saved?session_id=agent%3Acoder" >/dev/null
after_autosave="$(curl_ok --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/messages")"
expect_contains "$after_autosave" '"content":"hello"'
expect_not_contains "$after_autosave" '"content":"draft"'

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/sessions/agent%3Acoder/usage" >/dev/null
expect_status 404 --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/usage"
curl_ok \
  --request PUT \
  --header "$auth_header" \
  --header "Content-Type: application/json" \
  --data '{"total_tokens":321}' \
  "$BASE_URL/sessions/agent%3Acoder/usage" >/dev/null

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/sessions/agent%3Acoder/messages" >/dev/null
empty_messages="$(curl_ok --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/messages")"
expect_contains "$empty_messages" '"messages":[]'
expect_status 404 --header "$auth_header" "$BASE_URL/sessions/agent%3Acoder/usage"

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/memories/session.only?session_id=sess_contract" >/dev/null
expect_status 404 --header "$auth_header" "$BASE_URL/memories/session.only?session_id=sess_contract"

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/memories/key%20with%20spaces?session_id=sess%20id%3D1" >/dev/null
expect_status 404 --header "$auth_header" "$BASE_URL/memories/key%20with%20spaces?session_id=sess%20id%3D1"

still_global="$(curl_ok --header "$auth_header" "$BASE_URL/memories/key%20with%20spaces")"
expect_contains "$still_global" '"content":"Global remote memory"'

curl_ok \
  --request DELETE \
  --header "$auth_header" \
  "$BASE_URL/memories/key%20with%20spaces" >/dev/null

if curl --silent --header "$auth_header" "$BASE_URL/memories/key%20with%20spaces" | grep -F '"entry"' >/dev/null; then
  echo "deleted memory was still returned" >&2
  exit 1
fi

echo "NullClaw API compatibility contract passed"
