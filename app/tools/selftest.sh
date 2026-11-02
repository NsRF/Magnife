#!/bin/zsh
# Runs the in-app self-test with no helper of its own (APP_HELPER=none) on a
# database seeded through the real pipeline (tools/seed.zsh). The receiver
# checks start the bundled helper themselves, on free ports, and send gRPC
# with the sample sender (APP_SAMPLE_SENDER). Exit code 0 when every check passed.
set -u
here=${0:A:h}
root=${here:h:h}
source $here/seed.zsh
trap seed_stop EXIT INT TERM
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
store=/tmp/Magnife-self.sqlite
# Search's timing (S-017) reads a second store with 100,000 spans; seeded
# first, so $seed_grpc / $seed_http below stay the main store's helper.
search_store=/tmp/Magnife-self-100k.sqlite
seed_store $search_store --volume 100000 || exit 1
# Nothing more is sent to it: its helper would only take CPU from the timed checks.
seed_stop_last
seed_store $store || exit 1
# APP_SEED_GRPC / APP_SEED_HTTP: the seed helper, still writing $store, for the live list checks.
# The empty split-frames default makes the window's columns start at their
# ideal widths (docs/ux.md), not where the last run left them; it goes
# before --selftest, which the argument domain would otherwise read as a key.
APP_STORE=$store APP_HELPER=none APP_SEARCH_STORE=$search_store APP_SAMPLE_SENDER=$seed_sender APP_SEED_GRPC=$seed_grpc APP_SEED_HTTP=$seed_http \
  ~/Applications/Magnife.app/Contents/MacOS/Magnife -"NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView" "()" --selftest
