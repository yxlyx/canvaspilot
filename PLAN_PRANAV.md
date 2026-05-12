# CanvasPilot -- Pranav's Plan (Backend + AI/ML Pipeline)

## Current Status -- 2026-05-12

Milestone 1 backend implementation is substantially complete and locally verified.

- FastAPI app, models, schemas, routers, Alembic migrations, Docker config, and backend CI are scaffolded.
- Canvas OAuth backend endpoints and dual auth are implemented.
- Canvas OAuth env vars are configured locally, but the real OAuth flow is blocked until NUS replies with Canvas developer key approval/details.
- Local Phase 1 verification has been completed against the backend stack.
- pgvector IVFFlat embedding index migration has been added.
- Backend unit test suite is passing: 51 tests.
- Ruff lint is clean.

Remaining Milestone 1 backend work:

- Complete manual Canvas OAuth redirect flow once NUS responds.
- Run one real user sync against Canvas after OAuth is approved.
- Add DB-backed integration tests for `retrieve()` and chat endpoint behavior with pgvector.
- Share stable backend URL and SSE/auth contract with Yu Xi when deployment is ready.

## Your Domain

You own everything in `backend/`, the FastAPI server, Canvas API integration, content ingestion pipeline, RAG retrieval, LLM orchestration, task extraction, and all backend tests. You also own `.github/workflows/backend.yml`.

**Rule: You never touch `frontend/`.** If you need a frontend change, open an issue or message Yu Xi. If an API endpoint needs to change, open a PR on `shared/api-spec.yaml` first.

---

## Milestone 1 -- Technical Proof of Concept

### Week 1-2: Foundation

#### 1. Project scaffolding (pair with Yu Xi)
- Set up monorepo structure, `docker-compose.yml` with Postgres 16 + pgvector
- FastAPI project with `pyproject.toml`, Ruff config, pytest setup
- SQLAlchemy models: `User`, `Module`, `Announcement`, `Assignment`, `ContentChunk`, `Task`
- Alembic migrations for initial schema
- Files: `backend/app/models/`, `backend/app/db/`, `backend/app/config.py`

#### 2. Canvas OAuth 2.0 backend
- OAuth start/callback/logout/me endpoints
- Store encrypted access/refresh tokens per user
- Token refresh support in the Canvas client
- App session support through Bearer JWT and session cookie
- Status: implemented and locally configured; pending NUS Canvas developer approval for real redirect-chain verification
- Files: `backend/app/routers/auth.py`, `backend/app/services/canvas.py`, `backend/app/dependencies.py`

### Week 3-4: Ingestion + RAG

#### 3. Canvas API client
- Fetch enrolled courses, announcements, assignments, files for a single module
- Paginated API calls with rate limiting
- Files: `backend/app/services/canvas.py`

#### 4. Content parsing & chunking
- HTML to text extraction (BeautifulSoup) for announcements
- Chunk strategy: 512-token chunks with 64-token overlap
- Metadata preservation (source module, document title, URL)
- Files: `backend/app/services/ingestion.py`

#### 5. Embedding + vector storage
- OpenAI `text-embedding-3-small` integration
- Batch embedding with retry logic
- Store in pgvector (`ContentChunk` table with `embedding` column)
- Files: `backend/app/services/embedding.py`

#### 6. RAG retrieval pipeline
- Cosine similarity search via pgvector
- Top-k retrieval (k=5) with confidence threshold (>0.7)
- Re-ranking by recency + relevance
- Files: `backend/app/services/retrieval.py`

#### 7. Chat endpoint with streaming
- `POST /api/chat` with SSE streaming
- System prompt enforcing grounded responses + citation format
- Parse LLM output to extract citation references
- Files: `backend/app/routers/chat.py`, `backend/app/services/llm.py`

#### 8. Backend CI
- GitHub Actions: Ruff lint, pytest with Postgres service container
- Files: `.github/workflows/backend.yml`

### Milestone 1 Deliverable
A working backend where: user authenticates via Canvas OAuth, module content is ingested and embedded, and a chat query returns a grounded streaming response with citations.

Current deliverable status: backend code is ready for real OAuth verification once NUS responds. Until then, Milestone 2 backend work can proceed behind mocked Canvas/API tests and local seeded data.

---

## Immediate Execution Plan

Use this order from here.

### A. While Waiting For NUS OAuth Approval

1. Add DB-backed integration tests
   - Seed `users`, `modules`, and `content_chunks` with pgvector embeddings.
   - Test `retrieve()` returns expected chunks.
   - Test low/no-result paths.
   - Test `/api/chat` with mocked retrieval and mocked LLM stream.

2. Start Milestone 2A: DB-backed sync lifecycle
   - Add `SyncJob` model.
   - Add Alembic migration for `sync_jobs`.
   - Replace in-memory `_active_syncs` with DB-backed job status.
   - Keep `POST /api/modules/sync` and `GET /api/modules/sync/status` response shapes stable.
   - Return 409 if a user already has a running sync.

3. Improve incremental sync semantics
   - Use `module.last_synced_at` to fetch changed Canvas data where Canvas supports it.
   - Replace chunks by `(module_id, source_type, source_id)` for changed sources.
   - Re-embed only new or changed chunks.

### B. Once NUS OAuth Approval Arrives

1. Test full OAuth chain
   - `GET /api/auth/canvas/start`
   - Canvas login/consent
   - `GET /api/auth/canvas/callback`
   - redirect back to `FRONTEND_URL`
   - verify app token/session behavior

