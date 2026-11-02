#!/bin/zsh
# Records the working tree as one pending commit without creating a commit,
# for when commit signing is unavailable (1Password locked overnight).
# Each checkpoint stores a git tree object, its patch and its message in .night/.
# scripts/replay-night-commits.sh later turns them into real signed commits.
# Usage: scripts/night-checkpoint.sh "<conventional commit message>" [paths...]
#   With paths, only those paths are taken from the working tree.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
dir="$root/.night"
mkdir -p "$dir/patches" "$dir/messages"
log="$dir/checkpoints.tsv"
touch "$log"
export GIT_INDEX_FILE="$dir/index"
prev=$(tail -1 "$log" | cut -f1)
[[ -n "$prev" ]] || prev=$(git rev-parse 'HEAD^{tree}')
git read-tree "$prev"
if (( $# > 1 )); then git add -A -- "${@:2}"; else git add -A; fi
tree=$(git write-tree)
if [[ "$tree" == "$prev" ]]; then echo "night-checkpoint: no changes"; exit 0; fi
n=$(printf %03d $(( $(wc -l < "$log") + 1 )))
print -r -- "$1" > "$dir/messages/$n.txt"
git diff-tree -p --binary "$prev" "$tree" > "$dir/patches/$n.patch"
printf "%s\t%s\n" "$tree" "$dir/messages/$n.txt" >> "$log"
echo "night-checkpoint $n $tree $(head -1 "$dir/messages/$n.txt")"
