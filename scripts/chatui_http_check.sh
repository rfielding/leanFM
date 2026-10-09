#!/usr/bin/env bash
# Requirement refs: leanfm.chatui, proof:Concurrent BYOK isolation,
# proof:Keyless launch cannot spend provider funds, task:manage_projects.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /tmp/leanfm-chatui-check.XXXXXX)"
server_log="$test_root/server.log"
provider_log="$test_root/provider.log"
cookie_a="$test_root/a.cookies"
cookie_b="$test_root/b.cookies"

cleanup() {
  status=$?
  if [[ $status -ne 0 ]]; then
    echo "--- ChatUI server log ---" >&2
    test -f "$server_log" && tail -80 "$server_log" >&2 || true
    echo "--- provider stub log ---" >&2
    test -f "$provider_log" && tail -80 "$provider_log" >&2 || true
    echo "--- chat responses ---" >&2
    test -f "$test_root/chat-a.json" && cat "$test_root/chat-a.json" >&2 || true
    test -f "$test_root/chat-b.json" && cat "$test_root/chat-b.json" >&2 || true
  fi
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  if [[ -n "${provider_pid:-}" ]]; then kill "$provider_pid" 2>/dev/null || true; fi
  rm -rf -- "$test_root"
  exit "$status"
}
trap cleanup EXIT

cd "$repo_root"
python3 scripts/chatui_provider_stub.py >"$provider_log" 2>&1 &
provider_pid=$!
LEANFM_DATA_ROOT="$test_root/data" \
LEANFM_OPENAI_BASE_URL="http://127.0.0.1:18080/v1" \
LEANFM_LLM_MODEL="test-model" \
  .lake/build/bin/leanfm-server >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
  curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1 && break
  sleep 0.1
done

root_html="$(curl -fsS http://127.0.0.1:8080/)"
rg -q 'What are we building|Create account|Diagrams / Artifacts' <<<"$root_html"
test "$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/me)" = 401

register() {
  local username="$1" cookie="$2" key="$3"
  curl -fsS -c "$cookie" -b "$cookie" \
    --data-urlencode "username=$username" \
    --data-urlencode 'password=correct horse battery staple' \
    --data-urlencode 'provider=openai' \
    --data-urlencode "api_key=$key" \
    http://127.0.0.1:8080/api/accounts | rg -q "\"username\":\"$username\""
}

register rfielding "$cookie_a" test-user-key
register second_user "$cookie_b" second-user-key

test -f "$test_root/data/accounts/rfielding/credentials/default.json"
test ! -e "$test_root/data/accounts/rfielding/credentials/default.b64"
test ! -d "$test_root/data/accounts/rfielding/sessions"
! rg -q 'dGVzdC11c2VyLWtleQ==' "$test_root/data"
! rg -q 'test-user-key|second-user-key|correct horse battery staple' "$test_root/data"

create_project() {
  local cookie="$1" name="$2"
  curl -fsS -b "$cookie" --data-urlencode "display_name=$name" http://127.0.0.1:8080/api/projects |
    sed -n 's/.*"project_id":"\([^"]*\)".*/\1/p'
}

project_a="$(create_project "$cookie_a" LeanFM)"
project_b="$(create_project "$cookie_b" Separate)"
test -n "$project_a" && test -n "$project_b" && test "$project_a" != "$project_b"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/book/main.pdf"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Requirements.lean"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Requirements.proto"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Implementation.lean"
test -d "$test_root/data/accounts/rfielding/projects/$project_a/events"

curl -sS -b "$cookie_a" --data-urlencode 'prompt=make a state machine' \
  "http://127.0.0.1:8080/api/projects/$project_a/chat" >"$test_root/chat-a.json" &
chat_a_pid=$!
curl -sS -b "$cookie_b" --data-urlencode 'prompt=keep this separate' \
  "http://127.0.0.1:8080/api/projects/$project_b/chat" >"$test_root/chat-b.json" &
chat_b_pid=$!
wait "$chat_a_pid" "$chat_b_pid"

rg -q '"input_tokens":11.*"cached_input_tokens":3.*"output_tokens":7.*"total_tokens":18' "$test_root/chat-a.json"
rg -q '"input_tokens":11.*"cached_input_tokens":3.*"output_tokens":7.*"total_tokens":18' "$test_root/chat-b.json"
curl -fsS -b "$cookie_a" "http://127.0.0.1:8080/api/projects/$project_a/artifacts" | rg -q '"kind":"mermaid"'
test "$(curl -sS -b "$cookie_b" -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/api/projects/$project_a/conversation")" = 404
rg -q 'make a state machine' <(curl -fsS -b "$cookie_a" "http://127.0.0.1:8080/api/projects/$project_a/conversation")
! rg -q 'keep this separate' <(curl -fsS -b "$cookie_a" "http://127.0.0.1:8080/api/projects/$project_a/conversation")

echo 'ok: ChatUI bootstrap, usage, artifacts, and concurrent session isolation'

# Requirement: password verification precedes migration; copied sessions cannot spend.
login_status() {
  curl -sS -o /dev/null -w '%{http_code}' --data-urlencode 'username=rfielding' \
    --data-urlencode "password=$1" http://127.0.0.1:8080/api/login
}
rg -q 'alice response' "$test_root/chat-a.json"
rg -q 'bob response' "$test_root/chat-b.json"
cp "$test_root/data/accounts/rfielding/credentials/default.json" "$test_root/original.json"
cp "$test_root/data/accounts/second_user/credentials/default.json" "$test_root/data/accounts/rfielding/credentials/default.json"
test "$(login_status 'correct horse battery staple')" = 403
cp "$test_root/original.json" "$test_root/data/accounts/rfielding/credentials/default.json"
printf '%s\n' 'dGVzdC11c2VyLWtleQ==' > "$test_root/data/accounts/rfielding/credentials/default.b64"
printf '%s' '' > "$test_root/data/accounts/rfielding/credentials/default.json"
test "$(login_status 'correct horse battery staple')" = 403
rm "$test_root/data/accounts/rfielding/credentials/default.json"
test "$(login_status wrong-password)" = 403
test -f "$test_root/data/accounts/rfielding/credentials/default.b64"
test "$(login_status 'correct horse battery staple')" = 200
test ! -f "$test_root/data/accounts/rfielding/credentials/default.b64"
test -f "$test_root/data/accounts/rfielding/credentials/default.json"
test "$(stat -c %a "$test_root/data/accounts/rfielding/credentials/default.json")" = 600
kill "$server_pid"
wait "$server_pid" || true
LEANFM_DATA_ROOT="$test_root/data" LEANFM_OPENAI_BASE_URL="http://127.0.0.1:18080/v1" \
  .lake/build/bin/leanfm-server >"$server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1 && break
  sleep 0.1
done
test "$(curl -sS -b "$cookie_a" -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/me)" = 401
echo 'ok: encrypted credentials, account isolation, migration and restart invalidation'
