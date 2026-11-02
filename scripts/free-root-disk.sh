#!/usr/bin/env bash
# scripts/free-root-disk.sh — reclaim ~15GB on / before mount-nix-loop.
#
# GitHub-hosted ubuntu runners ship with variable baseline free space on /
# (~10-18GB). The runner worker writes its diagnostic log to / during
# job setup; on unlucky provisioning a fresh runner can OOM the worker
# before any step runs (observed: System.IO.IOException at
# /home/runner/actions-runner/.../_diag/Worker_*.log during step 3).
#
# mount-nix-loop.sh moves /nix onto /mnt — necessary but not sufficient,
# because `/` itself can be starved.
#
# This script scrubs the largest preinstalled toolchains nothing in this
# repo uses. That takes ~2-2.5 min (millions of small files), so it only
# runs when / is short: current images (2026-10) ship / at 145G with
# ~86G free, and the sparse /nix loop plus /tmp peak around 45-55G.

set -euo pipefail

echo "before:"
df -h /

min_free_gb=70
free_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
if [ "$free_gb" -ge "$min_free_gb" ]; then
  echo "/ has ${free_gb}G free (>= ${min_free_gb}G); skipping cleanup"
  exit 0
fi
echo "/ has only ${free_gb}G free (< ${min_free_gb}G); cleaning up"

sudo rm -rf \
  /usr/share/dotnet \
  /usr/share/swift \
  /opt/ghc \
  /usr/local/.ghcup \
  /usr/local/lib/android \
  /usr/local/share/boost \
  /usr/local/share/powershell \
  /opt/hostedtoolcache/CodeQL \
  /opt/hostedtoolcache/PyPy \
  /opt/hostedtoolcache/Ruby \
  /opt/hostedtoolcache/go \
  /opt/microsoft \
  /opt/google \
  /var/cache/apt/archives \
  /var/lib/apt/lists \
  || true

# Stop docker daemon + nuke its overlay store (~3-5 GB on hosted runners,
# pre-pulled images we never use). `sudo` because the daemon socket and
# /var/lib/docker are root-only.
sudo systemctl stop docker.service docker.socket 2>/dev/null || true
sudo rm -rf /var/lib/docker || true

echo "after:"
df -h /
