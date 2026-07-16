# Milestone 3 frontend delivery

This document describes the frontend-only Milestone 3 surfaces. It does not claim that the Milestone 3 backend contracts or broad parent issues are complete.

## Routes

| Route | Frontend surface |
| --- | --- |
| `/settings/providers` | Provider status, capabilities, and disabled write-only credential controls |
| `/outputs` | Source/wiki selection, cited summary, grounding boundary, and disabled export |
| `/health` | Summary, severity URL filters, and structured findings |
| `/history` | Timeline filters, versions, citation changes, and unified diff |
| `/progress` | Evidence-based semantic meters, uncertainty, signals, and recommendations |
| `/marked-papers` | Synthetic paper list and privacy guidance |
| `/marked-papers/:id` | Synthetic extraction details and unconfirmed evidence proposals |

## Explicit demo mode

Fixtures are shown only when both the server environment opt-in and request query opt-in are present:

```sh
cd frontend
WIKIBASE_MOCK_ENABLED=true zig build serve
# then open http://127.0.0.1:3001/progress?mock=1
```

`WIKIBASE_MOCK_ENABLED=1` is also accepted. A bare `?mock=1` without the environment variable does not enable M3 fixtures.

## Live, demo, and unavailable behavior

- **Explicit demo:** each page displays a visible “Demo data” label. All records are deterministic, synthetic, and use `demo-` IDs. Provider credentials and real papers are never included.
- **Authenticated, non-demo:** the page honestly says that its backend contract is unavailable. It does not silently substitute fixtures.
- **Anonymous, non-demo:** the request redirects to `/login`.
- **Mutations and export:** Test, Save, Disconnect, generation, health checks, restore, paper upload/review decisions, and export are disabled where no backend mutation exists. No fake success or download is produced.
- **Older M2 pages:** their existing unauthenticated fixture behavior is preserved as known debt; the stricter gate applies to new M3 routes.

## Backend blockers

These frontend views are demonstrations pending backend work. They do not close or complete the parent issues below:

- **#15:** cited output generation, grounding enforcement, citations, persistence, and workspace isolation.
- **#17:** project-wide evaluation, user testing, cross-stack coverage, and final submission evidence.
- **#18:** canonical Markdown/archive generation, workspace authorization, and download endpoints.
- **#19:** workspace health computation, revision history storage, diff generation, and restore mutations.
- **#20:** knowledge meter evidence aggregation, confidence calculation, and recommendations.
- **#30:** marked-paper upload, private storage, extraction, review, correction, deletion, and meter integration.
- **#54:** provider discovery, encrypted/write-only credential persistence, validation, test, save, and disconnect endpoints.

## Automated checks

Run from `frontend/`:

```sh
zig fmt app src tools build.zig
zig build codegen
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

The Zig tests cover explicit demo gating, safe IDs and export filenames, unknown meter semantics, and fixture secret-sentinel absence.

## Accessibility and manual checklist

- [ ] Navigate all links, fields, selectors, details, and enabled controls by keyboard.
- [ ] Confirm the universal focus indicator is visible against every surface.
- [ ] Confirm headings and landmarks produce a useful screen-reader outline.
- [ ] Confirm demo/live-unavailable labels are announced and not conveyed by color alone.
- [ ] Confirm provider status text includes configured, disconnected, invalid, and pending.
- [ ] Confirm health text includes healthy, warning, failed, stale, and unknown.
- [ ] Confirm the uncertain topic says “Estimate unknown” and does not display `0%`.
- [ ] Confirm disabled actions explain their backend dependency.
- [ ] Confirm one-column layouts and 44px touch targets on a narrow mobile viewport.
- [ ] Confirm reduced-motion preference removes nonessential transitions.
- [ ] Confirm dynamic route IDs and all fixture text are escaped before HTML output.
- [ ] Confirm no browser storage is used by M3 pages and no credential appears in page source.
