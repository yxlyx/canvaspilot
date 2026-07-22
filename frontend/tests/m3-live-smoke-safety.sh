#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
stop_process(){
 pid=${1:-}; [ -n "$pid" ] || return 0
 kill "$pid" 2>/dev/null || true
 attempts=0
 while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 5 ]; do sleep 1; attempts=$((attempts + 1)); done
 if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
 wait "$pid" 2>/dev/null || true
}
cleanup(){ stop_process "${PID:-}"; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
python3 - "$TMP/port" <<'PY' &
import socket,sys,time
sock=socket.socket()
sock.bind(("127.0.0.1",0))
sock.listen()
open(sys.argv[1],"w").write(str(sock.getsockname()[1]))
time.sleep(30)
PY
PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep .02; done
port=$(cat "$TMP/port")
frontend_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
if BACKEND_PORT="$port" FRONTEND_PORT="$frontend_port" "$ROOT/tests/m3-live-smoke.sh" >"$TMP/out" 2>&1; then
 echo "M3 smoke accepted an occupied backend port" >&2
 exit 1
fi
grep -q "refuses invalid or occupied port: $port" "$TMP/out"
echo "M3 live smoke port safety passed"
