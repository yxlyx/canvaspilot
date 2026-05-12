# CanvasPilot Frontend Execution Plan

This version assumes the frontend is built from scratch with **merjs** instead of Next.js. The frontend remains Yu Xi's ownership area, but the implementation model changes from React/Next.js to Zig-rendered server-side pages with optional browser-side JavaScript or WASM for interactivity.

## Updated Frontend Goal

Build a compact, user-friendly CanvasPilot interface where a student can:

- Connect their Canvas account.
- See modules, announcements, assignments, files, and urgent deadlines.
- Use a Canvas-grounded chat interface with citations.
- Inspect summaries, recent updates, and study recommendations.
- Use the core dashboard and chat flows comfortably on desktop and mobile.

## What Changes With merjs

### Old Next.js Assumption

- React components.
- App Router pages.
- Auth.js / NextAuth.
- Client-side hydration.
- npm packages.
- Vercel-first deployment.
- Jest/Vitest/Playwright test setup.

### New merjs Assumption

- Zig files define routes and render HTML.
- `app/*.zig` pages map to frontend routes.
- `api/*.zig` files can define lightweight frontend API/proxy routes.
- `app/layout.zig` wraps page fragments.
- `zig build codegen` scans routes and generates the route table.
- `mer dev` or `zig build serve` runs the app.
- Tailwind can be used through the standalone Tailwind CLI.
- Client interactivity should be deliberately small: normal HTML forms first, small JS where needed, WASM only when it is worth the complexity.
- Cloudflare Workers is a natural deployment path for merjs, while Vercel is no longer the obvious default.

## Recommended Architecture

```text
canvaspilot/
  frontend/
    app/
      layout.zig
      index.zig
      login.zig
      callback.zig
      dashboard.zig
      module/[id].zig
      chat.zig
      tasks.zig
      planner.zig
    api/
      auth/
        start.zig
        callback.zig
        logout.zig
        me.zig
      modules.zig
      module/[id].zig
      chat.zig
      tasks.zig
      summaries.zig
    src/
      components/
        shell.zig
        nav.zig
        module_card.zig
        task_list.zig
        announcement_list.zig
        chat_message.zig
        citation_panel.zig
      lib/
        backend_client.zig
        config.zig
        cookies.zig
        mock_data.zig
        session.zig
        time.zig
      types/
        api.zig
    wasm/
      chat.zig
      filters.zig
    public/
      styles.css
      app.js
    worker/
      wrangler.toml
    build.zig
    build.zig.zon
```

Use this as a guide, not a sacred folder tree. If `mer init` scaffolds something slightly different, follow the framework's generated shape first.

## Key Architecture Decisions

### 1. Auth Ownership

Canvas OAuth should still be backend/server-side. With merjs, there is no Auth.js, so the cleanest model is:

- Frontend has `/login` and a "Connect with Canvas" button.
- Frontend redirects to either the backend OAuth start route or a merjs `/api/auth/start` proxy.
- Backend exchanges the OAuth code for Canvas tokens.
- Backend stores Canvas access/refresh tokens.
- Frontend receives only an app session cookie or session token.
- Frontend never stores Canvas refresh tokens in browser storage.

Recommended choice:

- Let Pranav's FastAPI backend own Canvas OAuth token exchange and token refresh.
- Let merjs own the visual login/callback/logout screens.
- Use secure cookies for the app session if possible.

### 2. Frontend To Backend Communication

There are two viable choices.

#### Option A: merjs Pages Call FastAPI Directly Server-Side

Flow:

```text
Browser -> merjs page -> FastAPI backend -> Canvas/db/RAG
```

Pros:

- Browser mostly receives rendered HTML.
- Backend URL is not scattered through client code.
- Easier to keep auth tokens server-side.
- Good fit for dashboards, module pages, tasks, summaries.

Cons:

- The merjs server becomes part of request-time data fetching.
- Need clear backend client code in Zig.

Recommended for:

- Dashboard.
- Module detail.
- Task list.
- Summary pages.
- Initial page loads.

#### Option B: Browser Calls FastAPI Directly

Flow:

```text
Browser -> FastAPI backend
```

Pros:

- Simpler for highly interactive features.
- Useful for streaming chat via SSE if merjs proxying gets awkward.

Cons:

- Requires CORS.
- Browser-facing auth is more delicate.
- More frontend JavaScript.

Recommended for:

- Chat streaming only, if direct SSE is simpler.

#### Option C: Browser Calls merjs API Route, merjs Proxies FastAPI

Flow:

```text
Browser -> merjs api/*.zig -> FastAPI backend
```

Pros:

- Browser only talks to the frontend origin.
- Good for cookies and error normalization.
- Similar feel to Next.js API routes.

Cons:

- More code.
- Avoid duplicating real backend business logic.

Recommended for:

