# CanvasPilot

CanvasPilot is a Canvas-connected study workspace for NUS students. It imports module
content, structures it into useful study data, and gives students a single place to view
module updates, upcoming tasks, and grounded answers based on their own course material.

Target level: **Artemis**

Team:

- Lim Yu Xi (`@yxlyx`)
- Pranav Pappu (`@pranavp311`)

## Current Status

Milestone 1 focuses on a technical proof of concept: authentication flow, one-module
dashboard, grounded chat flow, database-backed ingestion, CI, and deployment preparation.

| Area | Status | Evidence |
| --- | --- | --- |
| Backend scaffold | Done | FastAPI app, routers, schemas, tests, Alembic migrations |
| Database | Done | PostgreSQL + pgvector schema and migration files |
| Canvas OAuth | Waiting on NUS reply | Flow and env config exist; production credentials pending |
| Canvas sync | Basic implementation | `/api/sync`, Canvas service, ingestion service |
| Retrieval pipeline | Basic implementation | chunking, embedding, vector lookup, chat route |
| Frontend scaffold | Done | PR #24 |
| Dashboard | Done | PR #25 |
| Chat interface | Done | PR #26 |
| Deployment files | Frontend done, backend pending | PR #27 |
| M1 tracker | Done | PR #28 and `docs/m1-submission.md` |
| CI | Done | Backend CI and Frontend CI workflows |

## Milestone 1 Scope

The proof of concept demonstrates the smallest useful version of CanvasPilot:

1. Canvas OAuth connection flow.
2. Basic module import and sync pipeline.
3. PostgreSQL storage with vector search support.
4. One-module dashboard with announcements, assignments, and recent updates.
5. Chat interface that asks the backend for grounded answers and displays citations.
6. Mock data fallback so the demo remains usable while external Canvas access is pending.
7. Automated checks on pull requests.
8. Docker/deployment preparation for the frontend.

The live Canvas OAuth flow is blocked until NUS provides OAuth application approval and
production credentials. Until then, the frontend demo uses mock data and the backend is
tested with fixture data.

## Repository Layout

```text
.
├── backend/                 FastAPI backend, database models, migrations, tests
│   ├── app/
│   │   ├── routers/         API routes for auth, modules, sync, chat, tasks
│   │   ├── services/        Canvas, ingestion, embedding, retrieval, LLM services
│   │   ├── models/          SQLAlchemy models
│   │   ├── schemas/         Pydantic request/response models
│   │   └── db/              database setup and Alembic migrations
│   └── tests/               unit and integration tests
├── frontend/                merjs frontend
│   ├── app/                 pages
│   ├── api/                 frontend-side API handlers
│   ├── src/lib/             config, session, backend client, shared types
│   ├── public/              browser script assets
│   └── zig-pkg/             vendored Zig dependencies for reproducible builds
├── docs/                    milestone and design documentation
├── .github/workflows/       CI workflows
└── docker-compose.yml       local PostgreSQL + pgvector service
```

## System Architecture

CanvasPilot has three main layers:

1. **Frontend**: merjs app for auth, dashboard, chat, and demo flow.
2. **Backend**: FastAPI API for OAuth, Canvas sync, retrieval, chat, and task endpoints.
3. **Data layer**: PostgreSQL with pgvector for structured records and vector search.

High-level flow:

```text
Canvas LMS
   ↓ OAuth token + REST API
FastAPI backend
   ↓ parse, chunk, embed
PostgreSQL + pgvector
   ↑ retrieve relevant chunks
FastAPI chat route
   ↓ grounded answer + citations
merjs frontend
```

More detail: [`docs/architecture.md`](docs/architecture.md)

## Core Features

### 1. Canvas Module Import and Sync

The backend stores user and module data, calls Canvas through the Canvas service, and
normalises module content into database records. The current implementation supports the
M1-level path needed for a basic module sync.

### 2. Unified Module Dashboard

The frontend dashboard shows one module's current state: announcements, assignments,
upcoming tasks, and recent sync status. It works with mock data for the demo flow and can
call the backend when a session is available.

### 3. Grounded Chat With Citations

The chat UI sends questions to the frontend API handler, which forwards authenticated
requests to the backend chat endpoint. The backend retrieves relevant chunks, builds a
grounded response, and returns source citations.

### 4. Task and Deadline Foundation

The backend includes task schemas, models, and routes. Full task extraction is planned for
the next milestone, but the M1 data model and endpoint surface are in place.

## Local Setup

### Prerequisites

