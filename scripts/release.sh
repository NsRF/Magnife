#!/bin/zsh
# release.sh: build Magnife <version> for download and, with --publish, put it
# on GitHub Releases.
#
# What it makes, in ~/Library/Developer/Magnife/release/<version>/:
#   Magnife.dmg        drag-to-Applications disk image (for people)
#   Magnife.zip        the app zipped with ditto (for scripts/install.sh and Homebrew)
#   SHA256SUMS.txt     shasum -a 256 of both
#   notes.md           the release notes (install steps, checksums, commit)
# The asset names carry no version, so these links always point at the newest
# release:  https://github.com/<repo>/releases/latest/download/Magnife.dmg
#
# How:
#   1. scripts/install-local.sh with ARCHS="arm64 x86_64" into a staging folder:
#      the universal helper, a universal app, signed ad hoc, verified.
#   2. Sets CFBundleShortVersionString to <version> and signs again:
#        - ad hoc by default (no Apple account needed). Gatekeeper blocks an ad
#          hoc app that was downloaded with a browser; scripts/install.sh
#          downloads with curl, which sets no quarantine flag, and the notes
#          say how to open the DMG copy (Privacy & Security > Open Anyway).
#        - with DEV_ID="Developer ID Application: … (TEAM)" it signs with that
#          certificate (hardened runtime, secure timestamp), and with
#          NOTARY_PROFILE=<notarytool keychain profile> also notarizes and
#          staples the app and the DMG (docs/RELEASE.md B1, B3, B4).
#   3. Packs the DMG and the zip and writes the checksums and notes.
#   4. --publish: tags v<version> (annotated), pushes the tag, and creates the
#      GitHub release with the three files (gh CLI: brew install gh; gh auth login).
#
# Usage:
#   scripts/release.sh 0.1.0                  build and package only
#   scripts/release.sh 0.1.0 --publish        and create the GitHub release
#   scripts/release.sh 0.1.0 --publish --draft   as a draft, to look at first
# Options:
#   --draft         create the release as a draft (publish it on github.com)
#   --allow-dirty   package a tree with uncommitted changes (never with --publish)
# Environment:
#   GH_REPO         owner/name of the GitHub repo (default NsRF/Magnife)
#   DEV_ID          Developer ID Application identity (default: sign ad hoc)
#   NOTARY_PROFILE  notarytool keychain profile (needs DEV_ID)
#   RELEASE_DIR     output root (default ~/Library/Developer/Magnife/release)
# Local settings: put DEV_ID and NOTARY_PROFILE in .release.env at the repo
# root (git ignores it), e.g.
#   DEV_ID="Developer ID Application: Your Name (TEAMID1234)"
#   NOTARY_PROFILE=magnife-notary
# They are names, not secrets: the certificate's private key and the notary
# credentials stay in your login keychain. Variables set in the shell win.
#
# The app needs Xcode 27 (SwiftUI's macros), so this runs on a Mac with it,
# not on GitHub's runners (Xcode 26.6 at the time of writing).
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

name=Magnife
repo="${0:A:h:h}"
if [[ -f "$repo/.release.env" ]]; then
  _dev_id=${DEV_ID-} _notary=${NOTARY_PROFILE-}
  source "$repo/.release.env"
  [[ -n $_dev_id ]] && DEV_ID=$_dev_id
  [[ -n $_notary ]] && NOTARY_PROFILE=$_notary
  unset _dev_id _notary
fi
gh_repo="${GH_REPO:-NsRF/Magnife}"
version=""
publish=0
draft=0
allow_dirty=0
while (( $# )); do
  case "$1" in
    --publish)     publish=1 ;;
    --draft)       draft=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    -*)            echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)             [[ -z $version ]] || { echo "one version only" >&2; exit 2; }; version=$1 ;;
  esac
  shift
done
[[ -n $version ]] || { echo "usage: scripts/release.sh <version> [--publish [--draft]] (try --help)" >&2; exit 2; }
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] || { echo "error: version must look like 1.2.3 or 1.2.3-beta.1, not $version" >&2; exit 2; }
tag="v$version"
(( draft && ! publish )) && { echo "error: --draft goes with --publish" >&2; exit 2; }
[[ -n "${NOTARY_PROFILE:-}" && -z "${DEV_ID:-}" ]] && { echo "error: NOTARY_PROFILE needs DEV_ID (notarization needs a Developer ID signature)" >&2; exit 2; }

step() { print -P "%B==>%b $*"; }
cd "$repo"

# Checks before the long build ---------------------------------------------
if [[ -n "$(git status --porcelain)" ]]; then
  if (( publish || ! allow_dirty )); then
    echo "error: the work tree has uncommitted changes; commit them first" >&2
    (( publish )) || echo "       (or pass --allow-dirty for a local test package)" >&2
    exit 1
  fi
  echo "warning: packaging a tree with uncommitted changes"
fi
commit=$(git rev-parse HEAD)
if (( publish )); then
  command -v gh >/dev/null || { echo "error: the GitHub CLI is not installed: brew install gh, then gh auth login" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: gh is not signed in: gh auth login" >&2; exit 1; }
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git rev-parse "$tag^{commit}")" == "$commit" ]] || { echo "error: tag $tag exists and is not HEAD" >&2; exit 1; }
  fi
  if gh release view "$tag" --repo "$gh_repo" >/dev/null 2>&1; then
    echo "error: $gh_repo already has a release $tag" >&2; exit 1
  fi
