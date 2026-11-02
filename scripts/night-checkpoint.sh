#!/bin/zsh
# Commits the working tree as one signed commit, one per finished story.
# When signing is unavailable (1Password locked), it records a checkpoint
# instead: a git tree object, its patch and its message in .night/, which a
# later run turns into real signed commits, in order, before its own commit.
# Every commit or checkpoint also leaves .night/patches/NNN.patch for review.
# Usage: scripts/night-checkpoint.sh "<conventional commit message>" [paths...]
#   With paths, only those paths are taken from the working tree.
#   scripts/night-checkpoint.sh --flush only commits pending checkpoints.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
dir="$root/.night"
mkdir -p "$dir/patches" "$dir/messages"
pending="$dir/checkpoints.tsv"
done_log="$dir/committed.tsv"
touch "$pending" "$done_log"

# One writer at a time: several agents may finish a story at once.
until mkdir "$dir/lock" 2>/dev/null; do sleep 0.2; done
trap 'rmdir "$dir/lock"' EXIT

trailer="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
next_number() { printf %03d $(( $(cat "$pending" "$done_log" | wc -l) + 1 )) }
with_trailer() { grep -qF "$trailer" "$1" || print -r -- $'\n'"$trailer" >> "$1" }
can_sign() { git commit-tree -S 'HEAD^{tree}' -p HEAD -m probe >/dev/null 2>&1 }

# Turns pending checkpoints into signed commits on HEAD, keeping their
# recorded author time. The working tree is not touched.
flush() {
  [[ -s "$pending" ]] || return 0
  can_sign || return 1
  local parent tree msg
  parent=$(git rev-parse HEAD)
  while IFS=$'\t' read -r tree msg; do
    with_trailer "$msg"
    parent=$(GIT_AUTHOR_DATE="$(stat -f %Sm -t %Y-%m-%dT%H:%M:%S "$msg")" \
      git commit-tree -S "$tree" -p "$parent" -F "$msg")
    echo "commit $parent $(head -1 "$msg")"
  done < "$pending"
  git update-ref -m "commit night checkpoints" HEAD "$parent"
  git reset -q
  cat "$pending" >> "$done_log"
  : > "$pending"
}

checkpoint() {
  local n=$1 msgfile=$2 prev tree
  shift 2
  export GIT_INDEX_FILE="$dir/index"
  prev=$(tail -1 "$pending" | cut -f1)
  [[ -n "$prev" ]] || prev=$(git rev-parse 'HEAD^{tree}')
  git read-tree "$prev"
  if (( $# > 0 )); then git add -A -- "$@"; else git add -A; fi
  tree=$(git write-tree)
  unset GIT_INDEX_FILE
  if [[ "$tree" == "$prev" ]]; then echo "night-checkpoint: no changes"; rm -f "$msgfile"; return 0; fi
  git diff-tree -p --binary "$prev" "$tree" > "$dir/patches/$n.patch"
  printf "%s\t%s\n" "$tree" "$msgfile" >> "$pending"
  echo "night-checkpoint $n $tree $(head -1 "$msgfile") (signing unavailable; not committed yet)"
}

if [[ "${1:-}" == "--flush" ]]; then flush || { echo "signing unavailable"; exit 1; }; exit 0; fi

n=$(next_number)
msgfile="$dir/messages/$n.txt"
print -r -- "$1" > "$msgfile"
with_trailer "$msgfile"

if ! flush; then checkpoint "$n" "$msgfile" "${@:2}"; exit 0; fi

if (( $# > 1 )); then git add -A -- "${@:2}"; else git add -A; fi
if git diff --cached --quiet; then echo "night-checkpoint: no changes"; rm -f "$msgfile"; exit 0; fi
git diff --cached -p --binary > "$dir/patches/$n.patch"
if ! git commit -q -S -F "$msgfile"; then
  git reset -q
  checkpoint "$n" "$msgfile" "${@:2}"
  exit 0
fi
printf "%s\t%s\n" "$(git rev-parse 'HEAD^{tree}')" "$msgfile" >> "$done_log"
echo "commit $(git rev-parse --short HEAD) $(head -1 "$msgfile")"
