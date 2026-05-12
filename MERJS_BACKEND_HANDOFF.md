# CanvasPilot merjs Frontend Change: Backend Handoff

## Current Status -- 2026-05-12

Backend OAuth code is implemented and local OAuth-related env vars are configured:

- `CANVAS_BASE_URL=https://canvas.nus.edu.sg`
- `CANVAS_OAUTH_REDIRECT_URI=http://localhost:8000/api/auth/canvas/callback`
- `FRONTEND_URL=http://localhost:3000`
- `BACKEND_URL=http://localhost:8000`

Real OAuth verification is not complete yet because NUS has not replied with Canvas developer key approval/details. Until then, frontend/backend integration should treat the OAuth redirect chain as implemented but externally blocked.

Backend Phase 1 verification has otherwise been completed locally. Backend tests pass and lint is clean.

Yu Xi is switching the frontend from Next.js to merjs. This does not change the backend's core responsibilities around Canvas ingestion, RAG, tasks, summaries, or storage, but it does change the auth/frontend integration assumptions.

## Main Backend Plan Change

Replace this assumption:

> Yu Xi sets up Auth.js on the frontend to redirect to your OAuth callback.

With this:

> Yu Xi will build the merjs login/callback/logout UI. Pranav's backend should own Canvas OAuth code exchange, Canvas token storage, token refresh, and the authenticated backend session. The frontend should receive only an app session cookie or app session token, not Canvas access/refresh tokens.

## Things To Confirm Between Frontend And Backend

### 1. OAuth Flow Ownership

Recommended flow:

```text
User clicks "Connect with Canvas"
  -> merjs frontend redirects to backend OAuth start endpoint
  -> backend redirects user to Canvas
  -> Canvas redirects back to backend callback endpoint
  -> backend exchanges code for Canvas tokens
  -> backend stores encrypted Canvas tokens
  -> backend creates app session
  -> backend redirects user back to merjs /dashboard
```

Backend should confirm:

- Exact OAuth start URL, e.g. `GET /api/auth/canvas/start`.
- Exact OAuth callback URL, e.g. `GET /api/auth/canvas/callback`.
- Redirect target after success, e.g. `FRONTEND_URL/dashboard`.
- Redirect target after failure, e.g. `FRONTEND_URL/login?error=oauth_failed`.
- Whether app session is a secure HTTP-only cookie or JWT.

### 2. Session Contract

Frontend needs one stable way to know whether the user is logged in.

Recommended endpoint:

```http
GET /api/auth/me
```

Recommended response:

```json
{
  "id": "user_123",
  "name": "Yu Xi",
  "email": "example@u.nus.edu",
  "canvasUserId": "12345"
}
```

For unauthenticated users:

```http
401 Unauthorized
```

```json
{
  "error": "unauthorized",
  "detail": "Session expired or missing"
}
```

### 3. Cookie And CORS Setup

Because merjs is not Next.js/Auth.js, backend and frontend need to agree on deployment domains.

Confirm:

- Will frontend and backend share a parent domain?
- Will cookies need `SameSite=None; Secure` for cross-site requests?
- Will frontend make browser-side calls directly to FastAPI?
- If yes, FastAPI must configure CORS for the merjs frontend origin and allow credentials.
- If no, merjs can call FastAPI server-side or through merjs proxy routes.

Recommended default:

- Server-rendered merjs pages call FastAPI server-side for dashboard/tasks/module data.
- Chat may use browser-to-FastAPI SSE if that is simpler.
- If browser-to-FastAPI is used, backend must support credentialed CORS.

### 4. SSE Chat Format

Frontend needs the exact streaming format early.

Backend should document:

- HTTP method and path, currently `POST /api/chat`.
- Whether the response is `text/event-stream`.
- Event names.
- JSON shape per event.
- End-of-stream event.
- Error event.
- Whether citations arrive at the end or during streaming.

Suggested format:

```text
event: token
data: {"text":"The assignment is due "}

event: token
data: {"text":"on Friday."}

event: citations
data: {"citations":[{"title":"Assignment 1","url":"https://...","snippet":"Due Friday..."}]}

event: done
data: {"grounded":true,"confidence":0.82}
```

### 5. Error Format

Frontend needs consistent errors because merjs pages will render error states directly.

Recommended shape:

```json
{
  "error": "short_machine_code",
  "detail": "Human readable message"
}
```

Examples:

- `unauthorized`
- `canvas_token_expired`
- `sync_in_progress`
- `module_not_found`
- `chat_unavailable`
- `rate_limited`

### 6. API Response Shape Stability

Because the frontend will define Zig structs, response shape changes are more painful than loose JavaScript objects.

Backend should avoid changing field names casually. If a response changes, update `shared/api-spec.yaml` first.

Frontend especially needs stable shapes for:

- `GET /api/auth/me`
- `GET /api/modules`
- `GET /api/modules/{id}`
- `GET /api/tasks`
- `POST /api/chat`
- `GET /api/modules/{id}/summary`
- `GET /api/modules/{id}/diff`

### 7. Deployment URLs

Backend needs these env vars or equivalent:

```text
FRONTEND_URL=http://localhost:3000
BACKEND_URL=http://localhost:8000
CANVAS_OAUTH_REDIRECT_URI=http://localhost:8000/api/auth/canvas/callback
```

For production, replace with deployed merjs and FastAPI URLs.

## Backend Plan Lines To Update

In Pranav's plan, update the dependency section:

Old:

```text
Week 1: She sets up Auth.js on the frontend to redirect to your OAuth callback
```

New:

```text
Week 1: Yu Xi builds merjs login/callback/logout UI. Backend owns Canvas OAuth code exchange, encrypted token storage, token refresh, and app session issuance. Both agree on session cookie/JWT format and redirect URLs.
```

Add:

```text
Week 1: Agree whether merjs calls FastAPI server-side, browser-side with CORS, or via merjs proxy routes.
Week 3-4: Document SSE chat event format before frontend chat integration.
```
