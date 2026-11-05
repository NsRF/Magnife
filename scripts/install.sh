#!/bin/bash
# install.sh: download Magnife from GitHub Releases and install it.
#
#   curl -fsSL https://raw.githubusercontent.com/NsRF/Magnife/main/scripts/install.sh | bash
#
# It downloads Magnife.zip and SHA256SUMS.txt from the release, checks the
# checksum and the code signature, quits a Magnife running from the
# destination, installs Magnife.app and opens it. curl sets no quarantine
# flag, so macOS opens the app without the "could not verify" prompt.
#
# Environment:
#   MAGNIFE_VERSION      a release such as 0.1.0 (default: the latest)
#   MAGNIFE_INSTALL_DIR  where to install (default /Applications, or
#                        ~/Applications when /Applications is not writable)
#   MAGNIFE_NO_OPEN=1    do not open the app afterwards
#   MAGNIFE_REPO         owner/name on GitHub (default NsRF/Magnife)
#   MAGNIFE_DOWNLOAD_URL a folder with Magnife.zip and SHA256SUMS.txt instead of
#                        the release (a mirror, or file:///… to test a local build)
set -euo pipefail

repo="${MAGNIFE_REPO:-NsRF/Magnife}"
version="${MAGNIFE_VERSION:-latest}"
version="${version#v}"
if [[ $version == latest ]]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/v$version"
fi
base="${MAGNIFE_DOWNLOAD_URL:-$base}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Magnife is a macOS app"
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || die "Magnife needs macOS 26 or later (this Mac has $(sw_vers -productVersion))"

dest="${MAGNIFE_INSTALL_DIR:-}"
if [[ -z $dest ]]; then
  if [[ -w /Applications ]]; then dest=/Applications; else dest="$HOME/Applications"; fi
fi
mkdir -p "$dest"
app="$dest/Magnife.app"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/magnife-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

say "Downloading Magnife ($version) from $base"
curl -fL --progress-bar -o "$tmp/Magnife.zip" "$base/Magnife.zip" || die "could not download $base/Magnife.zip"
curl -fsSL -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || die "could not download $base/SHA256SUMS.txt"

expected=$(awk '$2 == "Magnife.zip" { print $1 }' "$tmp/SHA256SUMS.txt")
actual=$(shasum -a 256 "$tmp/Magnife.zip" | awk '{ print $1 }')
[[ -n $expected ]] || die "SHA256SUMS.txt has no line for Magnife.zip"
[[ $expected == "$actual" ]] || die "checksum mismatch for Magnife.zip (expected $expected, got $actual)"
say "Checksum OK ($actual)"

mkdir "$tmp/unzipped"
ditto -x -k "$tmp/Magnife.zip" "$tmp/unzipped"
new="$tmp/unzipped/Magnife.app"
[[ -d $new ]] || die "the zip has no Magnife.app"
codesign --verify --strict --deep "$new" || die "Magnife.app fails its signature check"
installed_version=$(plutil -extract CFBundleShortVersionString raw -o - "$new/Contents/Info.plist")

# Quit only the copy being replaced: a polite quit, so it stops its helper
# and frees ports 4317 and 4318.
for pid in $(pgrep -x Magnife 2>/dev/null || true); do
  exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }' || true)
  if [[ $exe == "$app/Contents/MacOS/Magnife" ]]; then
    say "Quitting the Magnife running from $app"
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 || true
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && die "Magnife did not quit; quit it and run this again"
    sleep 0.5
  fi
done

say "Installing Magnife $installed_version to $app"
rm -rf "$app"
ditto "$new" "$app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x $lsregister ]] && "$lsregister" -f "$app" >/dev/null 2>&1 || true

cat <<EOF

Magnife $installed_version is installed in $app.
Point your service at it:
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
To uninstall: rm -rf "$app" ~/Library/Application\ Support/Magnife
EOF

if [[ -z "${MAGNIFE_NO_OPEN:-}" ]]; then
  open "$app"
fi
