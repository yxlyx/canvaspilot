# WikiBase (draft 1)

WikiBase is a student-first knowledge-base workspace for NUS students. It helps
students collect readings, notes, links, PDFs, repository references, and research
outputs, then turn those sources into a structured Markdown wiki with citations,
search, grounded Q&A, reusable study material, and topic-level learning visualizations.

Target level: **Artemis**

Team:

- Lim Yu Xi (`@yxlyx`)
- Pranav Pappu (`@pranavp311`)

## Overview

WikiBase is a pivoted Orbital project that now focuses on a local, student-owned
study workspace rather than a Canvas-integrated course dashboard. The product is built
around source ingestion, citation-aware wiki generation, grounded Q&A, flashcards, and
learning evidence visualisation.

The goal is to help students keep their study material in one place and keep it usable.
Instead of scattering useful content across folders, bookmarks, PDFs, and separate apps,
WikiBase compiles the material into a Markdown knowledge base that can be searched,
exported, and revised from.

## Current Status

Milestone 1 is focused on a technical proof of concept for the pivot. The repo already
contains more implemented work than the original Canvas-dashboard plan, and the current
direction is now anchored around the student knowledge-base workflow.

| Area | Status | Evidence |
| --- | --- | --- |
| Backend scaffold | Done | FastAPI app, routers, schemas, tests, Alembic migrations |
| Database | Done | PostgreSQL + pgvector schema and migration files |
| Frontend scaffold | Done | PR #24 merged |
| Workspace overview | Done | PR #25 merged |
| Cited Q&A interface | Done | PR #26 merged |
| Frontend deployment files | Done | PR #27 merged |
| Milestone 1 tracker | Done | PR #28 merged |
| Local auth flow | Implemented, awaiting review | PR #31 open |
| Source ingestion foundation | Basic implementation | ingestion service and database-backed content records |
| Retrieval pipeline | Basic implementation | chunking, embedding, vector lookup, chat route |
| CI | Done | Backend CI and Frontend CI workflows |

## What We Have Actually Built

The Git history shows that the project has moved past the original starter scaffold.
The main pieces already implemented are:

1. A reusable frontend scaffold with auth pages and shared UI plumbing.
2. A workspace dashboard that can be repurposed for the knowledge-base view.
3. A chat interface wired to the frontend API bridge for cited Q&A.
4. Frontend deployment files and Docker support.
5. Backend scaffold, database models, migration setup, and tests.
6. A local auth flow with signup, signin, session handling, and backend auth routes.
7. A README and milestone tracker that reflect the pivoted direction.
8. GitHub issue tracking, PR history, CI checks, and branch protection evidence.

The important takeaway is that the project is no longer just a concept writeup. It has
an actual working base for auth, source records, retrieval, frontend screens, and
version-controlled delivery.

## Motivation

Students rarely study from one clean source of truth. A single module can involve
lecture slides, tutorial sheets, PDF readings, textbook chapters, personal notes,
browser links, repository references, project documents, and outputs from separate tools.
These materials build up quickly, but they do not automatically become a usable knowledge
base.

This creates recurring problems:

- useful material is spread across folders, tabs, cloud drives, and repositories;
- students waste time rediscovering where a concept was explained;
- notes drift away from their original sources and become hard to verify;
- saved links and PDFs are not organized into a coherent study structure;
- study outputs can become disconnected from the source text they were based on;
- students using Markdown or Obsidian-like workflows still need to maintain pages,
  backlinks, indexes, citations, and revision material manually;
- students often do not know which topics they understand well and which ones need more
  practice until it is too late.

WikiBase addresses this by helping students turn scattered study and research sources
into a maintained, citation-aware Markdown knowledge base.

## Vision

WikiBase is a student-first LLM knowledge-base workspace. It helps students collect
raw sources, compile them into a Markdown wiki, ask cited questions over their own
workspace, generate reusable study material, and visualize topic-level learning progress.

The core aim is not just to answer isolated questions. WikiBase should help students
maintain a source-grounded study workspace that remains readable, verifiable, searchable,
and exportable.

