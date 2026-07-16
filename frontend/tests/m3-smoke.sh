#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/canvaspilot-m3-smoke.XXXXXX")"
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
        printf '\n--- M3 smoke server log ---\n' >&2
        cat "$SERVER_LOG" >&2
    fi
    if ((status != 0)) && [[ -s "$BACKEND_LOG" ]]; then
        printf '\n--- M3 smoke backend-spy log ---\n' >&2
        cat "$BACKEND_LOG" >&2
    fi
    rm -rf -- "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf 'm3-smoke: %s\n' "$*" >&2
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

PORT="${M3_SMOKE_PORT:-}"
if [[ -z "$PORT" ]]; then
    PORT="$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
fi
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
BACKEND_PORT="$(python3 - "$PORT" <<'PY'
import socket
import sys
app_port = int(sys.argv[1])
while True:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    if port != app_port:
        print(port)
        break
PY
)"
BASE_URL="http://127.0.0.1:$PORT"
BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"

cat >"$TMP_DIR/backend_spy.py" <<'PY'
import http.server
import pathlib
import sys

port = int(sys.argv[1])
record = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def handle_request(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length) if length else b""
        with record.open("a", encoding="utf-8") as stream:
            stream.write(self.path + "\n")
        if self.path == "/api/modules/sync":
            status, body = 200, b'{"status":"started"}'
        elif self.path == "/api/chat" and b"oversized response boundary" in payload:
            status, body = 200, b"x" * (512 * 1024 + 1)
        elif self.path == "/api/flashcards/decks":
            status = 200
            body = b'[{"id":"live-deck-id","user_id":"live-user-id","title":"Live backend deck","description":"Returned by the smoke backend.","generation_scope":"sources","source_ids":["live-source-id"],"wiki_page_id":null,"topic_tags":["live"],"card_count":3,"cards":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]'
        elif self.path == "/api/wiki/pages":
            status = 200
            body = b'[{"id":"live-page-id","user_id":"live-user-id","slug":"live-page","title":"Live backend page","page_type":"source","markdown":"# Live page","summary":"Returned by the smoke backend.","source_ids":["live-source-id"],"citation_count":1,"backlinks":[],"citations":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]'
        else:
            status, body = 503, b'{"detail":"backend spy intentionally unavailable"}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, _format, *_args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
python3 "$TMP_DIR/backend_spy.py" "$BACKEND_PORT" "$BACKEND_RECORD" >"$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

WIKIBASE_MOCK_ENABLED=true \
WIKIBASE_BACKEND_URL="$BACKEND_URL" \
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
        curl --noproxy '*' --silent --show-error --max-time 5 \
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

