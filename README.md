<p align="center">
  <img src="assets/wikibase-readme-hero.png" alt="WikiBase turns student sources into a connected, cited study workspace" width="1200">
</p>

<h1 align="center">WikiBase</h1>

<p align="center">
  <strong>Turn scattered course material into a knowledge base you can study from.</strong>
</p>

<p align="center">
  Bring together PDFs, notes, images, links, and repositories; compile a cited Markdown wiki; ask grounded questions; and turn the same evidence into flashcards and learning signals.
</p>

<p align="center">
  <img alt="Status: working prototype" src="https://img.shields.io/badge/status-working%20prototype-58724f">
  <img alt="Python 3.12 or newer" src="https://img.shields.io/badge/Python-3.12%2B-171915?logo=python&logoColor=white">
  <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16-f7a41d?logo=zig&logoColor=white">
  <img alt="PostgreSQL 16 and pgvector" src="https://img.shields.io/badge/PostgreSQL%2016-pgvector-4169e1?logo=postgresql&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-d4a72c"></a>
</p>

<p align="center">
  <a href="#why-wikibase">Why WikiBase</a> ·
  <a href="#what-it-does">Features</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#verification">Verification</a>
</p>

---

## Why WikiBase

Students rarely learn from one clean source of truth. A module can span lecture slides, tutorial sheets, readings, personal notes, browser links, repositories, and marked work. Finding an explanation is slow; verifying where it came from is harder; turning it into revision material means rebuilding the context again.

WikiBase keeps that context intact. Sources, citations, wiki pages, questions, flashcards, and learning evidence live in one account-scoped workspace, so each step can trace back to the material that supports it.

> WikiBase is citation-first. Generated pages, answers, study outputs, and flashcards are designed to expose their evidence. Knowledge meters are evidence-based estimates, not claims of mastery.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="frontend/public/media/product-dashboard-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="frontend/public/media/product-dashboard-light.png">
  <img src="frontend/public/media/product-dashboard-light.png" alt="WikiBase workspace dashboard showing indexed sources, wiki topics, flashcards, cited questions, and learning evidence" width="1440">
</picture>

<p align="center"><sub>The workspace connects source coverage, generated knowledge, cited questions, and review evidence.</sub></p>

## What it does

| Capability | What you get |
| --- | --- |
| **Source library** | Import PDFs, images, Markdown, plain text, links, and repository references into an isolated workspace. Preview content and follow durable processing states instead of waiting on a single request. |
| **Cited Markdown wiki** | Compile source material into readable pages with citations, connected topics, backlinks, revisions, and portable Markdown downloads. |
| **Workspace search** | Search structured records and embedded source chunks from the same indexed knowledge base. |
| **Grounded Q&A** | Ask questions over selected workspace evidence and keep citations visible beside the answer. |
| **Study outputs** | Generate reusable summaries, guides, and cited outputs without detaching them from their source context. |
| **Flashcards** | Draft, edit, approve, practise, archive, and restore cited cards while recording review evidence. |
| **Learning evidence** | Combine source coverage, flashcard attempts, marked-paper feedback, and recency into explainable topic signals and next actions. |
| **Workspace health** | Surface thin coverage, stale material, broken references, and other findings before they become silent gaps. |
| **Portable export** | Download wiki pages or selected workspace material as Markdown and ZIP archives. |

## How it works

```mermaid
flowchart LR
    A["PDFs · notes · images · links · repositories"] --> B["Parse · preview · chunk"]
    B --> C["PostgreSQL · pgvector"]
    C --> D["Cited wiki · search · Q&A"]
    D --> E["Study outputs · flashcards"]
    E --> F["Learning evidence · health checks"]
    F --> D
```

1. **Collect sources.** Add course or project material to an account-bound library.
2. **Process evidence.** WikiBase validates, parses, chunks, previews, and indexes each source through durable jobs.
3. **Build knowledge.** The wiki compiler produces Markdown pages that retain citations and connections.
4. **Study in context.** Search, Q&A, study outputs, and flashcards reuse the same evidence base.
5. **Close the loop.** Review activity and confirmed marked-paper evidence help identify what needs attention next.

