# CanvasPilot

CanvasPilot is a student-first knowledge-base workspace for NUS students. It helps
students collect readings, notes, links, PDFs, repository references, and research
outputs, then turn those sources into a structured Markdown wiki with citations,
search, grounded Q&A, reusable study material, and topic-level learning visualizations.

Target level: **Artemis**

Team:

- Lim Yu Xi (`@yxlyx`)
- Pranav Pappu (`@pranavp311`)

## Current Status

Milestone 1 now focuses on a technical proof of concept for the pivot:
local signup/signin, account workspace foundations, and a minimal
source-to-wiki demo.

| Area | Status | Evidence |
| --- | --- | --- |
| Backend scaffold | Done | FastAPI app, routers, schemas, tests, Alembic migrations |
| Database | Done | PostgreSQL + pgvector schema and migration files |
| Local auth | In progress | signup/signin work in the current working tree |
| Source ingestion foundation | Basic implementation | ingestion service and database-backed content records |
| Retrieval pipeline | Basic implementation | chunking, embedding, vector lookup, chat route |
| Frontend scaffold | Done | PR #24 |
| Dashboard | Done | PR #25, to be repurposed as workspace overview |
| Chat interface | Done | PR #26, to be repurposed as cited Q&A |
| Deployment files | Frontend done, backend pending | PR #27 |
| M1 tracker | Updating for pivot | `docs/m1-submission.md` |
| CI | Done | Backend CI and Frontend CI workflows |

## Milestone 1 Scope

The proof of concept demonstrates the smallest useful version of CanvasPilot:

1. Local signup and signin flow.
2. Account-bound workspace shell.
3. Import of a small controlled source set, such as Markdown, plain text, or fixture
   excerpts.
4. Source parsing, chunking, embedding, and storage in PostgreSQL.
5. Minimal Markdown wiki compiler that produces cited pages from the source set.
6. Cited Q&A against workspace sources.
7. Mock or fixture data fallback so the demo remains stable.
8. Automated checks on pull requests.
9. Frontend and backend deployment preparation.

## Repository Layout

```text
.
├── backend/                 FastAPI backend, database models, migrations, tests
│   ├── app/
│   │   ├── routers/         API routes for auth, modules, sync, chat, tasks
│   │   ├── services/        ingestion, embedding, retrieval, LLM services
│   │   ├── models/          SQLAlchemy models
│   │   ├── schemas/         Pydantic request/response models
│   │   └── db/              database setup and Alembic migrations
│   └── tests/               unit and integration tests
├── frontend/                merjs frontend
│   ├── app/                 pages
│   ├── api/                 frontend-side API handlers
│   ├── src/lib/             config, session, backend client, mock data, types
│   ├── public/              browser script assets
│   └── zig-pkg/             vendored Zig dependencies for reproducible builds
├── docs/                    milestone and design documentation
├── .github/workflows/       CI workflows
└── docker-compose.yml       local PostgreSQL + pgvector service
```

## System Architecture

CanvasPilot has three main layers:

1. **Frontend**: merjs app for auth, workspace overview, source review, wiki pages,
   and cited Q&A.
2. **Backend**: FastAPI API for auth, source ingestion, retrieval, wiki compilation,
   chat, and workspace records.
3. **Data layer**: PostgreSQL with pgvector for structured records and vector search.

High-level flow:

```text
Student sources
   |
   v
FastAPI backend
   |
   v
parse, chunk, embed, index
   |
   v
PostgreSQL + pgvector
   |
   +--> Markdown wiki pages with citations
   |
   +--> cited Q&A and search
   |
   v
merjs frontend
```

## Core Features

### 1. Source Library

Students can collect study and research material in one workspace. The planned
source library supports uploaded documents, pasted notes, links, repository
references, and structured metadata such as title, source type, course, topic, and
last-reviewed status.

### 2. Markdown Wiki Compiler

CanvasPilot turns raw source material into a readable Markdown knowledge base. Pages
include citations back to the source records, while index pages and backlinks help
students navigate related concepts.

### 3. Cited Q&A and Search

The retrieval flow answers questions using workspace sources and returns citations so
students can verify claims. Search and Q&A share the same indexed source base.

### 4. Exportable Study Workspace

The Markdown output is intended to remain useful outside the app. Milestone 2 and 3
work will focus on Obsidian-friendly export, reusable summaries, cited flashcard decks,
and change history.

### 5. Flashcards and Knowledge Meters

CanvasPilot will generate cited flashcards from selected sources, wiki pages, or topics.
Logged answers, confidence ratings, Q&A patterns, and marked question papers will feed
topic-level knowledge completion meters. These meters are evidence-based estimates, not
absolute mastery claims.

### 6. Workspace Health Checks

Later milestones add checks for missing citations, stale pages, duplicate sources,
unsupported files, and topics that need more source coverage.

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
FRONTEND_URL=http://localhost:3000
BACKEND_URL=http://localhost:8000
SESSION_SECRET=<local secret>
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

The frontend supports mock data so the workspace demo can still be shown while
source-ingestion flows are being completed.

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

## Version Control and Project Tracking

The repo uses:

- GitHub Issues for task breakdown.
- Milestones for Lift-off, M1, M2, M3, and refinement grouping.
- Labels for backend, frontend, database, RAG, source ingestion, auth, testing,
  deployment, design, documentation, blocked work, bugs, and features.
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

- Student workspaces are account-bound.
- Session cookies are HttpOnly.
- Local secrets and environment files are not committed.
- CORS is restricted through environment configuration.
- Source-grounded responses include citations so users can verify claims.

### Reliability

- The frontend can fall back to mock data for demos.
- CI runs on every relevant PR.
- Database migrations are tracked through Alembic.
- Fixture sources keep the M1 demo repeatable.

### Performance

- PostgreSQL + pgvector keeps structured data and vector search in one store.
- Content is chunked before embedding.
- The frontend is server-rendered and keeps browser-side code small.

### Maintainability

- Backend modules are separated by routers, services, schemas, and models.
- Frontend pages, API handlers, and shared library code are separated.
- Milestone notes are tracked in `docs/m1-submission.md`.

## Roadmap

### Before Lift-off Submission

- Finish local signup/signin proof of concept.
- Add poster and demo video links to `docs/m1-submission.md`.
- Add screenshots of CI and the app demo.
- Confirm Skylab project ID and submission links.
- Demonstrate a small source-to-wiki flow using controlled fixture data.

### Milestone 1, by 1 June 2026

- Expand README evidence with screenshots and diagrams.
- Complete backend deployment plan.
- Demonstrate one end-to-end source import, wiki page, and cited Q&A flow.
- Add architecture diagram image if available.
- Keep project log updated with hours per member.

### Milestone 2

- Multi-source ingestion for Markdown, plain text, PDFs, links, and repository
  references.
- Wiki compiler with citations, index pages, and backlinks.
- Full text search and cited Q&A across a workspace.
- Cited flashcard generation from selected wiki pages or source chunks.
- Flashcard answer logging with topic tags, citations, accuracy, confidence, and recency.
- User testing with NUS students.
- Retrieval quality evaluation.

### Milestone 3

- Workspace health checks.
- Reusable study outputs, including flashcard decks.
- Knowledge completion meters under visualization, based on learning evidence from Q&A,
  flashcards, review recency, confidence ratings, and marked question papers.
- Marked-paper upload and analysis as an extension input for topic weakness detection.
- Visualization and export flows.
- UI refinements from user testing.
- Higher backend coverage and end-to-end browser tests.

## Documentation Index

- [`docs/m1-submission.md`](docs/m1-submission.md): M1 checklist and submission tracker.
