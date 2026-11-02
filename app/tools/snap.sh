#!/bin/zsh
# Snapshots of every page in light and dark, on fresh fixture databases in /tmp,
# with no helper (APP_HELPER=none).
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh
set -u
here=${0:A:h}
app=~/Applications/Magnife.app/Contents/MacOS/Magnife
store=/tmp/Magnife-test.sqlite
shots=/tmp/Magnife-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
"$here/make-fixture-db.sh" $store || exit 1
# 01-empty-state reads the schema-only file next to the store (SnapshotPage.emptyStore).
"$here/make-fixture-db.sh" ${store:r}.empty.sqlite --empty || exit 1
rm -rf $shots
APP_STORE=$store APP_HELPER=none APP_SNAPSHOT=$shots $app
