# Good morning: Magnife after the night

Written 2026-11-03 at about 01:00. Read this first. Everything else is linked from here. Every command below was run tonight or read from its script.

**In one paragraph:** all 32 stories in [STORIES.md](STORIES.md) are built. 28 are fully done. 4 need you:
- S-030 is blocked on a 100 ms budget.
- S-004 is partial because its VoiceOver check has not run unlocked.
- S-028 and S-032 are done except for one line each that can only be checked by hand.

The detectors (Slow SQL, N+1, HTTP Error) now say what is wrong and where it is. Release prep (M4) is done up to the point where your Apple account is needed. **Your first action:** unlock 1Password and run `scripts/night-checkpoint.sh --flush`. That turns the last 8 checkpoints into signed commits (section 6).

Milestone names: the night's M1 is STORIES "M1 Core loop" (S-001 to S-008). The night's M2 is STORIES M2 to M4 (S-009 to S-022). The night's M3 is STORIES M5 and M6 (S-023 to S-032). M4 is release prep ([RELEASE.md](RELEASE.md)).

---

## 1. Build, install, launch

```sh
cd ~/Personal/Magnife

app/build.sh                # release build, installs ~/Applications/Magnife.app
                            # (signed "Apple Development: nasserfarhatt@gmail.com" when the
                            # keychain has it, else ad hoc). --debug, --open (quit + reopen)
scripts/install-local.sh    # always ad hoc, assembles in a staging folder, quits only the copy
                            # it replaces. --dest <dir> (or INSTALL_DIR), --open, --no-quit, --debug
open ~/Applications/Magnife.app
```

- `app/build.sh` deletes `~/Applications/Magnife.app` before it copies the new build. Quit Magnife first.
- `scripts/install-local.sh` swaps the bundle only after it has been signed and verified.
- Sparkle is off by default. `MAGNIFE_SPARKLE=1` in front of either script adds Magnife > Check for Updates…, with placeholder feed and key values ([RELEASE.md](RELEASE.md) A2).

Send test data to a running Magnife (default ports 4317 gRPC and 4318 HTTP; `--grpc host:port` and `--http host:port` change them):

```sh
scripts/send-sample-traces                         # seed set: 5 traces, 37 spans, 20 logs, 3 services, mixed protocols
scripts/send-sample-traces --edges                 # detector edge set: 6 traces, 51 spans, fixed ids and durations
scripts/send-sample-traces --volume 12000 --seed 1 # random traces until N spans; --seed makes them the same every run
scripts/send-sample-traces --rate 5000 --duration 60s   # the S-030 flood
scripts/send-sample-traces --huge-trace 30000 --protocol grpc
scripts/send-sample-traces --live                  # a random trace every 1-2 s until Ctrl-C
scripts/send-sample-traces --help                  # --protocol http-protobuf|http-json|grpc|mixed, --scenarios, --compression, --workers
```

All of these ran tonight against a helper on a `mktemp -d` store (ports 47417/47418):
- The seed set stored 37 spans, 5 traces and 20 logs.
- `--edges` stored 51 spans in 6 traces.
- `--volume 200 --seed 1` stored 204 spans in 17 traces.
- The helper listened on 127.0.0.1 only.

Checks: `cd ingest && go test ./...`, `cd app && swift test`, `app/tools/selftest.sh` (`APP_SELFTEST_ONLY=<area>` runs one area), `app/tools/snap.sh` (prints its shots folder, linked from `/tmp/Magnife-shots`), `scripts/interop/run-all.sh`. The full release test pass is [RELEASE.md](RELEASE.md) A3.

## 2. Point your apps at Magnife

These work for every SDK. The endpoint is the base URL, without `/v1/traces`:

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # or http://localhost:4317 for grpc
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf           # or grpc (Node also http/json)
```

The empty trace list shows these lines per language and has a Copy button (S-003).

| Language | What to know | Tested live |
| --- | --- | --- |
| .NET | `AddOtlpExporter()` with no options reads the variables. Its default protocol is **grpc on 4317**: use `http://localhost:4317`, or set `http/protobuf` with 4318. Log bodies arrive as the template (`loading order {OrderId}`) unless you set `IncludeFormattedMessage = true`. | yes: grpc, http/protobuf, default (grpc) |
| Go | The exporter is chosen in code: `otlptracehttp` / `otlploghttp` for HTTP, `otlptracegrpc` / `otlploggrpc` for gRPC. Both read the endpoint variable (`http://` means no TLS). There is no http/json. | yes: grpc, http/protobuf, default |
| Node | Use `@opentelemetry/sdk-node`. Traces, logs and metrics go to OTLP by default. The default protocol is http/protobuf. | yes: grpc, http/protobuf, http/json, default |
| Python | Run the app under `opentelemetry-instrument`, and set `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` for `logging` records. The distro defaults to grpc on 4317. | yes: grpc, http/protobuf, default (grpc) |
| Java | `-javaagent:opentelemetry-javaagent.jar` with the same variables. | **no, documented only** |

