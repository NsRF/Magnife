# Platform: macOS APIs for Magnife v0.1

Research for Magnife. Done 2026-11-02.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.

Question: which macOS APIs and practices do the menu bar, notifications, helper launch and supervision, IPC, updates and signing need, and what are their limits?
Decision it informs: how version one implements each of them (stories S-001, S-002, S-008, S-026–S-028, and release work).

## Findings

### Menu bar extra (S-026, S-027)
- `MenuBarExtra` `.menu` style becomes an NSMenu: buttons, dividers and submenus only, keyboard navigation built in. Enough for "last five errors" as plain items. [K]
- `.window` style allows rich rows, but there is no public API to open or close it from code. The third-party MenuBarExtraAccess fills that gap; its window sample broke on the macOS 27 beta. [V](https://github.com/orchetect/MenuBarExtraAccess/issues/25)
- The label ignores `.tint` and `.foregroundColor`, and template images always render monochrome. A red icon must be a non-template `NSImage` (`isTemplate = false`) passed as `Image(nsImage:)`. [V](https://zenn.dev/kyome/articles/58d89dc746e0dc)
- The label reliably renders only Text, Image or Label. Whether a count next to the icon renders is [U]; the fallback is to draw the count into the NSImage.
- Activation is stricter on purpose; DTS recommends `openWindow(id:)`. Accessory apps report windows opening behind other apps. [V](https://developer.apple.com/forums/thread/836619) Magnife is a regular Dock app, which should avoid most of this. [U]
- `openSettings` from a menu bar extra fails without a SwiftUI context on macOS 26. [V](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/)
- If a single `Window` is the primary scene, the app quits when it closes; a `WindowGroup` keeps running. [V](https://developer.apple.com/documentation/swiftui/window) Also return false from `applicationShouldTerminateAfterLastWindowClosed`. [K]

### Notifications (S-028)
- Set `UNUserNotificationCenter.delegate` before launch finishes (`applicationWillFinishLaunching`), or the notification that launched the app can be lost. [V](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/delegate)
- `didReceive` reads the trace id from `userInfo` and routes through the app model or a `magnife://trace/<id>` URL. `willPresent` must return `[.banner, .list]` or nothing shows while Magnife is frontmost. [K]
- `threadIdentifier` groups notifications; use one per service. [V](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/threadidentifier)
- There is no rate-limit API. Coalesce in the app; reusing a request identifier replaces the delivered notification. [K]
- No entitlement needed, but a stable bundle id and a real signature are. Ad-hoc dev builds may be refused authorization. [U]

### Helper launch and supervision (S-001, S-002, S-008)
| Option | Verdict |
| --- | --- |
| `Contents/Helpers/` or `Contents/MacOS/` | Both are official places for a helper tool; never `Resources`. [V](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle) |
| Foundation `Process` | Use it. The app becomes the responsible code for privacy prompts. [V](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |
| `posix_spawn` | Only for extra flags like `POSIX_SPAWN_CLOEXEC_DEFAULT`. [K] |
| `SMAppService` | Wrong fit: registers a launchd agent that needs Login Items approval and is meant to stay resident. [K] |

- macOS has no `PDEATHSIG`. kqueue `EVFILT_PROC` + `NOTE_EXIT` on the parent pid works [V, community]; simpler and crash-proof: the helper reads stdin and exits on EOF, which the kernel delivers when the app dies. [K]
- Restart from `terminationHandler` with backoff, 0.5 s doubling to 30 s, reset after 60 s stable. [K]
- Port owner: `lsof -nP -iTCP:4317 -sTCP:LISTEN` or libproc `proc_pidfdinfo`. [K] Gotcha: with `SO_REUSEADDR`, binding `127.0.0.1:4317` may succeed while another process holds `*:4317`, splitting traffic silently. [U]
- Binding only to 127.0.0.1 avoids the firewall's "accept incoming connections" prompt. [V](https://bugzilla.mozilla.org/show_bug.cgi?id=1546481) The firewall remembers decisions only for a stable signing identity. [V](https://developer.apple.com/forums/thread/743191) Local Network privacy does not apply to accepting connections. [V](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Go: older linkers emitted no `LC_UUID`, which breaks macOS privacy machinery; build with `-ldflags=-B gobuildid` or a Go version that emits it. [V](https://golang.org/issue/68678) Build arm64 and amd64, `lipo -create`, then sign. Go needs no hardened-runtime entitlements. [K]

### IPC between helper and app (S-001, S-004)
- `sun_path` is 104 bytes including the NUL; `NWEndpoint.unix` has the same limit. [V](https://developer.apple.com/forums/thread/756756) Socket goes in `$TMPDIR` or a 0700 directory; unlink before bind, and unlink and retry on a refused connect. [K]
- `notify_post` from Go needs cgo. Named XPC needs launchd registration, so it does not fit a `Process`-spawned Go helper. [K]
- Simplest: the helper writes one line per committed batch to stdout ("batch committed, trace ids…"), and the app reads the pipe. No socket file, no stale-file cleanup, and it pairs with stdin EOF for parent death. [K]

### Sparkle 2 (release work)
- SwiftUI: `SPUStandardUpdaterController(startingUpdater: true, …)` and a Check for Updates… item in `CommandGroup(after: .appInfo)`. [V](https://sparkle-project.org/documentation/programmatic-setup/)
- `generate_keys` keeps the EdDSA private key in the Keychain; `SUPublicEDKey` and an HTTPS `SUFeedURL` go in Info.plist. A non-sandboxed app needs no Sparkle XPC services. [V](https://sparkle-project.org/documentation/)
- The installer waits for the app to quit and does not kill other processes. [V](https://github.com/sparkle-project/Sparkle/discussions/2692) If the helper outlives the app, the relaunched helper cannot bind 4317/4318. [U]
- Homebrew `auto_updates true` keeps the cask out of plain `brew upgrade`. [V](https://github.com/Homebrew/homebrew-cask/issues/170994)

### Signing and notarization (release work)
- Sign inside-out, never `--deep` (deprecated for signing since macOS 13). [V](https://developer.apple.com/forums/thread/15433) Every Mach-O, including the Go helper and Sparkle's Autoupdate and Updater.app, needs `--options runtime --timestamp`. [V](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- Old Go notarization failures (`LC_BUILD_VERSION` SDK values) are fixed in the linker. [V](https://golang.org/issue/30488)
- `notarytool submit --key --key-id --issuer --wait` needs a Team API key; Individual keys cannot notarize. [V](https://developer.apple.com/forums/thread/768634) Staple the .app, put it in the DMG, notarize and staple the DMG. [K]
- Homebrew quarantines cask downloads, `--no-quarantine` was removed, and casks failing Gatekeeper are being disabled from September 2026. [V](https://github.com/Homebrew/brew/issues/20755) Notarization is mandatory for the cask.

## Decisions
1. Launch the helper with `Process` from `Contents/Helpers/`, because the app becomes the responsible code and no Login Items approval is needed. [V] TN3179.
2. Helper exits on stdin EOF, because it covers app crashes with no extra machinery. Planned test: `kill -9` the app, check with `pgrep` that the helper is gone within 1 second (self-test for S-008).
3. Signal new data with line-delimited events on the helper's stdout instead of a Unix socket in v0.1, because it removes the socket path limit and stale socket files. Accepted 2026-11-02; brief and S-001 updated. Planned test: 5,000 spans/s for 60 s with no dropped events (S-030).
4. Bind only `127.0.0.1:4317` and `127.0.0.1:4318`, because that avoids the firewall prompt. [V] Mozilla bug 1546481.
5. Before starting the helper, check both ports with `lsof`/libproc and name the owner in the S-001 banner. Planned test: run `otelcol` on `*:4317`, start Magnife, expect the busy-port banner rather than a silent split.
6. Stop the helper in `applicationWillTerminate` and wait for it to exit, because Sparkle relaunches would otherwise collide on the ports. [V] Sparkle discussion 2692.
7. Main scene is a `WindowGroup` plus `applicationShouldTerminateAfterLastWindowClosed` returning false, because a single `Window` quits the app on close. [V] Apple docs.
8. Menu bar uses `.menu` style with a non-template NSImage for the red state, because `.window` cannot be controlled from code and template images ignore tint. [V] MenuBarExtraAccess #25, Kyome.
9. Notification delegate set in `applicationWillFinishLaunching`; authorization asked on the first error trace; `threadIdentifier` per service; coalescing in the app. [V] Apple docs.
10. Build Go with `-B gobuildid`, lipo into a universal binary, sign every Mach-O inside-out with hardened runtime and timestamp, notarize with a Team API key. [V] golang #68678, Apple notarization docs.

## Open questions
- Does a Text + Image label render a count in `MenuBarExtra` on macOS 26? Test in a snapshot of 08-menu-bar; fall back to drawing the count into the image.
- Does `SO_REUSEADDR` let the helper bind 127.0.0.1 while another collector holds `*:4317`? Test with Docker `otel/opentelemetry-collector` running.
- Do notification authorization requests work from a development-signed (not ad-hoc) build? Test on first run of S-028.
- Does the helper always exit before Sparkle swaps the bundle? Test with a local appcast before the first public release.