## Product surfaces

<table>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="frontend/public/media/product-sources-dark.png">
        <img src="frontend/public/media/product-sources-light.png" alt="WikiBase source library" width="720">
      </picture>
      <br><strong>Source library</strong><br><sub>Review what is indexed, processing, and connected.</sub>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="frontend/public/media/product-wiki-dark.png">
        <img src="frontend/public/media/product-wiki-light.png" alt="WikiBase cited wiki article" width="720">
      </picture>
      <br><strong>Cited wiki</strong><br><sub>Read connected pages without losing the source trail.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="frontend/public/media/product-chat-dark.png">
        <img src="frontend/public/media/product-chat-light.png" alt="WikiBase grounded question and answer workspace" width="720">
      </picture>
      <br><strong>Grounded Q&amp;A</strong><br><sub>Ask against selected evidence and verify the citations.</sub>
    </td>
    <td width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="frontend/public/media/product-flashcards-dark.png">
        <img src="frontend/public/media/product-flashcards-light.png" alt="WikiBase evidence-backed flashcard review" width="720">
      </picture>
      <br><strong>Evidence-backed review</strong><br><sub>Practise cited cards and keep the outcome attached to its topic.</sub>
    </td>
  </tr>
</table>

## Architecture

WikiBase separates the student-facing workspace, application services, and persistence layer so ingestion, retrieval, and study workflows can evolve independently.

