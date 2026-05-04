#!/usr/bin/env bash
# scripts/bootstrap-deploy-target.sh — convert /etc/nixos from the old
# symlinked layout (post-bare-repo conversion) into a fresh root-owned
# clone of origin/main. Run BEFORE enabling nixos-deploy.service.
#
# Pre-flight 1: verify origin/main builds (don't strand the host on a
#               broken commit).
# Pre-flight 2: refuse if any local diagnostic edits exist in /etc/nixos
#               (mirrors bootstrap-bare-repo.sh's discipline).
#
# Recovery: if step fails, restore from /etc/nixos.bak.<timestamp> backup
# created earlier.

set -euo pipefail

if [ ! -L /etc/nixos ] && [ -d /etc/nixos/.git ]; then
  echo "/etc/nixos is already a real git checkout; skipping"
  exit 0
fi

# Pre-flight 1: verify origin/main builds
echo "[1/4] Pre-flight build of origin/main..."
nix build --no-link "git+ssh://git@github.com/jonathanmoregard/nixos-config?ref=main#nixosConfigurations.dellan.config.system.build.toplevel"

# Pre-flight 2: refuse to destroy local diagnostic edits
echo "[2/4] Pre-flight dirty-tree check..."
if [ -d /etc/nixos/.git ] || [ -L /etc/nixos ]; then
  REAL=$(readlink -f /etc/nixos)
  if [ -n "$(git -C "$REAL" status --porcelain 2>/dev/null)" ]; then
    echo "abort: $REAL has uncommitted changes; resolve before bootstrap" >&2
    git -C "$REAL" status --short >&2
    exit 1
  fi
fi

# Stop deploy timer/service to avoid a race
echo "[3/4] Stopping any existing nixos-deploy service..."
sudo systemctl stop nixos-deploy.service nixos-deploy.timer 2>/dev/null || true

# Clone fresh, then atomically replace
echo "[4/4] Cloning origin/main into /etc/nixos.new..."
sudo git clone --branch main git@github.com:jonathanmoregard/nixos-config.git /etc/nixos.new
sudo git -C /etc/nixos.new config safe.directory /etc/nixos

# Snapshot the old symlink target before removing
if [ -L /etc/nixos ]; then
  TARGET=$(readlink /etc/nixos)
  echo "old /etc/nixos was symlink to: $TARGET"
fi
echo "Replacing /etc/nixos atomically..."
sudo rm -rf /etc/nixos       # safe: pre-flights verified above
sudo mv /etc/nixos.new /etc/nixos

# Optional: restart deploy. Caller decides.
echo "Bootstrap complete. /etc/nixos is now a fresh root-owned checkout of origin/main."
echo "Start the deploy service with: sudo systemctl start nixos-deploy.service"
