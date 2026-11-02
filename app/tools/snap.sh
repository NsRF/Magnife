#!/bin/zsh
# Snapshots of every page in light and dark. The data comes through the real
# pipeline (tools/seed.zsh): the bundled helper receives the sample sender's
# OTLP on free ports and writes fresh databases in /tmp, and keeps them open
# while the app reads them with APP_HELPER=none.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh
set -u
here=${0:A:h}
root=${here:h:h}
source $here/seed.zsh
trap seed_stop EXIT INT TERM
app=~/Applications/Magnife.app/Contents/MacOS/Magnife
store=/tmp/Magnife-test.sqlite
shots=/tmp/Magnife-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
seed_store $store || exit 1
# 01-empty-state reads the schema-only file next to the store (SnapshotPage.emptyStore).
seed_store ${store:r}.empty.sqlite --empty || exit 1
rm -rf $shots
# The empty split-frames default makes the window's columns start at their
# ideal widths (docs/ux.md), not where the last run left them.
APP_STORE=$store APP_HELPER=none APP_SNAPSHOT=$shots $app -"NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView" "()"
