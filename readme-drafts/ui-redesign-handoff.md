# UI Redesign Handoff

Frontend reskin from generic gradient-SaaS to a clean, modern **course-workspace**
aesthetic modelled on the chosen slopkill reference. Shipped 2026-06-28 on
`feature/frontend-course-os-ui`. This doc is the design contract + the behavior the
UI must keep.

## What shipped

- Reskin implemented **entirely in `frontend/app/_styles.css`**, reusing every
  existing `cp-*` class. No markup / render-logic / `app.js` behavior changed in the
  styling pass, so all form actions, field names, and chat DOM hooks are preserved by
  construction.
- Direction = **inspiration #8** (`AI E-learning Dashboard / Educational Coaching Web
  App`, "LeaderForge") — a clean modern education app: cool-light surfaces, **white
  cards with soft shadows + light borders**, a **teal/emerald accent**, sans-serif
  type, rounded corners, pastel/soft pills, and a list-of-cards + document layout.
  Reference image: `ui-redesign-assets/inspiration-8.jpg`. Built to read as the same
  family as that reference.

## Design system (`:root` in `_styles.css`)

- **Surfaces (cool light):** `--cp-bg #f4f6f8` (page), `--cp-surface #ffffff` (cards),
  `--cp-surface-2 #f5f7f9` (fills/inputs), `--cp-border #e8eaef` (light).
- **Text (slate):** `--cp-text #2c3038`, `--cp-heading #14171c`, `--cp-muted #6b7280`.
- **Accent (teal — the brand action color):** `--cp-accent #0d9488`,
  `--cp-accent-strong #0b7d73`, `--cp-accent-soft #e3f4f1`. Drives buttons, active nav,
  links, chips, progress, focus rings. (Single brand lever — change `--cp-accent` to
  reskin the whole product.)
- **Status:** green `#2f9e6e`, red `#dc4c44`, amber `#9a7b2e` with soft tinted fills.
- **Geometry:** radii 10/14px, pills 999px; soft subtle shadows
  (`--cp-shadow-sm` for cards, `--cp-shadow` for elevated panels) — tasteful, not the
  old heavy/gradient look. No `linear-gradient` anywhere.
- **Type:** all sans (`Inter, ui-sans-serif, system-ui`); mono only for course codes &
  citations. Heading weights 700–800 with tight tracking. No webfonts — CSS is inlined
  and works offline.

### Component language
- App shell: white sidebar, light divider; teal rounded `CP` monogram; active nav =
  soft-teal rounded pill with a teal dot.
- Buttons: solid **teal** primary (subtle shadow), white ghost with light border.
- Cards: white, light border, soft shadow, 14px radius. `.cp-card-title` = dark
  semibold heading with muted right-hand meta.
