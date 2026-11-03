# Magnife release checklist

From an ad hoc local build to a notarized, auto-updating download with a
Homebrew cask, as docs/MVP.md ("Distribuição, preço e licenciamento") plans
it: Developer ID plus notarization, Sparkle updates, a cask from day one,
distribution outside the Mac App Store.

The checklist has two parts:

- **Part A, works now** (no Apple account, no certificate, no keys, no
  money): ad hoc local installs, the Sparkle build behind its flag, and the
  test pass. Everything in Part A was run on 2026-11-02 (docs/PROGRESS.md, Log, "M4").
- **Part B, needs the owner**: every step marked **[owner]** needs the Apple
  Developer Program, a Developer ID certificate, an App Store Connect API key,
  Sparkle's EdDSA key pair, a host, or a payment provider. None of it has
  been run. No key, certificate or account was created for this checklist.

Placeholders: `<TEAM_ID>` (10 characters), `<DEV_ID_NAME>` (the name on the
certificate), `<KEY_ID>` / `<ISSUER_ID>` (App Store Connect API key),
`<HOST>` (where the appcast and downloads live), `<GH_USER>`, `<VERSION>`
(for example `0.1.0`), `<BUILD>` (CFBundleVersion).

## Facts this checklist relies on

- Bundle id `com.nasserfarhat.magnife` (`app/Info.plist.in`, docs/BRIEF.md);
  the helper's signing identifier `com.nasserfarhat.magnife.ingest`. Minimum macOS 26.
- `CFBundleShortVersionString` is hard-coded `0.1`; `CFBundleVersion` is
  `__BUILD__`, replaced with `date +%Y%m%d%H%M` by both build scripts.
- The app binary is built for the host architecture only; `ingest/build.sh`
  makes a universal helper (arm64 + x86_64, each slice with an LC_UUID).
- Magnife is not sandboxed and needs no entitlements; the helper listens on
  127.0.0.1 only. Its database is `~/Library/Application Support/Magnife/magnife.sqlite`.
- Sparkle 2 is the SwiftPM package trait `Sparkle`, pinned to exactly
  **2.10.1** (`app/Package.swift`; `Package.resolved` revision
  `ab7d71291238df6e0492143b120c9b696a35f603`). Off by default.

---

# Part A — works now (unsigned / ad hoc)

## A1. Local install, ad hoc

```sh
scripts/install-local.sh                      # ~/Applications/Magnife.app
scripts/install-local.sh --dest /tmp/x        # anywhere else (or INSTALL_DIR=...)
scripts/install-local.sh --open               # launch it afterwards
scripts/install-local.sh --no-quit            # refuse instead of quitting a copy running from <dest>
```

- [ ] Builds the helper (`ingest/build.sh`; a failure stops the install) and the
      app (release, scratch `~/Library/Developer/Magnife/install-local`).
- [ ] Signs inside out, ad hoc, never with a keychain identity: the helper as
      `com.nasserfarhat.magnife.ingest`, then the app as
      `com.nasserfarhat.magnife`, both with the hardened runtime.
- [ ] Quits only the Magnife running from `<dest>` (a quit request to that pid,
      so the helper stops and frees its ports; SIGTERM after 10 s), then swaps
      the bundle. A Magnife running from another folder is left alone.
- [ ] Check:

```sh
codesign --verify --deep --strict ~/Applications/Magnife.app
codesign -dv ~/Applications/Magnife.app/Contents/Helpers/magnife-ingest 2>&1 | grep -E "Identifier|flags"
#   Identifier=com.nasserfarhat.magnife.ingest, flags=0x10002(adhoc,runtime)
```

Limits of an ad hoc build: Gatekeeper rejects it on any other Mac once it is
quarantined (downloaded, AirDropped); each rebuild is a new code identity to
TCC, so the notification permission may be asked again, and macOS may refuse
it to ad hoc builds. `app/build.sh` is the day-to-day build: it signs with an
Apple Development identity when the keychain has one, ad hoc otherwise.

## A2. Sparkle behind its flag