## Product Direction

The current product direction is:

1. Students add sources such as Markdown notes, PDFs, links, and repository references.
2. The backend parses those sources, chunks them, and stores them in PostgreSQL with
   embedding support.
3. The wiki compiler turns the raw sources into Markdown pages with citations.
4. Search and Q&A use the indexed source base to return grounded answers.
5. Flashcards and practice evidence feed topic-level progress meters.
6. The Markdown output remains portable for note-taking workflows outside the app.

## Scope Of Project

WikiBase is intentionally scoped as a local, student-owned workspace rather than a
Canvas integration. That reduces dependency risk and keeps the focus on the product
mechanics that matter for Orbital:

- source organisation
- citation-aware generation
- retrieval and grounded answers
- study output generation
- learning evidence and visualisation
- GitHub-based software engineering practice

## Core Features

### 1. Local Auth and Workspace

Students sign up and sign in locally, and their sources and generated outputs are scoped
to their own workspace.

### 2. Source Library

Students can collect study and research material in one place. The source library is
planned to support uploaded documents, pasted notes, links, repository references, and
metadata such as title, source type, topic, and last-reviewed status.

### 3. Markdown Wiki Compiler

WikiBase turns raw source material into a readable Markdown knowledge base. Pages
include citations back to source records, while index pages and backlinks help students
navigate related concepts.

### 4. Cited Q&A and Search

The retrieval flow answers questions using workspace sources and returns citations so
students can verify claims. Search and Q&A share the same indexed source base.

### 5. Exportable Study Workspace

The Markdown output is intended to remain useful outside the app. Later milestones will
focus on exportable Markdown, reusable summaries, cited flashcard decks, and revision
history.

### 6. Flashcards and Knowledge Meters

WikiBase will generate cited flashcards from selected sources, wiki pages, or topics.
Logged answers, confidence ratings, Q&A patterns, and marked question papers will feed
topic-level knowledge completion meters. These meters are evidence-based estimates, not
absolute mastery claims.

### 7. Workspace Health Checks

Later milestones add checks for missing citations, stale pages, duplicate sources,
unsupported files, and topics that need more source coverage.

## User Stories

1. As a student with scattered readings and notes, I want to collect sources in one
   workspace so that I can stop searching across disconnected folders and links.
2. As a student preparing revision notes, I want sources to compile into Markdown pages
   so that I can maintain a clean wiki faster.
3. As a student checking accuracy, I want wiki pages and answers to include citations so
   that I can trace claims back to their source.
4. As a student using Markdown-first notes, I want to export my wiki so that I can keep
   the output portable.
5. As a student revising for exams, I want to ask questions over my saved sources so that
   answers match the material I am studying.
6. As a student managing a large topic, I want backlinks and index pages so that related
   concepts are connected.
7. As a student with outdated notes, I want health checks so that I know which pages,
   citations, and topics need review.
8. As a student preparing for class, I want summaries, outlines, and study guides so that
   I can revise faster.
9. As a student practising recall, I want cited flashcards generated from my sources so
   that practice stays aligned with the knowledge base.
10. As a student answering flashcards, I want attempts and confidence ratings to be
    saved so that weak topics can be detected over time.
11. As a student reviewing marked papers, I want marks and feedback to contribute to
    topic progress so that mistakes become actionable.
12. As a student viewing progress meters, I want to know what evidence each meter is based
    on so that I do not mistake a low-evidence estimate for a final judgment.

## Technical Proof Of Concept

The proof of concept currently demonstrates the smallest useful version of WikiBase:

1. Local signup and signin flow.
2. Account-bound workspace shell.
3. Import of a controlled source set such as Markdown, plain text, or fixture excerpts.
4. Source parsing, chunking, embedding, and storage in PostgreSQL.
5. A minimal Markdown wiki compiler that can produce cited pages from the source set.
6. Cited Q&A against workspace sources.
7. Mock or fixture data fallback so the demo remains stable.
8. Automated checks on pull requests.
9. Frontend and backend deployment preparation.

