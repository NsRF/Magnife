# Seed data through the real pipeline (docs/STORIES.md, "Seed data"): the
# bundled helper receives the sample sender's OTLP and writes the database,
# so every value on screen comes from telemetry Magnife received.
# Sourced by snap.sh and selftest.sh, which set $root to the repo root.
#
#   seed_store <db in /tmp>           helper on <db> + scripts/send-sample-traces
#   seed_store <db in /tmp> --empty   helper on <db>, nothing sent (schema only)
#   seed_stop                         stops every helper seed_store started
#   $seed_grpc, $seed_http            the last seeded helper's addresses
#
# Each helper keeps running until seed_stop (an EXIT trap): the app reads
# read-only, and a read-only reader needs the -wal file, which exists only
# while the helper has the database open (PROGRESS decision 14). Helpers use
# port 0, so they never collide with 4317/4318 or with each other; the ports
# line says which ports they got.

typeset -ga seed_pids
seed_sender=$root/ingest/bin/send-sample-traces

seed_helper() {
  local bundled=~/Applications/Magnife.app/Contents/Helpers/magnife-ingest
  if [[ -x $bundled ]]; then print -r -- $bundled; return; fi
  [[ -x $root/ingest/bin/magnife-ingest ]] || (cd $root/ingest && ./build.sh) >&2 || return 1
  print -r -- $root/ingest/bin/magnife-ingest
}

# Waits up to $2 tenths of a second for the command in $1 to succeed.
seed_wait() {
  local i
  for i in {1..$2}; do eval "$1" && return 0; sleep 0.1; done
  return 1
}

# The sum of one count ($1: spans or logs) over the batch lines in $2.
seed_total() {
  local n total=0
  for n in $(grep -o "\"$1\":[0-9]*" $2 | cut -d: -f2); do (( total += n )); done
  print $total
}

seed_store() {
  local db=$1 mode=${2:-}
  [[ $db == /tmp/* ]] || { print -u2 "seed: $db is not in /tmp"; return 1 }
  local helper; helper=$(seed_helper) || { print -u2 "seed: no helper"; return 1 }
  rm -f $db $db-wal $db-shm
  local out=$db.helper.jsonl
  : > $out
  $helper --db $db --grpc 127.0.0.1:0 --http 127.0.0.1:0 --no-stdin > $out 2> $db.helper.log &
  seed_pids+=($!)
  seed_wait "grep -q '\"type\":\"ports\"' $out" 50 || { print -u2 "seed: helper did not report its ports (see $db.helper.log)"; return 1 }
  local grpc http
  grpc=$(sed -n 's/.*"grpc":{"addr":"\([^"]*\)","state":"listening".*/\1/p' $out | head -1)
  http=$(sed -n 's/.*"http":{"addr":"\([^"]*\)","state":"listening".*/\1/p' $out | head -1)
  [[ -n $grpc && -n $http ]] || { print -u2 "seed: helper ports not listening: $(head -1 $out)"; return 1 }
  # The last seeded store's helper, so the self-test can send it more (S-004).
  typeset -g seed_grpc=$grpc seed_http=$http
  [[ $mode == --empty ]] && return 0
  # The seed set, over mixed protocols (gRPC, HTTP protobuf and JSON, with and without gzip).
  local summary
  summary=$($root/scripts/send-sample-traces --grpc $grpc --http $http 2>&1 | tail -1)
  local spans=${${summary##*: }%% spans*} logs=${${summary%% logs,*}##* }
  [[ $spans == <-> && $logs == <-> && $summary == *" 0 errors"* ]] || { print -u2 "seed: sender failed: $summary"; return 1 }
  # Every span and log is committed once the batch lines add up.
  seed_wait "(( \$(seed_total spans $out) >= $spans && \$(seed_total logs $out) >= $logs ))" 50 \
    || { print -u2 "seed: batches did not add up to $spans spans and $logs logs"; return 1 }
  print "seed: $db has $spans spans and $logs logs from $grpc / $http"
}

seed_stop() {
  (( ${#seed_pids} )) || return 0
  kill -TERM $seed_pids 2>/dev/null
  wait $seed_pids 2>/dev/null
  seed_pids=()
}
