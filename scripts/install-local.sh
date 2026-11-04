#!/bin/zsh
# install-local.sh: build Magnife and its Go helper, sign them ad hoc, and
# install Magnife.app for use on THIS Mac. No certificate, no Apple account,
# no network beyond what `swift build` / `go build` need to fetch packages.
#
# What it does, in order:
#   1. Builds the helper with ingest/build.sh (universal arm64 + x86_64, with
#      LC_UUIDs), or takes a prebuilt one from HELPER_BIN.
#   2. Builds the app with `swift build -c release` (host architecture only).
#   3. Assembles Magnife.app in a staging folder:
#        Contents/MacOS/Magnife             the SwiftPM executable
#        Contents/Helpers/magnife-ingest    the helper (HelperConfiguration looks here)
#        Contents/Info.plist                app/Info.plist.in, __BUILD__ = yyyymmddHHMM
#        Contents/Resources/Assets.car, AppIcon.icns   copied from app/Resources
#   4. Signs inside out, ad hoc (`codesign -s -`), never --deep: the helper
#      first (identifier <bundle id>.ingest), then the app around it. Both
#      get the hardened runtime, like app/build.sh. Verifies the result.
#   5. Quits the copy running from <dest>/Magnife.app, if any (a polite quit,
#      so the app stops its helper and frees its ports; SIGTERM after 10 s),
#      then replaces <dest>/Magnife.app (and registers it with Launch Services
#      when <dest> is an Applications folder).
#      A Magnife running from anywhere else is left alone.
#   6. Prints how to launch it (or launches it with --open).
#
# How it differs from app/build.sh (which it is modelled on):
#   - Always ad hoc. build.sh picks an "Apple Development" identity when the
#     keychain has one; this script never looks at the keychain.
#   - A helper build failure is fatal. build.sh installs an app without a
#     helper (which then shows Not receiving); a local install should not.
#   - It assembles and verifies in a staging folder, and only then quits the
#     running copy and swaps the bundle. build.sh deletes the installed app
#     before it starts copying.
#   - Its own SwiftPM scratch path (~/Library/Developer/Magnife/install-local),
#     so it never fights a concurrent build.sh or test run over the same
#     .build lock.
#   - It never runs tools/make_icon.sh (which writes app/Resources/ in the
#     repo); it copies the compiled icon that is there and warns when it is
#     older than app/Icon/AppIcon.icon. Run app/build.sh once to refresh it.
#   - The helper's signing identifier is reverse-DNS (com.nasserfarhat.magnife.ingest)
#     instead of codesign's default from the file name (magnife-ingest), the
#     identifier a Developer ID release should use (docs/RELEASE.md).
#   - Destination overridable (--dest or INSTALL_DIR); quits the old copy
#     by default (build.sh only does that with --open).
#
# Limits of an ad hoc build (fine for your own Mac, not for distribution):
#   - Gatekeeper rejects it on any other Mac once it carries a quarantine
#     attribute (downloaded, AirDropped). Use the Developer ID flow in docs/RELEASE.md.
#   - The ad hoc designated requirement is the code hash, so each rebuild is a
#     new identity to TCC: notification permission may be asked again, and
#     macOS may refuse it to ad hoc builds (docs/research/platform.md).
#   - Switching between this and a build.sh install signed with an Apple
#     Development certificate also changes identity (same caveat).
#   - The app binary is host architecture only; the helper is universal.
#
# Usage:
#   scripts/install-local.sh                       release build into ~/Applications
#   scripts/install-local.sh --dest /Applications  another destination (or INSTALL_DIR=...)
#   scripts/install-local.sh --debug               debug configuration
#   scripts/install-local.sh --open                launch it after installing
#   scripts/install-local.sh --no-quit             never quit a running Magnife; stops
#                                                  with an error if one runs from <dest>
# Environment:
#   MAGNIFE_REPO   repo root (default: the folder above this script)
#   INSTALL_DIR    destination folder (default ~/Applications)
#   BUILD_DIR      SwiftPM scratch + staging (default ~/Library/Developer/Magnife/install-local);
#                  one run at a time per BUILD_DIR (a lock on BUILD_DIR/.lock)
#   HELPER_BIN     use this prebuilt magnife-ingest instead of running ingest/build.sh
#   MAGNIFE_SPARKLE=1   with Sparkle 2 and Magnife > Check for Updates… (off by default;
#                  SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY, SPARKLE_AUTOMATIC_CHECKS as in app/build.sh). Ad hoc,
#                  the app is then signed without the hardened runtime: library
#                  validation refuses an ad hoc framework in an ad hoc app.
set -euo pipefail

