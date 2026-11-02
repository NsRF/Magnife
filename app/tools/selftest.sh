#!/bin/zsh
# Runs the in-app self-test against a fresh fixture database in /tmp, with no
# helper (APP_HELPER=none). Exit code 0 when every check passed.
set -u
here=${0:A:h}
rm -rf ~/Library/Saved\ Application\ State/com.nasserfarhat.magnife.savedState
store=/tmp/Magnife-self.sqlite
"$here/make-fixture-db.sh" $store || exit 1
APP_STORE=$store APP_HELPER=none ~/Applications/Magnife.app/Contents/MacOS/Magnife --selftest
