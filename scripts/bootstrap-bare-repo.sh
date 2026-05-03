#!/usr/bin/env bash
# scripts/bootstrap-bare-repo.sh — convert ~/Repos/nixos-config from a
# symlink (to /etc/nixos) into a bare repo, with worktrees as the only way
# to obtain a working tree.
#
# Pre-flight refuses to proceed on uncommitted/unpushed/stashed/untracked
# work to prevent silent loss.
#
# Run interactively, NOT autonomously. Destructive on first run.

set -euo pipefail

OLD=~/Repos/nixos-config           # currently a symlink to /etc/nixos
ETC=/etc/nixos                     # the actual checkout
BARE=~/Repos/nixos-config

# 1. Pre-flight: refuse if uncommitted, unpushed, stashed, or untracked
cd "$ETC"
if [ -n "$(git status --porcelain)" ]; then
  echo "abort: $ETC has uncommitted/untracked changes" >&2
  git status --short >&2
  exit 1
fi
if git stash list | grep -q .; then
  echo "abort: $ETC has stashed changes; pop or drop first" >&2
  exit 1
fi
# Find any local branch not in origin/
local_only=$(git for-each-ref --format='%(refname:short)' refs/heads/ \
  | while read -r b; do
      git rev-parse --verify "origin/$b" >/dev/null 2>&1 || echo "$b"
    done)
if [ -n "$local_only" ]; then
  echo "abort: local-only branches not on origin (push or delete first):" >&2
  echo "$local_only" >&2
  exit 1
fi
# Confirm all local branches at-or-behind their tracking branches
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  if [ -n "$(git log "origin/$b..$b" --oneline 2>/dev/null)" ]; then
    echo "abort: branch $b has unpushed commits" >&2
    exit 1
  fi
done

# 2. Convert. /etc/nixos is root-owned → use sudo.
sudo systemctl stop nixos-deploy.service 2>/dev/null || true
git clone --bare git@github.com:jonathanmoregard/nixos-config.git "${BARE}.new"
sudo rm "$OLD"   # the symlink
mv "${BARE}.new" "$BARE"
git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
mkdir -p ~/Repos/nixos-config-worktrees
git -C "$BARE" worktree add ../nixos-config-worktrees/main main

# 3. /etc/nixos is now disconnected from ~/Repos. It will be reconverted
# in step B (see scripts/bootstrap-deploy-target.sh) into its own
# root-owned clone.
echo "Bare conversion done. Run scripts/bootstrap-deploy-target.sh next."
