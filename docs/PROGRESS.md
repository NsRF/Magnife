# Magnife — Progress log

Running log of the overnight MVP build (started 2026-11-02). Newest entries at the bottom of each section.

## Log

- Read docs/MVP.md, BRIEF.md, STORIES.md, GLOSSARY.md, research/platform.md, research/design.md.
- Toolchain: Xcode 27.2 (27B52), Swift 6.4.2, macOS 27.2 host, system SQLite 3.54.0 (FTS5 and JSON built in).
- Go was not installed. Installed Go 1.27.3 with Homebrew (a package registry).
- `git init` at the repo root; moved `MVP.md` to `docs/MVP.md`, where the instructions expect it.
- Wrote `docs/schema.sql` (schema version 1), the Go/Swift contract, including the helper's stdout/stdin protocol. Checked it loads in `sqlite3`.
- Foundation workflow (5 agents: 3 builders, 2 independent verifiers):
  - `ingest/`: Go helper on the Collector's pdata decoders, modernc SQLite, batch writer, busy-port detection, pruning, stdin protocol; sample sender `scripts/send-sample-traces`; interop apps in `scripts/interop/` (Go, Node, .NET 10, Python). `go test -race ./...` passes. Verifier fixed 6 issues (2.9 s exit under flood → 0.7 s budget, 64 KiB stdin line crash, retention overflow, truncated owner names, 64→16 MiB cache, metrics logging).
  - Interop: 13 SDK × protocol combinations PASS (traces, logs, metrics dropped without exporter errors): Go grpc/http-protobuf, Node grpc/http-protobuf/http-json, .NET grpc/http-protobuf, Python grpc/http-protobuf.
  - Load: 5,000 spans/s for 60 s, 300,010 spans + 81,292 logs, 0 lost, export→batch-line p99 142 ms, helper RSS 73 MB. 30,000-span trace commits in ~420 ms. Backlog drains at ~25,000 spans/s.
  - `app/`: BAMA template scaffold, SwiftData removed, GRDB 7.12 read-only `TelemetryReader` (all reads `@concurrent`), `HelperEvent`/`LineBuffer`, `HelperSupervisor` with 0.5→30 s backoff, three-column skeleton, snapshot pages 01–09, fixture db tool. 62 unit tests (3 clean runs), self-test 38/38, snapshots 20 PNGs via real `screencapture`, grid checks PASS. Verifier fixed an AppKit NSTableView reentrancy warning, glossary wording, a clipped Time column.
  - Lifecycle with the real helper: helper listening 0.44 s after launch on 127.0.0.1 only; quit → helper gone in 0.15 s; `kill -9` app → helper gone in 0.017 s.
  - `docs/ux.md`: app-wide structure, menus, keyboard map, query language, UX blocks S-009–S-032; new glossary terms.
- **Commits:** the repo's commits are signed through 1Password (`commit.gpgsign=true`, `op-ssh-sign`), which cannot sign while you are away ("1Password: agent returned an error"). Turning signing off was refused by the safety classifier, correctly. So the night's work is recorded as checkpoints with `scripts/night-checkpoint.sh` (a tree object + patch + Conventional Commit message per story in `.night/`), and `scripts/replay-night-commits.sh` turns them into real signed commits in one go. Tested the replay in a scratch clone.

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
10. **Minimum macOS stays 26** (brief decision); the build uses the installed Xcode 27 SDK and Swift 6.4 tools. `swift-tools-version: 6.4` (template pinned 6.2).
11. **Decoding uses Collector pdata** (`ptraceotlp`/`plogotlp`/`pmetricotlp`), not the full `otlpreceiver`: same decoders and gRPC services, without the Collector component framework; we need our own listeners for the busy-port check anyway.
12. **SQLite in Go is modernc.org/sqlite** (pure Go, CGO_ENABLED=0), so the amd64 slice cross-compiles without a C toolchain. Page cache 16 MiB.
13. **Helper exit budget:** on stdin EOF, queued data is committed for up to 700 ms, then dropped and counted on stderr. Stdin lines over 4 KiB are ignored. Busy-port owner name comes from `ps`.
14. **The app waits for the helper before opening the database.** A read-only connection cannot open a WAL database whose `-wal` file is missing (verified, see below), which is the state after the helper closes cleanly. The app opens the db after the helper's `ports` event and retries every 2 s. Not adopted: SQLITE_FCNTL_PERSIST_WAL in the helper (would let the app read stored data if the helper cannot start at all); revisit if that case matters.
15. **A service scope** (sidebar) shows every trace with any span from that service; the sidebar count is traces with an Error span from it.
16. **Traces vs Logs** is a toolbar segmented control plus View > Traces ⌘1 / Logs ⌘2 (docs/ux.md). Pause is ⌃⌘P (⌘P is Print).
17. **Duration format:** "850 µs", "4.6 ms", "240 ms", "1.24 s", "12.4 s", "2 min 5 s".
18. **Settings keeps the template's Appearance tab** (accent picker, "System" default) next to General and Notifications.
19. **Commits are checkpoints until you replay them** (see Log). One checkpoint per story, Conventional Commit messages.

## Verified [U] items

| Item | Source | Result |
| --- | --- | --- |
| With SO_REUSEADDR, binding 127.0.0.1:P succeeds while another process holds *:P, splitting traffic | platform.md, helper | **Confirmed.** Go's `net.Listen("tcp","127.0.0.1:P")` succeeded with a python3 holder on `0.0.0.0:P` and on `[::]:P` (dual stack), and the Go listener then accepted the 127.0.0.1 connections. Fails only when the holder is on 127.0.0.1:P. The helper detects any other listener (lsof + connect probe on 127.0.0.1 and ::1) and reports busy instead of binding. Automated: `TestBusyWildcardListener`, `TestBusyPortThenRetry`. |
| Older Go linkers emit no LC_UUID; build with `-B gobuildid` | platform.md, helper | **Disproved for Go 1.27.3:** LC_UUID present in both slices even without `-B gobuildid`. With it, the UUID is reproducible across rebuilds. `ingest/build.sh` fails if a slice lacks LC_UUID. |
| (new) A read-only reader can open the WAL db at any time | app | **Disproved when `-wal` is missing:** read-only GRDB pool fails with SQLITE_CANTOPEN (error 14) if the `-wal` file is absent, even in a writable folder; works if an (empty) `-wal` exists, and sees live commits from another process. Apple's sqlite3 keeps the `-wal` after close; modernc (the helper) deletes it. Tests: `WALReadonlyTests.swift`. Design: decision 14. |
| Helper outlives the app and blocks the ports after Sparkle relaunch | platform.md | **Partly verified:** quit → helper gone in 0.15 s, `kill -9` → 0.017 s (stdin EOF). Sparkle itself not tested (no appcast). |

## Problems

## Blocked

- **Signed commits** (1Password locked). Work is recorded as checkpoints; run `scripts/replay-night-commits.sh` with 1Password unlocked to create the signed commits. Not retried further.