- Auth helper routes.
- Chat proxy if CORS/session handling becomes annoying.
- Lightweight frontend-specific endpoints.

Overall recommendation:

- Use merjs SSR pages for most screens.
- Use a small `backend_client.zig` for server-side FastAPI calls.
- Use direct browser SSE or a merjs proxy for chat after testing which is smoother.

## Milestone 0: Framework And Contract Setup

### Tasks

- Scaffold `frontend/` with merjs.
- Confirm Zig version required by the chosen merjs release.
- Confirm deploy target: Cloudflare Workers, Railway, Fly.io, or another host that can run the merjs binary.
- Confirm whether frontend pages fetch from FastAPI server-side or browser-side.
- Keep `shared/api-spec.yaml` as the frontend/backend contract.
- Decide the session cookie/token format with Pranav.

### Deliverables

- merjs app runs locally.
- Basic layout renders.
- Build command works in CI.
- API contract is reviewed before real integration.

### Questions

- Are you allowed to deploy merjs somewhere other than Vercel?
- Will the backend issue an app session cookie, a JWT, or both?
- Will FastAPI and merjs share the same domain in production?
- Does your evaluator expect React/Next.js, or is using merjs acceptable and explainable?

## Milestone 1: Technical Proof Of Concept

Target outcome: user can log in, view one module, and ask questions in chat with citations.

### 1. merjs Scaffold

Set up:

- `frontend/app/layout.zig`
- `frontend/app/index.zig`
- `frontend/app/login.zig`
- `frontend/app/dashboard.zig`
- `frontend/app/chat.zig`
- `frontend/src/components/*`
- `frontend/src/lib/config.zig`
- `frontend/src/lib/mock_data.zig`
- `frontend/src/lib/backend_client.zig`
- Tailwind standalone CLI if you want utility CSS.

Acceptance criteria:

- `mer dev` starts locally.
- Routes are generated successfully.
- CSS is included.
- Layout works on desktop and mobile widths.

### 2. Shared API Types In Zig

Create Zig structs matching the OpenAPI contract:

- `User`
- `Module`
- `Announcement`
- `Task`
- `Citation`
- `ChatMessage`
- `ChatRequest`
- `ChatStreamEvent`

Acceptance criteria:

- Mock data and real backend responses use the same structs.
- Parsing failures produce a visible error state, not a crash.
- Date/time fields are handled consistently.

### 3. Auth UI

Build:

- `/login`
- `/api/auth/start` or redirect button to backend auth start.
- `/callback` visual page for loading/error/success.
- Logout action.
- Session check helper.
- Protected route guard helper used by dashboard/chat/tasks pages.

Acceptance criteria:

- Signed-out users are sent to login.
- Signed-in users can reach dashboard.
- Canvas OAuth errors are understandable.
- No Canvas token is stored in browser local storage.

Questions:

- Does backend own `/api/auth/canvas` and `/api/auth/callback/canvas`, or should merjs own the callback route and forward the code?
- What exact cookie/session name will frontend check?
- What should happen if the session expires mid-chat?

### 4. Dashboard V1

Build:

- Dashboard header.
- One-module summary.
- Announcements list.
- Upcoming assignments/deadlines.
- Last synced status.
- Empty/loading/error states.

Implementation:

- Start with `mock_data.zig`.
- Then replace with `backend_client.getModule(id)`.

Acceptance criteria:

- Dashboard renders without JavaScript.
- Page remains readable with long announcement titles.
- Urgent deadlines are easy to spot.

### 5. Chat UI V1

Build:

- Chat page.
- Message list.
- Chat input.
- Streaming assistant response.
- Citation display.
- Retry state.

Implementation choice:

- Use normal server-rendered history for the page shell.
- Use a small browser script for sending messages and reading SSE.
- Use WASM only if you want to handle local filtering/state in Zig; plain JS is probably faster for Milestone 1.

Acceptance criteria:

- Streaming response appears progressively.
- Citations are attached to assistant messages.
- User cannot accidentally submit the same message twice.
- Chat failure state preserves the user's question.

Questions:

- What is the exact SSE format from FastAPI?
- Will citations arrive during the stream or after completion?
- Does chat need conversation persistence in Milestone 1?

### 6. Frontend CI

Create `.github/workflows/frontend.yml`.

Checks:

- Install Zig.
- Build merjs app.
- Run Zig formatting check.
- Run Zig tests.
- Run route/codegen build.
- Optionally run browser/E2E smoke test.

Acceptance criteria:

- CI only touches frontend-relevant paths.
- No Node/npm checks remain unless you intentionally use separate JS tooling.

## Milestone 2: Full Prototype

### 7. Multi-Module Dashboard

Build:

- Module grid/list.
- Recent updates feed.
- Deadline timeline.
- Module detail route: `/module/[id]`.
- Tabs or segmented links for Announcements, Files, Assignments.