- **Live:** `scripts/interop/run-all.sh 47517` was re-run at 00:58 tonight against the current helper (with the new Host check). All 13 SDK and protocol rows passed for traces, logs, metrics (dropped without exporter errors) and exports. Details are in [scripts/interop/README.md](../scripts/interop/README.md).
- **Optional:** `OTEL_BSP_SCHEDULE_DELAY=500` sends spans every 0.5 s instead of every 5 s.
- **Docker:** apps in Docker Desktop containers can use `http://host.docker.internal:4318`. The receiver accepts that Host (decision 200). This has not been tested from a real container.

## 3. What works

### The headline: detectors that say what and where

Every finding names the query, call or route, the service it ran in, and the route or span it ran under. Findings show in four places: a badge in the list, a strip line under the waterfall header, an orange icon on the waterfall row, and a sentence in the span detail.

These lines were printed tonight from a fresh seed plus `--edges` store through the real helper, by `MAGNIFE_EDGE_STORE=<db> MAGNIFE_FINDINGS_DUMP=<file> swift test`. The edge golden test passed, with totals of Slow SQL 4, N+1 3 and HTTP Error 9.

**Seed set** (strip line, then span detail):
- `Slow SQL · 851 ms · SELECT Orders · checkout-api · GET /reports/sales · SELECT date_trunc('day', …`
  "This query took 851 ms in checkout-api, under GET /reports/sales: 96% of the trace's 884 ms. Queries over 100 ms are flagged."
- `N+1 · 8 times, 58 ms in all · SELECT order_items · orders · GET /v1/orders · SELECT * FROM order_items WHERE order_id = ?`
  "This statement ran 8 times in orders, under GET /v1/orders, 58 ms in all: 60% of the trace's 96 ms. Each run took 7.2 ms. …"
- `HTTP Error · 500 · 57 ms · web → checkout-api · POST /payments`
  "web called POST http://localhost:5080/payments and got 500 after 57 ms. checkout-api answered as POST /payments. Under it, INSERT Payments in checkout-api has status Error: 23505: duplicate key value violates unique constraint "IX_Payments_OrderId"."
- `Slow SQL · 2.00 s · orders · UPDATE inventory SET available = available - $1, …` "… The span has status Error: context deadline exceeded."

**Edge set** (the boundaries):
- `Slow SQL · just over 100 ms · SELECT MonthlyTotals · checkout-api · GET /reports/thresholds`: a 100.4 ms query. The 99.9 ms and 100.0 ms queries are not flagged.
- `Slow SQL · 330 ms · checkout-api · GET /reports/thresholds · SELECT Ledger`: a query with no statement. Its detail says "This postgresql query took 330 ms …".
- `N+1 · 6 times, 138 ms in all · SELECT inventory · checkout-api and orders · GET /stock`: one group across two services, in the same trace.
- `N+1 · 5 times, 10 ms in all · SELECT prices · checkout-api · LoadRecentOrders · … sku IN (?)`: exactly 5 runs, with IN lists of 1 to 5 values and a different sqlcommenter comment on each run, grouped as one statement.
- `HTTP Error · no response code · 30.0 s · checkout-api · POST api.stripe.com/v1/refunds`: "… got no response code in 30.0 s. The span has status Error: The request was canceled due to the configured HttpClient.Timeout …"
- `HTTP Error · 200 · 40 ms · checkout-api · GET /stock/{sku}`: "… returned 200 after 40 ms, but the span has status Error …"
- `HTTP Error · 404 · 16 ms · checkout-api · GET /customers/{id}` and `… 400 … POST /customers/{id}/validate`: 4xx responses count.

Snapshots, light and dark (`-light.png` / `-dark.png`), taken tonight after the fixes at 2560 × 1520:
- `~/Library/Developer/Magnife/e2e/M4/snap/03-trace-detail-slow-sql-light.png`
- `~/Library/Developer/Magnife/e2e/M4/snap/03-trace-detail-n-plus-one-dark.png`
- `~/Library/Developer/Magnife/e2e/M4/snap/03-trace-detail-http-error-light.png`
- `~/Library/Developer/Magnife/e2e/M4/snap/02-trace-list-findings-wide-light.png` (the badges with their words)