## Architecture

WikiBase has three main layers:

1. Frontend: merjs pages for auth, workspace overview, source review, wiki pages, and
   cited Q&A.
2. Backend: FastAPI API for auth, source ingestion, retrieval, wiki compilation, chat,
   and workspace records.
3. Data layer: PostgreSQL with pgvector for structured records and vector search.

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

## Tech Stack

| Area | Technology | Reason |
| --- | --- | --- |
| Frontend | merjs and Zig | Server-rendered frontend with compact deployment and reproducible builds. |
| Backend | FastAPI and Python | Async API framework with typed schemas and OpenAPI support. |
| Database | PostgreSQL + pgvector | Relational records plus vector search in one database. |
| Retrieval | Embeddings and vector lookup | Grounded Q&A and search over workspace chunks. |
| Document parsing | PyMuPDF, python-docx, BeautifulSoup, Markdown tooling | Support for PDFs, DOCX, links, and Markdown sources. |
| Testing | pytest, Ruff, Zig format/build tests | Automated checks across backend and frontend. |
| CI/CD | GitHub Actions | Pull request checks and deployment confidence. |
| Local services | Docker Compose | Repeatable local PostgreSQL and pgvector setup. |

## Software Engineering Practices

### Version Control

The repo uses feature branches, pull requests, branch protection, and CI checks. Recent
history includes frontend scaffold, dashboard, chat, deployment files, submission tracker,
and the auth flow PR.

### GitHub Tracking

The project uses issues, milestones, labels, and project-board style status tracking to
make progress visible. The current issue set is split across Lift-off, Milestone 1,
Milestone 2, and Milestone 3.

### Code Review

Code review is part of the workflow. The auth PR is currently open and waiting for
review.

### Testing

Backend tests cover auth, schema validation, ingestion, retrieval, and exceptions.
Frontend CI covers formatting, build, tests, and a boot smoke test.

### Documentation

The README, submission tracker, architecture notes, testing strategy, and project log are
used to keep the milestone narrative clear and auditable.

## Non-Functional Requirements

### Security and Privacy

- Workspaces must be account-bound.
- Session cookies should be HttpOnly.
- Secrets and environment files must not be committed.
- Private study material and marked papers must be handled as sensitive user data.
- Access control should be tested for cross-user data isolation.

### Reliability

- The M1 demo should work with controlled fixture data.
- Unsupported source types should fail with clear messages.
- Database migrations should be reversible where practical and reviewed before merge.
- Source processing failures should not corrupt existing workspace data.

### Performance

- Source ingestion should be moved to background jobs when files become large.
- Search should use database indexes and vector indexes.
- Compiled wiki pages and topic-meter calculations should be cached or stored when
  recomputation becomes expensive.
- Workspace overview should remain responsive for the test dataset.

### Maintainability

- Backend routers, services, schemas, and models should remain separated.
- Frontend pages, API bridge handlers, shared types, and UI helpers should remain
  organized by responsibility.
- Tests should cover service behavior separately from route behavior where possible.
- Design decisions and alternatives should be documented as the system evolves.

### Traceability

- Claims in wiki pages, answers, flashcards, and recommendations should trace back to
  source chunks where possible.
- Topic meters should expose the evidence used to compute them.
- Change history should make regenerated pages auditable.

## Milestone 1 Plan

### What Milestone 1 Needs To Show

The main evidence should be:

- a clear product definition;
- a working technical proof of concept;
- a development plan by component and milestone;
- GitHub issues, branches, PRs, and CI history;
- a sensible testing strategy;
- a README that explains the direction and progress clearly.

### Milestone 1 Deliverables

- README
- Project log
- Project poster
- Project video

### Milestone 1 Focus

1. Local auth and workspace setup.
2. One controlled source-to-wiki flow.
3. Cited Q&A on the same source set.
4. Clear evidence of development workflow and testing.
5. Updated proposal and supporting submission materials.

## Milestone 2 Plan

Milestone 2 should expand the prototype into a usable study flow.

