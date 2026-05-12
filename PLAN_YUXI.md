# CanvasPilot -- Yu Xi's Plan (Frontend + Auth + UI)

## Your Domain

You own everything in `frontend/`, the Next.js application, all UI components, Auth.js integration, frontend tests, Vercel deployment config, and `.github/workflows/frontend.yml`.

**Rule: You never touch `backend/`.** If you need a backend change, open an issue or message Pranav. If an API endpoint needs to change, open a PR on `shared/api-spec.yaml` first.

---

## Milestone 1 -- Technical Proof of Concept

### Week 1-2: Foundation

#### 1. Project scaffolding (pair with Pranav)
- Next.js 14+ with App Router, TypeScript, Tailwind CSS
- Component library setup (shadcn/ui recommended)
- ESLint + Prettier config
- Auth.js (NextAuth) setup with Canvas OAuth provider
- Files: `frontend/src/app/layout.tsx`, `frontend/tailwind.config.ts`, `frontend/next.config.js`

#### 2. Auth UI
- Login page with "Connect with Canvas" button
- OAuth callback handler (`/api/auth/callback/canvas`)
- Session provider, protected route middleware
- User context (name, modules list)
- Files: `frontend/src/app/(auth)/`, `frontend/src/lib/auth.ts`

### Week 3-4: Core UI

#### 3. Dashboard page (single module)
- Module header (name, code, last synced)
- Announcements list (title, date, truncated content)
- Upcoming assignments list (title, due date, status)
- Fetch from `GET /api/modules/{id}` via backend proxy
- Files: `frontend/src/app/dashboard/`, `frontend/src/components/`

#### 4. Chat UI
- Chat input with send button
- Streaming message display (consume SSE from `/api/chat`)
- Assistant message with inline citation links
- Conversation history (client-side state)
- Files: `frontend/src/app/chat/`, `frontend/src/components/chat/`

#### 5. Frontend CI
- GitHub Actions: ESLint, Prettier check, Jest unit tests, build verification
- Files: `.github/workflows/frontend.yml`

### Milestone 1 Deliverable
A working frontend where: user logs in via Canvas, sees a dashboard for one module, and can ask questions in the chat interface with streaming responses and citation links.

---

## Milestone 2 -- Prototype

### Week 5-7: Full UI

#### 6. Multi-module dashboard
- Module grid/list with cards showing key stats (announcement count, upcoming deadlines)
- Module detail page with tabs: Announcements, Files, Assignments
- Global "recent updates" feed across all modules
- Deadline timeline view (sorted by due date, color-coded by module)
- Files: `frontend/src/app/dashboard/`, `frontend/src/components/dashboard/`

#### 7. Task/deadline view
- To-do list with checkbox completion
- Filters: by module, by type (assignment/quiz/tutorial/exam), by date range
- Sort: by due date, by module
- Visual timeline/calendar component
- Files: `frontend/src/app/tasks/`, `frontend/src/components/tasks/`

#### 8. Chat UI v2
- Module selector dropdown (filter RAG context to specific module)
- Conversation history sidebar
- Citation panel: click citation to see full source snippet
- Loading states, error handling, empty states
- Files: `frontend/src/app/chat/`, `frontend/src/components/chat/`

#### 9. Summary display
- Expandable summary cards on announcements
- "Summarise" button on documents/files
- Summary tooltip/popover on hover
- Files: `frontend/src/components/`

#### 10. Responsive design
- Mobile-first layout adjustments
- Bottom navigation on mobile
- Collapsible sidebar on desktop
- Files: `frontend/src/app/layout.tsx`, `frontend/src/components/`

### Milestone 2 Deliverable
Full-featured frontend: multi-module dashboard, task management, enhanced chat with module context, summaries, and responsive design.

---

## Milestone 3 -- Extended System

#### 11. Study recommendations UI
- Recommendations card on dashboard homepage
- Suggested revision topics with links to relevant materials
- Files: `frontend/src/components/dashboard/`

#### 12. Weekly planner UI
- Calendar-style weekly view with distributed study blocks
- Drag-to-rearrange for manual adjustments
- Files: `frontend/src/app/planner/`, `frontend/src/components/planner/`

#### 13. Calendar export UI
- "Export to Google Calendar" button on task views
- iCal file download option
- Files: `frontend/src/components/tasks/`

#### 14. "What changed" diff view
- Per-module change summary since last visit
- Badge indicators on module cards (new announcements, updated files)
- Highlighted new/changed items in module detail
- Files: `frontend/src/components/dashboard/`

#### 15. UI/UX refinements
- Address top 3 usability issues from Milestone 2 user testing
- Improve onboarding flow (first-time sync experience)
- Polish transitions, loading states, empty states

#### 16. Playwright E2E tests
- Critical flows: login -> dashboard -> chat -> task completion
- Cross-browser testing (Chrome, Firefox, Safari)
- Files: `frontend/e2e/`, `frontend/playwright.config.ts`

#### 17. Frontend documentation
- Component guide (pair with Pranav on architecture doc)
- Deployment guide for Vercel config
- Files: `docs/`

---

## Your Feature Branches

```
feature/frontend-scaffolding         (Week 1)
feature/frontend-auth-ui             (Week 1-2)
feature/frontend-dashboard-v1        (Week 3)
feature/frontend-chat-ui             (Week 3-4)
feature/frontend-multi-module        (Week 5)
feature/frontend-task-view           (Week 5-6)
feature/frontend-chat-v2             (Week 6)
feature/frontend-summaries           (Week 6-7)
feature/frontend-responsive          (Week 7)
feature/frontend-recommendations     (Week 8)
feature/frontend-planner             (Week 8-9)
feature/frontend-calendar-export     (Week 9)
feature/frontend-diff-view           (Week 9)
feature/frontend-ux-refinements      (Week 10)
feature/frontend-e2e-tests           (Week 10)
```

---

## Dependencies on Pranav

- **Week 1-2:** He builds the OAuth token exchange endpoint -- you redirect to it and handle the callback
- **Week 3:** He provides `GET /api/modules/{id}` so your dashboard can display real data
- **Week 3-4:** He provides `POST /api/chat` with SSE streaming -- agree on the streaming format early
- **Week 5:** He provides `GET /api/modules` (multi-module) and `GET /api/tasks` endpoints
- **Week 6:** He provides `GET /api/modules/{id}/summary` for your summary display
- **Milestone 2:** Coordinate user testing together

## What Pranav Needs From You

- Stable frontend deployed on Vercel for end-to-end testing
- Feedback on API response shapes (does the data structure work for your UI?)
- User testing logistics (recruit participants, prepare test scripts)
- Report any API bugs or missing fields promptly via GitHub Issues

---

## Tips for Building Without Backend

While waiting for Pranav's endpoints, you can work productively:

1. **Mock the API** -- Create a `frontend/src/lib/mock-data.ts` file with sample responses matching the API spec. Use it in development and switch to real API calls when ready.
2. **Build components first** -- All UI components (cards, lists, chat bubbles, timelines) can be built and tested with static data.
3. **Use MSW (Mock Service Worker)** -- Intercept fetch calls in development to return mock data, making the switch to real API seamless.
4. **Write tests against mocks** -- Jest tests with mock data validate component behavior before the real API exists.