fi

out="${RELEASE_DIR:-$HOME/Library/Developer/$name/release}/$version"
rm -rf "$out"
mkdir -p "$out/stage"
app="$out/stage/$name.app"

# 1. Build a universal app, ad hoc -------------------------------------------
step "Building $name $version (universal)"
ARCHS="arm64 x86_64" INSTALL_DIR="$out/stage" BUILD_DIR="$HOME/Library/Developer/$name/release-build" \
  "$repo/scripts/install-local.sh" --no-quit
for f in "$app/Contents/MacOS/$name" "$app/Contents/Helpers/magnife-ingest"; do
  archs=" $(lipo -archs "$f") "
  [[ $archs == *" arm64 "* && $archs == *" x86_64 "* ]] || { echo "error: $f is not universal:$archs" >&2; exit 1; }
  # LSMinimumSystemVersion is 26.0; a binary built for a newer macOS would not launch there.
  for a in arm64 x86_64; do
    minos=$(otool -arch $a -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }')
    [[ ${minos%%.*} -le 26 ]] || { echo "error: $f ($a) needs macOS $minos" >&2; exit 1; }
  done
done

# 2. Version and signature -------------------------------------------------
plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$plist")
build=$(plutil -extract CFBundleVersion raw -o - "$plist")
if [[ -n "${DEV_ID:-}" ]]; then
  step "Signing with $DEV_ID"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" \
    --identifier "$bundle_id.ingest" "$app/Contents/Helpers/magnife-ingest"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$app"
  signed_with="Developer ID"
else
  step "Signing ad hoc"
  # The helper's signature still holds; the app's must cover the new Info.plist.
  codesign --force --options runtime --timestamp=none --sign - "$app" 2>&1 | grep -v "replacing existing signature" || true
  signed_with="ad hoc"
fi
codesign --verify --strict --deep "$app" || { echo "error: signature check failed" >&2; exit 1; }
if [[ -n "$(codesign -d --entitlements - "$app" 2>/dev/null)" ]]; then
  echo "error: the app has entitlements; a release must have none (docs/RELEASE.md B3)" >&2; exit 1
fi

notarize() {
  step "Notarizing ${1:t}"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
notarized=0
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out/notarize.zip"
  notarize "$out/notarize.zip"
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute -vv "$app"
  notarized=1
fi

# 3. Packages --------------------------------------------------------------
step "Packing $name.dmg and $name.zip"
dmgroot="$out/dmg"
mkdir -p "$dmgroot"
ditto "$app" "$dmgroot/$name.app"
ln -s /Applications "$dmgroot/Applications"
hdiutil create -quiet -volname "$name $version" -srcfolder "$dmgroot" -ov -format UDZO "$out/$name.dmg"
rm -rf "$dmgroot"
if [[ -n "${DEV_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEV_ID" "$out/$name.dmg"
fi
if (( notarized )); then
  notarize "$out/$name.dmg"
  xcrun stapler staple "$out/$name.dmg"
fi
hdiutil verify -quiet "$out/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$name.zip"
(cd "$out" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)

# 4. Notes -----------------------------------------------------------------
if (( notarized )); then
  open_note="The app is signed with a Developer ID and notarized by Apple: it opens like any downloaded app."
else
  open_note="This build is not notarized (signed ad hoc), so macOS stops it the first time if you downloaded the DMG with a browser. Open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**, or run:

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/Magnife.app
\`\`\`

The install script below needs neither step."
fi
cat > "$out/notes.md" <<EOF
Magnife $version: a native macOS viewer for your local OpenTelemetry traces and logs.

## Install

Requires **macOS 26 or later**, on Apple silicon or Intel.

**Script** (downloads Magnife.zip, checks its SHA-256, installs to /Applications and opens it):

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$gh_repo/main/scripts/install.sh | bash
\`\`\`

**Disk image**: download **Magnife.dmg** below, open it and drag Magnife to Applications.

$open_note

Then point your service at it:

\`\`\`sh
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
\`\`\`

## Checksums (SHA-256)

\`\`\`
$(cat "$out/SHA256SUMS.txt")
\`\`\`

Built from $commit, CFBundleVersion $build, signed $signed_with.
EOF

step "Packaged in $out"
ls -lh "$out" | sed 1d | awk '{print "    " $5 "\t" $NF}'

# 5. Publish ---------------------------------------------------------------
if (( publish )); then
  if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    step "Tagging $tag"
    git tag -a "$tag" -m "Magnife $version"
  fi
  step "Pushing $tag"
  git push origin "refs/tags/$tag"
  release_flags=(--repo "$gh_repo" --verify-tag --title "Magnife $version" --notes-file "$out/notes.md")
  (( draft )) && release_flags+=(--draft)
  [[ $version == *-* ]] && release_flags+=(--prerelease)
  step "Creating the GitHub release $tag${${draft:#0}:+ (draft)}"
  gh release create "$tag" "${release_flags[@]}" "$out/$name.dmg" "$out/$name.zip" "$out/SHA256SUMS.txt"
else
  echo
  echo "Not published. To publish this version:"
  echo "    scripts/release.sh $version --publish"
fi