1. Add richer source ingestion support.
2. Improve the wiki compiler with citations, backlinks, and index pages.
3. Build search and cited Q&A across a workspace.
4. Add flashcard generation and answer logging.
5. Run user testing and refine the UI and retrieval flow.

## Milestone 3 Plan

Milestone 3 should extend the prototype into a stronger study workspace.

1. Add health checks for source quality and coverage.
2. Add reusable output generation.
3. Add knowledge completion meters and weak-topic recommendations.
4. Add marked-paper evidence handling.
5. Polish export and visualisation flows.

## Testing Strategy

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

## Risks (generated)

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Scope grows too large | M1 or M2 delivery may slip | Keep M1 to auth plus one source-to-wiki demo; move extensions to M3. |
| Retrieval quality is inconsistent | Answers may miss relevant context | Use citations, thresholds, fixture evaluation sets, and user feedback. |
| Wiki pages are hard to verify | Students may distrust output | Show citations and source links on pages and answers. |
| Knowledge meters overstate understanding | Students may be misled | Label meters as estimates, show evidence confidence, and combine multiple signals. |
| Marked-paper formats vary widely | Extraction may be noisy | Start with fixture-supported formats and expose uncertain extraction results. |
| Sensitive data is mishandled | Privacy risk | Account-bound workspaces, no committed secrets, access-control tests, and careful file handling. |
| Deployment takes longer than expected | Demo may depend on local setup | Keep Docker/local demo path stable and deploy incrementally. |



------------------------------------------------------------------------------------------------------------------------------------------
draft 2 For diagram and HTML gen
# WikiBase

**Milestone 1 Submission**

WikiBase is a student-first knowledge-base workspace for source-grounded notes, cited Q&A, flashcards, and learning progress.

**Target Level:** Artemis

## Team

| Member | Primary focus |
| --- | --- |
| Lim Yu Xi | Frontend flows, workspace UI, Q&A UI, deployment files, frontend CI. |
| Pranav Pappu | Backend APIs, database, retrieval, local auth, ingestion foundations, backend CI. |

## Milestone 1 Focus

Problem definition, proof of concept, design direction, GitHub evidence, testing strategy, and roadmap.

## Product Flow

```text
Collect Sources -> Parse & Chunk -> Embed & Index -> Compile Wiki -> Revise with Evidence
```

## Motivation

Students rarely study from one clean source of truth. A single module can involve lecture slides, tutorial sheets, PDF readings, textbook chapters, personal notes, browser links, repository references, project documents, and separate study outputs.

WikiBase exists because study material is not only hard to find. It is also hard to verify, connect, revise, and keep up to date.

| Current Pain | Product Response |
| --- | --- |
| Sources are scattered across tools. | Collect sources in one workspace. |
| Notes drift away from original references. | Compile cited Markdown wiki pages. |
| Students waste time rediscovering explanations. | Search and ask source-grounded questions. |
| Generated study material can lose source context. | Turn practice evidence into revision guidance. |

## Vision And Aim

WikiBase is a student-first LLM knowledge-base workspace. It helps students collect raw sources, compile them into a Markdown wiki, ask cited questions over their own workspace, generate reusable study material, and visualize topic-level learning progress.

### 1. Source Base

Readings, notes, PDFs, links, and repositories live in one account-bound workspace.

### 2. Cited Wiki

Raw material becomes Markdown pages with citations, indexes, and backlinks.

### 3. Revision Loop

Q&A, flashcards, marked papers, and confidence ratings feed weak-topic guidance.

The product is designed to be useful even outside the app. Markdown output can later be exported to Obsidian-like workflows or Git-backed notes.

## Scope Of Project

The project originally explored a Canvas-style course dashboard, but the current scope is a student-owned knowledge-base workspace. This avoids institutional integration risk while preserving meaningful technical complexity.

