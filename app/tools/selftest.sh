#!/bin/zsh
# Runs the in-app self-test with no helper of its own (APP_HELPER=none) on a
# database seeded through the real pipeline (tools/seed.zsh). The receiver
# checks start the bundled helper themselves, on free ports, and send gRPC
# with the sample sender (APP_SAMPLE_SENDER). Exit code 0 when every check passed.
# Every run has its own directory (mktemp -d /tmp/Magnife-self.XXXXXX, APP_TEST_ROOT)
# and its own defaults suite (TestRun), so runs that overlap never share a file.
# The stores are removed at the end; the logs and captures (shots/) stay.
set -u
here=${0:A:h}
root=${here:h:h}
source $here/seed.zsh
run=$(mktemp -d /tmp/Magnife-self.XXXXXX) || exit 1
cleanup() { seed_stop; rm -f $run/*.sqlite(N) $run/*.sqlite-wal(N) $run/*.sqlite-shm(N) }
trap cleanup EXIT INT TERM
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
# Earlier runs' directories older than a day.
find /tmp -maxdepth 1 -name 'Magnife-self.*' -type d -mtime +1 -exec rm -rf {} + 2>/dev/null
store=$run/self.sqlite
# Search's timing (S-017) and the launch timing (S-029) read a second store
# with 100,000 spans; seeded first, so $seed_grpc / $seed_http below stay the main store's helper.
search_store=$run/self-100k.sqlite
seed_store $search_store --volume 100000 || exit 1
# Nothing more is sent to it: its helper would only take CPU from the timed checks.
seed_stop_last
# SELFTEST_LAUNCH_VOLUMES="12000 300000": more stores for the launch timing (S-029, APP_LAUNCH_STORES).
launch_stores=()
for volume in ${=SELFTEST_LAUNCH_VOLUMES:-}; do
  seed_store $run/launch-$volume.sqlite --volume $volume || exit 1
  seed_stop_last
  launch_stores+=($run/launch-$volume.sqlite)
done
seed_store $store || exit 1
print "selftest: run directory $run"
# APP_SEED_GRPC / APP_SEED_HTTP: the seed helper, still writing $store, for the live list checks.
# The empty split-frames default makes the window's columns start at their
# ideal widths (docs/ux.md), not where the last run left them; it goes
# before --selftest, which the argument domain would otherwise read as a key.
APP_STORE=$store APP_HELPER=none APP_TEST_ROOT=$run APP_SEARCH_STORE=$search_store APP_SAMPLE_SENDER=$seed_sender \
  APP_LAUNCH_STORES=${(j:,:)launch_stores} APP_SEED_GRPC=$seed_grpc APP_SEED_HTTP=$seed_http \
  ~/Applications/Magnife.app/Contents/MacOS/Magnife -"NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView" "()" --selftest
