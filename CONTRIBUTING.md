# Contributing to Magnife

Thanks for taking a look. Magnife is small on purpose, and a few rules keep it fast and correct.

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md). Found a security problem? Please report it privately, as [SECURITY.md](SECURITY.md) explains, not in an issue. Questions are welcome in [Discussions](https://github.com/NsRF/Magnife/discussions).

## Set up

- macOS 26 or later, Xcode 27 (Swift 6.4), Go 1.27 (`brew install go`).
- `app/build.sh --open` builds the Go helper and the app, installs `~/Applications/Magnife.app` and opens it.
- `scripts/send-sample-traces` sends the seed set (5 traces, 3 services) to a running Magnife.

If `swift` reports `plugin for module 'SwiftUIMacros' not found`, `xcode-select` points at the Command Line Tools. The build scripts switch to Xcode by themselves. For a bare `swift test`, prefix it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Before you open a pull request

```sh
cd ingest && go vet ./... && go test ./...      # the helper
cd app && swift test                            # MagnifeKit unit tests
app/tools/selftest.sh                           # the in-app end-to-end checks (APP_SELFTEST_ONLY=<area> for one area)
```

`app/tools/snap.sh` takes a screenshot of every page in light and dark mode. Look at the pages you changed.

## Rules the code depends on

- **One writer.** Only the Go helper writes the database. The app opens it read-only and never migrates or checkpoints it. Even File > Import Traces… asks the helper to do the writing.
- **One contract.** [`docs/schema.sql`](docs/schema.sql) defines the tables, the JSON columns and the helper's stdin/stdout protocol. A change updates both sides in the same commit and bumps `PRAGMA user_version`. `ingest/internal/store/schema.sql` must stay a byte-identical copy.
- **Nothing on the main thread that can wait.** Every database read is a `@concurrent` method on `TelemetryReader`. The live lists are AppKit tables, because SwiftUI's `Table` could not keep up at 5,000 spans/s.
- **Words.** UI text follows [`docs/GLOSSARY.md`](docs/GLOSSARY.md) and [`docs/ux.md`](docs/ux.md). Say "route", never "endpoint". The keyboard self-test checks that every action in `docs/ux.md` has its menu item and shortcut.
- **Commits.** Conventional Commits (`feat(app): …`, `fix(ingest): …`), with the story id when there is one (`S-033`).

More detail for working in the app is in [`app/CLAUDE.md`](app/CLAUDE.md). The helper is described in [`ingest/README.md`](ingest/README.md).