| Included | Deferred / Avoided |
| --- | --- |
| Local signup/signin and account workspace | Dependence on external LMS permissions |
| Source ingestion, parsing, chunks, embeddings | Large-scale production file processing in M1 |
| Markdown wiki pages with citations | Fully editable public publishing platform |
| Cited Q&A, flashcards, learning meters | Unsupported mastery claims without evidence |

This scope keeps Milestone 1 realistic while leaving enough complexity for Artemis-level Milestone 2 and Milestone 3 work.

## User Stories

1. As a student with scattered readings and notes, I want to collect sources in one workspace.
2. As a student preparing revision notes, I want sources to compile into Markdown pages.
3. As a student checking accuracy, I want wiki pages and answers to include citations.
4. As a student using Markdown-first notes, I want to export my wiki.
5. As a student revising for exams, I want to ask questions over my saved sources.
6. As a student managing a large topic, I want backlinks and index pages.
7. As a student with outdated notes, I want health checks.
8. As a student preparing for class, I want summaries, outlines, and study guides.
9. As a student practising recall, I want cited flashcards.
10. As a student answering flashcards, I want attempts and confidence ratings saved.
11. As a student reviewing marked papers, I want marks and feedback to contribute to progress.
12. As a student viewing progress meters, I want to know what evidence each meter is based on.

## Core Features

| Feature | Milestone Role | Description |
| --- | --- | --- |
| Local auth and workspace | M1 core | Signup, signin, session handling, account-bound workspace. |
| Source library | M2 core | Store documents, notes, links, repository references, and metadata. |
| Wiki compiler | M1-M2 core | Compile raw source material into cited Markdown pages. |
| Cited Q&A and search | M1-M2 core | Ask questions over workspace sources with citations. |
| Flashcards | M2 extension | Generate cited recall cards and log practice attempts. |
| Knowledge meters | M3 extension | Estimate topic understanding using evidence from practice and sources. |
| Export and health checks | M3 extension | Export Markdown and flag weak citations, stale pages, and duplicate sources. |

## Technical Proof Of Concept

The proof of concept demonstrates that the project has a working base, not just a written plan.

### Implemented Foundation

- FastAPI backend scaffold
- PostgreSQL and pgvector migrations
- Frontend scaffold and workspace UI
- Chat interface and API bridge
- CI workflows for backend and frontend

### Auth PR In Review

- Signup and signin endpoints
- Password hashing and auth schemas
- Frontend signin/register handlers
- Session cookie handling
- Backend tests for auth behavior

PR #31 contains the current local auth flow and is awaiting review. CI is passing on the PR.

## Architecture

WikiBase uses a three-layer architecture: a merjs frontend, a FastAPI backend, and PostgreSQL with pgvector for structured records and vector search.

```text
Study Sources
    |
    v
FastAPI Backend
    | parse
    | chunk
    | embed
    | retrieve
    v
PostgreSQL + pgvector
    |
    +--> Wiki Pages
    |
    +--> Cited Q&A
```

The architecture keeps source records, chunks, citations, flashcards, and learning evidence in our own database. Markdown output is generated from canonical records rather than being treated as the only source of truth.

## Source-To-Wiki Flow

The key product workflow is source-to-wiki-to-revision. This is the central path that Milestone 2 will expand into a usable prototype.

```text
Collect Sources -> Parse & Chunk -> Embed & Index -> Compile Wiki -> Revise with Evidence
```

| Step | Responsibility |
| --- | --- |
| Collect | Source library stores documents, pasted notes, links, and repository references. |
| Parse and chunk | Backend normalizes text while preserving citation locations. |
| Embed and index | Chunks are stored for search and retrieval. |
| Compile | Wiki pages are generated with citations, backlinks, and indexes. |
| Revise | Q&A, flashcards, and meters help students act on the knowledge base. |

## Knowledge Meters

Knowledge completion meters are evidence-based estimates, not absolute mastery scores. They combine multiple signals and show confidence when evidence is sparse.

Signals:

- Source coverage
- Q&A evidence
- Flashcard attempts
- Marked papers

Topic meter inputs:

