#!/bin/zsh
# Builds Magnife and installs it to ~/Applications/Magnife.app, with the Go
# helper (../ingest) in Contents/Helpers/magnife-ingest.
# Build products live in ~/Library/Developer/Magnife, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
#        MAGNIFE_SPARKLE=1 ./build.sh   with Sparkle 2 and Magnife > Check for Updates… (off by
#                              default; SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY fill
#                              Info.plist, placeholders otherwise; SPARKLE_AUTOMATIC_CHECKS=0|1|ask,
#                              0 by default: tools/sparkle-bundle.sh, docs/RELEASE.md)
set -euo pipefail
# SwiftUI's macros ship with Xcode, not the Command Line Tools: when
# xcode-select points at the latter and Xcode is installed, build with Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
here=${0:A:h}
name="Magnife"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
# Sparkle is a package trait: off, it is not fetched as a binary, not compiled,
# not linked (a resolve may still check out its source; docs/RELEASE.md A2).
sparkle=${MAGNIFE_SPARKLE:-0}
swift_flags=()
if [[ $sparkle == 1 ]]; then
  swift_flags=(--traits Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" "${swift_flags[@]}" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" "${swift_flags[@]}" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# The helper: ../ingest/build.sh writes ../ingest/bin/magnife-ingest.
ingest="$here/../ingest"
helper=""
if [[ -f "$ingest/build.sh" ]]; then
  if (cd "$ingest" && ./build.sh) && [[ -x "$ingest/bin/magnife-ingest" ]]; then
    mkdir -p "$app/Contents/Helpers"
    cp "$ingest/bin/magnife-ingest" "$app/Contents/Helpers/magnife-ingest"
    helper="$app/Contents/Helpers/magnife-ingest"
  else
    echo "warning: ingest/build.sh failed; the app has no helper and will show Not receiving"
  fi
else
  echo "warning: ingest/build.sh not found; the app has no helper and will show Not receiving"
fi
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
if [[ $sparkle == 1 ]]; then
  "$here/tools/sparkle-bundle.sh" "$scratch/$config/Sparkle.framework" "$app"
fi
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
xattr -cr "$app"
# Sign inside out, never --deep: the helper first, then the app around it.
# Ad hoc signing has no timestamp; Developer ID release builds add --timestamp.
if [[ -n "$helper" ]]; then
  codesign --force --options runtime --timestamp=none --sign "$identity" "$helper" 2>&1 | grep -v "replacing existing signature" || true
fi
app_runtime=(--options runtime)
if [[ $sparkle == 1 ]]; then
  "$here/tools/sparkle-bundle.sh" --sign "$identity" "$app"
  # Ad hoc only: library validation under the hardened runtime refuses to load
  # an ad hoc Sparkle.framework into an ad hoc app ("different Team IDs").
  # Signed with a certificate, both share the team and the runtime stays on.
  [[ "$identity" == "-" ]] && app_runtime=()
fi
codesign --force "${app_runtime[@]}" --timestamp=none --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --strict "$app" || { echo "signature check failed"; exit 1; }
[[ $sparkle == 1 ]] && { codesign --verify --strict --deep "$app" || { echo "signature check failed (Sparkle.framework)"; exit 1; }; }
echo "installed $app (signed: ${identity}${helper:+, with helper}${${sparkle:#0}:+, with Sparkle})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
