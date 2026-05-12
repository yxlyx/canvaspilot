# CanvasPilot -- Overall Implementation Plan

## Project Overview

CanvasPilot is a Canvas-integrated academic copilot that combines automated ingestion of Canvas module content, a RAG-powered AI Q&A system with source citations, and automatic task/deadline extraction into a unified dashboard for NUS students.

**Level of Achievement:** Artemis
**Tech Stack:** merjs (frontend) | FastAPI (backend) | PostgreSQL + pgvector | OpenAI API | Vercel/Railway or equivalent

---

## Current Status -- 2026-05-12

Backend Milestone 1 is implemented and locally verified. OAuth settings are configured, but real Canvas OAuth verification is blocked until NUS replies with developer key approval/details.

Backend status:

- FastAPI app, routers, models, schemas, migrations, and services are scaffolded.
- Canvas OAuth backend code is implemented.
- Dual auth is implemented: Bearer JWT for server-side/frontend calls and session cookie support for browser-direct SSE.
- Canvas client, ingestion, embedding, retrieval, and chat streaming code are implemented.
- pgvector IVFFlat index migration has been added.
- Backend tests pass: 51 tests.
- Ruff lint is clean.

Next backend work:

- Complete real Canvas OAuth verification once NUS responds.
- Add pgvector-backed integration tests for retrieval and chat endpoint paths.
- Implement DB-backed `SyncJob` lifecycle for multi-module sync.
- Add incremental sync, file parsing, task extraction, summaries, and syllabus-bounded responses for Milestone 2.

Frontend coordination status:

- Frontend is now assumed to be merjs rather than Next.js/Auth.js.
- Backend owns Canvas OAuth code exchange, encrypted Canvas token storage, token refresh, and app session issuance.
- Frontend should consume stable snake_case JSON responses and the documented SSE chat format.

## Repository Structure

```
canvaspilot/
├── frontend/                    # merjs app (Yu Xi owns)
│   └── ...                      # Yu Xi owns frontend structure
│
├── backend/                     # FastAPI app (Pranav owns)
│   ├── app/
│   │   ├── main.py              # FastAPI entrypoint
│   │   ├── config.py            # Environment & settings
│   │   ├── models/              # SQLAlchemy models
│   │   ├── schemas/             # Pydantic request/response schemas
│   │   ├── routers/             # API route handlers
│   │   │   ├── auth.py          # OAuth token exchange
│   │   │   ├── modules.py       # Module CRUD endpoints
│   │   │   ├── chat.py          # RAG Q&A endpoint
│   │   │   ├── tasks.py         # Task/deadline endpoints
│   │   │   └── sync.py          # Trigger/status for Canvas sync
│   │   ├── services/            # Business logic
│   │   │   ├── canvas.py        # Canvas REST API client
│   │   │   ├── ingestion.py     # Content parsing & chunking
│   │   │   ├── embedding.py     # Vectorisation service
│   │   │   ├── retrieval.py     # RAG retrieval pipeline
│   │   │   ├── llm.py           # LLM orchestration (Q&A, summaries)
│   │   │   ├── tasks.py         # Task extraction engine
│   │   │   └── summariser.py    # Document/announcement summarisation
│   │   └── db/
│   │       ├── database.py      # DB connection & session
│   │       └── migrations/      # Alembic migrations
│   ├── tests/
│   ├── pyproject.toml
│   └── Dockerfile
│
├── shared/                      # API contract (both touch, rarely changes)
│   └── api-spec.yaml            # OpenAPI spec (source of truth)
│
├── .github/
│   └── workflows/
│       ├── frontend.yml         # Frontend CI (Yu Xi owns)
│       └── backend.yml          # Backend CI (Pranav owns)
│
├── docker-compose.yml           # Local dev (Postgres + pgvector)
└── README.md
```

---

## Ownership Split