| Build | Sparkle | Info.plist | Menu |
| --- | --- | --- | --- |
| `./build.sh`, `scripts/install-local.sh` (default) | not fetched as a binary, not compiled, not linked | no `SU*` keys | no Check for Updates… |
| `MAGNIFE_SPARKLE=1 ./build.sh` / `MAGNIFE_SPARKLE=1 scripts/install-local.sh` | `Contents/Frameworks/Sparkle.framework` (2.9 MB) | `SUFeedURL`, `SUPublicEDKey` (placeholders), `SUEnableAutomaticChecks` false | Magnife > Check for Updates…, disabled |
| the same with `SPARKLE_FEED_URL=https://… SPARKLE_PUBLIC_ED_KEY=<base64>` | as above | the real values | enabled; checks only when chosen |

- Default builds: SwiftPM prunes the trait-only dependency. With the Sparkle
  pin in `Package.resolved`, a fresh resolve still makes a source checkout of
  the Sparkle repo (package-registry traffic only) but never downloads the
  10 MB binary artifact; `otool -L` shows no Sparkle.
- Placeholders: `__SPARKLE_FEED_URL__` and `__SPARKLE_PUBLIC_ED_KEY__`
  (`app/tools/sparkle-bundle.sh`). With either still a placeholder,
  `UpdaterController` never starts Sparkle (`UpdateConfiguration.isConfigured`:
  an HTTPS feed with a host and a base64 key of 32 bytes), so the app makes no
  request and shows no "can't check for updates" alert.
- With a real feed and key Sparkle starts, but `SUEnableAutomaticChecks` is
  false: no check at launch, no "check automatically?" question on the second
  launch. The only request is the one Check for Updates… makes.
