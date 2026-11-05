## What and why

<!-- What this changes, and the problem it solves. Link the issue: "Closes #123". -->

## How it was checked

- [ ] `cd ingest && go vet ./... && go test ./...`
- [ ] `cd app && swift test`
- [ ] `app/tools/selftest.sh` (or `APP_SELFTEST_ONLY=<area>` for the area you changed)
- [ ] UI changes: `app/tools/snap.sh`, and I looked at the light and dark pages I changed (screenshots below)

## Rules this respects

- [ ] The app stays read-only: only the Go helper writes the database.
- [ ] A change to `docs/schema.sql` updates both sides, the helper's copy and `PRAGMA user_version`.
- [ ] Words follow `docs/GLOSSARY.md`, and every new action has a menu item and a shortcut in `docs/ux.md`.

## Screenshots

<!-- For UI changes: before and after, light and dark. -->
