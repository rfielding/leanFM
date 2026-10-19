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
server_port=18081
base_url="http://127.0.0.1:$server_port"
data_root_setting="$(realpath --relative-to="$repo_root" "$test_root/data")"

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
    test -f "$test_root/book-update.json" && cat "$test_root/book-update.json" >&2 || true
    test -f "$test_root/book-repair.json" && cat "$test_root/book-repair.json" >&2 || true
    test -f "$test_root/source-write.json" && cat "$test_root/source-write.json" >&2 || true
    test -f "$test_root/empty-source-implementation.json" && cat "$test_root/empty-source-implementation.json" >&2 || true
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
# Exercise the production-relevant relative-root configuration while assertions
# continue to inspect the same canonical temporary directory.
LEANFM_DATA_ROOT="$data_root_setting" \
LEANFM_OPENAI_BASE_URL="http://127.0.0.1:18080/v1" \
LEANFM_LLM_MODEL="test-model" \
LEANFM_LLM_MODELS="test-model,test-model-fast" \
LEANFM_TEST_UNSANDBOXED_BOOK_BUILD=1 \
LEANFM_PORT="$server_port" \
  .lake/build/bin/leanfm-server >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
  curl -fsS "$base_url/health" >/dev/null 2>&1 && break
  sleep 0.1
done

root_html="$(curl -fsS $base_url/)"
rg -q '<div id="root"></div>' <<<"$root_html"
rg -q '/assets/chatui-react1.js' <<<"$root_html"
react_bundle="$(curl -fsS $base_url/assets/chatui-react1.js)"
rg -q 'Create account' <<<"$react_bundle"
rg -q 'Project book' <<<"$react_bundle"
rg -q 'Project memory' <<<"$react_bundle"
rg -q 'phase-panel' <<<"$react_bundle"
rg -q 'project-panel' <<<"$react_bundle"
rg -q 'You can inspect any project or phase while it runs' <<<"$react_bundle"
rg -q 'Cancel requested' <<<"$react_bundle"
rg -q 'Model for new prompts' <<<"$react_bundle"
rg -q 'Long-running model or tool work is still active' <<<"$react_bundle"
test "$(curl -sS -o /dev/null -w '%{http_code}' $base_url/api/me)" = 401

register() {
  local username="$1" cookie="$2" key="$3"
  curl --fail-with-body -sS -c "$cookie" -b "$cookie" \
    --data-urlencode "username=$username" \
    --data-urlencode 'password=correct horse battery staple' \
    --data-urlencode 'provider=openai' \
    --data-urlencode "api_key=$key" \
    $base_url/api/accounts | rg -q "\"username\":\"$username\""
}

register rfielding "$cookie_a" test-user-key
register second_user "$cookie_b" second-user-key

me_json="$(curl -fsS -b "$cookie_a" $base_url/api/me)"
rg -q '"provider":"openai"' <<<"$me_json"
rg -q '"credential_ref":"default"' <<<"$me_json"
rg -q '"key_fingerprint":"[0-9a-f]{12}"' <<<"$me_json"
rg -q '"model":"test-model"' <<<"$me_json"
rg -q '"models":\["test-model","test-model-fast"\]' <<<"$me_json"
rg -q '"tokens_used":0' <<<"$me_json"
rg -q '"tokens_remaining":1000000' <<<"$me_json"

projects_json="$(curl -fsS -b "$cookie_a" $base_url/api/projects)"
rg -q '"project_id":"leanfm-workspace".*"read_only":true' <<<"$projects_json"
rg -q '"project_id":"go-server-example".*"read_only":true' <<<"$projects_json"
test "$(curl -sS -b "$cookie_a" -o /dev/null -w '%{http_code}' "$base_url/api/projects/leanfm-workspace/source/.git/config")" = 404

test -f "$test_root/data/accounts/rfielding/credentials/default.json"
test ! -e "$test_root/data/accounts/rfielding/credentials/default.b64"
test ! -d "$test_root/data/accounts/rfielding/sessions"
! rg -q 'dGVzdC11c2VyLWtleQ==' "$test_root/data"
! rg -q 'test-user-key|second-user-key|correct horse battery staple' "$test_root/data"