assert_not_contains() {
    local text=$1
    if grep -Fq -- "$text" "$BODY"; then
        fail "$LAST_URL: response unexpectedly contained: $text"
    fi
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

assert_demo_page() {
    local path=$1
    request "$BASE_URL$path"
    assert_status 200
    assert_contains 'data-cp-demo="true"'
    assert_contains 'Demo data · synthetic fixtures, not live workspace data'
}

# Every M3 demo surface boots with visible and machine-readable fixture labels.
demo_routes=(
    '/settings/providers?mock=1'
    '/outputs?mock=1'
    '/health?mock=1'
    '/history?mock=1'
    '/progress?mock=1'
    '/marked-papers?mock=1'
    '/marked-papers/demo-paper-functional-midterm?mock=1'
    '/marked-papers/demo-paper-unknown-score?mock=1'
)
for route in "${demo_routes[@]}"; do
    assert_demo_page "$route"
done

# Anonymous requests without the request-level opt-in must not receive fixtures.
non_demo_routes=(
    '/settings/providers'
    '/outputs'
    '/health'
    '/history'
    '/progress'
    '/marked-papers'
    '/marked-papers/demo-paper-functional-midterm'
)
for route in "${non_demo_routes[@]}"; do
    request "$BASE_URL$route"
    assert_status 303
    grep -Eiq '^location:[[:space:]]*/login[[:space:]]*\r?$' "$HEADERS" || fail "$route did not redirect to /login"
done

# Authenticated non-demo requests render an honest unavailable state, not fixtures.
request "$BASE_URL/progress" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'Live unavailable'
assert_contains 'Backend contract not implemented'
assert_not_contains 'data-cp-demo="true"'
assert_not_contains 'Estimate unknown'

# Provider-specific schemas stay read-only and contain no secret values.
request "$BASE_URL/settings/providers?mock=1"
assert_status 200
for state in configured disconnected invalid pending; do
    assert_contains "cp-state-$state"
done
assert_contains 'type="password"'
assert_contains 'type="url"'
assert_contains 'name="deployment"'
assert_contains 'write-only'
assert_contains 'aria-labelledby="provider-title-demo-provider-openai"'
assert_contains 'aria-describedby="provider-actions-demo-provider-openai"'
assert_contains 'aria-disabled="true" readonly'
assert_contains 'aria-disabled="true" aria-describedby="provider-actions-demo-provider-openai">Test connection</button>'
assert_contains 'aria-disabled="true" aria-describedby="provider-actions-demo-provider-openai">Update configuration</button>'
assert_contains '>Save configuration</button>'
assert_contains '>Disconnect</button>'
assert_not_contains 'sk-demo-secret-sentinel'
if grep -Eq '<input[^>]+value=' "$BODY"; then
    fail 'provider response rendered an input value'
fi

# Severity filters have deterministic partitions and expose selected state.
request "$BASE_URL/health?mock=1&severity=info"
assert_status 200
assert_contains 'Citation coverage healthy'
assert_contains 'File status unknown'
assert_contains 'aria-disabled="true" aria-describedby="health-run-note">Run checks</button>'
assert_contains 'aria-current="page">Info</a>'
assert_not_contains 'Thin topic coverage'
assert_not_contains 'Broken source reference'

request "$BASE_URL/health?mock=1&severity=warning"
assert_status 200
assert_contains 'Thin topic coverage'
assert_contains 'Page may be stale'
assert_contains 'Review sources'
assert_contains '/sources?type=markdown&amp;mock=1'
assert_not_contains 'Citation coverage healthy'
assert_not_contains 'Broken source reference'

request "$BASE_URL/health?mock=1&severity=error"
assert_status 200
assert_contains 'Broken source reference'
assert_not_contains 'Thin topic coverage'

request "$BASE_URL/health?mock=1&severity=does-not-exist"
assert_status 200
assert_contains 'No findings match this severity.'

# Timeline filters likewise retain demo mode and selected semantics.
request "$BASE_URL/history?mock=1&type=content"
assert_status 200
assert_contains 'Immutable lists and streams'
assert_contains 'aria-current="page">Content</a>'
assert_contains '/history?type=citations&amp;mock=1'
assert_contains 'aria-disabled="true" aria-describedby="history-note-demo-history-streams-v3">Restore version</button>'
assert_not_contains 'Functional collections checklist'

request "$BASE_URL/history?mock=1&type=citations"
assert_status 200
assert_contains 'Functional collections checklist'
assert_not_contains 'Immutable lists and streams'

request "$BASE_URL/history?mock=1&type=does-not-exist"
assert_status 200
assert_contains 'No history entries match this filter.'

# Aggregate and topic meters distinguish measured, zero, and unknown values.
request "$BASE_URL/progress?mock=1"
assert_status 200
assert_contains 'Workspace evidence overview'
assert_contains '7 signals'
assert_contains '1 known · 1 unknown'
assert_contains 'Unknown topics stay unknown and are never counted as 0%.'
assert_contains 'Estimate unknown'
assert_contains 'not enough evidence to calculate a percentage'
assert_contains 'value="78"'
assert_contains 'Practice cited cards'
assert_contains '/flashcards?deck=deck-streams&amp;mock=1'
assert_not_contains 'value="0"'
assert_not_contains '>0%</strong>'

# Source selection scopes both the summary and citation evidence.
request "$BASE_URL/outputs?mock=1&state=grounded&source=demo-source-lab&wiki=demo-wiki-lab"
assert_status 200
assert_contains 'Immutable lists and streams — cited summary'
assert_contains 'Preview source: Synthetic lab brief · Wiki context: Lab 6 checklist'
assert_contains 'value="demo-source-lab" selected'
assert_contains 'value="demo-wiki-lab" selected'
assert_contains 'stream computes its next element only when requested'
assert_contains 'Exercise 4'
assert_not_contains 'Synthetic lecture notes</strong>'
assert_not_contains 'Section 2'
assert_contains 'Backend export is unavailable; no download is created.'
assert_contains 'aria-disabled="true" aria-describedby="export-note"'

# Output boundary and loading states are directly reviewable through the URL.
request "$BASE_URL/outputs?mock=1&state=insufficient"
assert_status 200
assert_contains 'Insufficient context'
assert_contains 'No cited output generated'
assert_not_contains 'Immutable lists and streams — cited summary'

request "$BASE_URL/outputs?mock=1&state=empty"
assert_status 200
assert_contains 'Synthetic empty-state preview'
assert_contains 'no source or wiki selection'
assert_not_contains 'Immutable lists and streams — cited summary'

request "$BASE_URL/outputs?mock=1&state=loading"
assert_status 200
assert_contains 'Synthetic loading-state preview'
assert_contains 'No request is running in this static preview.'
assert_not_contains 'aria-busy="true"'
assert_not_contains 'Immutable lists and streams — cited summary'

request "$BASE_URL/outputs?mock=1&state=unsupported"
assert_status 200
assert_contains 'value="grounded" selected'
assert_contains 'Immutable lists and streams — cited summary'

# Explicit demo context survives M2 shell, list, and contextual navigation.
request "$BASE_URL/wiki?mock=1"
assert_status 200
assert_contains 'data-cp-demo="true"'
assert_contains '/wiki/immutable-lists?mock=1'
assert_contains '<details class="cp-mobile-more"><summary aria-label="More workspace pages">'
assert_contains '/marked-papers?mock=1'
assert_contains '<a class="cp-mobile-account" href="/login">Sign in</a>'
assert_contains '<input type="checkbox" name="page" value="immutable-lists">'
assert_contains 'aria-disabled="true" aria-describedby="wiki-export-note">Export selected</button>'
assert_contains 'aria-disabled="true" aria-describedby="wiki-export-note">Export full wiki</button>'
assert_contains 'No placeholder download is created.'
assert_contains 'synthetic generated notes'
assert_contains 'synthetic source links'
assert_contains 'synthetic workspace records'
assert_contains 'synthetic practice sets'
assert_not_contains ' download='

request "$BASE_URL/wiki/immutable-lists?mock=1"
assert_status 200
assert_contains 'data-cp-demo="true"'
assert_contains 'Demo data · synthetic fixtures, not live workspace data'
assert_contains 'Synthetic fixture preview · fixture timestamp'
assert_contains 'aria-disabled="true" aria-describedby="page-export-note">Export unavailable</button>'
assert_contains 'Canonical Markdown export requires the authenticated backend endpoint.'
assert_not_contains 'Generated from indexed workspace sources'
assert_not_contains ' download='

request "$BASE_URL/flashcards?mock=1&deck=deck-streams"
assert_status 200
assert_contains '/flashcards?deck=deck-streams&amp;mock=1'
assert_contains '/progress?mock=1'
assert_contains 'Ask follow-up'
assert_contains 'aria-disabled="true" aria-describedby="review-note-card-streams-1">Again</button>'
assert_contains 'Review grading is unavailable for synthetic fixture cards'

# Explicit demo pages cannot trigger live chat or workspace-sync side effects.
request "$BASE_URL/chat?mock=1" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'data-endpoint="/api/chat?mock=1"'
assert_contains '<a href="/wiki?mock=1">wiki</a>'
assert_contains '<a href="/flashcards?mock=1">flashcards</a>'

request "$BASE_URL/api/chat?mock=1" \
    --header 'Cookie: cp_session=m3-smoke' \
    --header 'Content-Type: application/json' \
    --data '{"message":"demo boundary check"}'
assert_status 200
assert_json_field source mock
assert_contains '(demo)'
assert_contains '/sources?type=announcement&mock=1'

request "$BASE_URL/dashboard?mock=1" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'aria-disabled="true" aria-describedby="demo-sync-note">Sync unavailable</button>'
assert_contains 'Demo mode never starts a live workspace sync.'
assert_contains 'synthetic source records'
assert_contains 'synthetic chunks'
assert_contains '<form action="/logout" method="post" class="cp-mobile-account">'
assert_not_contains 'action="/api/sync"'

request "$BASE_URL/api/sync?mock=1" --header 'Cookie: cp_session=m3-smoke' --data 'action=sync'
assert_status 400
assert_contains 'sync is unavailable in demo mode'

request "$BASE_URL/api/flashcards/attempt?mock=1" \
    --header 'Cookie: cp_session=m3-smoke' \
    --data 'card_id=card-streams-1&deck_id=deck-streams&correct=true&confidence=5'
assert_status 400
assert_contains 'flashcard attempts are unavailable in demo mode'

# The recording backend proves demo requests never crossed the live boundary.
[[ ! -s "$BACKEND_RECORD" ]] || fail 'an explicit demo mutation contacted the backend spy'

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=m3-smoke' \
    --header 'Content-Type: application/json' \
    --data '{"message":"live boundary check"}'
assert_status 502
assert_json_field error 'live chat is unavailable; no demo answer was substituted'
assert_json_absent source
assert_json_absent message
assert_json_absent citations
[[ "$(grep -Fxc '/api/chat' "$BACKEND_RECORD")" == "1" ]] || fail 'authenticated live chat did not contact the backend spy exactly once'

request "$BASE_URL/api/sync" --header 'Cookie: cp_session=m3-smoke' --data 'action=sync'
assert_status 303
grep -Eiq '^location:[[:space:]]*/dashboard\?synced=1[[:space:]]*\r?$' "$HEADERS" || fail 'authenticated live sync did not return its success redirect'
[[ "$(grep -Fxc '/api/modules/sync' "$BACKEND_RECORD")" == "1" ]] || fail 'authenticated live sync did not contact the backend spy exactly once'
[[ "$(wc -l <"$BACKEND_RECORD" | tr -d '[:space:]')" == "2" ]] || fail 'unexpected backend requests were recorded'

# API method guards reject non-POST calls before any backend request.
request "$BASE_URL/api/chat"
assert_status 405
request "$BASE_URL/api/sync"
assert_status 405
[[ "$(wc -l <"$BACKEND_RECORD" | tr -d '[:space:]')" == "2" ]] || fail 'method-guard requests reached the backend spy'

# Marked-paper previews expose privacy, format, uncertainty, and disabled decisions.
request "$BASE_URL/marked-papers?mock=1"
assert_status 200
assert_contains 'Supported PDF or image formats will be defined'
assert_contains 'this frontend accepts no files.'
assert_contains 'aria-disabled="true" aria-describedby="paper-upload-note">Upload paper</button>'
assert_contains 'Extracted score: <strong>unknown</strong>'

request "$BASE_URL/marked-papers/demo-paper-functional-midterm?mock=1"
assert_status 200
assert_contains 'These are proposals, not confirmations.'
assert_contains '<strong>Score:</strong> unknown'
assert_contains 'Unconfirmed proposal:'
assert_contains 'Evidence proposals'
assert_contains 'aria-disabled="true" aria-describedby="evidence-note-demo-evidence-q1">Accept</button>'
assert_contains 'aria-disabled="true" aria-describedby="evidence-note-demo-evidence-q1">Edit</button>'
assert_contains 'aria-disabled="true" aria-describedby="evidence-note-demo-evidence-q1">Reject</button>'

# Touched M2 routes preserve explicit demo context and dynamic not-found behavior.
request "$BASE_URL/sources?mock=1&type=announcement"
assert_status 200
assert_contains 'data-cp-demo="true"'
assert_contains 'aria-current="page">Announcement</a>'
assert_contains '/chat?mock=1'

request "$BASE_URL/wiki/not-a-demo-page?mock=1"
assert_status 404
assert_contains 'data-cp-demo="true"'
assert_contains 'Wiki page not generated yet'
assert_contains '/dashboard?mock=1'

# Dynamic marked-paper not-found handling is route-specific and labelled synthetic.
request "$BASE_URL/marked-papers/not-a-demo-paper?mock=1"
assert_status 404
assert_contains 'data-cp-demo="true"'
assert_contains 'Marked paper not found'
assert_not_contains 'Page not found'

# Authenticated M2 fallback surfaces never present fixture provenance as live.
# These read-only requests run after backend-contact cardinality assertions.
request "$BASE_URL/dashboard" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'Backend metadata is incomplete.'
assert_contains 'dashboard source and chunk totals unavailable'
assert_contains '<span class="cp-metric-value">Unavailable</span>'
assert_contains '<span class="cp-metric-label">Available cards</span>'
assert_not_contains '<span class="cp-metric-label">Due cards</span>'
assert_not_contains 'synthetic source records'

request "$BASE_URL/flashcards" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'Live backend deck'
assert_contains '<span class="cp-metric-label">Available</span>'
assert_contains 'loaded from backend'
assert_contains '<strong>0</strong> available'
assert_not_contains '<span class="cp-metric-label">Due now</span>'
assert_not_contains '<strong>0</strong> due'

request "$BASE_URL/wiki" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'Live backend page'
assert_contains 'live generated notes'
assert_contains 'live source links'
assert_contains 'Live count · not included in wiki response'
assert_not_contains 'synthetic workspace records'
assert_not_contains 'synthetic practice sets'

request "$BASE_URL/wiki/immutable-lists" --header 'Cookie: cp_session=m3-smoke'
assert_status 200
assert_contains 'Demo data · synthetic fixtures, not live workspace data'
assert_contains 'Backend wiki page unavailable — showing prototype fixture content.'
assert_contains 'Synthetic fixture preview · fixture timestamp'
assert_not_contains 'data-cp-demo="true"'
assert_not_contains 'Generated from indexed workspace sources'

request "$BASE_URL/api/chat" \
    --header 'Cookie: cp_session=m3-smoke' \
    --header 'Content-Type: application/json' \
    --data '{"message":"oversized response boundary"}'
assert_status 502
assert_json_field error 'live chat is unavailable; no demo answer was substituted'

printf 'm3-smoke: all assertions passed at %s\n' "$BASE_URL"
