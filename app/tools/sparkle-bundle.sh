#!/bin/zsh
# Puts Sparkle 2 into a Magnife.app built with the Sparkle trait
# (MAGNIFE_SPARKLE=1 ./build.sh, scripts/install-local.sh). Two steps, so the
# callers can sign their helper in between:
#
#   sparkle-bundle.sh <Sparkle.framework> <Magnife.app>
#       copies the framework into Contents/Frameworks and adds the SU keys to
#       Contents/Info.plist: SUFeedURL and SUPublicEDKey from SPARKLE_FEED_URL
#       and SPARKLE_PUBLIC_ED_KEY (placeholders when unset, so the updater does
#       not start; UpdaterController), and SUEnableAutomaticChecks false.
#   sparkle-bundle.sh --sign <identity> <Magnife.app>
#       signs Sparkle's code inside out (Sparkle's docs for builds outside
#       Xcode), before the caller signs the app around it.
#
# Never generates keys: the EdDSA key pair is the owner's (docs/RELEASE.md).
set -euo pipefail

if [[ "${1:-}" == "--sign" ]]; then
  identity=${2:?identity}; app=${3:?app}
  fw="$app/Contents/Frameworks/Sparkle.framework"
  [[ -d "$fw" ]] || { echo "error: no $fw" >&2; exit 1; }
  sign() { codesign --force --options runtime --timestamp=none --sign "$identity" "$@" 2>&1 | grep -v "replacing existing signature" || true; }
  sign "$fw/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
  sign "$fw/Versions/B/Autoupdate"
  sign "$fw/Versions/B/Updater.app"
  sign "$fw"
  exit 0
fi

framework=${1:?Sparkle.framework}; app=${2:?app}
[[ -d "$framework" ]] || { echo "error: no $framework (was the app built with --traits Sparkle?)" >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks"
# ditto keeps the framework's Versions/Current symlinks.
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
plist="$app/Contents/Info.plist"
# Placeholders until the owner has a feed and keys (docs/RELEASE.md, Sparkle).
plutil -insert SUFeedURL -string "${SPARKLE_FEED_URL:-__SPARKLE_FEED_URL__}" "$plist"
plutil -insert SUPublicEDKey -string "${SPARKLE_PUBLIC_ED_KEY:-__SPARKLE_PUBLIC_ED_KEY__}" "$plist"
# No background checks, and no "check automatically?" question on the second launch.
plutil -insert SUEnableAutomaticChecks -bool NO "$plist"
if [[ -z "${SPARKLE_FEED_URL:-}" || -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "note: no SPARKLE_FEED_URL / SPARKLE_PUBLIC_ED_KEY; Check for Updates… stays disabled in this build"
fi
