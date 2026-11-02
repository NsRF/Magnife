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
seed_store $store || exit 1
# APP_SEED_GRPC / APP_SEED_HTTP: the seed helper, still writing $store, for the live list checks.
APP_STORE=$store APP_HELPER=none APP_SAMPLE_SENDER=$seed_sender APP_SEED_GRPC=$seed_grpc APP_SEED_HTTP=$seed_http \
  ~/Applications/Magnife.app/Contents/MacOS/Magnife --selftest