- Python 3.12
- Docker
- Zig 0.16.0
- PostgreSQL client tools are useful but not required

### Backend

Start the database:

```bash
docker compose up -d db
```

Set up the backend:

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
alembic upgrade head
uvicorn app.main:app --reload --port 8000
```

Useful backend environment variables:

```text
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/canvaspilot
CANVAS_BASE_URL=https://canvas.nus.edu.sg
CANVAS_CLIENT_ID=<pending NUS approval>
CANVAS_CLIENT_SECRET=<pending NUS approval>
CANVAS_OAUTH_REDIRECT_URI=http://localhost:8000/api/auth/canvas/callback
FRONTEND_URL=http://localhost:3000
BACKEND_URL=http://localhost:8000
SESSION_SECRET=<local secret>
CANVAS_TOKEN_SECRET=<fernet key>
```

Health check:

```bash
curl http://localhost:8000/api/health
```

### Frontend

```bash
cd frontend
zig build
zig build serve -- --port 3000
```

Open:

```text
http://localhost:3000
```

The frontend supports mock data when no Canvas session exists, so the dashboard and chat
demo can still be shown before NUS OAuth approval is complete.

## Testing

Backend:

```bash
cd backend
ruff check .
ruff format --check .
pytest --cov=app --cov-report=term-missing
```

Frontend:

```bash
cd frontend
zig fmt --check src app api tools
zig build
zig build test --summary all
```

CI:

- Backend CI runs Ruff and pytest with a PostgreSQL + pgvector service.
- Frontend CI runs formatting, build, tests, and a boot smoke test.
- PRs #24-#28 were reviewed and merged through the pull request workflow.

Full strategy: [`docs/testing-strategy.md`](docs/testing-strategy.md)

## Version Control and Project Tracking

The repo uses:

- GitHub Issues for task breakdown.
- Milestones for M1/M2/M3 grouping.
- Labels for backend, frontend, database, RAG, Canvas API, OAuth, testing, deployment,
  design, documentation, blocked work, bugs, and features.
- GitHub Project board for tracking status.
- Feature branches and pull requests.
- CI checks before merge.

Important merged frontend PRs:

- PR #24: frontend scaffold and CI
- PR #25: dashboard
- PR #26: chat UI and API bridge
- PR #27: frontend deployment files
- PR #28: M1 submission tracker

## Non-Functional Requirements

### Security

- Canvas tokens are stored server-side and should not be exposed to browser scripts.
- Session cookies are HttpOnly.
- OAuth production credentials are not committed.
- CORS is restricted through environment configuration.
- Source-grounded responses include citations so users can verify claims.

### Reliability

- The frontend can fall back to mock data for demos while Canvas access is pending.
- CI runs on every relevant PR.
- Database migrations are tracked through Alembic.

### Performance

- PostgreSQL + pgvector keeps structured data and vector search in one store.
- Content is chunked before embedding.
- The frontend is server-rendered and keeps browser-side code small.

### Maintainability

- Backend modules are separated by routers, services, schemas, and models.
- Frontend pages, API handlers, and shared library code are separated.
- Design and testing notes are kept in `docs/`.

## Roadmap

### Before Lift-off submission

- Add poster and demo video links to `docs/m1-submission.md`.
- Add screenshots of CI and the app demo.
- Confirm Skylab project ID and submission links.
- Document OAuth status clearly as pending NUS approval.

### Milestone 1, by 1 June 2026

- Expand README evidence with screenshots and diagrams.
- Complete backend deployment.
- Demonstrate one end-to-end query flow using either approved Canvas access or a controlled
  fixture dataset.
- Add architecture diagram image if available.
- Keep project log updated with hours per member.

### Milestone 2

- Multi-module Canvas ingestion.
- More content types: PDFs, pages, assignment descriptions, calendar events.
- Full task extraction and deadline view.
- User testing with NUS students.
- Retrieval quality evaluation.

### Milestone 3

- Study recommendations.
- Weekly planner.
- Calendar export.
- Module content diff view.
- UI refinements from user testing.
- Higher backend coverage and end-to-end browser tests.

## Documentation Index

- [`docs/m1-submission.md`](docs/m1-submission.md): M1 checklist and submission tracker.
- [`docs/architecture.md`](docs/architecture.md): architecture, data flow, and design decisions.
- [`docs/testing-strategy.md`](docs/testing-strategy.md): test levels, commands, and acceptance criteria.
- [`docs/project-log.md`](docs/project-log.md): task log and contribution tracking.