### Per milestone

**M1, the core loop (S-001 to S-008).** All done except S-004 (partial, section 5).
- OTLP over HTTP and gRPC on 127.0.0.1 only, with busy-port banners and Try Again.
- Environment variables per language.
- A live list that holds still when you scroll away.
- An NSOutlineView waterfall that auto-collapses above 500 spans.
- Span detail with an exception first.
- Persistent WAL, so stored traces show at once on relaunch.

Snapshots:
- `~/Library/Developer/Magnife/e2e/M1/snap-seed/` (01 to 04)
- `~/Library/Developer/Magnife/e2e/M1/after-fix/03-trace-detail-30000-light.png` (a 30,000-span trace)
- `~/Library/Developer/Magnife/e2e/M1/snap-busy-real/`, `snap-relaunch/`, `snap-volume/`, `snap-empty/`

**M2, navigate, logs, retention, speed (S-009 to S-022).** All done.
- Sidebar services with error counts, and Pause.
- Span logs, Trace Logs, the Logs view and its filters.
- Retention: 24 h by default, with Settings > General > Data.
- ⌘K Search, status / "Slower than" / attribute filters, saved filters.
- Full keyboard navigation.

Real window captures driven through System Events:
- `~/Library/Developer/Magnife/e2e/M2/after-fix/01-empty.png` to `14-logs-error-chip-axpress.png`
- Snapshot pages: `~/Library/Developer/Magnife/e2e/M2/snap/`

**M3, detect, alert, polish (S-023 to S-032).**
- Detectors (above).
- Menu bar extra with Recent Errors, which opens a failed trace.
- Notifications for failed traces: built, but the real prompt is untested (section 5).
- Opens in under a second: rows on screen in 470-543 ms at 12,000 to 300,000 spans.
- Light, dark and Increase Contrast palettes.
- Magnife's own icon.

Snapshots:
- `~/Library/Developer/Magnife/e2e/M3/after-fix/snap/` and `~/Library/Developer/Magnife/e2e/M3/snap/`: the 03 detector pages, 05 Logs, 06 ⌘K, `08-menu-bar-*`, `03-trace-detail-contrast-*`, `05-logs-contrast-*`.
- These were taken before the "what and where" words. For the current words, use the M4 folder below.

**Current build, all pages:** `~/Library/Developer/Magnife/e2e/M4/snap/`. This is a copy of tonight's last `app/tools/snap.sh` run (124 PNGs, every page in light and dark). For example:
- `01-empty-state-light.png`
- `02-trace-list-dark.png`
- `04-span-detail-logs-light.png`
- `05-logs-filtered-dark.png`
- `06-command-k-tokens-dark.png`
- `07-filter-bar-condition-light.png`
- `08-menu-bar-light.png`
- `09-settings-general-light.png`
- `09-settings-notifications-light.png`

**M4, release prep.**
- `scripts/install-local.sh`: ad hoc, `--dest`, `--no-quit`. It finds a copy started by relative path and runs one install at a time.
- Sparkle 2.10.1 behind the `MAGNIFE_SPARKLE` trait.
- [RELEASE.md](RELEASE.md): Part A works now. Part B is your steps.
- The security, scope and e2e review: all 21 findings fixed, except the S-030 re-measure ([PROGRESS.md](PROGRESS.md) Log, "Security, scope and e2e review fixes").
- Of those fixes, the helper now:
  - refuses values nested more than 64 levels,
  - caps bodies at 32 MiB with 4 decoding at once,
  - answers only localhost Hosts and Origins,
  - keeps 0600 files in a 0700 folder,
  - shrinks the `-wal` after bursts.

**Tonight's final checks, on the current working tree:**
- `app/build.sh`: no warnings, `codesign --verify --deep --strict` passes.
- `swift test`: 343 passed, including the edge golden test on a live store.
- `go test ./...`: 73 passed.
- Interop: 13 of 13 passed.
- The fix round's full self-test: 564 of 565. The one failure is the known S-021 rename Esc flake, which passes alone (`=saved-filters`, 50 of 50).

## 4. [U] results (unverified research items)

All of these are in the [PROGRESS.md](PROGRESS.md) "Verified [U] items" table.

