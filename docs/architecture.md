# CanvasPilot Architecture

This document records the Milestone 1 architecture for CanvasPilot and the main design
decisions behind it.

## Goals

CanvasPilot should:

- import module information from Canvas;
- structure announcements, assignments, files, and future task data;
- store searchable course content in PostgreSQL with pgvector;
- answer module questions with source citations;
- provide a small frontend proof of concept for dashboard and chat flows;
- keep the system easy to run locally and deploy incrementally.

## High-Level Components

```text
┌────────────┐       ┌──────────────────┐       ┌────────────────────┐
│ Canvas LMS │──────▶│ FastAPI backend  │──────▶│ PostgreSQL+pgvector │
└────────────┘       └──────────────────┘       └────────────────────┘
      ▲                       ▲                            ▲
      │                       │                            │
      │ OAuth                 │ HTTP API                   │ vector lookup
      │                       │                            │
┌────────────┐       ┌──────────────────┐       ┌────────────────────┐
│ NUS user   │──────▶│ merjs frontend   │──────▶│ chat/retrieval flow │
└────────────┘       └──────────────────┘       └────────────────────┘
```

## Backend

The backend is a FastAPI application under `backend/app`.

| Area | Files | Responsibility |
| --- | --- | --- |
| API routes | `app/routers/` | HTTP endpoints for auth, modules, sync, chat, tasks |
| Services | `app/services/` | Canvas calls, ingestion, embedding, retrieval, response generation |
| Models | `app/models/` | SQLAlchemy database tables |
| Schemas | `app/schemas/` | Pydantic request and response contracts |
| Database | `app/db/` | async database session and Alembic migrations |
| Tests | `backend/tests/` | unit and integration coverage |

### Backend Request Flow

```text
Frontend request
   ↓
FastAPI router
   ↓
Service layer
   ↓
Database or Canvas API
   ↓
Pydantic response
```

The service layer is kept separate from routers so Canvas API handling, ingestion, retrieval,
and response construction can be tested independently.

## Frontend

The frontend is a merjs application under `frontend/`.

| Area | Files | Responsibility |
| --- | --- | --- |
| Pages | `frontend/app/` | Home, login, callback, dashboard, chat, logout, 404 |
| API handlers | `frontend/api/` | frontend-side bridge routes for auth, me, sync, chat |
| Shared library | `frontend/src/lib/` | config, session, backend client, mock data, types, UI helpers |
| Entry point | `frontend/src/main.zig` | app boot and server startup |
| Route generation | `frontend/tools/codegen.zig` | scans app/api routes and writes route table |
| Static assets | `frontend/public/` | browser script for chat enhancement |

The frontend can run without a real Canvas session by using mock data. This keeps the M1 demo
usable while OAuth production approval is pending.

## Data Model

Milestone 1 uses these core entities:

```text
User
  └── Module
        ├── ContentItem
        │     └── ContentChunk + embedding
        └── Task
```

The schema is designed so raw Canvas content, parsed content, structured tasks, and vector
chunks can be stored together in one PostgreSQL database.

## Retrieval Flow

```text
User question
   ↓
Chat endpoint
   ↓
Embed query
   ↓
pgvector similarity search
   ↓
Select relevant chunks
   ↓
Build grounded answer
   ↓
Return answer + citations
```

For M1, the key requirement is to prove that course-specific chunks can be retrieved and tied
back to sources. Future milestones will add stronger evaluation, threshold tuning, and more
content types.

## Canvas Sync Flow

```text
OAuth token
   ↓
Canvas service
   ↓
Fetch modules and content
   ↓
Normalise into internal records
   ↓
Chunk and embed text content
   ↓
Store records and vectors
```

Current limitation: production OAuth approval from NUS is still pending, so real Canvas sync is
not yet available in production. Backend tests use controlled fixtures and mocked Canvas
responses.

## Deployment Shape

Planned M1 deployment:

```text
Frontend container
   ↓ HTTP
Backend container
   ↓ asyncpg
PostgreSQL + pgvector
```

The frontend has `Dockerfile` and `DEPLOY.md`. Backend deployment is still pending and should
be completed before the final M1 submission if possible.

## Design Decisions

### PostgreSQL + pgvector

Chosen because the app needs relational records and vector search. Keeping both in one
database reduces infrastructure complexity for M1.

### FastAPI backend

Chosen for typed request/response models, async support, simple testing, and generated API
documentation.

### merjs frontend

Chosen for a small server-rendered frontend that can be built and deployed as a compact Zig
service. The app vendors its Zig dependencies for reproducible CI.

### Mock fallback

Chosen because OAuth approval is outside the team's control. Mock data keeps the demo
presentable without pretending that production Canvas access is already complete.

### Feature branches and pull requests

Chosen to create clear evidence of code review, CI, and task traceability for Artemis-level
software engineering practice.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| OAuth approval delayed | Real Canvas demo blocked | mock dataset, fixture tests, clear status note |
| Retrieval quality too weak | answers may be incomplete | citations, thresholds, evaluation set in M2 |
| Deployment complexity | M1 demo may be local only | Docker files, staged backend deploy work |
| Scope creep | M1 delivery risk | keep M1 to scaffold, dashboard, chat, sync foundation |
| Data privacy | sensitive course data exposure | server-side tokens, private repo, no committed secrets |
