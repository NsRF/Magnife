#!/bin/zsh
# Turns the checkpoints recorded by scripts/night-checkpoint.sh into real,
# signed commits on the current branch, in order, without touching the
# working tree. Run it once with 1Password unlocked.
exec "${0:A:h}/night-checkpoint.sh" --flush
