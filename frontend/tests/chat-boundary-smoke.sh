#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/canvaspilot-chat-boundary.XXXXXX")"
SERVER_PID=""
BACKEND_PID=""
SERVER_LOG="$TMP_DIR/server.log"
BACKEND_LOG="$TMP_DIR/backend.log"
BACKEND_RECORD="$TMP_DIR/backend-requests"
BODY="$TMP_DIR/body"
HEADERS="$TMP_DIR/headers"
HTTP_STATUS=""
LAST_URL=""

stop_process() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for ((attempt = 1; attempt <= 40; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        [[ "$(ps -o state= -p "$pid" 2>/dev/null || true)" == *Z* ]] && break
        sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null && [[ "$(ps -o state= -p "$pid" 2>/dev/null || true)" != *Z* ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_process "$SERVER_PID" 2>/dev/null
    stop_process "$BACKEND_PID" 2>/dev/null
    if ((status != 0)) && [[ -s "$SERVER_LOG" ]]; then
        printf '\n--- chat-boundary server log ---\n' >&2
        cat "$SERVER_LOG" >&2
    fi
    if ((status != 0)) && [[ -s "$BACKEND_LOG" ]]; then
        printf '\n--- chat-boundary backend log ---\n' >&2
        cat "$BACKEND_LOG" >&2
    fi
    rm -rf -- "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf 'chat-boundary-smoke: %s\n' "$*" >&2
    if [[ -s "$BODY" ]]; then
        printf '%s\n' '--- last response body ---' >&2
        cat "$BODY" >&2
    fi
    exit 1
}

for tool in zig curl grep mktemp python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

cd -- "$FRONTEND_DIR"
zig build -Doptimize=ReleaseSafe
APP="$FRONTEND_DIR/zig-out/bin/app"
[[ -x "$APP" ]] || fail "compiled frontend binary is missing: $APP"

free_port() {
    python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

PORT="${CHAT_BOUNDARY_PORT:-$(free_port)}"
BACKEND_PORT="$(free_port)"
if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    fail "invalid port: $PORT"
fi
while [[ "$PORT" == 0* && "$PORT" != "0" ]]; do
    PORT="${PORT#0}"
done
if ((${#PORT} > 5)) || ((10#$PORT < 1 || 10#$PORT > 65535)); then
    fail "invalid port: $PORT"
fi
PORT="$((10#$PORT))"
while [[ "$BACKEND_PORT" == "$PORT" ]]; do
    BACKEND_PORT="$(free_port)"
done
BASE_URL="http://127.0.0.1:$PORT"
BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"
: >"$BACKEND_RECORD"

cat >"$TMP_DIR/backend_spy.py" <<'PY'
import http.server
import pathlib
import sys

port = int(sys.argv[1])
record = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def handle_request(self):
        if self.path == "/health":
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length) if length else b""
        with record.open("a", encoding="utf-8") as stream:
            stream.write(self.path + "\n")

        content_type = "application/json"
        if self.path == "/api/chat" and b"valid live boundary" in payload:
            status = 200
            content_type = "text/event-stream"
            body = (
                b'event: token\r\ndata: {"text":"Grounded live reply"}\r\n\r\n'
                b'event: done\r\ndata: {"grounded":true,"confidence":0.9}\r\n\r\n'
            )
        elif self.path == "/api/chat" and b"truncated live boundary" in payload:
            status = 200
            content_type = "text/event-stream"
            body = b'event: token\ndata: {"text":"plausible but incomplete"}\n\n'
        elif self.path == "/api/chat" and b"oversized response boundary" in payload:
            status, body = 200, b"x" * (512 * 1024 + 1)
        elif self.path == "/api/modules/sync":
            status, body = 200, b'{"status":"started"}'
        elif self.path == "/api/sources" and b'created source' in payload:
            status = 201
            body = b'{"id":"source-1","user_id":"user-1","source_type":"link","origin":"test","title":"created source","status":"ready"}'
        elif self.path == "/api/sources" and b'oversized source response' in payload:
            status, body = 200, b"x" * (1024 * 1024 + 1)
        elif self.path == "/api/sources" and b'unauthorized source' in payload:
            status, body = 401, b'{"detail":"unauthorized"}'
        elif self.path == "/api/sources" and b'forbidden source' in payload:
            status, body = 403, b'{"detail":"forbidden"}'
        elif self.path == "/api/sources" and b'invalid source' in payload:
            status, body = 422, b'{"detail":"invalid"}'
        else:
            status, body = 503, b'{"detail":"backend spy intentionally unavailable"}'

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, _format, *_args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
python3 "$TMP_DIR/backend_spy.py" "$BACKEND_PORT" "$BACKEND_RECORD" >"$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

backend_ready=0
for ((attempt = 1; attempt <= 100; attempt++)); do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        wait "$BACKEND_PID" 2>/dev/null || true
        fail "backend spy exited before becoming ready"
    fi
    backend_status="$(curl --noproxy '*' --silent --max-time 1 --output /dev/null --write-out '%{http_code}' "$BACKEND_URL/health" || true)"
    if [[ "$backend_status" == "200" ]]; then
        backend_ready=1
        break
    fi
    sleep 0.05
done
((backend_ready == 1)) || fail "backend spy was not ready at $BACKEND_URL after 5 seconds"

PUBLIC_ORIGIN="https://study.example.com"
WIKIBASE_MOCK_ENABLED=true \
WIKIBASE_BACKEND_URL="$BACKEND_URL" \
WIKIBASE_PUBLIC_ORIGIN="$PUBLIC_ORIGIN" \
    "$APP" --host 127.0.0.1 --port "$PORT" --no-dev --no-dotenv \
    >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

ready=0
for ((attempt = 1; attempt <= 150; attempt++)); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        wait "$SERVER_PID" 2>/dev/null || true
        fail "server exited before becoming ready"
    fi
    readiness_status="$(curl --noproxy '*' --silent --max-time 1 --output /dev/null --write-out '%{http_code}' "$BASE_URL/login" || true)"
    if [[ "$readiness_status" == "200" ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
((ready == 1)) || fail "server was not ready at $BASE_URL after 15 seconds"

request() {
    local url=$1
    shift
    LAST_URL="$url"
    : >"$BODY"
    : >"$HEADERS"
    HTTP_STATUS="$(
        curl --noproxy '*' --silent --show-error --max-time 8 \
            --output "$BODY" \
            --dump-header "$HEADERS" \
            --write-out '%{http_code}' \
            "$@" "$url"
    )" || fail "curl failed for $url"
}

assert_status() {
    local expected=$1
    [[ "$HTTP_STATUS" == "$expected" ]] || fail "$LAST_URL: expected HTTP $expected, got $HTTP_STATUS"
}

assert_contains() {
    local text=$1
    grep -Fq -- "$text" "$BODY" || fail "$LAST_URL: response did not contain: $text"
}

assert_json_field() {
    local field=$1
    local expected=$2
    python3 - "$BODY" "$field" "$expected" <<'PY' || fail "$LAST_URL: JSON field $field did not equal $expected"
import json
import pathlib
import sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if body.get(sys.argv[2]) != sys.argv[3]:
    raise SystemExit(1)
PY
}

assert_json_absent() {
    local field=$1
    python3 - "$BODY" "$field" <<'PY' || fail "$LAST_URL: JSON unexpectedly contained field $field"
import json
import pathlib
import sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if sys.argv[2] in body:
    raise SystemExit(1)
PY
}

assert_backend_count() {
    local expected=$1
    local actual
    actual="$(wc -l <"$BACKEND_RECORD" | tr -d '[:space:]')"
    [[ "$actual" == "$expected" ]] || fail "expected $expected backend requests, recorded $actual"
}

# Explicit demo context reaches the demo API endpoint and never the backend.
request "$BASE_URL/chat?mock=1" --header 'Cookie: cp_session=chat-boundary'
assert_status 200
assert_contains 'data-cp-demo="true"'
assert_contains 'data-endpoint="/api/chat?mock=1"'

request "$BASE_URL/api/chat?mock=1" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data '{"message":"demo boundary check"}'
assert_status 200
assert_json_field source mock
assert_contains '/sources?type=announcement&mock=1'

request "$BASE_URL/api/sync?mock=1" --header 'Cookie: cp_session=chat-boundary' --data 'action=sync'
assert_status 400
assert_contains 'sync is unavailable in demo mode'

request "$BASE_URL/api/flashcards/attempt?mock=1" \
    --header 'Cookie: cp_session=chat-boundary' \
    --data 'card_id=card-1&deck_id=deck-1&correct=true&confidence=5'
assert_status 400
assert_contains 'flashcard attempts are unavailable in demo mode'
assert_backend_count 0

# Method and request-field guards fail before backend contact.
request "$BASE_URL/api/chat"
assert_status 405
request "$BASE_URL/api/sync"
assert_status 405

python3 - "$TMP_DIR/oversized-request.json" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"message": "x" * 9000}), encoding="utf-8")
PY
request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/oversized-request.json"
assert_status 400

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data "$(python3 - <<'PY'
import json
print(json.dumps({"message": "ok", "module_id": "m" * 257}))
PY
)"
assert_status 400
assert_backend_count 0

# Authenticated live requests contact the backend and never substitute demo output.
request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data '{"message":"live unavailable boundary"}'
assert_status 502
assert_json_field error 'live chat is unavailable; no demo answer was substituted'
assert_json_absent source
assert_json_absent message
assert_json_absent citations
assert_backend_count 1

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data '{"message":"valid live boundary"}'
assert_status 200
assert_json_field source backend
assert_json_field message 'Grounded live reply'
assert_backend_count 2

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data '{"message":"truncated live boundary"}'
assert_status 502
assert_json_field error 'live chat is unavailable; no demo answer was substituted'
assert_json_absent message
assert_contains 'no demo answer was substituted'
assert_backend_count 3

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --data '{"message":"oversized response boundary"}'
assert_status 502
assert_json_field error 'live chat is unavailable; no demo answer was substituted'
assert_backend_count 4

request "$BASE_URL/api/sync" --header 'Cookie: cp_session=chat-boundary' --data 'action=sync'
assert_status 303
grep -Eiq '^location:[[:space:]]*/dashboard\?synced=1[[:space:]]*\r?$' "$HEADERS" || fail 'authenticated live sync did not return its success redirect'
assert_backend_count 5
[[ "$(grep -Fxc '/api/chat' "$BACKEND_RECORD")" == "4" ]] || fail 'unexpected live chat backend request count'
[[ "$(grep -Fxc '/api/modules/sync' "$BACKEND_RECORD")" == "1" ]] || fail 'unexpected live sync backend request count'

# Cookie-authenticated source mutations fail closed unless the browser proves same origin.
source_payload='{"source_type":"link","origin":"test","title":"invalid source","source_url":"https://example.com"}'
request "$BASE_URL/api/sources" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: text/plain' \
    --header "Origin: $PUBLIC_ORIGIN" \
    --header 'Sec-Fetch-Site: same-origin' \
    --data "$source_payload"
assert_status 403
request "$BASE_URL/api/sources" \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --header 'Origin: https://evil.example.com' \
    --header 'Sec-Fetch-Site: same-site' \
    --data "$source_payload"
assert_status 403
request "$BASE_URL/api/sources" \
    --header 'Host: frontend:3000' \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Content-Type: application/json' \
    --header 'Origin: https://evil.example.com' \
    --header 'Sec-Fetch-Site: same-origin' \
    --header 'Forwarded: host=study.example.com;proto=https' \
    --header 'X-Forwarded-Host: study.example.com' \
    --header 'X-Forwarded-Proto: https' \
    --data "$source_payload"
assert_status 403
assert_backend_count 5

# A configured public origin works behind a proxy without trusting forwarding headers.
for case in 'unauthorized source:401' 'forbidden source:403' 'invalid source:422' 'oversized source response:502'; do
    title=${case%:*}
    expected=${case##*:}
    request "$BASE_URL/api/sources" \
        --header 'Host: frontend:3000' \
        --header 'Cookie: cp_session=chat-boundary' \
        --header 'Content-Type: application/json' \
        --header "Origin: $PUBLIC_ORIGIN" \
        --header 'Sec-Fetch-Site: same-origin' \
        --header 'Forwarded: host=study.example.com;proto=https' \
        --header 'X-Forwarded-Host: study.example.com' \
        --header 'X-Forwarded-Proto: https' \
        --data "{\"source_type\":\"link\",\"origin\":\"test\",\"title\":\"$title\",\"source_url\":\"https://example.com\"}"
    assert_status "$expected"
done

# Preserve backend success status and authenticate from the first repeated Cookie field.
request "$BASE_URL/api/sources" \
    --header 'Host: frontend:3000' \
    --header 'Cookie: cp_session=chat-boundary' \
    --header 'Cookie: other=value' \
    --header 'Content-Type: application/json' \
    --header "Origin: $PUBLIC_ORIGIN" \
    --header 'Sec-Fetch-Site: same-origin' \
    --data '{"source_type":"link","origin":"test","title":"created source","source_url":"https://example.com"}'
assert_status 201
assert_json_field title 'created source'
assert_backend_count 10
[[ "$(grep -Fxc '/api/sources' "$BACKEND_RECORD")" == "5" ]] || fail 'unexpected live source backend request count'

printf 'chat-boundary-smoke: all assertions passed at %s\n' "$BASE_URL"