| Item | How it was tested | Result |
| --- | --- | --- |
| SO_REUSEADDR lets 127.0.0.1:P bind while *:P is held | Go listener next to a python holder on 0.0.0.0 and [::] | Confirmed. The helper detects other listeners and reports the port busy (`TestBusyWildcardListener`). |
| Older Go linkers emit no LC_UUID | `otool` on both slices | Disproved for Go 1.27.3. `ingest/build.sh` fails if a slice lacks LC_UUID. |
| A read-only reader opens the WAL db at any time | GRDB read-only pool tests | Disproved when `-wal` is missing, so the helper keeps its `-wal` (decision 14). |
| After a clean helper exit the app opens the db at once | Go and Swift tests, plus the self-test | Confirmed with persistent WAL (2-3 ms). |
| The helper outlives the app after a Sparkle relaunch | Quit and `kill -9` timings in every self-test | Partly verified: the helper is gone 6-15 ms after the app. A real Sparkle relaunch is not tested (B9 local appcast test). |
| The 500-span auto-collapse threshold | `--huge-trace` 1,000 / 5,000 / 30,000 | Verified: opening takes 16-55 ms. 500 is kept for readability. |
| SwiftUI smooth at large row counts? | S-030 load check | Answered: no, the lists are AppKit (NSTableView / NSOutlineView). |
| Pruning does not block ingest or the UI | Self-test at 3 s retention under 4,000 spans/s | Confirmed: gaps of 132 ms, stalls of 93 ms. |
| An accessory-app window opens behind others | S-027 self-test from code | Partly verified: a real click on the status item is untested (needs your mouse). |
| Notification authorization from a development-signed build | — | **Not run (manual):** it would set your real permission. It is your check (B9). |
| Ad hoc builds may be refused notification authorization | — | **Not run (manual)**, same reason. It is your check on an `install-local.sh` build (B9). |
| `accessibilityHighContrastAqua` gives a high-contrast appearance | Script | Disproved (it returns Aqua). The real Increase Contrast setting was never turned on. |
| SwiftPM traits keep Sparkle out of the default build | `show-dependencies`, `otool -L`, bundle contents | Confirmed (Swift 6.4.2). |
| An ad hoc app with hardened runtime loads an ad hoc Sparkle.framework | Re-signed launch | Disproved: it exits 134. Ad hoc Sparkle builds drop the runtime (decision 195). |
| A configured Sparkle build with automatic checks off makes no request | Local TCP listener feed, a test key, a throwaway bundle id | Confirmed: 0 connections in 15 s. Check for Updates… was not clicked. |
| A count next to the MenuBarExtra icon renders | — | Not needed: the count is drawn into the icon bitmap. |
| Colors stay distinct for 10+ services | Palette contrast tests | By design: 10 colors, so the 11th service reuses the 1st. The name always shows beside the dot. |

## 5. Broken, untested, and decisions for you

