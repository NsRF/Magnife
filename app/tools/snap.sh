#!/bin/zsh
# Snapshots of every page in light and dark. The data comes through the real
# pipeline (tools/seed.zsh): the bundled helper receives the sample sender's
# OTLP on free ports and writes fresh databases in /tmp, and keeps them open
# while the app reads them with APP_HELPER=none.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh
# Every run has its own directory (mktemp -d /tmp/Magnife-snap.XXXXXX) and
# defaults suite, so runs that overlap never share a file. When a run ends,
# /tmp/Magnife-shots links to its shots (the last run to finish wins); each
# run also prints its own shots directory.
set -u
here=${0:A:h}
root=${here:h:h}
source $here/seed.zsh
app=~/Applications/Magnife.app/Contents/MacOS/Magnife
run=$(mktemp -d /tmp/Magnife-snap.XXXXXX) || exit 1
cleanup() { seed_stop; rm -f $run/*.sqlite(N) $run/*.sqlite-wal(N) $run/*.sqlite-shm(N) }
trap cleanup EXIT INT TERM
store=$run/test.sqlite
shots=$run/shots
# Earlier runs' directories older than a day.
find /tmp -maxdepth 1 -name 'Magnife-snap.*' -type d -mtime +1 -exec rm -rf {} + 2>/dev/null
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
seed_store $store || exit 1
# 01-empty-state reads the schema-only file next to the store (SnapshotPage.emptyStore).
seed_store ${store:r}.empty.sqlite --empty || exit 1
# The empty split-frames default makes the window's columns start at their
# ideal widths (docs/ux.md), not where the last run left them.
APP_STORE=$store APP_HELPER=none APP_TEST_ROOT=$run APP_SNAPSHOT=$shots $app -"NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView" "()"
code=$?
# /tmp/Magnife-shots: the newest finished run's shots (a real directory from older runs is replaced).
[[ -L /tmp/Magnife-shots || ! -e /tmp/Magnife-shots ]] || rm -rf /tmp/Magnife-shots
ln -sfn $shots /tmp/Magnife-shots
print "snap: shots in $shots (linked from /tmp/Magnife-shots)"
exit $code
