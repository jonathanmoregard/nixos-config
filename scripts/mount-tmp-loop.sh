#!/usr/bin/env bash
# scripts/mount-tmp-loop.sh — bind /tmp onto /mnt-backed dir.
#
# After mount-nix-loop.sh moves /nix off `/`, the remaining root-disk
# writer during VM tests is /tmp:
#   - Nix build sandbox (each derivation gets /tmp/nix-build-*).
#   - QEMU NixOS test runtime (qcow2 VM disks, screenshots, serial
#     logs, captured frames). A single vm-minimal lane can write
#     several GB to /tmp/nix-test-*.
#   - Misc test tooling (mktemp, $RUNNER_TEMP overflow).
#
# Hosted ubuntu runners ship /tmp on `/` (~14 GB free). vm-minimal
# (autodoro) ENOSPC'd here on run 26373588544 (the worker's _diag log
# was the visible crash site; QEMU's qcow2 had already starved the
# disk). Bind-mounting /tmp onto /mnt (~70 GB free) decouples test
# temp space from runner root.
#
# MUST run BEFORE determinate-nix-action AND mount-nix-loop.sh — the
# nix daemon caches TMPDIR at install time. Pair with `env:
# TMPDIR=/mnt/tmp` on the build steps so user tooling agrees with the
# bind mount.
#
# Idempotent: returns early if /tmp already shares the /mnt filesystem.

set -euo pipefail

# Create /mnt/tmp before any early return: the build steps export
# TMPDIR=/mnt/tmp unconditionally, and nix mkdtemp's under $TMPDIR while
# fetching flake inputs, so a missing directory here fails every attempt of
# the retry loop within seconds.
sudo mkdir -p /mnt/tmp
sudo chmod 1777 /mnt/tmp

# When /mnt IS the root filesystem (some runner image rollouts collapse it
# onto /dev/root), binding /tmp onto it moves QEMU's qcow2 files onto the
# very disk this redirection exists to protect. Leave /tmp alone there.
if [ "$(stat -c %d /mnt)" = "$(stat -c %d /)" ]; then
  echo "::warning::/mnt shares the root filesystem on this runner; leaving /tmp in place rather than adding root-disk pressure"
  df -h / /tmp
  exit 0
fi

# Compare filesystems, not mountpoint-ness. Some runner images ship /tmp as
# a ~7.7G tmpfs, and a bare `mountpoint -q /tmp` treats that as already
# done — silently leaving multi-GB VM disks on a RAM-backed filesystem.
if [ "$(stat -c %d /tmp)" = "$(stat -c %d /mnt/tmp)" ]; then
  echo "/tmp already shares the /mnt filesystem; nothing to do"
  exit 0
fi

# Preserve anything the runner has already written to /tmp during setup
# (action-runner bootstrap, checkout temp dirs). Copy across, swap, then
# point /tmp at the new location.
if [ -n "$(sudo ls -A /tmp 2>/dev/null)" ]; then
  sudo cp -a /tmp/. /mnt/tmp/ 2>/dev/null || true
fi
sudo mount --bind /mnt/tmp /tmp
# Re-assert sticky-world after the bind (the underlying dir's mode wins
# for `ls -ld /tmp`, but defensive).
sudo chmod 1777 /tmp
df -h /tmp