**Blocked or partial:**
- **S-030, staying responsive under load: blocked.** At 5,000 spans/s, switching Traces | Logs hangs the main thread **95-137 ms** against the 100 ms budget (37-47 ms at rest; 109 ms in tonight's last run). With the screen unlocked, scrolling and selecting are over budget too: 107-113 ms, once 178 ms. The earlier 77-96 ms came from locked-screen runs that draw nothing. Next steps:
  - Re-measure on a quiet, unlocked Mac at 1280 × 760, comparing 6a5ce29 against HEAD.
  - Candidate fix: swap the two columns in an AppKit container (STORIES S-030, PROGRESS Blocked).
- **S-004, the live list: partial.** VoiceOver read rows as their cells. That was fixed tonight (decision 202), and the in-process check passes for both lists. The check through the Accessibility API needs the screen unlocked, and the screen was locked all night. To finish it, run this with the screen unlocked; it passes when "VoiceOver reads … once" says PASS:
  `APP_SELFTEST_ONLY=trace-list app/tools/selftest.sh` and `APP_SELFTEST_ONLY=logs app/tools/selftest.sh`

**Manual lines only you can check ([RELEASE.md](RELEASE.md) B9):**
- **S-028:** the real notification permission prompt on the first error trace, and a banner click that launches Magnife on that trace. Both were never tried by hand. They are covered only through a fake poster and the router.
- **S-032:** the icon in the Dock and in Launchpad. It was only checked as Finder's icon at 16-128 pt.

**Still open from the reviews (PROGRESS Problems), all with reasons:**
- The S-021 rename Esc self-test flake.
- gRPC has no connection `LimitListener`.
- No Settings toggle for automatic update checks. You choose 0, 1 or ask in RELEASE.md B2.
- A failing attribute-filter read is still swallowed by `try?`. The new nesting cap makes it unreachable.
- Trace Logs is still a SwiftUI `Table`.
- A 100,000-row scroll was never timed.
- The real Increase Contrast setting was not tried. Snapshots fake it.
- No `de_DE` locale snapshot.
- List badges re-read a big growing trace (M3 review 8).

**Decisions to review** (numbers are in [PROGRESS.md](PROGRESS.md) Decisions):
- **186:** "endpoint" is never written. A finding says "in <service>, under <route>", per [GLOSSARY.md](GLOSSARY.md) (Route: "Not: endpoint").
- **137:** N+1 groups by normalized statement across the whole trace, not per parent span (sibling handlers count). With decision 172, statement-only spans count too.
- **135:** Slow SQL is strictly over 100 ms, so 100.000 ms is not flagged. With decision 182, 100.4 ms reads "just over 100 ms".
- **134:** list badges show the icon alone at the default width; the word appears when the column is wide enough. With decision 171, the word is orange.
- **194, 196:** Sparkle is behind the `MAGNIFE_SPARKLE` package trait and is off by default. The updater starts only with a real HTTPS feed and key, never in test runs, and automatic checks are off.
- **195 and RELEASE.md A1:** ad hoc signing for everything built tonight. Ad hoc Sparkle builds drop the hardened runtime. Developer ID, notarization and Sparkle EdDSA keys are your steps (RELEASE.md B1-B5). No keys or certificates were created.
- **Your keychain** also holds a Developer ID certificate for another team. It was never used. Do not sign Magnife with it (RELEASE.md B1).
- **200:** the receiver also accepts Host `host.docker.internal`, for Docker Desktop.

## 6. Commits

- **History:** 72 commits from 2026-11-02 01:12 to 23:36, all SSH-signed through 1Password. Stories were committed one per commit as each passed.
  - Foundation (4e4db29 to e6966b3): schema contract, Go helper, app scaffold.
  - M1 (00c67ab to 4798991): S-001 to S-008, review fixes, an architecture refactor, end-to-end results.
  - M2 (1010219 to 17405f6): S-009 to S-022, review and end-to-end fixes.
  - M3 (a5a5656 to cc91b29): S-023 to S-032, review fixes, the detector audit (edge set, "just over", what and where).
  - M4 (b854d4b, 841b5bf, 0bf736f): install-local.sh, Sparkle behind a flag, RELEASE.md.
- **Not in history yet: checkpoints 072-079.** 1Password locked at about 00:20, with "agent returned an error" on a probe at 00:58. That covers 072-078 (the seven review-fix commits) and 079 (this summary). Each is a tree, a patch (`.night/patches/NNN.patch`) and a message in `.night/`. Unlock 1Password, then run:
  `scripts/night-checkpoint.sh --flush`
  It signs them on HEAD in order, keeps their times, and leaves the working tree alone.
- **"No signature" in `git log --show-signature`** only means git has no allowed-signers file to check SSH signatures against. With one in place, all 72 commits read `Good "git" signature for nasserfarhatt@gmail.com` (checked tonight with a temp file). To set it up once:
  `echo "nasserfarhatt@gmail.com namespaces=\"git\" $(cat ~/.ssh/personal.pub)" >> ~/.ssh/allowed_signers && git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers`

## 7. Permissions

- **Normal use needs none.** Magnife listens on 127.0.0.1 only and makes no network calls.
- **Optional:** grant Magnife.app Accessibility (System Settings > Privacy & Security > Accessibility) so the self-test's VoiceOver row check (S-004, S-013) runs instead of printing INFO … skipped. The shell running the agents already has Accessibility and Screen Recording. Captures failed only because the screen was locked.
- **Notifications:** macOS asks once, on the first trace with an error (or when you turn the setting on in Settings > Notifications). Test runs never ask; they post to a fake.

## 8. Last night's failed background tasks

Three background commands from the M2 run ended non-zero. All three were re-run by hand and pass:
- a doubled pid path,
- a SIGTERM exit 143 from the script's own `kill`,
- a System Events timeout while the screen was locked.

None was a missing permission, and nothing was left broken. See [PROGRESS.md](PROGRESS.md) Log, "Failed background tasks, reviewed 2026-11-02", and Problems, "Background tasks".
