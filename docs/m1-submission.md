# CanvasPilot — Milestone 1 (Lift-off / Technical PoC) submission

Living tracker for the Milestone 1 submission deliverables called out in
[issue #9](https://github.com/yxlyx/canvaspilot/issues/9). Items marked
`Pending` are waiting on artefact links, screenshots, or final uploaded files.

Team: Lim Yu Xi (@yxlyx) · Pranav Pappu (@pranavp311)
Level of Achievement: **Artemis**
Due: **2026-05-18** (Lift-off / Technical PoC), **2026-06-01** (M1 - Ideation)

---

## 1. README

The repo-level [`README.md`](../README.md) introduces the project, lists the
core M1 features, shows the repo layout and architecture flow, and includes
local setup instructions for both `frontend/` and `backend/`.

- [x] README expanded for M1 review.
- [ ] Add live PoC deploy URLs once backend deployment is ready.

## 2. Proposal & plan documents

| Document                                                            | Status |
| ------------------------------------------------------------------- | ------ |
| Orbital proposal PDF (`A0322845A-A0317720L - Pranav Pappu.pdf`)     | ✅ Locked. Source of truth for milestone scope. |
| Frontend implementation PRs #24-#27                                 | ✅ Capture the merjs scaffold, dashboard, chat flow, and deploy files. |
| `docs/architecture.md`                                              | ✅ High-level system diagram, component notes, data model, and risks documented. |
| `docs/testing-strategy.md`                                          | ✅ Automated checks, smoke tests, and milestone acceptance criteria documented. |
| `docs/project-log.md`                                               | 🟡 Log structure ready; member hours still need to be filled in before submission. |

## 3. M1 issue checklist (frontend side, assigned to @yxlyx)

| # | Title | Status | Evidence |
|---|---|---|---|
| #5  | Build frontend application scaffold      | ✅ Done | PR [#24](https://github.com/yxlyx/canvaspilot/pull/24) merged 2026-05-13 |
| #3  | Build basic module dashboard             | ✅ Done | PR [#25](https://github.com/yxlyx/canvaspilot/pull/25) merged 2026-05-13 |
| #4  | Build basic chat interface               | ✅ Done | PR [#26](https://github.com/yxlyx/canvaspilot/pull/26) merged 2026-05-13 |
| #2  | Deploy proof of concept stack            | 🟡 Frontend deploy files done in PR [#27](https://github.com/yxlyx/canvaspilot/pull/27); backend deploy pending @pranavp311 | — |
| #22 | Document CI evidence                     | 🟡 Frontend workflow passing on PRs #24-#27; screenshots still needed | See §5 below |
| #21 | Enable pull request branch rules         | ✅ Closed — branch protection live on `main` | — |
| #23 | Invite adviser to repository             | ✅ Closed — @thienkimtranhoang invited with read access | — |

## 4. Project log

Detailed contribution tracking lives in [`docs/project-log.md`](project-log.md).
Fill in realistic hours before submission; the work items and evidence links
are already structured.

## 5. CI evidence (for #22)

The Frontend CI workflow lives at
[`.github/workflows/frontend.yml`](../.github/workflows/frontend.yml). It
runs on every PR touching `frontend/**` and exercises:

1. `zig fmt --check src app api tools`
2. `zig build` (codegen + ReleaseSafe compile)
3. `zig build test --summary all` (unit tests in `src/lib/time.zig`)
4. Boot smoke test: spin up `./zig-out/bin/app --port 3001 --no-dev` and
   `curl /` → expect HTTP 200.

Companion backend workflow: [`.github/workflows/backend.yml`](../.github/workflows/backend.yml)
(Ruff + pytest with a Postgres + pgvector service container).

- [ ] Pending: attach a screenshot of a successful Frontend CI run on `main`.
- [ ] Pending: attach a screenshot of a successful Backend CI run.
- [ ] Pending: paste the URL of one passing PR check run.

## 6. Poster

- [ ] Pending: 1-page poster PDF — design draft to be added at
      `docs/m1-poster.pdf` once finalised.
- [ ] Pending: poster mirror link (Google Drive / Notion).

## 7. Demo video

- [ ] Pending: 90-second demo recording walking through the OAuth UI →
      dashboard with mock data → chat with a grounded citation reply.
      Hosted on YouTube unlisted or Google Drive; paste the link here.

## 8. Submission checklist (Lift-off / Technical PoC due 2026-05-18)

- [x] Frontend scaffold (#5)
- [x] Module dashboard for one module (#3)
- [x] Chat with citations (#4)
- [x] CI on every PR (#22, workflow shipped)
- [x] Branch protection (#21)
- [x] Adviser added (#23)
- [ ] Backend ingest pipeline live with at least one test module
- [ ] One end-to-end query flow deployed (#2)
- [ ] README + project log up to date
- [ ] Poster + demo video uploaded and linked above
