#!/bin/zsh
# Turns the checkpoints recorded by scripts/night-checkpoint.sh into real,
# signed commits on the current branch, in order, without touching the
# working tree. Run it once with 1Password unlocked.
# Usage: scripts/replay-night-commits.sh
set -euo pipefail
root=${0:A:h:h}
cd "$root"
log="$root/.night/checkpoints.tsv"
[[ -s "$log" ]] || { echo "nothing to replay"; exit 0; }
parent=$(git rev-parse HEAD)
while IFS=$'\t' read -r tree msg; do
  parent=$(git commit-tree -S "$tree" -p "$parent" -F "$msg")
  echo "$parent $(head -1 "$msg")"
done < "$log"
git update-ref -m "replay night checkpoints" HEAD "$parent"
git reset -q   # index now matches the last commit; working tree untouched
mv "$log" "$log.replayed-$(date +%Y%m%d%H%M%S)"
git status --short | head -20
