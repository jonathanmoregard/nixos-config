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

# Sparse file via truncate, not fallocate: `fallocate -l 60G` reserves
# the whole 60GB upfront and cold-ENOSPCs at job start on images with a
# smaller /mnt. truncate materialises only metadata and grows as paths
# are written.
#
# But a sparse image larger than its backing filesystem does not fail
# gracefully when /mnt IS the root filesystem (some runner image
# rollouts collapse it onto /dev/root). The image grows until ROOT is
# exhausted, and the first casualty is the runner's own worker process
# writing _diag: it dies without logging, so the build step's retry loop
# never reaches attempt 2 and even the `always()` disk report never runs.
# The job then reports a failure with no error message anywhere in it.
#
# So cap the image at what the backing filesystem can actually spare.
# Overrunning a correctly-sized image gives ENOSPC *inside* the loopback,
# which surfaces as an ordinary nix build error with the runner intact.
# Over-committing is only dangerous on the collapsed-/mnt shape, so the
# cap applies there and nowhere else: on a real /mnt disk the sparse image
# may exceed it freely, because ENOSPC then lands inside the loopback and
# nix reports it like any other build failure.
MARGIN_GIB=12
FLOOR_GIB=20
MAX_GIB=60

sudo mkdir -p /mnt
if [ "$(stat -c %d /mnt)" = "$(stat -c %d /)" ]; then
  avail_gib=$(df -BG --output=avail /mnt | tail -1 | tr -dc '0-9')
  if [ -z "$avail_gib" ]; then
    echo "::error::could not read available space on the filesystem backing /mnt"
    df -h / /mnt
    exit 1
  fi
  img_gib=$(( avail_gib - MARGIN_GIB ))
  if [ "$img_gib" -gt "$MAX_GIB" ]; then
    img_gib=$MAX_GIB
  fi
  if [ "$img_gib" -lt "$FLOOR_GIB" ]; then
    echo "::error::/mnt shares the root filesystem and only ${img_gib}G can be spared for /nix (${avail_gib}G avail, ${MARGIN_GIB}G reserved for the runner); refusing to create an image that would exhaust root mid-build and kill the runner"
    df -h / /mnt
    exit 1
  fi
  echo "::warning::/mnt shares the root filesystem on this runner; /nix image capped at ${img_gib}G (${avail_gib}G avail, ${MARGIN_GIB}G reserved for the runner itself)"
else
  img_gib=$MAX_GIB
fi

echo "sizing /nix image at ${img_gib}G"
sudo truncate -s "${img_gib}G" /mnt/nix.img
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