- Pills (`.cp-chip`, `.cp-course-pill`, `.cp-task-due`): soft-tinted rounded pills.
- Lists (`.cp-feed`, `.cp-task-list`, `.cp-prompt-list`, `.cp-flow-list`): rows as
  light rounded **cards** (the #8 list-of-cards), with teal dots and muted meta.
- Chat: white log; user = teal bubble, reply = white card w/ soft shadow; citations
  as teal-link references under a light rule (the trust payload).
- Landing/auth: bold sans hero with teal accent word; numbered feature **cards** with
  soft-teal rounded number badges; soft-fill rounded inputs with a teal focus ring.

## Pages (each → a job)

| Page | Route | Job |
| --- | --- | --- |
| Landing | `/` | Evaluate |
| Login | `/login` | Commit |
| Dashboard | `/dashboard` | Orient |
| Chat (cited Q&A) | `/chat` | Ask & verify |

Shared shell: left sidebar (brand · Dashboard/Chat nav · prototype-flow note ·
sign-in/out), inlined global tokens, footer. We kept the existing sidebar rather than
#8's top nav — the hybrid reskins the current shell in place.

## Behavior the UI must preserve (do not regress in future edits)

**Global shell:** brand link to `/`; nav to `/dashboard` and `/chat` with active state;
mobile nav; sign-in/out; the `data-cp-auth="anonymous"` marker that makes the layout
show *Sign in* instead of *Sign out* (anonymous/demo pages must not show misleading
sign-out or live-sync actions).

**Landing `/`:** authed users redirect to `/dashboard`; primary CTA → `/login`; demo
CTA → `/dashboard?mock=1`; flow communicates sources → wiki → cited Q&A → flashcards.

**Login `/login`:** default signin; `?mode=signup` switches to create-account; tab
links `/login?mode=signin|signup`; `?signed_out=1` and `?error=<code>` banners
(`invalid_credentials`, `email_taken`, `weak_password`, `password_mismatch`,
`missing_fields`, `invalid_email`, `backend_unavailable`).
- Sign-in form: `method=post`, `action="/api/auth/signin"`; `email`
  (`type=email`,`autocomplete=email`,required), `password`
  (`type=password`,`autocomplete=current-password`,required).
- Signup form: `method=post`, `action="/api/auth/register"`; `name`
  (`autocomplete=name`,required), `email` (as above), `password` &
  `confirm_password` (`type=password`,`autocomplete=new-password`,`minlength=8`,required).
- Demo link `/dashboard?mock=1`.

**Dashboard `/dashboard`:** mock data when unauthenticated or `?mock=1`; authed path
fetches modules/announcements/upcoming tasks with graceful backend-failure fallback;
empty-module state renders; status banners for `?synced=1`, `?sync_failed=1`,
`?auth=registered`, `?auth=signed_in`. Content: module summary (code/name/term),
synced count, ≤5 focus-module announcements (title, relative time, summary/body
fallback) with empty state, upcoming assignments scoped to focus module (skip
completed, skip no-due-date, only due within next 14 days, ≤6 shown, urgent class,
empty text "Nothing due for this module in the next two weeks."), `Open chat` link.
Sync: authed shows POST form to `/api/sync` with hidden `action=sync`; anonymous shows
a sign-in-to-sync link instead.

**Chat `/chat`:** loads the cache-busted browser script (`/app.js?v=course-os-2`); mock
modules when unauthenticated or `?mock=1`; `?module=<id>` preselects; selector includes
"All modules". DOM hooks required by `frontend/public/app.js`: `id="cp-chat-form"`,
`cp-chat-log`, `cp-chat-input`, `cp-chat-send`, `cp-chat-module`; plus `role="log"`,
`aria-live="polite"`, input `name="message"`, select `name="module"`, POST to
`/api/chat` with `message`/`module_id`/`history`, citation rendering, mock-reply
warning, inline error + retry that does not duplicate the user turn.

**`frontend/public/app.js`:** escapes inserted text; appends user/reply bubbles;
disables input/button while sending then re-enables and focuses; stores failed message
for retry; citation links open in a new tab with `rel="noopener"`; retry avoids
duplicated history. (If `app.js` ever changes, bump the `/app.js?v=` query in
`chat.zig` — static assets are immutable.)

## Run & verify

```bash
cd frontend && zig build serve          # http://localhost:3000 (mock data, no backend)
# routes: /  /login  /login?mode=signup  /dashboard?mock=1  /dashboard?mock=1&synced=1  /chat?mock=1
cd frontend && zig build test --summary all
```
This pass: `zig fmt --check` clean, `zig build test` → `test success`. Visual review via
**kuri** (its SSRF guard blocks localhost, so drive Chrome and attach):
```bash
chrome --headless=new --remote-debugging-port=9224 --remote-allow-origins='*' \
  --user-data-dir=/tmp/cpkuri --window-size=1440,1000 <url>
CDP_URL=http://127.0.0.1:9224/json/version kuri
curl -H "Authorization: Bearer $(kuri token)" "http://127.0.0.1:8080/screenshot?tab_id=<id>&full=true"
```
Checked at 1440×1000 and 414px mobile. Before/after pairs in `ui-redesign-assets/`
(`before-*.png` / `after-*.png`).

## Follow-ups

- Chat default state shows a large empty log (pre-existing) — a seeded demo
  conversation would showcase the new reply + mono-citation styling.
- Future M2/M3 screens (Sources, Wiki, Flashcards) should inherit these tokens and the
  list-of-cards / soft-pill / teal-accent patterns.