2. Test real Canvas ingestion
   - Sync one user.
   - Confirm encrypted Canvas tokens in DB.
   - Confirm modules, announcements, assignments, chunks, and embeddings are created.

3. Share backend contract with Yu Xi
   - Auth start/callback/logout/me paths.
   - SSE event format.
   - Error response format.
   - Local and deployed backend URLs.

---

## Milestone 2 -- Prototype

### Week 5-7: Full Pipeline

#### 9. Multi-module sync
- Sync all enrolled modules.
- Track sync progress with a DB-backed `SyncJob`.
- Support incremental updates using `last_synced_at` and Canvas `updated_since` where available.
- Delete or replace orphaned chunks for changed/deleted source items.
- Re-embed only new/changed content.
- Return 409 when a sync is already running for the same user.
- Files: `backend/app/models/`, `backend/app/services/ingestion.py`, `backend/app/services/canvas.py`, `backend/app/routers/sync.py`

#### 10. PDF + DOCX parsing
- PyMuPDF for PDF text extraction with page-level chunking
- python-docx for DOCX files
- File download from Canvas Files API
- Skip files over 10MB
- Store file chunks with `source_type="file"`
- Files: `backend/app/services/ingestion.py`

#### 11. Calendar event ingestion
- Canvas Calendar API integration
- Parse into structured `Task` objects
- Deduplicate against assignment-created tasks by Canvas source ID
- Files: `backend/app/services/canvas.py`, `backend/app/services/tasks.py`

#### 12. Task extraction engine
- Rule-based extraction: due dates from assignment metadata
- LLM-assisted extraction: parse deadlines from announcement text
- Structured output: title, type, due date, source link
- Keep LLM extraction bounded to recent announcements first
- Files: `backend/app/services/tasks.py`, `backend/app/routers/tasks.py`

#### 13. Summarisation service
- GPT-4o summarisation with length constraints
- Cache summaries in DB (regenerate on content change)
- Add content hash invalidation
- Add `GET /api/modules/{id}/summary`
- Files: `backend/app/services/summariser.py`

#### 14. Syllabus-bounded responses
- Confidence threshold on retrieval scores
- System prompt: "If no relevant chunks found, say you don't have enough information"
- Response metadata: `grounded: boolean`, `confidence: float`
- Skip LLM call entirely when best retrieval score is below threshold
- Files: `backend/app/services/retrieval.py`, `backend/app/services/llm.py`

### Milestone 2 Deliverable
Full backend supporting all enrolled modules, PDF/DOCX ingestion, task extraction, summarisation, and syllabus-bounded RAG Q&A.

---

## Milestone 3 -- Extended System

#### 15. Smart study recommendations
- Endpoint suggesting topics based on upcoming deadlines + recent content
- Weigh by deadline proximity and content recency
- Files: `backend/app/routers/modules.py`, `backend/app/services/` (new recommendations service)

#### 16. Weekly study planner
- Generate distributable weekly plan from tasks + available days
- LLM-assisted scheduling with workload balancing
- Files: `backend/app/services/` (new planner service)

#### 17. iCal export
- Generate `.ics` file from extracted tasks
- `GET /api/tasks/export/ical` endpoint
- Files: `backend/app/routers/tasks.py`

#### 18. Module content diff
- Track `last_visited_at` per user-module pair
- Return new/changed items since last visit
- `GET /api/modules/{id}/diff` endpoint
- Files: `backend/app/routers/modules.py`, `backend/app/models/`

#### 19. Backend test suite
- >=80% coverage target
- Integration tests with real DB (Postgres service container in CI)
- Fixture data from real Canvas module exports
- Unit tests for chunking, task extraction, retrieval scoring
- Files: `backend/tests/`

#### 20. API documentation
- Auto-generated OpenAPI docs (FastAPI built-in)
- Architecture doc and ADRs (pair with Yu Xi)
- Files: `docs/`

---

## Your Feature Branches

```
feature/backend-scaffolding          (Week 1)
feature/backend-canvas-oauth         (Week 1-2)
feature/backend-canvas-client        (Week 3)
feature/backend-ingestion-pipeline   (Week 3)
feature/backend-embedding            (Week 3-4)
feature/backend-rag-retrieval        (Week 4)
feature/backend-chat-endpoint        (Week 4)
feature/backend-multi-module-sync    (Week 5)
feature/backend-pdf-docx-parsing     (Week 5-6)
feature/backend-task-extraction      (Week 6)
feature/backend-summarisation        (Week 6-7)
feature/backend-syllabus-bounded     (Week 7)
feature/backend-study-recommendations (Week 8)
feature/backend-weekly-planner       (Week 8-9)
feature/backend-ical-export          (Week 9)
feature/backend-content-diff         (Week 9)
feature/backend-tests                (Week 10)
```

---

## Dependencies on Yu Xi

- **Week 1:** Yu Xi builds merjs login/callback/logout UI. Backend owns Canvas OAuth code exchange, encrypted token storage, token refresh, and app session issuance.
- **Week 1:** Agree whether merjs calls FastAPI server-side, browser-side with CORS, or via merjs proxy routes.
- **Week 3-4:** She builds the chat UI that consumes your SSE stream -- SSE format is already implemented and should stay stable.
- **Milestone 2:** She needs your task and summary endpoints to be stable before building those UI views
- **Milestone 2:** Coordinate user testing together

## What Yu Xi Needs From You

- Stable, documented API endpoints matching `shared/api-spec.yaml`
- SSE streaming format documented (event types, data shape)
- Error response format consistent across all endpoints (e.g. `{ error: string; detail?: string }`)
- Backend deployed on Railway before she integrates the frontend
