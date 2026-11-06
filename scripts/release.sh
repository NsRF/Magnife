#!/bin/zsh
# release.sh: build Magnife <version> for download and, with --publish, put it
# on GitHub Releases.
#
# What it makes, in ~/Library/Developer/Magnife/release/<version>/:
#   Magnife.dmg        drag-to-Applications disk image (for people)
#   Magnife.zip        the app zipped with ditto (for scripts/install.sh and Homebrew)
#   SHA256SUMS.txt     shasum -a 256 of both
#   notes.md           the release notes (what's new, install steps, checksums, commit)
#   appcast.xml        the Sparkle update feed: one item, this version's
#                      Magnife.zip with its EdDSA signature (needs the key, below)
# The asset names carry no version, so these links always point at the newest
# release:  https://github.com/<repo>/releases/latest/download/Magnife.dmg
# and every build's SUFeedURL is
#           https://github.com/<repo>/releases/latest/download/appcast.xml
# so an installed Magnife finds the newest published, non-prerelease version.
#
# Updates (Sparkle 2, docs/RELEASE.md B2, B5 to B7):
#   - The app is built with MAGNIFE_SPARKLE=1 and SPARKLE_AUTOMATIC_CHECKS=ask:
#     Sparkle asks people on the second launch whether to check automatically;
#     until then only Magnife > Check for Updates… checks.
#   - SUPublicEDKey is SPARKLE_PUBLIC_ED_KEY, else the public half of the key
#     pair in the login keychain (generate_keys -p). --publish needs that key
#     pair: it signs Magnife.zip (sign_update) and refuses a SPARKLE_PUBLIC_ED_KEY
#     that is not the keychain's. Without a key (test packages) the build keeps
#     the placeholders, Check for Updates… stays disabled and no appcast is made.
#   - Sparkle's tools come with the build:
#     ~/Library/Developer/Magnife/release-build/swiftpm/artifacts/sparkle/Sparkle/bin
#
# How:
#   1. scripts/install-local.sh with ARCHS="arm64 x86_64" into a staging folder:
#      the universal helper, a universal app with Sparkle, signed ad hoc, verified.
#   2. Sets CFBundleShortVersionString to <version>, the feed and the key, and signs again:
#        - ad hoc by default (no Apple account needed). Gatekeeper blocks an ad
#          hoc app that was downloaded with a browser; scripts/install.sh
#          downloads with curl, which sets no quarantine flag, and the notes
#          say how to open the DMG copy (Privacy & Security > Open Anyway).
#        - with DEV_ID="Developer ID Application: … (TEAM)" it signs with that
#          certificate (hardened runtime, secure timestamp), and with
#          NOTARY_PROFILE=<notarytool keychain profile> also notarizes and
#          staples the app and the DMG (docs/RELEASE.md B1, B3, B4).
#   3. Packs the DMG and the zip, writes the checksums and notes, and signs the
#      zip for Sparkle into appcast.xml.
#   4. --publish: tags v<version> (annotated), pushes the tag, and creates the
#      GitHub release with the four files (gh CLI: brew install gh; gh auth login).
#      A draft or a prerelease is not "latest": installed copies see it only
#      once it is published as a full release.
#
# Usage:
#   scripts/release.sh 0.1.0                  build and package only
#   scripts/release.sh 0.1.0 --publish        and create the GitHub release
#   scripts/release.sh 0.1.0 --publish --draft   as a draft, to look at first
#   scripts/release.sh 0.1.3 --notes whats-new.md --publish
# Options:
#   --notes <file>  Markdown for "What's new": first in the GitHub notes and the
#                   text of Sparkle's update window (default: a link to the release)
#   --draft         create the release as a draft (publish it on github.com)
#   --ad-hoc        sign ad hoc even when .release.env names a Developer ID (a
#                   quick local test package; never with --publish)
#   --allow-dirty   package a tree with uncommitted changes (never with --publish)
# Environment:
#   GH_REPO         owner/name of the GitHub repo (default NsRF/Magnife)
#   DEV_ID          Developer ID Application identity (default: sign ad hoc)
#   NOTARY_PROFILE  notarytool keychain profile (needs DEV_ID)
#   SPARKLE_PUBLIC_ED_KEY  the update key's public half (default: the keychain's)
#   SPARKLE_ED_KEY_FILE    test packages only: sign the zip with this private key
#                   file (sign_update -f) instead of the keychain's, with
#                   SPARKLE_PUBLIC_ED_KEY its public half. Never with --publish.
#   SPARKLE_FEED_URL       the feed baked into the app (default: the repo's
#                   releases/latest/download/appcast.xml; never change it for a
#                   published app, or installed copies stop finding updates)
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
  _dev_id=${DEV_ID-} _notary=${NOTARY_PROFILE-} _ed_key=${SPARKLE_PUBLIC_ED_KEY-}
  source "$repo/.release.env"
  [[ -n $_dev_id ]] && DEV_ID=$_dev_id
  [[ -n $_notary ]] && NOTARY_PROFILE=$_notary
  [[ -n $_ed_key ]] && SPARKLE_PUBLIC_ED_KEY=$_ed_key
  unset _dev_id _notary _ed_key
