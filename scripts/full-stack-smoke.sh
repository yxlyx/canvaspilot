#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON=${PYTHON:-python}
"$PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'
export ENVIRONMENT=test
export SESSION_SECRET=test-session-secret-with-at-least-32-bytes
export CANVAS_TOKEN_SECRET=eE-4RX-m39GFpdZXEDBtsaKZoOlMC7EpNlV9XiFrOO8=
export PROVIDER_ENCRYPTION_SECRET=XRoe-9icgC8y3-AtmJVDwhbrRraWTUXCsSu013nHztY=
export SECURE_COOKIES=false

free_port() {
    "$PYTHON" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

port_from_url() {
    "$PYTHON" - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if (
    url.scheme != "http"
    or url.hostname != "127.0.0.1"
    or url.port is None
    or url.username is not None
    or url.password is not None
    or url.path not in {"", "/"}
    or url.query
    or url.fragment
):
    raise SystemExit("full-stack smoke URLs must be http://127.0.0.1:<port>")
print(url.port)
PY
}

port_is_free() {
    "$PYTHON" - "$1" <<'PY'
import socket
import sys

with socket.socket() as sock:
    try:
        sock.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError:
        raise SystemExit(1)
PY
}

if [[ -z "${BACKEND_URL:-}" ]]; then
    BACKEND_URL="http://127.0.0.1:$(free_port)"
fi
if [[ -z "${FRONTEND_URL:-}" ]]; then
    FRONTEND_URL="http://127.0.0.1:$(free_port)"
fi
BACKEND_PORT=$(port_from_url "$BACKEND_URL")
FRONTEND_PORT=$(port_from_url "$FRONTEND_URL")
if [[ "$BACKEND_PORT" == "$FRONTEND_PORT" ]]; then
    printf '%s\n' 'full-stack smoke requires distinct backend and frontend ports' >&2
    exit 2
fi
for port in "$BACKEND_PORT" "$FRONTEND_PORT"; do
    if ! port_is_free "$port"; then
        printf 'full-stack smoke refuses occupied port: %s\n' "$port" >&2
        exit 2
    fi
done
export BACKEND_URL FRONTEND_URL
export WIKIBASE_BACKEND_URL="$BACKEND_URL"
export WIKIBASE_PUBLIC_ORIGIN="$FRONTEND_URL"

COOKIE_JAR=$(mktemp)
BACKEND_LOG=$(mktemp)
FRONTEND_LOG=$(mktemp)
backend_pid=
frontend_pid=

stop_process() {
    local pid=$1
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null || [[ "$(ps -o state= -p "$pid" 2>/dev/null || true)" == *Z* ]]; then
            wait "$pid" 2>/dev/null || true
            return
        fi
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    stop_process "$frontend_pid"
    stop_process "$backend_pid"
    rm -f "$COOKIE_JAR" "$BACKEND_LOG" "$FRONTEND_LOG"
}
trap cleanup EXIT

wait_for() {
    local url=$1 log=$2 pid=$3 name=$4
    for _ in $(seq 1 100); do
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '%s child exited before becoming ready\n' "$name" >&2
            wait "$pid" 2>/dev/null || true
            cat "$log" >&2
            return 1
        fi
        if curl --fail --silent --output /dev/null "$url"; then
            kill -0 "$pid" 2>/dev/null || {
                printf '%s child exited during readiness check\n' "$name" >&2
                cat "$log" >&2
                return 1
            }
            return
        fi
        sleep 0.2
    done
    cat "$log" >&2
    return 1
}

(
    cd "$ROOT_DIR/backend"
    exec "$PYTHON" -m uvicorn app.main:app --host 127.0.0.1 --port "$BACKEND_PORT"
) >"$BACKEND_LOG" 2>&1 &
backend_pid=$!

"$ROOT_DIR/frontend/zig-out/bin/app" --host 127.0.0.1 --port "$FRONTEND_PORT" --no-dev --no-dotenv \
    >"$FRONTEND_LOG" 2>&1 &
frontend_pid=$!

wait_for "$BACKEND_URL/api/health" "$BACKEND_LOG" "$backend_pid" backend
wait_for "$FRONTEND_URL/login" "$FRONTEND_LOG" "$frontend_pid" frontend

email="full-stack-$(date +%s)-$$@test.example.com"
register_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" \
    --header "Origin: $FRONTEND_URL" --header 'Sec-Fetch-Site: same-origin' \
    --data-urlencode 'name=Full Stack Smoke' \
    --data-urlencode "email=$email" \
    --data-urlencode 'password=smoke-password' \
    --data-urlencode 'confirm_password=smoke-password' \
    "$FRONTEND_URL/api/auth/register")
[[ "$register_status" == 303 ]]
registered_me=$(curl --fail --silent --cookie "$COOKIE_JAR" "$FRONTEND_URL/api/me")
printf '%s' "$registered_me" | "$PYTHON" -c 'import json,sys; data=json.load(sys.stdin); assert data["email"] == sys.argv[1]' "$email"

# Prove sign-in establishes its own session rather than reusing registration's cookie.
: >"$COOKIE_JAR"
signin_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" \
    --header "Origin: $FRONTEND_URL" --header 'Sec-Fetch-Site: same-origin' \
    --data-urlencode "email=$email" \
    --data-urlencode 'password=smoke-password' \
    "$FRONTEND_URL/api/auth/signin")
[[ "$signin_status" == 303 ]]

me=$(curl --fail --silent --cookie "$COOKIE_JAR" "$FRONTEND_URL/api/me")
printf '%s' "$me" | "$PYTHON" -c 'import json,sys; data=json.load(sys.stdin); assert data["email"] == sys.argv[1]' "$email"

dashboard=$(curl --fail --silent --cookie "$COOKIE_JAR" "$FRONTEND_URL/dashboard")
[[ "$dashboard" == *'<h1 class="cp-page-title">Workspace</h1>'* ]]
if [[ "$dashboard" == *'data-cp-auth="anonymous"'* ]]; then
    printf '%s\n' 'authenticated frontend route rendered as anonymous' >&2
    exit 1
fi

source_title="Smoke source $RANDOM $$"
created=$(curl --fail --silent --cookie "$COOKIE_JAR" \
    --header 'Content-Type: application/json' \
    --header "Origin: $FRONTEND_URL" \
    --header 'Sec-Fetch-Site: same-origin' \
    --data "{\"source_type\":\"link\",\"origin\":\"full-stack-smoke\",\"title\":\"$source_title\",\"source_url\":\"https://test.example.com/source\"}" \
    "$FRONTEND_URL/api/sources")
printf '%s' "$created" | "$PYTHON" -c 'import json,sys; data=json.load(sys.stdin); assert data["title"] == sys.argv[1]' "$source_title"

sources_page=$(curl --fail --silent --cookie "$COOKIE_JAR" "$FRONTEND_URL/sources")
[[ "$sources_page" == *"$source_title"* ]]

for child in "$backend_pid" "$frontend_pid"; do
    kill -0 "$child" 2>/dev/null
done

printf '%s\n' 'full-stack smoke: frontend registration, sign-in, session read, authenticated render, and source mutation passed'
