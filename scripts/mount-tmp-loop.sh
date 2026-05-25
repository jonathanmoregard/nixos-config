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
# Idempotent: returns early if /tmp is already a mountpoint.

set -euo pipefail

if mountpoint -q /tmp 2>/dev/null; then
  echo "/tmp is already a mountpoint; nothing to do"
  exit 0
fi

# Preserve anything the runner has already written to /tmp during setup
# (action-runner bootstrap, checkout temp dirs). Copy across, swap, then
# point /tmp at the new location.
sudo mkdir -p /mnt/tmp
sudo chmod 1777 /mnt/tmp
if [ -n "$(sudo ls -A /tmp 2>/dev/null)" ]; then
  sudo cp -a /tmp/. /mnt/tmp/ 2>/dev/null || true
fi
sudo mount --bind /mnt/tmp /tmp
# Re-assert sticky-world after the bind (the underlying dir's mode wins
# for `ls -ld /tmp`, but defensive).
sudo chmod 1777 /tmp
df -h /tmp
