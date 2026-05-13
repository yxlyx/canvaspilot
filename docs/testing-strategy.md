# Testing Strategy

CanvasPilot uses automated checks, local smoke tests, and manual demo checks. The strategy is
split by layer so failures are easier to diagnose.

## Goals

- Catch formatting and lint failures before merge.
- Verify backend routers, schemas, services, and database behavior.
- Verify frontend route generation, build, and boot behavior.
- Keep a repeatable demo path for Milestone 1.
- Build toward broader integration and user testing in Milestone 2.

## Backend Tests

Backend tests live in `backend/tests/`.

| Test area | Files | Purpose |
| --- | --- | --- |
| API health and routers | `test_api.py` | endpoint availability and basic responses |
| Auth | `test_auth.py` | OAuth/session behavior |
| Canvas service | `test_canvas.py` | Canvas API handling with mocked responses |
| Ingestion | `test_ingestion.py` | parsing, chunking, and storage flow |
| Embedding | `test_embedding.py` | embedding service behavior |
| Retrieval | `test_retrieval.py` | vector lookup and relevance flow |
| Chat | `test_llm.py` | grounded response construction |
| Schemas | `test_schemas.py` | request and response model validation |
| Exceptions | `test_exceptions.py` | error handling |

Run locally:

```bash
cd backend
ruff check .
ruff format --check .
pytest --cov=app --cov-report=term-missing
```

CI command:

```bash
pytest --cov=app --cov-report=term-missing --cov-fail-under=60
```

## Frontend Tests

Frontend tests are currently build-oriented because the M1 frontend is a Zig server-rendered
app.

Run locally:

```bash
cd frontend
zig fmt --check src app api tools
zig build
zig build test --summary all
```

CI additionally starts the compiled app and checks that `/` returns HTTP 200.

## Integration Tests

M1 integration coverage:

- backend tests run against a PostgreSQL + pgvector service in GitHub Actions;
- frontend API handlers compile against shared frontend types;
- frontend build runs route generation before compiling;
- chat UI can call the frontend `/api/chat` bridge;
- mock fallback keeps dashboard and chat usable without Canvas credentials.

Planned M2 integration tests:

- Canvas sync from fixture export to database rows;
- chunking plus embedding plus retrieval in one test;
- chat endpoint response with citations from known fixture chunks;
- authenticated frontend-to-backend request path;
- deployment health checks.

## Manual Smoke Test Checklist

Before submission, record screenshots or short clips for:

- GitHub Actions passing on frontend and backend;
- home page loads;
- login/connect page displays;
- dashboard loads with mock data;
- chat page accepts a question and renders a reply;
- source/citation UI is visible in the chat reply;
- GitHub Project board and issues are populated.

## Acceptance Criteria

Milestone 1:

- backend CI passes;
- frontend CI passes;
- database migrations run;
- dashboard and chat demo flows are usable with mock data;
- OAuth status is documented as pending NUS approval;
- merged PRs show code review and CI evidence.

Milestone 2:

- ingestion supports multiple modules and major Canvas content types;
- retrieval returns relevant cited chunks on a fixed evaluation set;
- dashboard loads multi-module data within 3 seconds for the test dataset;
- user testing is run with NUS students and feedback is logged.
