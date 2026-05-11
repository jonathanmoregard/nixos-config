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
df -h /nix
