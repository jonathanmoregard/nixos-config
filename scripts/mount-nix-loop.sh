#!/usr/bin/env bash
# scripts/mount-nix-loop.sh — mount /nix on a /mnt-backed loopback file.
#
# GitHub-hosted ubuntu runners: / has ~14GB free, /mnt has ~70GB. The
# dellan closure is ~8-12GB. Redirecting /nix onto a /mnt-backed loop
# device gives nix room without scrubbing /usr/share/dotnet etc —
# jlumbroso/free-disk-space took ~2.5min per job; this is ~5s.
#
# MUST run BEFORE determinate-nix-action (or any nix install).
#
# Idempotent: returns early if /nix is already a mountpoint.

set -euo pipefail

if mountpoint -q /nix 2>/dev/null; then
  echo "/nix is already a mountpoint; nothing to do"
  exit 0
fi

sudo fallocate -l 60G /mnt/nix.img
sudo mkfs.ext4 -F -E lazy_itable_init=1,lazy_journal_init=1 /mnt/nix.img
sudo mkdir -p /nix
sudo mount -o loop,noatime /mnt/nix.img /nix
# Drop the ext4 lost+found that mke2fs auto-creates. It's root-owned
# mode 700, useless on an ephemeral loopback, and breaks tar runs that
# walk /nix as a non-root user — cache-nix-action's save step is the
# canonical victim ('Cannot open: Permission denied' → tar exits 2 →
# 'Could not save the new cache' → /nix/store never persists between
# runs). Removing the dir is cleaner than chmod-ing it readable.
#
# If rmdir fails (a future runner image pre-populates the dir, or
# mke2fs starts respecting -T no-lost+found), surface the failure
# loudly so the cache regression is grep-able in CI logs. Don't fail
# the step — the breakage is a perf bug, not a correctness one — but
# the warning shows up in the GitHub UI annotation list.
if ! sudo rmdir /nix/lost+found 2>/dev/null; then
  # GHA workflow-command parser only reads STDOUT for ::warning::
  # annotations. Stderr would be logged but not annotate the run.
  echo "::warning::could not rmdir /nix/lost+found; cache-nix-action tar may fail"
  sudo ls -la /nix/lost+found >&2 || true
fi
df -h /nix