create_project() {
  local cookie="$1" name="$2"
  curl --fail-with-body -sS -b "$cookie" --data-urlencode "display_name=$name" $base_url/api/projects |
    sed -n 's/.*"project_id":"\([^"]*\)".*/\1/p'
}

project_a="$(create_project "$cookie_a" LeanFM)"
project_b="$(create_project "$cookie_b" Separate)"
test -n "$project_a" && test -n "$project_b" && test "$project_a" != "$project_b"
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/tasks" >"$test_root/tasks.json"
rg -q '"source":".*/spec/Requirements.lean".*"validation":.*"tasks":' "$test_root/tasks.json"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/book/main.pdf"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Requirements.lean"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Requirements.proto"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/spec/Implementation.lean"
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/memory" >"$test_root/project-memory.json"
rg -q '"id":"book".*"status":"bootstrap"' "$test_root/project-memory.json"
rg -q '"id":"requirements".*"status":"bootstrap"' "$test_root/project-memory.json"
rg -q '"id":"implementation".*"status":"bootstrap"' "$test_root/project-memory.json"
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/memory/requirements" | rg -q 'Project-owned observable requirements'
test "$(curl -sS -b "$cookie_b" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/memory")" = 404
test "$(curl -sS -b "$cookie_a" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/memory/../../manifest.json")" = 404
test -d "$test_root/data/accounts/rfielding/projects/$project_a/events"
curl -fsS -b "$cookie_a" --data-urlencode 'prompt=TEST_MODEL_SELECTION report the selected model' \
  --data-urlencode 'model=test-model-fast' "$base_url/api/projects/$project_a/chat" >"$test_root/model-selection.json"
