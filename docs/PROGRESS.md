# Magnife — Progress log

Running log of the overnight MVP build (started 2026-11-02). Newest entries at the bottom of each section.

## Log

- Read docs/MVP.md, BRIEF.md, STORIES.md, GLOSSARY.md, research/platform.md, research/design.md.
- Toolchain: Xcode 27.2 (27B52), Swift 6.4.2, macOS 27.2 host, system SQLite 3.54.0 (FTS5 and JSON built in).
- Go was not installed. Installed Go 1.27.3 with Homebrew (a package registry).
- `git init` at the repo root; moved `MVP.md` to `docs/MVP.md`, where the instructions expect it.
- Wrote `docs/schema.sql` (schema version 1), the Go/Swift contract, including the helper's stdout/stdin protocol. Checked it loads in `sqlite3`.

## Decisions

1. **Milestone mapping.** The instructions name M1 Foundation, M2 Visualization, M3 Differentiators; STORIES.md has M1–M6. Mapping: M1 Foundation = stories M1 (S-001–S-008); M2 Visualization = stories M2–M4 (S-009–S-022: sidebar, pause, logs, retention, search, filters, keyboard); M3 Differentiators = stories M5–M6 (S-023–S-032: detectors, menu bar, notifications, polish). The instructions' M4 is release prep (no stories).
2. **Repo layout.** Monorepo: `ingest/` (Go), `app/` (Swift package from the BAMA template), `scripts/`, `docs/`. One git repo at the root.
3. **Detectors run in the app (Swift, MagnifeKit),** not in the helper, so they are unit-tested with `test-mac-app` as instructed and the app stays a read-only consumer. To keep them cheap, the helper promotes the attributes they need into columns (`db_system`, `db_statement`, `http_method`, `http_status_code`, `http_route`, `http_url`), reading both old and new semantic-convention names.
4. **Trace rows are recomputed by the helper** from the trace's spans after every batch that touches them, so late spans and missing roots are always consistent. Trace status: Error if any span is Error, else the root's status.
5. **Route** = `"<method> <http.route>"` when the root span has both (matches the UX example "POST /orders"), else `http.route`, else the root span name.
6. **App-owned state stays out of magnife.sqlite.** The app never writes the database, so saved filters, retention choice and UI preferences live in UserDefaults. The app tells the helper the retention with `--retention` and the `retention <seconds>` stdin command; the helper prunes.
7. **Helper protocol** is JSON lines on stdout (`ports`, `batch`, `pruned`, `error`) and text commands on stdin (`retention`, `prune`, `retry`); EOF on stdin means exit. Written into `docs/schema.sql`.
8. **Metrics are accepted and dropped** on both gRPC and HTTP (`/v1/metrics`), so SDKs that export metrics by default don't log export errors. Showing metrics is v0.2.
9. **Busy-port detection lives in the helper**: before binding, it checks for any other listener on the port (any address) and reports it as busy with the owner's name, instead of binding 127.0.0.1 next to a `*:port` listener.
10. **Minimum macOS stays 26** (brief decision); the build uses the installed Xcode 27 SDK and Swift 6.4 tools.

## Verified [U] items

| Item | Source | Result |
| --- | --- | --- |

## Problems

## Blocked