| Area | Owner | Directory |
|------|-------|-----------|
| Backend API, Canvas client, RAG pipeline, task extraction, LLM orchestration, backend tests | **Pranav** | `backend/` |
| Frontend UI, merjs auth/login screens, dashboard, chat interface, frontend tests, deployment | **Yu Xi** | `frontend/` |
| API contract (OpenAPI spec) | **Both** (PR-only) | `shared/` |
| Backend CI | **Pranav** | `.github/workflows/backend.yml` |
| Frontend CI | **Yu Xi** | `.github/workflows/frontend.yml` |

**Key rule: Pranav never touches `frontend/`. Yu Xi never touches `backend/`.** All communication goes through the API spec.

---

## API Contract (Agreed Upfront)

Both developers commit to this API spec before writing code. Changes require a PR reviewed by the other person.

### Core Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/auth/canvas/start` | Start Canvas OAuth redirect |
| `GET` | `/api/auth/canvas/callback` | Canvas OAuth callback and token storage |
| `GET` | `/api/auth/me` | Get current user info |
| `POST` | `/api/auth/logout` | Clear app session |
| `GET` | `/api/modules` | List synced modules |
| `POST` | `/api/modules/sync` | Trigger Canvas sync |
| `GET` | `/api/modules/{id}` | Module detail (announcements, files) |
| `GET` | `/api/modules/{id}/announcements` | Module announcements |
| `POST` | `/api/chat` | RAG Q&A (streaming SSE) |
| `GET` | `/api/tasks` | All extracted tasks/deadlines |
| `GET` | `/api/tasks/upcoming` | Upcoming deadlines |
| `GET` | `/api/modules/{id}/summary` | Module content summary |
| `GET` | `/api/modules/{id}/diff` | Changes since last visit |

### Response Schemas (Key Types)

```typescript
// Module
{ id: string; name: string; code: string; term: string; lastSynced: string; }

// Announcement
{ id: string; moduleId: string; title: string; content: string; postedAt: string; summary?: string; }

// Task
{ id: string; moduleId: string; title: string; type: "assignment" | "quiz" | "tutorial" | "exam"; dueDate: string; completed: boolean; source: string; }

// ChatMessage
{ role: "user" | "assistant"; content: string; citations?: { title: string; url: string; snippet: string; }[]; }

// ChatRequest
{ moduleId?: string; message: string; history: ChatMessage[]; }
```

---

## Milestone Breakdown

### Milestone 1 -- Technical Proof of Concept

| # | Task | Owner | Dependencies |
|---|------|-------|-------------|
| 1.1 | Project scaffolding: Next.js app, FastAPI app, docker-compose with Postgres+pgvector | Both (pair) | None |
| 1.2 | Canvas OAuth 2.0 flow (backend token exchange + frontend redirect) | Pranav (backend), Yu Xi (frontend) | 1.1 |
| 1.3 | Canvas API client: fetch modules, announcements, assignments for one module | Pranav | 1.2 |
| 1.4 | Content parsing & chunking pipeline (HTML announcements, assignment descriptions) | Pranav | 1.3 |
| 1.5 | Embedding service: chunk -> text-embedding-3-small -> pgvector storage | Pranav | 1.4 |
| 1.6 | RAG retrieval: cosine similarity search, top-k chunks with confidence threshold | Pranav | 1.5 |
| 1.7 | Chat endpoint: streaming SSE with GPT-4o, grounded prompt, source citations | Pranav | 1.6 |
| 1.8 | Auth UI: login page, backend OAuth redirect/callback handling, app session persistence | Yu Xi | 1.1 |
| 1.9 | Dashboard page: display announcements + assignments for one module | Yu Xi | 1.1 |
| 1.10 | Chat UI: message input, streaming response display, citation links | Yu Xi | 1.1 |
| 1.11 | GitHub Actions CI: ESLint/Prettier (frontend), Ruff/pytest (backend) | Both (one file each) | 1.1 |
| 1.12 | Deploy: Vercel (frontend) + Railway (backend + DB) | Both (pair) | All above |

### Milestone 2 -- Prototype