name="Magnife"
# One install at a time per build folder: two runs at once shared the SwiftPM
# scratch and the staging folder. The whole run, build through install,
# holds a lock on <BUILD_DIR>/.lock; a second run waits for it.
build_dir="${BUILD_DIR:-$HOME/Library/Developer/$name/install-local}"
if [[ -z "${MAGNIFE_INSTALL_LOCKED:-}" ]]; then
  mkdir -p "$build_dir"
  MAGNIFE_INSTALL_LOCKED=1 exec lockf -k "$build_dir/.lock" "$0" "$@"
fi
config=release
dest="${INSTALL_DIR:-$HOME/Applications}"
open_after=0
quit_running=1
while (( $# )); do
  case "$1" in
    --debug)   config=debug ;;
    --open)    open_after=1 ;;
    --no-quit) quit_running=0 ;;
    --dest)    shift; dest="${1:?--dest needs a folder}" ;;
    --dest=*)  dest="${1#--dest=}" ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# The repo: MAGNIFE_REPO, else the folder this script's folder sits in.
repo="${MAGNIFE_REPO:-${0:A:h:h}}"
appsrc="$repo/app"
ingest="$repo/ingest"
[[ -f "$appsrc/Package.swift" && -f "$appsrc/Info.plist.in" ]] || { echo "error: no Magnife app package in $appsrc (set MAGNIFE_REPO)" >&2; exit 1; }

scratch="$build_dir/swiftpm"
bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$appsrc/Info.plist.in")
[[ -n "$bundle_id" ]] || { echo "error: no CFBundleIdentifier in $appsrc/Info.plist.in" >&2; exit 1; }
mkdir -p "$build_dir" "$dest"
dest="${dest:A}"
app="$dest/$name.app"