- Source coverage: number and quality of chunks mapped to a topic.
- Q&A evidence: questions asked, citation coverage, and repeated gaps.
- Flashcard evidence: correctness, confidence, retries, and review recency.
- Marked-paper evidence: extracted marks, feedback, and weak-topic signals.

## Tech Stack

### Frontend

**Zig, merjs**

Server-rendered frontend with route generation, shared types, auth pages, dashboard, and chat UI.

### Backend

**FastAPI, Python, OpenAPI**

Typed API routes, schemas, services, and tests for auth, ingestion, retrieval, and chat.

### Data

**PostgreSQL, pgvector, Alembic**

Relational records plus vector similarity search in one database.

### Quality

**GitHub Actions, pytest, Ruff**

Backend and frontend CI for formatting, linting, tests, build, and boot smoke checks.

## GitHub Evidence

GitHub workflow is part of the Milestone 1 evidence. The project already has merged PRs, visible issues, milestones, labels, and CI checks.

| PR | Status | Evidence |
| --- | --- | --- |
| #24 | Merged | merjs scaffold, auth UI, shared library, frontend CI workflow. |
| #25 | Merged | workspace/dashboard foundation with mock/backend data path. |
| #26 | Merged | chat UI and frontend API bridge for cited Q&A. |
| #27 | Merged | frontend Dockerfile and deployment files. |
| #28 | Merged | Milestone 1 submission tracker. |
| #31 | Open | local auth flow with backend and frontend changes, awaiting review. |

## Testing Strategy

Testing is split by layer so failures are easier to diagnose and explain during milestone evaluation.

### Backend Checks

- Ruff format check
- Ruff lint check
- pytest test suite
- PostgreSQL + pgvector CI service

### Frontend Checks

- Zig format check
- Zig build
- Zig tests
- Repository-owned M3 boot and route smoke test (`frontend/tests/m3-smoke.sh`)

Additional planned M2 and M3 tests include parser fixtures, wiki compiler output, flashcard evidence logging, and user testing.

## Project Plan

### M1

Ideation and proof of concept. Define product, show local auth, source-to-wiki direction, cited Q&A foundation, GitHub evidence, testing plan, poster, video, and project log.

### M2

Prototype. Implement richer source ingestion, wiki compiler, search, cited Q&A, flashcards, practice evidence logging, and user testing.

### M3

Extensions. Add health checks, output generation, knowledge completion meters, marked-paper evidence, export, and UI refinements.

The frontend now includes honest M3 preview routes for provider settings, cited outputs, health, history, progress, and marked papers. These require explicit demo gating and do not imply that blocked backend contracts are complete. See [`docs/milestone-3-frontend.md`](docs/milestone-3-frontend.md) for routes and demo instructions.

### Splashdown

Refinement. Polish workflows, fix outstanding issues, strengthen tests, and prepare final showcase materials.

## Roles And Contributions

| Member | Primary Work | Current Log Estimate |
| --- | --- | --- |
| Lim Yu Xi | Frontend scaffold, workspace overview, chat UI, frontend deployment files, frontend CI, UI flows. | 31 hours drafted; to be confirmed by member. |
| Pranav Pappu | Backend scaffold, database, retrieval, ingestion, auth flow, tests, project documentation and tracking. | 37 hours drafted; to be confirmed by member. |

Both members share responsibility for project tracking, milestone materials, code review, testing evidence, and demo preparation.

## Risks And Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Scope grows too large | M1 or M2 delivery slips | Keep M1 to auth plus one source-to-wiki demo; move extensions to M3. |
| Retrieval quality is inconsistent | Answers may miss context | Use citations, thresholds, fixture evaluation sets, and user feedback. |
| Wiki pages are hard to verify | Students may distrust output | Show citations and source links on pages and answers. |
| Knowledge meters overstate understanding | Students may be misled | Label meters as estimates and show evidence confidence. |
| Marked-paper formats vary | Extraction may be noisy | Start with fixture-supported formats and expose uncertain results. |
| Sensitive data is mishandled | Privacy risk | Account-bound workspaces, no committed secrets, access-control tests. |
