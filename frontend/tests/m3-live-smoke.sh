#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BACKEND_PORT=${BACKEND_PORT:-18991}; FRONTEND_PORT=${FRONTEND_PORT:-18992}; TMP=$(mktemp -d); U=11111111-1111-1111-1111-111111111111
cleanup(){ code=$?; kill ${FPID:-} ${BPID:-} 2>/dev/null || true; if [ "$code" -ne 0 ]; then echo "smoke artifacts: $TMP" >&2; cat "$TMP/frontend.log" >&2 2>/dev/null || true; else rm -rf "$TMP"; fi; }; trap cleanup EXIT INT TERM
cat >"$TMP/spy.py" <<'PY'
import json,sys
from http.server import BaseHTTPRequestHandler,HTTPServer
U="11111111-1111-1111-1111-111111111111"; NOW="2026-01-01T00:00:00Z"
output={"id":U,"output_type":"summary","title":"Grounded summary","status":"grounded","content":"# Safe output\nGrounded claim [^c1]","source_ids":[U],"wiki_page_id":None,"message":"Grounded in one source","citations":[{"id":U,"source_id":U,"source_chunk_id":None,"citation_key":"c1","citation_ref":"section 1","source_title":"Live notes","snippet":"Evidence snippet"}],"created_at":NOW,"updated_at":NOW}
paper={"id":U,"filename":"private.pdf","content_type":"application/pdf","extraction_status":"completed","extraction_message":"Review extraction","questions":[],"created_at":NOW,"updated_at":NOW}
class H(BaseHTTPRequestHandler):
 idempotency={}
 def log_message(self,*a): pass
 def reply(self,value,status=200,ctype="application/json",extra=None):
  body=value if isinstance(value,bytes) else json.dumps(value).encode(); self.send_response(status); self.send_header("Content-Type",ctype); self.send_header("Content-Length",str(len(body))); [self.send_header(*h) for h in (extra or [])]; self.end_headers(); self.wfile.write(body)
 def do_GET(self):
  if self.headers.get("Authorization")=="Bearer expired-token": return self.reply({"detail":"expired"},401)
  p=self.path
  if p.startswith("/api/outputs/page?"): return self.reply({"items":[output],"next_cursor":None})
  if p=="/api/outputs" or p.startswith("/api/outputs?"): return self.reply([output])
  if p.startswith("/api/outputs/"): return self.reply(output)
  if p=="/api/sources" and self.headers.get("Authorization")=="Bearer partial-token": return self.reply({"detail":"sources unavailable"},503)
  if p=="/api/sources": return self.reply([{"id":U,"user_id":U,"source_type":"pdf","title":"Live notes","status":"ready"}])
  if p=="/api/wiki/pages": return self.reply([{"id":U,"user_id":U,"slug":"live-notes","title":"Live notes","markdown":"# Live","source_ids":[U],"citation_count":1}])
  if p=="/api/wiki/pages/live-notes": return self.reply({"id":U,"user_id":U,"slug":"live-notes","title":"Live notes","markdown":"# Live","source_ids":[U],"citation_count":1})
  if p.endswith("/download"): return self.reply(b"# canonical\n",ctype="text/markdown",extra=[("Content-Disposition",'attachment; filename="live-notes.md"')])
  if p=="/api/workspace/health": return self.reply([{"id":U,"code":"thin_evidence","severity":"warning","state":"warning","resource_type":"topic","resource_id":None,"topic":"recursion","message":"Only one signal","recommendation":"Review more evidence","created_at":NOW}])
  if p.startswith("/api/workspace/health/"): return self.reply({"id":U,"code":"thin_evidence","severity":"warning","state":"warning","resource_type":"topic","resource_id":None,"topic":"recursion","message":"Only one signal","recommendation":"Review more evidence","created_at":NOW})
  if p=="/api/workspace/history": return self.reply([])
  if p=="/api/meters/topics": return self.reply([{"topic":"recursion","estimated_completion":72.5,"evidence_confidence":0.8,"evidence_count":4,"state":"measured","stale":False,"signals":[{"name":"paper","value":0.75,"evidence_count":4}],"recommendation":"Review cited notes"}])
  if p.startswith("/api/marked-papers/page?"): return self.reply({"items":[paper],"next_cursor":None})
  if p.startswith("/api/marked-papers?"): return self.reply([paper])
  if p.startswith("/api/marked-papers/"): return self.reply(paper)
  if p=="/api/providers": return self.reply([{"id":"openai","name":"OpenAI","models":["gpt-4o"],"endpoint":"https://api.openai.com/v1"}])
  if p=="/api/providers/settings": return self.reply([])
  return self.reply({"detail":"missing"},404)
 def mutate(self):
  n=int(self.headers.get("content-length",0)); body=self.rfile.read(n); key=self.headers.get("Idempotency-Key")
  signature=(self.command,self.path,body)
  if self.path=="/api/outputs" and key in self.idempotency:
   if self.idempotency[key]!=signature: return self.reply({"error":"idempotency_key_reused"},409)
   return self.reply(output,201)
  if self.path=="/api/outputs": self.idempotency[key]=signature
  open(sys.argv[2],"ab").write(self.command.encode()+b" "+self.path.encode()+b" "+str(key).encode()+b" "+body+b"\n")
  if self.headers.get("Authorization")=="Bearer expired-token": return self.reply({"detail":"expired"},401)
  if self.path=="/api/wiki/download" and body!=b"null": return self.reply({"detail":"not an archive"})
  if self.path=="/api/wiki/download": return self.reply(b"PK\x03\x04archive",ctype="application/zip",extra=[("Content-Disposition",'attachment; filename="canonical-workspace.zip"')])
  if self.path=="/api/outputs": return self.reply(output,201)
  if self.path=="/api/workspace/health": return self.reply([],200)
  if self.command=="DELETE": return self.reply(b"",204)
  return self.reply(paper if "marked-papers" in self.path else {"provider":"openai","model":"gpt-4o","endpoint":"https://api.openai.com/v1","status":"configured","credential":"********","last_tested_at":None,"updated_at":NOW})
 do_POST=mutate; do_PUT=mutate; do_PATCH=mutate; do_DELETE=mutate
HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
python3 "$TMP/spy.py" "$BACKEND_PORT" "$TMP/requests" & BPID=$!
for i in $(seq 1 50); do curl -fsS "http://127.0.0.1:$BACKEND_PORT/api/outputs" >/dev/null 2>&1 && break; sleep .1; done
cd "$ROOT"; WIKIBASE_BACKEND_URL="http://127.0.0.1:$BACKEND_PORT" WIKIBASE_PUBLIC_ORIGIN="http://127.0.0.1:$FRONTEND_PORT" WIKIBASE_MOCK_ENABLED=true ./zig-out/bin/app --host 127.0.0.1 --port "$FRONTEND_PORT" --no-dev --no-dotenv >"$TMP/frontend.log" 2>&1 & FPID=$!
for i in $(seq 1 80); do curl -fsS "http://127.0.0.1:$FRONTEND_PORT/login" >/dev/null 2>&1 && break; sleep .1; done
base="http://127.0.0.1:$FRONTEND_PORT"; cookie="cp_session=spy-token"
curl -fsS "http://127.0.0.1:$BACKEND_PORT/api/outputs" | grep -q 'Grounded summary'
check(){ body=$(curl -fsS -H "Cookie: $cookie" "$base$1"); case "$body" in *"$2"*) :;; *) echo "missing '$2' on $1" >&2; exit 1;; esac; }
check /outputs "Grounded summary"; body=$(curl -fsS -H "Cookie: $cookie" "$base/settings/providers"); case "$body" in *'readonly aria-label="Fixed official endpoint URL"'*) :;; *) echo "fixed provider endpoint is editable" >&2; exit 1;; esac; check "/outputs/$U" "Evidence snippet"; check /health "Review more evidence"; check "/health/$U" "Remediation"; check /history "No recorded changes"; check /progress "73%"; check /marked-papers "private.pdf"; check "/marked-papers/$U" "Add question manually"; check /settings/providers "Replacement API key"; check /wiki "Export Markdown workspace"; check /wiki/live-notes "Download canonical Markdown"
# Explicit demo remains explicit; a dead live backend never falls back to its fixture title.
body=$(curl -fsS "$base/outputs?mock=1"); case "$body" in *"synthetic fixtures"*) :;; *) exit 1;; esac
kill "$BPID"; wait "$BPID" 2>/dev/null || true; unset BPID
body=$(curl -fsS -H "Cookie: $cookie" "$base/outputs"); case "$body" in *"Service unavailable"*) :;; *) exit 1;; esac; case "$body" in *"Immutable lists and streams"*) exit 1;; *) :;; esac
# Restart spy and verify origin guard, mutation forwarding/status, and real bounded download headers.
python3 "$TMP/spy.py" "$BACKEND_PORT" "$TMP/requests" & BPID=$!; sleep .2
body=$(curl -fsS -H 'Cookie: cp_session=partial-token' "$base/outputs"); case "$body" in *'value="source_ids" disabled'*"Sources are unavailable"*) :;; *) echo "partial dependency state missing" >&2; exit 1;; esac
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"action":"health.run","idempotency_key":"00000000-0000-4000-8000-000000000001"}' "$base/api/m3"); test "$code" = 403
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -d '{"action":"output.create","idempotency_key":"00000000-0000-4000-8000-000000000002","payload":{"output_type":"summary","topic":"recursion"}}' "$base/api/m3"); test "$code" = 201
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -d '{"action":"output.create","idempotency_key":"00000000-0000-4000-8000-000000000002","payload":{"output_type":"summary","topic":"recursion"}}' "$base/api/m3"); test "$code" = 201
grep -c 'POST /api/outputs' "$TMP/requests" | grep -q '^1$'
python3 - "$TMP/near-limit.json" <<'PY'
import base64,json,sys
raw=b"A"*(10*1024*1024)
with open(sys.argv[1],"w") as f: json.dump({"action":"paper.upload","idempotency_key":"00000000-0000-4000-8000-000000000004","payload":{"filename":"near-limit.pdf","content_type":"application/pdf","content_base64":base64.b64encode(raw).decode()}},f)
PY
code=$(curl -sS -o "$TMP/near-limit-response" -w '%{http_code}' -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -H 'Expect:' --data-binary "@$TMP/near-limit.json" "$base/api/m3"); if [ "$code" != 200 ]; then cat "$TMP/near-limit-response" >&2; exit 1; fi
python3 - "$FRONTEND_PORT" "$TMP/near-limit.json" <<'PY'
import http.client,sys
port=int(sys.argv[1]); body=open(sys.argv[2],"rb").read().replace(b"000000000004",b"000000000007",1)
connection=http.client.HTTPConnection("127.0.0.1",port,timeout=30)
headers={"Cookie":"cp_session=spy-token","Origin":f"http://127.0.0.1:{port}","Sec-Fetch-Site":"same-origin","Content-Type":"application/json"}
connection.request("POST","/api/m3",body,headers); response=connection.getresponse(); response.read(); assert response.status==200
connection.request("GET","/progress",headers={"Cookie":"cp_session=spy-token"}); response=connection.getresponse(); content=response.read(); assert response.status==200 and b"73%" in content
connection.close()
PY
python3 - "$TMP/oversize.json" <<'PY'
import sys
with open(sys.argv[1],"wb") as f: f.write(b"{"+b" "*(15*1024*1024)+b"}")
PY
code=$(curl -sS -D "$TMP/oversize-headers" -o "$TMP/oversize-response" -w '%{http_code}' -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -H 'Expect:' --data-binary "@$TMP/oversize.json" "$base/api/m3"); test "$code" = 413; grep -qi '^connection: close' "$TMP/oversize-headers"; grep -q 'content_length_too_large' "$TMP/oversize-response"
code=$(curl -sS -D "$TMP/expired-headers" -o /dev/null -w '%{http_code}' -H 'Cookie: cp_session=expired-token' -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -d '{"action":"health.run","idempotency_key":"00000000-0000-4000-8000-000000000005"}' "$base/api/m3"); test "$code" = 401; grep -qi 'set-cookie: cp_session=;.*Max-Age=0.*HttpOnly.*SameSite=Lax' "$TMP/expired-headers"
code=$(curl -sS -D "$TMP/page-expired-headers" -o /dev/null -w '%{http_code}' -H 'Cookie: cp_session=expired-token' "$base/outputs"); test "$code" = 303; grep -qi 'location: /login' "$TMP/page-expired-headers"; grep -qi 'set-cookie: cp_session=;.*Max-Age=0' "$TMP/page-expired-headers"
curl -fsS -D "$TMP/headers" -o "$TMP/export.zip" -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -d '{"action":"wiki.export","idempotency_key":"00000000-0000-4000-8000-000000000003"}' "$base/api/m3"; grep -qi 'content-disposition: attachment; filename="canonical-workspace.zip"' "$TMP/headers"; grep -qi 'content-type: application/zip' "$TMP/headers"; test -s "$TMP/export.zip"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H "Origin: $base" -H 'Sec-Fetch-Site: same-origin' -H 'Content-Type: application/json' -d '{"action":"wiki.export","idempotency_key":"00000000-0000-4000-8000-000000000006","payload":{"page_ids":["11111111-1111-1111-1111-111111111111"]}}' "$base/api/m3"); test "$code" = 502
! grep -q 'api_key' "$TMP/frontend.log"
echo "M3 live HTTP smoke passed"