| Layer | Technology | Responsibility |
| --- | --- | --- |
| Frontend | Zig 0.16 + [merjs](https://github.com/justrach/merjs) | Server-rendered routes, shared UI, authenticated mutations, responsive light/dark workspace. |
| Backend | Python 3.12 + FastAPI + Pydantic | Typed APIs for auth, sources, processing, search, wiki, Q&A, flashcards, evidence, health, and export. |
| Persistence | PostgreSQL 16 + SQLAlchemy + Alembic | Account-scoped records, migrations, durable processing state, citations, revisions, and learning evidence. |
| Retrieval | pgvector + configurable model providers | Embedding-backed search and source-grounded generation. |
| Verification | pytest + Ruff + Zig tests + Playwright | Unit, API, database, browser-boundary, audit, and full-stack checks run locally. |

The backend runs as two processes: the FastAPI application serves requests, while a worker claims durable processing stages. PostgreSQL remains the canonical store; generated Markdown is a portable output rather than the only source of truth.

## Quick start

> [!IMPORTANT]
> Launch WikiBase from the `feature/frontend-learning-settings-cleanup` branch.

Clone the launch branch and enter the repository:

```bash
git clone --branch feature/frontend-learning-settings-cleanup --single-branch https://github.com/yxlyx/canvaspilot.git
cd canvaspilot
```

### Preview the interface

The explicit fixture mode lets you explore the complete UI without a database or model provider.

```bash
cd frontend
WIKIBASE_MOCK_ENABLED=true zig build serve
```

Open [http://localhost:3001/dashboard?mock=1](http://localhost:3001/dashboard?mock=1).

### Run the full local stack

You will need:

- Python 3.12 or newer
- Zig 0.16.0
- Docker with Compose
- npm for browser verification

Install the backend and start PostgreSQL:

```bash
python3.12 -m venv backend/.venv
backend/.venv/bin/python -m pip install --require-hashes -r backend/requirements-dev.lock
backend/.venv/bin/python -m pip install --no-deps -e backend
cp backend/.env.example backend/.env
docker compose up -d --wait db
```

Before starting the backend, update `backend/.env`:

- Set `DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/canvaspilot` to match the local Compose database.
- Replace `SESSION_SECRET` with a random token of at least 32 characters.
- Replace `CANVAS_TOKEN_SECRET` and `PROVIDER_ENCRYPTION_SECRET` with two different Fernet keys.
- Add a provider credential only if you want live generation; the source library, wiki reader, and existing study material do not require one.

Generate suitable secret values with:

```bash
backend/.venv/bin/python -c "import secrets; print(secrets.token_urlsafe(32))"
backend/.venv/bin/python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Run the Fernet command twice so the two encryption settings do not share a key.

Run migrations and start each process in its own terminal:

```bash
cd backend
.venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --reload --port 8000
```

```bash
cd backend
.venv/bin/python -m app.worker
```

```bash
cd frontend
zig build serve
```

Open [http://localhost:3001](http://localhost:3001). The API health endpoint is at [http://localhost:8000/api/health](http://localhost:8000/api/health), and FastAPI serves interactive API documentation at [http://localhost:8000/docs](http://localhost:8000/docs).

## Configuration

Backend configuration lives in `backend/.env`; frontend runtime settings are regular environment variables.

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Async PostgreSQL connection used by the API and worker. |
| `SESSION_SECRET` | Signs browser sessions; must be non-default and at least 32 characters. |
| `PROVIDER_ENCRYPTION_SECRET` | Encrypts stored provider credentials. |
| `OPENAI_API_KEY` | Optional provider credential for live embedding or generation workflows. |
| `WIKIBASE_BACKEND_URL` | Frontend-to-backend base URL; defaults to `http://localhost:8000`. |
| `WIKIBASE_PUBLIC_ORIGIN` | Canonical frontend origin used to validate authenticated mutations. |
| `WIKIBASE_MOCK_ENABLED` | Allows fixture data only when the request also includes `?mock=1`. |

See `backend/.env.example`, `backend/DEPLOY.md`, and `frontend/DEPLOY.md` for the complete deployment configuration.

## Verification

The repository uses a local verification harness rather than hosted workflows. A complete run checks shell safety, Ruff, Alembic migrations, backend coverage, dependency audits, Zig formatting/build/tests, HTTP boundaries, Playwright, and a database-backed full-stack smoke flow.

```bash
PYTHON=backend/.venv/bin/python \
TEST_DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/wikibase_test \
./verify
```

The harness creates and removes a uniquely named test database. It refuses to reuse `DATABASE_URL` or connect to a database whose name is not clearly test-scoped.

For a deliberately partial local check:

```bash
PYTHON=backend/.venv/bin/python ./verify --no-db --no-e2e --no-audit
```

Every omitted verification layer is reported in the final result.

## Repository map

```text
backend/
  app/routers/       HTTP contracts
  app/services/      ingestion, retrieval, wiki, study, and evidence logic
  app/models/        SQLAlchemy records
  app/db/migrations/ Alembic history
  tests/             service, API, database, and isolation coverage
frontend/
  app/               server-rendered pages
  api/               same-origin backend bridges
  src/lib/           shared types, rendering, session, and API helpers
  public/media/      product and editorial assets
  e2e/               browser tests
scripts/             verification and full-stack smoke tooling
verify               complete local verification entrypoint
```

## Project status

WikiBase is a working research prototype built for NUS Orbital at the Artemis level. The complete source-to-study loop is implemented, including account isolation, durable ingestion, cited wiki/search/Q&A, flashcards, learning evidence, health findings, marked-paper review, history, and export.

It is still a prototype. Do not treat it as a hosted production service for sensitive academic material without completing a deployment-specific security, privacy, backup, and retention review.

## Contributing

Focused issues and pull requests are welcome.

1. Create a narrowly scoped branch.
2. Keep frontend, backend, database, and migration responsibilities separated.
3. Add tests for behavioral changes and user-isolation boundaries.
4. Run the relevant local checks, preferably the full `./verify` harness.
5. Open a pull request that explains the user-visible change and records the exact verification command and result.

## Team

WikiBase is built by [Lim Yu Xi](https://github.com/yxlyx) and [Pranav Pappu](https://github.com/pranavp311).

The project began as CanvasPilot; the repository URL retains that history, while the product is now focused on a student-owned knowledge base rather than an LMS integration.

## License

WikiBase is available under the [Apache License 2.0](LICENSE).