rg -q 'selected model: test-model-fast' "$test_root/model-selection.json"
rg -q '"model":"test-model-fast"' "$test_root/model-selection.json"
rg -q '"model":"test-model-fast"' <(curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/conversation")
test "$(curl -sS -b "$cookie_a" --data-urlencode 'prompt=TEST_INVALID_MODEL must not persist' --data-urlencode 'model=not-allowed' -o "$test_root/invalid-model.json" -w '%{http_code}' "$base_url/api/projects/$project_a/chat")" = 400
rg -q 'configured allowlist' "$test_root/invalid-model.json"
! rg -q 'TEST_INVALID_MODEL' <(curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/conversation")
printf '%s\n' 'package main' > "$test_root/data/accounts/rfielding/projects/$project_a/source/main.go"
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/source" | rg -q '"files":\["main.go"\]'
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/source/main.go" | rg -q '"source":"package main\\n"'
test "$(curl -sS -b "$cookie_b" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/source/main.go")" = 404

book_url="$base_url/api/projects/$project_a/book/main.pdf"
book_size="$(wc -c < "$test_root/data/accounts/rfielding/projects/$project_a/book/main.pdf")"
curl -sS -b "$cookie_a" -H 'Range: bytes=0-15' -D "$test_root/range-closed.headers" -o "$test_root/range-closed.bin" "$book_url"
rg -qi '^HTTP/1.1 206 Partial Content' "$test_root/range-closed.headers"
rg -qi "^Content-Range: bytes 0-15/$book_size" "$test_root/range-closed.headers"
rg -qi '^Accept-Ranges: bytes' "$test_root/range-closed.headers"
test "$(wc -c < "$test_root/range-closed.bin")" = 16
curl -sS -b "$cookie_a" -H 'Range: bytes=-10' -D "$test_root/range-suffix.headers" -o "$test_root/range-suffix.bin" "$book_url"
rg -qi '^HTTP/1.1 206 Partial Content' "$test_root/range-suffix.headers"
test "$(wc -c < "$test_root/range-suffix.bin")" = 10
curl -sS -b "$cookie_a" -H 'Range: bytes=16-' -D "$test_root/range-open.headers" -o "$test_root/range-open.bin" "$book_url"
rg -qi '^HTTP/1.1 206 Partial Content' "$test_root/range-open.headers"
test "$(wc -c < "$test_root/range-open.bin")" = "$((book_size - 16))"
test "$(curl -sS -b "$cookie_a" -H "Range: bytes=$book_size-" -o /dev/null -w '%{http_code}' "$book_url")" = 416
test "$(curl -sS -b "$cookie_a" -H 'Range: bytes=0-1,4-5' -o /dev/null -w '%{http_code}' "$book_url")" = 416

curl -sS -b "$cookie_a" --data-urlencode 'prompt=make a state machine' \
  "$base_url/api/projects/$project_a/chat" >"$test_root/chat-a.json" &
chat_a_pid=$!
curl -sS -b "$cookie_b" --data-urlencode 'prompt=keep this separate' \
  "$base_url/api/projects/$project_b/chat" >"$test_root/chat-b.json" &
chat_b_pid=$!
wait "$chat_a_pid" "$chat_b_pid"

rg -q '"input_tokens":11.*"cached_input_tokens":3.*"output_tokens":7.*"total_tokens":18' "$test_root/chat-a.json"
rg -q '"input_tokens":11.*"cached_input_tokens":3.*"output_tokens":7.*"total_tokens":18' "$test_root/chat-b.json"
curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/artifacts" | rg -q '"kind":"mermaid"'
test "$(curl -sS -b "$cookie_b" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/conversation")" = 404
curl -sS -b "$cookie_b" "$base_url/api/projects/$project_a/conversation" >"$test_root/actionable-error.json"
rg -q '"error":"Project not found\."' "$test_root/actionable-error.json"
rg -q '"action":"[^"]' "$test_root/actionable-error.json"
rg -q '"code":"leanfm_http_404"' "$test_root/actionable-error.json"
rg -q 'make a state machine' <(curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/conversation")
rg -q '"sent_at_ms":[0-9]' <(curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/conversation")
! rg -q 'keep this separate' <(curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/conversation")

curl -fsS -b "$cookie_a" --data-urlencode 'prompt=TEST_UPDATE_BOOK update the durable book now' \
  "$base_url/api/projects/$project_a/chat" >"$test_root/book-update.json"
rg -q '"book_updated":true' "$test_root/book-update.json"
rg -q 'Durable chat book update marker' "$test_root/data/accounts/rfielding/projects/$project_a/book/main.tex"
test -s "$test_root/data/accounts/rfielding/projects/$project_a/book/main.pdf"

curl -fsS -b "$cookie_a" --data-urlencode 'prompt=TEST_REPAIR_BOOK show the requested MCP animation while repairing the book' \
  "$base_url/api/projects/$project_a/chat" >"$test_root/book-repair.json" &
book_repair_pid=$!
repair_status_seen=false
for _ in $(seq 1 30); do
  if curl -fsS -b "$cookie_a" "$base_url/api/projects/$project_a/chat/status" >"$test_root/book-repair-status.json" &&
      rg -q '"stage":"book-repair"' "$test_root/book-repair-status.json" &&
      rg -q '"attempt":1' "$test_root/book-repair-status.json"; then
    repair_status_seen=true
    break
  fi
  sleep 0.1
done
test "$repair_status_seen" = true
test "$(curl -sS -b "$cookie_b" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/chat/status")" = 404
wait "$book_repair_pid"
rg -q '"book_updated":true' "$test_root/book-repair.json"
rg -q 'Requested MCP animation remains visible after internal repair' "$test_root/book-repair.json"
! rg -q 'Internal repair housekeeping' "$test_root/book-repair.json"
rg -Fq 'A \& B' "$test_root/data/accounts/rfielding/projects/$project_a/book/main.tex"
diagnostic_a="$test_root/data/accounts/rfielding/projects/$project_a/logs/runtime-diagnostics.jsonl"
test -f "$diagnostic_a"
test -f "$test_root/data/accounts/rfielding/projects/$project_a/logs/README.md"
rg -q '"category":"resolved"' "$diagnostic_a"
! rg -q '"category":"book_compiler"' "$diagnostic_a"

curl -fsS -b "$cookie_b" --data-urlencode 'prompt=TEST_WRITE_SOURCE implement the server now' \
  "$base_url/api/projects/$project_b/chat" >"$test_root/source-write.json" &
source_write_pid=$!
live_trace_seen=false
for _ in $(seq 1 30); do
  if curl -fsS -b "$cookie_b" "$base_url/api/projects/$project_b/chat/trace" >"$test_root/live-trace.json" &&
      rg -q 'Wrote source/main.go' "$test_root/live-trace.json"; then
    live_trace_seen=true
    break
  fi
  sleep 0.1
done
test "$live_trace_seen" = true
rg -Fq 'Attempting write to source/main.go (text file,' "$test_root/live-trace.json"
test "$(curl -sS -b "$cookie_a" -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_b/chat/trace")" = 404
kill -0 "$source_write_pid"
wait "$source_write_pid"
rg -q 'status.*success' "$test_root/source-write.json"
test -f "$test_root/data/accounts/second_user/projects/$project_b/source/main.go"
rg -q 'func main' "$test_root/data/accounts/second_user/projects/$project_b/source/main.go"
diagnostic_b="$test_root/data/accounts/second_user/projects/$project_b/logs/runtime-diagnostics.jsonl"
test -f "$diagnostic_b"
rg -q '"category":"resolved".*source/main.go' "$diagnostic_b"
! rg -q 'package main' "$diagnostic_b"
curl -fsS -b "$cookie_b" "$base_url/api/projects/$project_b/source" | rg -q '"files":\["main.go"\]'

project_empty="$(create_project "$cookie_b" Empty)"
curl -fsS -b "$cookie_b" --data-urlencode 'prompt=implement the server now' \
  "$base_url/api/projects/$project_empty/chat" >"$test_root/empty-source-implementation.json"
rg -q 'status.*fail' "$test_root/empty-source-implementation.json"
rg -q 'no files exist beneath the selected project.*source/' "$test_root/empty-source-implementation.json"
test ! -e "$test_root/data/accounts/second_user/projects/$project_empty/source/main.go"

curl -sS -b "$cookie_a" --data-urlencode 'prompt=TEST_CANCEL_AGENT implement a file that cancellation must prevent' \
  "$base_url/api/projects/$project_a/chat" >"$test_root/cancelled-chat.json" &
cancelled_chat_pid=$!
sleep 0.2
test "$(curl -sS -b "$cookie_b" -X POST -o /dev/null -w '%{http_code}' "$base_url/api/projects/$project_a/chat/cancel")" = 404
curl -fsS -b "$cookie_a" -X POST "$base_url/api/projects/$project_a/chat/cancel" | rg -q '"cancel_requested":true'
wait "$cancelled_chat_pid"
rg -q '"cancelled":true' "$test_root/cancelled-chat.json"
test ! -e "$test_root/data/accounts/rfielding/projects/$project_a/source/must-not-exist.go"

echo 'ok: ChatUI bootstrap, durable book/source edits, artifacts, and concurrent session isolation'

# Requirement: password verification precedes migration; copied sessions cannot spend.
login_status() {
  curl -sS -o /dev/null -w '%{http_code}' --data-urlencode 'username=rfielding' \
    --data-urlencode "password=$1" $base_url/api/login
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
LEANFM_DATA_ROOT="$data_root_setting" LEANFM_OPENAI_BASE_URL="http://127.0.0.1:18080/v1" LEANFM_TEST_UNSANDBOXED_BOOK_BUILD=1 LEANFM_PORT="$server_port" \
  .lake/build/bin/leanfm-server >"$server_log" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -fsS $base_url/health >/dev/null 2>&1 && break
  sleep 0.1
done
test "$(curl -sS -b "$cookie_a" -o /dev/null -w '%{http_code}' $base_url/api/me)" = 401
echo 'ok: encrypted credentials, account isolation, migration and restart invalidation'