step() { print -P "%B==>%b $*"; }
# Sparkle is a package trait: off, it is not fetched as a binary, not compiled,
# not linked (a resolve may still check out its source; docs/RELEASE.md A2).
sparkle=${MAGNIFE_SPARKLE:-0}
swift_flags=()
if [[ $sparkle == 1 ]]; then
  swift_flags=(--traits Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

# 1. The helper ------------------------------------------------------------
if [[ -n "${HELPER_BIN:-}" ]]; then
  step "Using prebuilt helper $HELPER_BIN"
  helper_src="$HELPER_BIN"
else
  step "Building the helper (ingest/build.sh)"
  [[ -x "$ingest/build.sh" ]] || { echo "error: $ingest/build.sh not found or not executable" >&2; exit 1; }
  command -v go >/dev/null || { echo "error: Go is not installed (brew install go), or pass HELPER_BIN=<magnife-ingest>" >&2; exit 1; }
  "$ingest/build.sh"
  helper_src="$ingest/bin/magnife-ingest"
fi
[[ -x "$helper_src" ]] || { echo "error: helper $helper_src is missing or not executable" >&2; exit 1; }
lipo -info "$helper_src"

# 2. The app ---------------------------------------------------------------
step "Building $name ($config)"
swift build -c $config --package-path "$appsrc" --scratch-path "$scratch" "${swift_flags[@]}" 2>&1 \
  | grep -E "error|warning:|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "error: build failed (no $bin)" >&2; exit 1; }
# swift build can report success while an edited file failed to compile (app/build.sh).
stale=$(find "$appsrc/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "error: build failed: binary is older than $stale" >&2
  swift build -c $config --package-path "$appsrc" --scratch-path "$scratch" "${swift_flags[@]}" 2>&1 | grep -E "error" | head -20 >&2
  exit 1
fi

# 3. Assemble in staging ---------------------------------------------------
step "Assembling $name.app"
# A staging folder of this run's own, removed however the run ends.
stage=$(mktemp -d "$build_dir/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
staged="$stage/$name.app"
mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Helpers" "$staged/Contents/Resources"
cp "$bin" "$staged/Contents/MacOS/$name"
cp "$helper_src" "$staged/Contents/Helpers/magnife-ingest"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$appsrc/Info.plist.in" > "$staged/Contents/Info.plist"
if [[ $sparkle == 1 ]]; then
  "$appsrc/tools/sparkle-bundle.sh" "$scratch/$config/Sparkle.framework" "$staged"
fi
plutil -lint -s "$staged/Contents/Info.plist"
car="$appsrc/Resources/Assets.car"
icns="$appsrc/Resources/AppIcon.icns"
if [[ -f "$car" && -f "$icns" ]]; then
  cp -X "$car" "$icns" "$staged/Contents/Resources/"
  if [[ -d "$appsrc/Icon/AppIcon.icon" && -n "$(find "$appsrc/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    echo "warning: app/Resources/Assets.car is older than app/Icon/AppIcon.icon; run app/build.sh (or app/tools/make_icon.sh) to refresh the icon"
  fi
else
  echo "warning: no compiled icon in app/Resources; the app gets the generic icon (run app/build.sh once)"
fi
# Finder info and quarantine attributes break signatures ("resource fork,
# Finder information, or similar detritus not allowed").
xattr -cr "$staged"

# 4. Sign inside out, ad hoc ----------------------------------------------
step "Signing ad hoc (helper, then app)"
sign() { codesign --force --options runtime --timestamp=none --sign - "$@" 2>&1 | grep -v "replacing existing signature" || true; }
sign --identifier "$bundle_id.ingest" "$staged/Contents/Helpers/magnife-ingest"
if [[ $sparkle == 1 ]]; then
  "$appsrc/tools/sparkle-bundle.sh" --sign - "$staged"
  codesign --force --timestamp=none --sign - "$staged" 2>&1 | grep -v "replacing existing signature" || true
else
  sign "$staged"
fi
codesign --verify --strict "$staged/Contents/Helpers/magnife-ingest" || { echo "error: helper signature check failed" >&2; exit 1; }
codesign --verify --strict --deep "$staged" || { echo "error: app signature check failed" >&2; exit 1; }
codesign -dv "$staged/Contents/Helpers/magnife-ingest" 2>&1 | grep -E "^Identifier=|flags=" | sed 's/^/    helper: /'
codesign -dv "$staged" 2>&1 | grep -E "^Identifier=|flags=" | sed 's/^/    app:    /'

# 5. Quit the copy being replaced, then swap -------------------------------
# Only processes whose executable is this destination's copy: a Magnife
# running from another folder is someone else's and keeps running.
# Executables are compared with symlinks resolved (/tmp is /private/tmp).
# The path comes from the process's mapped executable (lsof's txt entry),
# not `ps -o comm=`: a copy started with a relative path reports that path,
# which resolved against this shell's folder names the wrong file, and the
# swap below then replaced the bundle under the live process.
running_pids() {
  local pid exe
  for pid in $(pgrep -x "$1" 2>/dev/null); do
    exe=$(lsof -a -p $pid -d txt -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}') || continue
    [[ -n "$exe" && "${exe:A}" == "${2:A}" ]] && print $pid
  done
  return 0
}
app_pids() { running_pids "$name" "$app/Contents/MacOS/$name"; }
helper_pids() { running_pids magnife-ingest "$app/Contents/Helpers/magnife-ingest"; }
if [[ -n "$(app_pids)" ]]; then
  if (( ! quit_running )); then
    echo "error: $name is running from $app (pid $(app_pids | tr '\n' ' ')); quit it, or run without --no-quit" >&2
    exit 1
  fi
  step "Quitting the $name running from $app"
  # A quit request to that process only (NSRunningApplication.terminate), so
  # applicationWillTerminate stops the helper and waits for it.
  for pid in $(app_pids); do
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 || true
  done
  for _ in {1..100}; do [[ -z "$(app_pids)" ]] && break; sleep 0.1; done
  if [[ -n "$(app_pids)" ]]; then
    # The helper exits on its own when its stdin closes, so SIGTERM is safe.
    echo "warning: $name did not quit in 10 s; sending SIGTERM"
    app_pids | xargs kill -TERM 2>/dev/null || true
    for _ in {1..30}; do [[ -z "$(app_pids)" ]] && break; sleep 0.1; done
  fi
  [[ -z "$(app_pids)" ]] || { echo "error: $name is still running from $app; quit it and run again" >&2; exit 1; }
  # Give its helper a moment to see stdin EOF and free the ports.
  for _ in {1..30}; do [[ -z "$(helper_pids)" ]] && break; sleep 0.1; done
  [[ -z "$(helper_pids)" ]] || echo "warning: a helper from $app is still running (pid $(helper_pids | tr '\n' ' '))"
fi

step "Installing to $app"
rm -rf "$app"
ditto "$staged" "$app"
codesign --verify --strict --deep "$app" || { echo "error: installed copy fails its signature check" >&2; exit 1; }
# Only an Applications folder: a scratch copy registered with Launch Services
# could answer `open -b` or a notification click instead of the real one.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "${dest:t}" == Applications && -x $lsregister ]]; then
  "$lsregister" -f "$app" >/dev/null 2>&1 || true
fi

# 6. How to launch --------------------------------------------------------
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
echo
echo "Installed $app ($version, build $build; signed ad hoc, helper $bundle_id.ingest${${sparkle:#0}:+, with Sparkle})"
echo "Launch it with:"
echo "    open \"$app\""
echo "    \"$app/Contents/MacOS/$name\"        # from a terminal, helper stderr in this shell"
echo "Then point an app at it:"
echo "    export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
if (( open_after )); then
  open "$app"
fi
