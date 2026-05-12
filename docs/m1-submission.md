# CanvasPilot — Milestone 1 (Lift-off / Technical PoC) submission

Living tracker for the Milestone 1 submission deliverables called out in
[issue #9](https://github.com/yxlyx/canvaspilot/issues/9). Anything that says
`TODO` is a placeholder waiting on the artefact link / screenshot / file.

Team: Lim Yu Xi (@yxlyx) · Pranav Pappu (@pranavp311)
Level of Achievement: **Artemis**
Due: **2026-05-18** (Lift-off / Technical PoC), **2026-06-01** (M1 - Ideation)

---

## 1. README

The repo-level [`README.md`](../README.md) introduces the project, lists the
core M1 features, and points readers to this document for the full M1
submission.

- [ ] TODO: expand `README.md` with a 1-paragraph project pitch, repo layout
      diagram, "how to run locally" instructions for both `frontend/` and
      `backend/`, and links to the live PoC deploy URLs once #2 lands.

## 2. Proposal & plan documents

| Document                                                            | Status |
| ------------------------------------------------------------------- | ------ |
| Orbital proposal PDF (`A0322845A-A0317720L - Pranav Pappu.pdf`)     | ✅ Locked. Source of truth for milestone scope. |
| [`FRONTEND_PLAN_YUXI.md`](../FRONTEND_PLAN_YUXI.md)                 | ✅ Captures the Next.js → merjs swap rationale and frontend milestone breakdown. Landed in PR #24. |
| `docs/architecture.md`                                              | [ ] TODO: high-level system diagram (Canvas API → FastAPI ingest → pgvector → RAG → merjs frontend). Will be expanded at the end of M1. |

## 3. M1 issue checklist (frontend side, assigned to @yxlyx)

| # | Title | Status | Evidence |
|---|---|---|---|
| #5  | Build frontend application scaffold      | ✅ Done — pending merge | PR [#24](https://github.com/yxlyx/canvaspilot/pull/24) |
| #3  | Build basic module dashboard             | ✅ Done — pending merge | PR [#25](https://github.com/yxlyx/canvaspilot/pull/25) |
| #4  | Build basic chat interface               | ✅ Done — pending merge | PR [#26](https://github.com/yxlyx/canvaspilot/pull/26) |
| #2  | Deploy proof of concept stack            | 🟡 Frontend half done — PR [#27](https://github.com/yxlyx/canvaspilot/pull/27); backend deploy pending @pranavp311 | — |
| #22 | Document CI evidence                     | 🟡 Workflow file shipped in #24; screenshots after first run on `main` | See §5 below |
| #21 | Enable pull request branch rules         | ✅ Closed — branch protection live on `main` | — |
| #23 | Invite adviser to repository             | ✅ Closed — @thienkimtranhoang invited with read access | — |

## 4. Project log

Reverse-chronological summary of the M1 frontend work. Bullet style, keep
each entry to a single sentence. Update as work lands.

- `2026-05-12` — Branch protection (1 approval, dismiss stale, require
  conversation resolution) enabled on `main`. Adviser invited as a reader.
- `2026-05-12` — Pruned multi-module dashboard / tasks page / module-detail
  routes that overshot into M2. Strict M1 frontend now: scaffold + auth UI +
  one-module dashboard + chat with citations + Dockerfile.
- `2026-05-12` — Real FastAPI SSE aggregation added to `api/chat.zig`:
  parses `event: token` / `event: citations` / `event: done` frames from
  `backend/app/services/llm.py`, returns a single JSON reply with citations.
  Mock fallback for the demo flow when the backend isn't running.
- `2026-05-12` — CI workflow (`.github/workflows/frontend.yml`) added:
  `zig fmt --check`, `zig build`, `zig build test --summary all`, and a
  boot smoke test against `/dashboard?mock=1`.
- `2026-05-12` — Patched two upstream merjs 0.2.5 scaffold bugs that the
  team would otherwise hit on first `mer init`: `mercss_jit` import in
  `tools/codegen.zig`, and the missing `runtime.init()` call in
  `src/main.zig` that segfaulted the dev server on startup.
- `2026-05-12` — Hermetic build: vendored merjs and its transitive Zig
  dependencies under `frontend/zig-pkg/` so the build doesn't depend on
  network fetches at compile time. Switched the global cache to a
  workspace-local directory for the same reason.
- `2026-05-12` — Initial merjs scaffold (`mer init`) wired into the repo at
  `frontend/`. Added shared `lib` module (config, session, backend client,
  mock data, types, time helpers, UI helpers) and the app shell layout.

## 5. CI evidence (for #22)

The Frontend CI workflow lives at
[`.github/workflows/frontend.yml`](../.github/workflows/frontend.yml). It
runs on every PR touching `frontend/**` and exercises:

1. `zig fmt --check src app api tools`
2. `zig build` (codegen + ReleaseSafe compile)
3. `zig build test --summary all` (unit tests in `src/lib/time.zig`)
4. Boot smoke test: spin up `./zig-out/bin/app --port 3001 --no-dev` and
   `curl /dashboard?mock=1` → expect HTTP 200.

Companion backend workflow: [`.github/workflows/backend.yml`](../.github/workflows/backend.yml)
(Ruff + pytest with a Postgres + pgvector service container).

- [ ] TODO: attach a screenshot of the first successful Frontend CI run on
      `main` (will appear once PR #24 merges).
- [ ] TODO: attach a screenshot of a successful Backend CI run.
- [ ] TODO: paste the URL of one passing PR check run.

## 6. Poster

- [ ] TODO: 1-page poster PDF — design draft to be added at
      `docs/m1-poster.pdf` once finalised.
- [ ] TODO: poster mirror link (Google Drive / Notion).

## 7. Demo video

- [ ] TODO: 90-second demo recording walking through the OAuth UI →
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
