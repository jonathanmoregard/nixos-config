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

# Sparse file via truncate, not fallocate. `fallocate -l 60G` reserves
# the full 60GB on /mnt's underlying filesystem upfront — fine on
# ubuntu-latest images where /mnt = /dev/sdb1 with ~70GB free, but
# some image rollouts have collapsed /mnt onto /dev/root, leaving
# only ~47GB free after free-root-disk.sh. fallocate then ENOSPCs
# and the job dies in step 6 (observed on runs 26387387551 attempt 3
# and 26397985441 attempt 1 during the PR #101 stability loop).
# truncate creates a sparse image: only filesystem metadata is
# materialised, actual disk consumed grows as paths are written. The
# cap is enforced by underlying /mnt free space at runtime —
# graceful ENOSPC mid-build instead of cold ENOSPC at job start.
# Works identically on both image variants.
#
# Size the cap from actual free space rather than hardcoding it. A flat
# 60G was the binding limit, not the disk: on PR #407 (voquill joins the
# host closure, so CI compiles a Tauri app plus whisper.cpp twice) the
# image grew to its full 60G and 288 `No space left on device` lines
# killed `build tuxedo toplevel` and four VM lanes — while the runner
# still had 29G free (root went 57G -> 116G of 145G, i.e. 57G baseline
# + the 59G image). Spending that idle headroom costs nothing, because
# the file is sparse.
#
# `max(60G, avail - reserve)` so this can only ever help: the runner
# image whose /mnt collapsed onto /dev/root with ~47G free keeps the
# historical 60G ceiling (unreachable there anyway — the disk binds
# first), while a 145G root variant gets ~78G of real room. The reserve
# is for build temp dirs, which land outside the image on the same
# filesystem: ci.yml sets TMPDIR=/mnt/tmp, and /tmp is bind-mounted onto
# /mnt, so an unreserved cap would just move the ENOSPC into cargo's
# and cmake's scratch space instead.
reserve_k=$((10 * 1024 * 1024))                 # 10 GiB for /mnt/tmp
floor_k=$((60 * 1024 * 1024))                   # never below the old cap
avail_k=$(df --output=avail -k /mnt | tail -1 | tr -d ' ')
size_k=$((avail_k - reserve_k))
[ "$size_k" -lt "$floor_k" ] && size_k="$floor_k"
echo "/mnt avail ${avail_k}K; sizing /nix image at ${size_k}K"
sudo truncate -s "${size_k}K" /mnt/nix.img
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