- Sparkle never starts in snapshot or self-test runs (it keeps its state in
  the app's own defaults domain).
- Ad hoc only: the app is signed **without** the hardened runtime when
  Sparkle is in it, because library validation refuses to load an ad hoc
  framework into an ad hoc app ("different Team IDs"). Signed with an Apple
  Development or Developer ID certificate, the framework is re-signed with
  the same team and the runtime stays on (checked with Apple Development).
- Sparkle's tools come with its SwiftPM artifact, after any trait build:
  `~/Library/Developer/Magnife/build/artifacts/sparkle/Sparkle/bin/`
  (`generate_keys`, `generate_appcast`, `sign_update`, `BinaryDelta`).
  **Do not run `generate_keys` until B5**; it writes into the login keychain.

## A3. Test pass (run on every release candidate)

Never against the real database in `~/Library/Application Support/Magnife/`
(app/CLAUDE.md). Use `mktemp -d` paths and ports 127.0.0.1:0 or 47xxx.

- [ ] Helper: `cd ingest && go test -race ./...`
- [ ] App unit tests: `cd app && swift test --scratch-path ~/Library/Developer/Magnife/test-build`
- [ ] `app/build.sh`, then `app/tools/selftest.sh` exits 0 (receiver checks with
      the bundled helper; S-008 lifecycle: quit, crash restart, `kill -9`).
      `APP_SELFTEST_ONLY=updates app/tools/selftest.sh` checks the update menu.
- [ ] `MAGNIFE_SPARKLE=1 app/build.sh`, then `APP_SELFTEST_ONLY=updates app/tools/selftest.sh`
      (Check for Updates… after About Magnife, disabled, no shortcut;
      automatic checks off); then `app/build.sh` again to go back.
- [ ] Snapshots and grid: `app/tools/snap.sh`, `app/tools/grid-lint.sh`,
      `swift app/tools/check-layout.swift /tmp/Magnife-shots/*-layout.json`;
      look at the light and dark PNGs.
- [ ] SDK interop: `scripts/interop/run-all.sh` (gRPC 34317, HTTP 34318).
- [ ] An installed copy end to end (`scripts/install-local.sh --dest "$(mktemp -d)"`):

```sh
T=$(mktemp -d /tmp/magnife-e2e.XXXXXX); APP=<dest>/Magnife.app
codesign --verify --deep --strict "$APP"
APP_STORE=$T/store.sqlite APP_GRPC_PORT=47317 APP_HTTP_PORT=47318 "$APP/Contents/MacOS/Magnife" &
lsof -nP -iTCP:47317 -iTCP:47318 -sTCP:LISTEN      # the helper, 127.0.0.1 only
scripts/send-sample-traces --grpc 127.0.0.1:47317 --http 127.0.0.1:47318
sqlite3 "file:$T/store.sqlite?mode=ro" "select count(distinct trace_id), count(*) from spans"   # 5 traces
# Quit it (⌘Q, or a quit request to its pid), then:
pgrep -lf "$APP"                                   # nothing
lsof -nP -iTCP:47317 -iTCP:47318 -sTCP:LISTEN      # nothing
```

- [ ] Sparkle build, no network at launch: `lsof -nP -a -p <app pid> -i` stays
      empty for 10 s after launch (only the helper has sockets). With a feed
      pointing at a local TCP listener and a well-formed test key, under a
      throwaway bundle id so Sparkle's defaults never reach
      `com.nasserfarhat.magnife`: Sparkle starts (`SUHasLaunchedBefore`) and the
      listener sees no connection.

---

# Part B — needs the owner

## B1. Apple Developer account and certificate **[owner]**

- [ ] Apple Developer Program membership (paid, yearly). Note the Team ID:
      developer.apple.com > Account > Membership details.
- [ ] Create a **Developer ID Application** certificate (only the Account
      Holder can): Xcode > Settings > Accounts > the team > Manage
      Certificates… > + > Developer ID Application, or a CSR from Keychain
      Access at developer.apple.com > Certificates.
- [ ] Back up the certificate and its private key (Keychain Access > export
      .p12) into the password manager.
- [ ] Check it is usable, and that it is the right team (the keychain may hold
      Developer ID certificates of other teams; never sign Magnife with those):

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
export DEV_ID="Developer ID Application: <DEV_ID_NAME> (<TEAM_ID>)"
```

- [ ] A Developer ID Installer certificate is only for .pkg installers; Magnife
      ships a .dmg and a .zip, so skip it.

## B2. Versioning **[owner: decide]**

- [ ] Pick `<VERSION>` (semver, `0.1.0` for the first public build). Change
      `CFBundleShortVersionString` in `app/Info.plist.in`, or make it a
      `__VERSION__` placeholder that the build scripts fill like `__BUILD__`.
- [ ] `CFBundleVersion` must only grow: Sparkle compares it (`sparkle:version`).
      The `yyyymmddHHMM` stamp works while release machines keep a correct
      clock. Record each release's value:
      `plutil -extract CFBundleVersion raw Magnife.app/Contents/Info.plist`.
- [ ] Release notes for the version (`Magnife-<VERSION>.html`, used by B6).
- [ ] Tag the release commit: `git tag -s v<VERSION>` (signed through 1Password).

## B3. Release build and signing **[owner: certificate]**

Requirements notarization checks:

- [ ] **Hardened runtime and a secure timestamp on every Mach-O**
      (`--options runtime --timestamp`, not the scripts' `--timestamp=none`):
      the helper, Sparkle's `Installer.xpc`, `Downloader.xpc`, `Autoupdate`,
      `Updater.app`, `Sparkle.framework`, then the app.
- [ ] **No entitlements** for the app or the helper. Only Sparkle's
      `Downloader.xpc` keeps its own (`--preserve-metadata=entitlements`).
      Never ship `com.apple.security.get-task-allow` or
      `com.apple.security.cs.disable-library-validation`.
- [ ] Helper identifier `com.nasserfarhat.magnife.ingest` (install-local.sh
      already uses it; `app/build.sh` still takes codesign's default,
      `magnife-ingest`). The file and process name stay `magnife-ingest`.
- [ ] **Universal app binary** (the helper already is):
      `swift build -c release --arch arm64 --arch x86_64` (with the Sparkle
      trait flags); the binary is at
      `$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Magnife`.
      Decide whether Intel Macs on macOS 26 are supported **[owner]**; if not,
      ship arm64 only and add `depends_on arch: :arm64` to the cask.
- [ ] Build with the real feed and key (B5, B7) and fail when either is
      missing, or the release ships a disabled Check for Updates…:

```sh
export SPARKLE_FEED_URL=https://<HOST>/appcast.xml SPARKLE_PUBLIC_ED_KEY=<base64 from B5>
MAGNIFE_SPARKLE=1 SIGN_IDENTITY=- app/build.sh   # assemble; signatures are replaced below
APP=~/Library/Developer/Magnife/release/Magnife.app
rm -rf "$APP" && mkdir -p "${APP:h}" && ditto ~/Applications/Magnife.app "$APP"
plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist"   # must not be __SPARKLE_PUBLIC_ED_KEY__

# Inside out, never --deep.
codesign --force --options runtime --timestamp --sign "$DEV_ID" \
  --identifier com.nasserfarhat.magnife.ingest "$APP/Contents/Helpers/magnife-ingest"
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$DEV_ID" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$FW/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$FW/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$FW"
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"

codesign --verify --strict --deep --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Timestamp|flags"
#   Authority=Developer ID Application: …, TeamIdentifier=<TEAM_ID>, flags=0x10000(runtime), a Timestamp= line
codesign -d --entitlements - "$APP"          # expect none
```

- [ ] Build in `~/Library/Developer/Magnife/…`, never in a Dropbox or iCloud
      folder (extended attributes break signatures).

## B4. Notarization and stapling **[owner: API key]**

- [ ] Create a **Team** App Store Connect API key (Users and Access >
      Integrations > App Store Connect API > Team Keys; role Developer or
      above); an Individual key cannot notarize. Download `AuthKey_<KEY_ID>.p8`
      once and keep it in the password manager.
- [ ] Store the credentials in the keychain once:

```sh
xcrun notarytool store-credentials magnife-notary \
  --key ~/secure/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

- [ ] Notarize and staple the app:

```sh
cd ~/Library/Developer/Magnife/release
ditto -c -k --sequesterRsrc --keepParent Magnife.app Magnife-notarize.zip
xcrun notarytool submit Magnife-notarize.zip --keychain-profile magnife-notary --wait
# On "Invalid": xcrun notarytool log <SUBMISSION_ID> --keychain-profile magnife-notary
xcrun stapler staple Magnife.app && xcrun stapler validate Magnife.app
spctl --assess --type execute -vv Magnife.app      # accepted, source=Notarized Developer ID
rm Magnife-notarize.zip                            # has no ticket; never ship it
```

## B5. Sparkle EdDSA keys **[owner, once]**

```sh
SPARKLE_BIN=~/Library/Developer/Magnife/build/artifacts/sparkle/Sparkle/bin
"$SPARKLE_BIN/generate_keys"        # key pair in the login keychain; prints the public key
"$SPARKLE_BIN/generate_keys" -p     # prints the public key again
"$SPARKLE_BIN/generate_keys" -x ~/secure/magnife-sparkle-private.key   # backup export
```

- [ ] Public key -> `SPARKLE_PUBLIC_ED_KEY` (Info.plist `SUPublicEDKey`). It is
      public; it may go in a release script.
- [ ] Private key -> password manager, then delete the exported file. **Losing
      it means no signed update reaches existing installs.** Never commit it;
      never print it in CI logs.

## B6. Packaging and appcast **[owner: certificate]**

```sh
V=<VERSION>
rm -rf dmg && mkdir dmg && ditto Magnife.app dmg/Magnife.app && ln -s /Applications dmg/Applications
hdiutil create -volname "Magnife" -srcfolder dmg -ov -format UDZO "Magnife-$V.dmg"
codesign --force --timestamp --sign "$DEV_ID" "Magnife-$V.dmg"
xcrun notarytool submit "Magnife-$V.dmg" --keychain-profile magnife-notary --wait
xcrun stapler staple "Magnife-$V.dmg"
spctl --assess --type open --context context:primary-signature -vv "Magnife-$V.dmg"
ditto -c -k --sequesterRsrc --keepParent Magnife.app "Magnife-$V.zip"    # for Sparkle
shasum -a 256 "Magnife-$V.dmg" "Magnife-$V.zip"

mkdir -p ~/MagnifeReleases && cp "Magnife-$V.zip" "Magnife-$V.html" ~/MagnifeReleases/
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://<HOST>/releases/" \
  --link "https://<HOST>/" ~/MagnifeReleases
```

- [ ] Keep every past archive in `~/MagnifeReleases` (deltas come from them).
- [ ] The new item's `sparkle:version` is greater than the last release's;
      `sparkle:minimumSystemVersion` is 26.0; it has an `edSignature`.

## B7. Hosting **[owner]**

- [ ] Choose `<HOST>` (MVP open decision: domain, handles, a USPTO search for
      "Magnife"). HTTPS is required (Sparkle and `UpdateConfiguration`), with
      stable URLs and a correct `Content-Length`: GitHub Releases + Pages,
      S3/CloudFront, or Cloudflare R2. The feed URL is baked into every build.
- [ ] Upload the DMG, the zip and the notes, then `appcast.xml` last.
- [ ] `curl -sI https://<HOST>/appcast.xml` and each archive URL: 200, HTTPS.

## B8. Homebrew cask **[owner: GitHub repo]**

Start with an own tap; notarization is mandatory either way (Homebrew
quarantines downloads). `Casks/magnife.rb` in `<GH_USER>/homebrew-tap`:

```ruby
cask "magnife" do
  version "<VERSION>"
  sha256 "<SHA256_OF_DMG>"

  url "https://<HOST>/releases/Magnife-#{version}.dmg"
  name "Magnife"
  desc "Native viewer for local OpenTelemetry traces and logs"
  homepage "https://<HOST>/"

  livecheck do
    url "https://<HOST>/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Magnife.app"

  zap trash: [
    "~/Library/Application Support/Magnife",
    "~/Library/Caches/com.nasserfarhat.magnife",
    "~/Library/HTTPStorages/com.nasserfarhat.magnife",
    "~/Library/Preferences/com.nasserfarhat.magnife.plist",
    "~/Library/Saved Application State/com.nasserfarhat.magnife.savedState",
  ]
end
```

```sh
brew tap <GH_USER>/tap
brew style --fix Casks/magnife.rb
brew audit --cask --online <GH_USER>/tap/magnife
brew install --cask <GH_USER>/tap/magnife
brew uninstall --cask --zap magnife
```

- [ ] Each release: bump `version` and `sha256`.
- [ ] Unverified: the `depends_on macos:` symbol for macOS 26 in the Homebrew
      you run (`:tahoe`); `brew audit` says.

## B9. Release-candidate tests that need B1 to B7 **[owner]**

- [ ] Part A's test pass (A3) on the Developer-ID-signed build.
- [ ] The **notarized DMG**, downloaded (so it is quarantined), on a clean
      user account or a second Mac: opens with only the "downloaded from the
      Internet" prompt; `spctl -a -vv` accepted; receiver on 127.0.0.1:4317 and
      4318 only; `scripts/send-sample-traces` shows 5 traces and 3 services in
      under 60 s from the first launch (MVP goal); quit frees both ports and
      leaves no `magnife-ingest`; a busy port shows the busy-port banner.
- [ ] Notifications (S-028, still untested by hand): the permission prompt on
      the first error trace, and a banner click that opens the trace.
- [ ] **Local appcast test** (docs/research/platform.md open question: does the
      helper exit before Sparkle swaps the bundle?). Build version A with a
      test feed; publish version B (higher CFBundleVersion); in A, Magnife >
      Check for Updates… > Install and Relaunch. Pass when B relaunches,
      exactly one `magnife-ingest` runs and holds both ports, stored traces are
      still there, and `codesign --verify --strict --deep` passes on the new bundle.
- [ ] `brew install --cask <GH_USER>/tap/magnife` on a clean machine opens the app.

## B10. Payment and licensing **[owner]**

From docs/MVP.md (hypotheses to validate with the first users; nothing is
built, and nothing above depends on it):

- [ ] Merchant of record: Paddle or Lemon Squeezy (they handle sales tax and
      issue the licence). Account, products, payout details.
- [ ] One-time licence (US$ 49 to 79 with a year of updates) or subscription
      (US$ 6 to 8 per month): open decision in MVP.md.
- [ ] Free vs Pro (MVP hypothesis: Free = traces and logs, 1 hour retention,
      2 services; Pro = configurable retention, unlimited services, detectors,
      saved filters, menu bar).
- [ ] Licence check: offline-verifiable signed keys fit an app that makes no
      other network calls; online activation adds a request the privacy
      statement must disclose.
- [ ] Legal pages (EULA, privacy policy, refunds) before going live.

## B11. Launch-day order **[owner]**

1. A3 and B9 green on the candidate.
2. Sign (B3), notarize and staple the app (B4), DMG and zip, notarize and
   staple the DMG, appcast (B6).
3. Upload the archives and notes, then the appcast (B7).
4. Cask commit with the new `sha256` (B8).
5. `git tag -s v<VERSION>` and push the tag.
6. Download the public DMG on a clean machine and open it once more.
