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

# Sparse file via truncate, not fallocate: `fallocate -l 60G` reserves the
# whole image upfront and cold-ENOSPCs at job start on images with a smaller
# /mnt. truncate materialises only metadata and grows as paths are written.
#
# Two failure modes bound the size, from opposite directions:
#
#   Too small — a flat 60G was the binding limit, not the disk. On PR #407
#   (voquill joins the host closure, so CI compiles a Tauri app plus
#   whisper.cpp twice) the image grew to its full 60G and 288 `No space left
#   on device` lines killed `build tuxedo toplevel` and four VM lanes, while
#   the runner still had 29G free. Spending idle headroom costs nothing,
#   because the file is sparse.
#
#   Over-committed — some runner image rollouts collapse /mnt onto /dev/root.
#   There an image larger than its own backing filesystem does not ENOSPC
#   inside the loopback; it exhausts ROOT. The first casualty is the runner's
#   own worker process writing _diag: it dies without logging, so the build
#   step's retry loop never reaches attempt 2 and even the `always()` disk
#   report never runs. The job then reports a failure with no error message
#   anywhere in it.
#
# So size from free space, and apply the historical 60G floor only where
# over-committing stays contained — a real /mnt disk, where overrunning the
# image gives ENOSPC inside the loopback and nix reports it like any other
# build failure. On the collapsed shape the image never exceeds what the
# filesystem can spare.
# The reserve differs by shape. On a real /mnt disk only the build temp dirs
# share the filesystem — ci.yml sets TMPDIR=/mnt/tmp and /tmp is bind-mounted
# onto /mnt, so an unreserved cap would just move the ENOSPC into cargo's and
# cmake's scratch space. On the collapsed shape the runner's own agent and its
# _diag writes live there too, so hold back more.
RESERVE_SEPARATE_K=$((10 * 1024 * 1024))
RESERVE_COLLAPSED_K=$((12 * 1024 * 1024))
BASELINE_K=$((60 * 1024 * 1024))  # the historical cap, kept as a minimum
ADVISORY_K=$((20 * 1024 * 1024))  # warn below this, but do not refuse: a capped
                                  # image can only ENOSPC inside the loopback,
                                  # so trying and failing legibly beats refusing
                                  # a build that would have fitted

sudo mkdir -p /mnt

# Classify with the same tool that measures, and treat an unreadable answer as
# collapsed: "separate" is the guess that over-commits. `stat -c %d` is not
# usable here — btrfs subvolumes report distinct st_dev on one filesystem, and
# a failed stat compares unequal, both of which read as "separate".
mnt_src=$(df --output=source /mnt 2>/dev/null | tail -1 | tr -d ' ' || true)
root_src=$(df --output=source / 2>/dev/null | tail -1 | tr -d ' ' || true)
if [ -n "$mnt_src" ] && [ -n "$root_src" ] && [ "$mnt_src" != "$root_src" ]; then
  shape=separate
  reserve_k=$RESERVE_SEPARATE_K
else
  shape=collapsed
  reserve_k=$RESERVE_COLLAPSED_K
  if [ -z "$mnt_src" ] || [ -z "$root_src" ]; then
    echo "::warning::could not identify the filesystem backing /mnt; assuming it shares the root filesystem"
  fi
fi

avail_k=$(df --output=avail -k /mnt | tail -1 | tr -d ' ')
case "$avail_k" in
  '' | *[!0-9]*)
    echo "::error::could not read available space on the filesystem backing /mnt (got '${avail_k}')"
    df -h / /mnt
    exit 1
    ;;
esac

size_k=$((avail_k - reserve_k))
if [ "$size_k" -le 0 ]; then
  echo "::error::/mnt has only $((avail_k / 1024 / 1024))G available, below the $((reserve_k / 1024 / 1024))G reserved for the runner and build temp dirs; no room for a /nix image at all"
  df -h / /mnt
  exit 1
fi

if [ "$shape" = separate ]; then
  if [ "$size_k" -lt "$BASELINE_K" ]; then
    size_k=$BASELINE_K
  fi
else
  echo "::warning::/mnt shares the root filesystem on this runner; /nix image held to $((size_k / 1024 / 1024))G ($((avail_k / 1024 / 1024))G avail, $((reserve_k / 1024 / 1024))G reserved) so it cannot exhaust root"
fi

if [ "$size_k" -lt "$ADVISORY_K" ]; then
  echo "::warning::/nix image is only $((size_k / 1024 / 1024))G; recent closures have needed more, so expect ENOSPC inside the loopback"
fi

echo "/mnt avail ${avail_k}K; sizing /nix image at ${size_k}K (${shape} /mnt)"
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
