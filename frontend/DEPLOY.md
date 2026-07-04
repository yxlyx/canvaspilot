# Deploying the WikiBase frontend

Milestone 1 of the proposal calls for an end-to-end proof of concept deployed
for one complete query flow. The original proposal listed Vercel + Railway as
the deploy target, but the frontend was implemented in Zig with
[merjs](https://github.com/justrach/merjs) — a single statically-compiled
binary — so Vercel's Node runtime doesn't apply. Railway (or any other
container host) is the natural fit instead.

This directory ships a `Dockerfile` that produces a small Debian image with
the compiled binary and the `public/` static assets. Everything below uses
that one image.

## Required environment variables

| Variable                  | Purpose                                                                                | Required?       |
| ------------------------- | -------------------------------------------------------------------------------------- | --------------- |
| `PORT`                    | Port the HTTP server binds to. Railway / Fly inject this automatically.                 | Yes (defaults to `3001`) |
| `WIKIBASE_BACKEND_URL` | Base URL of the FastAPI backend, e.g. `https://wikibase-backend.up.railway.app`.    | Yes for real backend; otherwise falls back to mock data |
| `WIKIBASE_SESSION_COOKIE` | Name of the HttpOnly cookie storing the app JWT. Defaults to `cp_session`.         | No              |

## 1. Railway (matches the proposal)

1. Push this repo to GitHub.
2. In Railway, create a new project → "Deploy from GitHub repo".
3. Pick the repo and set the **root directory** to `frontend`.
4. Railway auto-detects the `Dockerfile`. The build runs `zig build
   -Doptimize=ReleaseSafe` inside the container, takes ~2–3 min on a cold build.
5. Add the env vars listed above under "Variables".
6. Generate a public domain. Visit `/dashboard?mock=1` to verify SSR.

## 2. Fly.io (alternative — same image)

```bash
cd frontend
fly launch --no-deploy   # answer no to Postgres / Redis; pick a region
fly deploy
```

`fly launch` writes a `fly.toml` that points at the `Dockerfile` and forwards
port `8080` → container `$PORT`.

## 3. Local Docker (for one-off smoke tests)

```bash
cd frontend
docker build -t wikibase-frontend .
docker run --rm -p 3001:3001 \
  -e WIKIBASE_BACKEND_URL=http://host.docker.internal:8000 \
  wikibase-frontend
# open http://localhost:3001/dashboard?mock=1
```

## Future: Cloudflare Workers

merjs has a `worker` build mode that compiles the same routes to WASM and runs
them on the Cloudflare edge (see `zig-pkg/.../examples/kanban/worker/` for a
worked example). It needs a `worker_entry.zig` that explicitly lists routes,
a `wrangler.toml`, and a JS shim. We've held that for Milestone 2/3 — the
Railway/Fly Docker path covers Milestone 1's "end-to-end proof of concept"
requirement with much less moving infrastructure.