merjs approach:

- Prefer normal links and SSR pages.
- Use small client scripts only for filters or instant UI changes.

### 8. Task And Deadline View

Build:

- `/tasks`
- Filter by module, type, date range.
- Sort by due date or module.
- Completion checkbox.
- Timeline/calendar-style view.

Implementation:

- Server-render default task list.
- Use query params for filters first: `/tasks?module=cs1010&type=assignment`.
- Add JS enhancement later for smoother filtering.

### 9. Chat UI V2

Build:

- Module selector.
- Conversation sidebar.
- Citation panel.
- Source snippet viewer.
- Better mobile layout.

Implementation:

- Shell SSR from merjs.
- Streaming and active chat state handled by JS or WASM.
- Persist conversations only if backend supports conversation IDs.

### 10. Summary Display

Build:

- Expandable summaries on announcements.
- Summarise buttons for files/documents.
- Summary loading and failure states.

Implementation:

- Use SSR for precomputed summaries.
- Use small fetch-driven enhancement for on-demand summaries.

### 11. Responsive Layout

Build:

- Compact desktop sidebar.
- Mobile bottom navigation.
- Touch-friendly chat/task controls.
- Dashboard optimized for fast scanning.

Design direction:

- Use a compact productivity dashboard.
- Keep it friendlier and clearer than Canvas.
- Make chat one click away everywhere.

## Milestone 3: Extended System

### 12. Study Recommendations

- Dashboard recommendation card.
- Suggested revision topics.
- Links to files, announcements, or citations.

### 13. Weekly Planner

- `/planner`
- Weekly calendar view.
- Generated study blocks.
- Manual rearrangement if time allows.

### 14. Calendar Export

- Export selected tasks.
- `.ics` download.
- Optional Google Calendar handoff.

### 15. What Changed

- Per-module change badges.
- New/updated indicators.
- Since-last-visit summary.

### 16. UX Testing And Refinement

Test flows:

- Login and sync.
- Find the next deadline.
- Ask a module-specific question.
- Inspect a citation.
- Mark task complete.
- Find what changed.

### 17. E2E Tests

Use whichever is practical for merjs:

- Playwright if Node tooling is acceptable in CI.
- merjs/kuri if you want to stay closer to the framework's ecosystem.
- At minimum, browser smoke tests for dashboard and chat.

## Things To Change From The Old Plan

- Replace Next.js with merjs.
- Remove Auth.js unless you intentionally build a separate Node auth layer.
- Remove React component assumptions.
- Remove shadcn/ui assumptions.
- Replace React Testing Library/Jest with Zig tests plus browser/E2E tests.
- Replace Vercel as default deployment with Cloudflare Workers or a binary-friendly host.
- Replace client-heavy state management with SSR-first pages and progressive enhancement.
- Replace `frontend/src/app/*` with merjs `frontend/app/*.zig`.
- Replace TypeScript API types with Zig structs.
- Replace Next.js API routes with merjs `api/*.zig` proxy/helper routes where needed.

## Suggested Branch Order

1. `feature/frontend-merjs-scaffold`
2. `feature/frontend-api-types`
3. `feature/frontend-auth-ui`
4. `feature/frontend-dashboard-v1`
5. `feature/frontend-chat-ui`
6. `feature/frontend-ci`
7. `feature/frontend-multi-module`
8. `feature/frontend-task-view`
9. `feature/frontend-chat-v2`
10. `feature/frontend-summaries`
11. `feature/frontend-responsive`
12. `feature/frontend-recommendations`
13. `feature/frontend-planner`
14. `feature/frontend-calendar-export`
15. `feature/frontend-diff-view`
16. `feature/frontend-e2e-tests`
17. `feature/frontend-ux-refinements`

## Recommended First Week

Day 1:

- Scaffold merjs frontend.
- Confirm Zig/merjs versions.
- Confirm deployment target.
- Agree with Pranav on auth/session ownership.

Day 2:

- Build layout, navigation, and CSS baseline.
- Create mock data and Zig API structs.

Day 3:

- Build login/callback/logout screens.
- Add protected-page helper.

Day 4:

- Build dashboard V1 with mock data.
- Review missing backend fields with Pranav.

Day 5:

- Build chat shell and test streaming approach.
- Add frontend CI.
- Document local setup and architecture decisions.

## Immediate Questions

1. Are you choosing merjs because the team wants Zig/no-Node, or because the evaluator specifically suggested it?
2. Are you comfortable writing UI rendering logic in Zig, or should we keep the frontend structure very simple and componentized?
3. Can the deployment be Cloudflare Workers/Railway/Fly.io, or must it still be Vercel?
4. Will Pranav's backend issue a frontend-readable session endpoint like `GET /api/auth/me`?
5. Should chat streaming go browser-to-FastAPI directly first, or browser-to-merjs-to-FastAPI?