fi
gh_repo="${GH_REPO:-NsRF/Magnife}"
version=""
publish=0
draft=0
allow_dirty=0
ad_hoc=0
notes_file=""
while (( $# )); do
  case "$1" in
    --publish)     publish=1 ;;
    --draft)       draft=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    --ad-hoc)      ad_hoc=1 ;;
    --notes)       shift; notes_file="${1:?--notes needs a Markdown file}" ;;
    --notes=*)     notes_file="${1#--notes=}" ;;
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
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  (( publish )) && { echo "error: SPARKLE_ED_KEY_FILE is for test packages; --publish signs with the keychain's key" >&2; exit 2; }
  [[ -f $SPARKLE_ED_KEY_FILE && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || { echo "error: SPARKLE_ED_KEY_FILE needs the file and SPARKLE_PUBLIC_ED_KEY" >&2; exit 2; }
fi
if (( ad_hoc )); then
  (( publish )) && { echo "error: --ad-hoc is for local test packages, not --publish" >&2; exit 2; }
  unset DEV_ID NOTARY_PROFILE
fi
[[ -n "${NOTARY_PROFILE:-}" && -z "${DEV_ID:-}" ]] && { echo "error: NOTARY_PROFILE needs DEV_ID (notarization needs a Developer ID signature)" >&2; exit 2; }
if [[ -n $notes_file ]]; then
  [[ -f $notes_file ]] || { echo "error: no notes file $notes_file" >&2; exit 2; }
  notes_file=${notes_file:A}
  # The notes go into the appcast inside CDATA.
  grep -q ']]>' "$notes_file" && { echo "error: $notes_file contains ']]>'" >&2; exit 2; }
fi
feed_url="${SPARKLE_FEED_URL:-https://github.com/$gh_repo/releases/latest/download/appcast.xml}"
[[ $feed_url == https://* ]] || { echo "error: SPARKLE_FEED_URL must be https, not $feed_url" >&2; exit 2; }
build_dir="$HOME/Library/Developer/$name/release-build"
sparkle_bin="$build_dir/swiftpm/artifacts/sparkle/Sparkle/bin"

step() { print -P "%B==>%b $*"; }
# The update key's public half: SPARKLE_PUBLIC_ED_KEY, else the keychain's
# (generate_keys -p reads it; the keychain may ask to allow access).
keychain_ed_key() { [[ -x "$sparkle_bin/generate_keys" ]] && "$sparkle_bin/generate_keys" -p 2>/dev/null | tail -1 || true; }
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
  # The update key, before the long build when an earlier build left Sparkle's tools.
  if [[ -x "$sparkle_bin/generate_keys" && -z "$(keychain_ed_key)" ]]; then
    echo "error: no Sparkle update key in the login keychain; make it once (docs/RELEASE.md B5):" >&2
    echo "       $sparkle_bin/generate_keys" >&2
    exit 1
  fi
fi

out="${RELEASE_DIR:-$HOME/Library/Developer/$name/release}/$version"
rm -rf "$out"
mkdir -p "$out/stage"
app="$out/stage/$name.app"

# 1. Build a universal app, ad hoc -------------------------------------------
step "Building $name $version (universal, with Sparkle)"
# The feed and key are set below (step 2), once Sparkle's tools exist; the
# build writes placeholders and says so in a note.
MAGNIFE_SPARKLE=1 SPARKLE_AUTOMATIC_CHECKS=ask SPARKLE_FEED_URL= SPARKLE_PUBLIC_ED_KEY= \
  ARCHS="arm64 x86_64" INSTALL_DIR="$out/stage" BUILD_DIR="$build_dir" \
  "$repo/scripts/install-local.sh" --no-quit
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || { echo "error: $app has no Sparkle.framework" >&2; exit 1; }
[[ -x "$sparkle_bin/sign_update" ]] || { echo "error: no Sparkle tools in $sparkle_bin after the build" >&2; exit 1; }
for f in "$app/Contents/MacOS/$name" "$app/Contents/Helpers/magnife-ingest" "$app/Contents/Helpers/magnife-mcp"; do
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

keychain_key=$(keychain_ed_key)
ed_key="${SPARKLE_PUBLIC_ED_KEY:-$keychain_key}"
sign_flags=()
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  sign_flags=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
  keychain_key=$ed_key   # the file's key stands in for the keychain's
fi
if (( publish )); then
  [[ -n $keychain_key ]] || { echo "error: no Sparkle update key in the login keychain; make it once with $sparkle_bin/generate_keys (docs/RELEASE.md B5)" >&2; exit 1; }
  [[ $ed_key == "$keychain_key" ]] || { echo "error: SPARKLE_PUBLIC_ED_KEY is not the public half of the keychain's update key ($keychain_key)" >&2; exit 1; }
fi
plutil -replace SUFeedURL -string "$feed_url" "$plist"
if [[ -n $ed_key ]]; then
  [[ "$(print -rn -- "$ed_key" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] || { echo "error: the Sparkle public key is not 32 bytes of base64: $ed_key" >&2; exit 1; }
  plutil -replace SUPublicEDKey -string "$ed_key" "$plist"
  step "Updates: $feed_url, key $ed_key, Sparkle asks about automatic checks"
else
  echo "note: no Sparkle update key; Check for Updates… stays disabled and no appcast.xml is made"
fi
plutil -lint -s "$plist"
# Sparkle asks on the second launch: the key must be absent, not false.
if plutil -extract SUEnableAutomaticChecks raw -o - "$plist" >/dev/null 2>&1; then
  echo "error: Info.plist has SUEnableAutomaticChecks; the release lets Sparkle ask" >&2; exit 1
fi

if [[ -n "${DEV_ID:-}" ]]; then
  step "Signing with $DEV_ID"
  # Inside out, never --deep: the helpers, Sparkle's code, then the app.
  codesign --force --options runtime --timestamp --sign "$DEV_ID" \
    --identifier "$bundle_id.ingest" "$app/Contents/Helpers/magnife-ingest"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" \
    --identifier "$bundle_id.mcp" "$app/Contents/Helpers/magnife-mcp"
  "$repo/app/tools/sparkle-bundle.sh" --sign "$DEV_ID" "$app"
  codesign --force --options runtime --timestamp --sign "$DEV_ID" "$app"
  signed_with="Developer ID"
else
  step "Signing ad hoc"
  # The helper's and Sparkle's signatures still hold; the app's must cover the
  # new Info.plist. No hardened runtime: library validation refuses an ad hoc
  # Sparkle.framework in an ad hoc app (docs/RELEASE.md A2).
  codesign --force --timestamp=none --sign - "$app" 2>&1 | grep -v "replacing existing signature" || true
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

# The update feed: one item, this version. Sparkle compares sparkle:version
# (CFBundleVersion, a yyyymmddHHMM stamp that only grows) and checks the zip's
# EdDSA signature against the installed app's SUPublicEDKey, then its code
# signature against the installed app's.
release_url="https://github.com/$gh_repo/releases/tag/$tag"
if [[ -n $ed_key && $ed_key == "$keychain_key" ]]; then
  step "Signing $name.zip for Sparkle (appcast.xml)"
  enclosure=$("$sparkle_bin/sign_update" "${sign_flags[@]}" "$out/$name.zip")   # sparkle:edSignature="…" length="…"
  [[ $enclosure == *'sparkle:edSignature="'*'length="'* ]] || { echo "error: sign_update printed: $enclosure" >&2; exit 1; }
  signature=${${enclosure#*sparkle:edSignature=\"}%%\"*}
  "$sparkle_bin/sign_update" "${sign_flags[@]}" --verify "$out/$name.zip" "$signature" >/dev/null || { echo "error: the zip's update signature does not verify" >&2; exit 1; }
  if [[ -n $notes_file ]]; then
    whats_new=$(<"$notes_file")
  else
    whats_new="Magnife $version. [Release notes]($release_url)"
  fi
  cat > "$out/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$name</title>
    <link>https://github.com/$gh_repo</link>
    <description>$name updates</description>
    <language>en</language>
    <item>
      <title>$name $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>$release_url</link>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$release_url</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[$whats_new]]></description>
      <enclosure url="https://github.com/$gh_repo/releases/download/$tag/$name.zip" type="application/octet-stream" $enclosure />
    </item>
  </channel>
</rss>
EOF
  xmllint --noout "$out/appcast.xml" || { echo "error: appcast.xml is not well-formed" >&2; exit 1; }
elif (( publish )); then
  echo "error: no appcast.xml (no update key)" >&2; exit 1
fi

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
if [[ -n $notes_file ]]; then
  whats_new_section="## What's new

$(<"$notes_file")
"
else
  whats_new_section=""
fi
if [[ -f "$out/appcast.xml" ]]; then
  update_note="**Updates:** this build updates itself (**Magnife > Check for Updates…**; on the second launch it asks whether to check automatically). Magnife 0.1.2 and earlier have no updater: install this one over them once.
"
else
  update_note=""
fi
cat > "$out/notes.md" <<EOF
Magnife $version: a native macOS viewer for your local OpenTelemetry traces and logs.

$whats_new_section
## Install

Requires **macOS 26 or later**, on Apple silicon or Intel.

**Script** (downloads Magnife.zip, checks its SHA-256, installs to /Applications and opens it):

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$gh_repo/main/scripts/install.sh | bash
\`\`\`

**Disk image**: download **Magnife.dmg** below, open it and drag Magnife to Applications.

$open_note

$update_note
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
  # appcast.xml is what every installed copy reads (releases/latest/download).
  gh release create "$tag" "${release_flags[@]}" "$out/$name.dmg" "$out/$name.zip" "$out/SHA256SUMS.txt" "$out/appcast.xml"
  if (( ! draft )) && [[ $version != *-* ]]; then
    step "Checking the update feed"
    sleep 2
    live=$(curl -fsSL "$feed_url" 2>/dev/null | grep -o '<sparkle:shortVersionString>[^<]*' | sed 's/.*>//' || true)
    if [[ $live == "$version" ]]; then
      echo "    $feed_url serves $version"
    else
      echo "warning: $feed_url serves '${live:-nothing}', not $version yet; check it in a minute" >&2
    fi
  fi
else
  echo
  echo "Not published. To publish this version:"
  echo "    scripts/release.sh $version --publish"
fi