| # | Task | Owner | Dependencies |
|---|------|-------|-------------|
| 2.1 | Multi-module sync: fetch all enrolled modules, incremental sync | Pranav | 1.3 |
| 2.2 | PDF/DOCX parsing: PyMuPDF + python-docx for uploaded files | Pranav | 1.4 |
| 2.3 | Calendar event ingestion: parse Canvas calendar API | Pranav | 2.1 |
| 2.4 | Task extraction engine: parse deadlines from announcements + assignments | Pranav | 2.1 |
| 2.5 | Announcement/document summarisation service | Pranav | 2.1 |
| 2.6 | Syllabus-bounded responses: confidence threshold + "I don't know" fallback | Pranav | 1.7 |
| 2.7 | Multi-module dashboard: module cards, recent updates, deadline timeline | Yu Xi | 1.9 |
| 2.8 | Task/deadline view: to-do list with filters, completion toggle, timeline | Yu Xi | 1.9 |
| 2.9 | Chat UI improvements: module selector, conversation history, citation panel | Yu Xi | 1.10 |
| 2.10 | Summary display: inline summaries on announcements and documents | Yu Xi | 1.9 |
| 2.11 | Responsive design + mobile layout | Yu Xi | 2.7-2.10 |
| 2.12 | User testing with 8-10 NUS students, SUS scores | Both (pair) | All above |

### Milestone 3 -- Extended System

| # | Task | Owner | Dependencies |
|---|------|-------|-------------|
| 3.1 | Smart study recommendations endpoint | Pranav | 2.4, 2.5 |
| 3.2 | Weekly study planner generation | Pranav | 3.1 |
| 3.3 | iCal export endpoint for tasks | Pranav | 2.4 |
| 3.4 | Module content diff: track last-visited, compute changes | Pranav | 2.1 |
| 3.5 | Study recommendations UI | Yu Xi | 2.7 |
| 3.6 | Weekly planner UI | Yu Xi | 2.7 |
| 3.7 | Calendar export UI + Google Calendar integration | Yu Xi | 2.8 |
| 3.8 | "What changed" diff view per module | Yu Xi | 2.7 |
| 3.9 | UI/UX refinements from Milestone 2 feedback | Yu Xi | 2.12 |
| 3.10 | Backend test suite >= 80% coverage | Pranav | All backend |
| 3.11 | Playwright E2E tests for critical flows | Yu Xi | All frontend |
| 3.12 | Final documentation: architecture doc, setup guide, ADRs | Both (pair) | All |

---

## Integration Points (Conflict-Risk Zones)

These are the only areas where both developers touch code. Handle with care:

1. **`shared/api-spec.yaml`** -- Change via PR only, never direct push
2. **`docker-compose.yml`** -- Rarely changes after initial setup
3. **`.github/workflows/`** -- Each person owns their own CI file
4. **`README.md`** -- Update at milestones only, coordinate via PR
5. **Initial scaffolding (1.1)** -- Pair-program this in a single session

---

## Branching Strategy

```
main (protected, always deployable)
├── feature/backend-canvas-oauth     (Pranav)
├── feature/backend-rag-pipeline     (Pranav)
├── feature/frontend-auth-ui         (Yu Xi)
├── feature/frontend-dashboard       (Yu Xi)
└── ...
```

- All branches require 1 review from the other team member
- Backend branches only touch `backend/` and `shared/`
- Frontend branches only touch `frontend/` and `shared/`
- This directory isolation prevents merge conflicts

---

## Coordination Checklist

- [x] **Day 1:** Pair-program scaffolding (1.1) together -- agree on repo structure, docker-compose, and API spec
- [ ] **Week 1:** Both review and merge/update `shared/api-spec.yaml` -- this is the contract
- [ ] **OAuth blocker:** Wait for NUS Canvas developer key response, then verify real redirect chain end to end
- [ ] **Backend next:** Implement DB-backed `SyncJob` lifecycle before PDF/DOCX and task extraction work
- [ ] **Weekly:** 15-min sync to discuss any API changes or blockers
- [ ] **Before Milestone 2:** Joint code review of all Milestone 1 PRs
- [ ] **Milestone 2:** Coordinate user testing logistics together
- [ ] **Before Milestone 3:** Review user testing feedback together, prioritise fixes
