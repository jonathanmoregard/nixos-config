{ config, pkgs, lib, ... }:
# research-agent dev container — long-running "hot" worker.
#
# The research-agent MCP server (spawned by Claude Code via the
# home/research-agent-mcp.nix wrapper) doesn't run the agent itself —
# it docker-execs into a named container for each call. That container
# must already be up; this module makes that happen declaratively at
# boot, mirroring the .devcontainer/{devcontainer.json,Dockerfile}
# upstream pattern from VS Code's Dev Containers plugin.
#
# Lifecycle:
#  1. docker daemon active (virtualisation.docker.enable in docker.nix).
#  2. research-agent-container.service waits for docker.service +
#     network-online.
#  3. ExecStartPre builds the image from
#     ~/Repos/research-agent/.devcontainer/Dockerfile if the local repo
#     exists and the image is missing/stale.
#  4. ExecStart runs `docker run` with --rm in foreground so systemd
#     owns the container's lifetime — `--rm` cleans up on stop, restart
#     re-creates.
#
# Container internals: the entrypoint runs init-firewall.sh (iptables
# allowlist for the outbound proxy) then `tail -f /dev/null` to keep
# alive. Each `research()` call from the MCP server `docker exec`s a
# fresh bubblewrap jail via scripts/run-agent.sh, so per-call isolation
# is intact even though the container itself is long-lived.
#
# Prereq: ~/Repos/research-agent must exist on disk (personal clone,
# not nix-managed). Service fails loudly if absent.
{
  systemd.services.research-agent-container = {
    description = "research-agent dev container (long-running worker for MCP exec)";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.docker pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gawk ];

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "10s";
      # systemd kills the foreground `docker run` on stop. --rm in the
      # docker invocation ensures the container is reaped cleanly.
      TimeoutStopSec = "30s";
    };

    script = ''
      set -euo pipefail

      REPO=/home/jonathan/Repos/research-agent
      IMG=research-agent:latest
      NAME=research-agent

      if [ ! -f "$REPO/.devcontainer/Dockerfile" ]; then
        echo "research-agent repo missing at $REPO — clone it first" >&2
        # Don't tight-loop on a missing-prereq state.
        sleep 60
        exit 1
      fi

      # Build (or rebuild on Dockerfile change). Layer cache makes
      # incremental builds cheap; first build pulls the Ubuntu 24.04
      # base (~500MB) and is slow.
      dockerfile_mtime=$(stat -c %Y "$REPO/.devcontainer/Dockerfile")
      built_iso=$(docker inspect "$IMG" --format '{{.Created}}' 2>/dev/null || echo "")
      if [ -z "$built_iso" ]; then
        built_mtime=0
      else
        built_mtime=$(date -d "$built_iso" +%s 2>/dev/null || echo 0)
      fi
      if [ "$dockerfile_mtime" -gt "$built_mtime" ]; then
        echo "Building $IMG from $REPO/.devcontainer/..."
        docker build -t "$IMG" -f "$REPO/.devcontainer/Dockerfile" "$REPO/.devcontainer"
      fi

      # Clean up any leftover container from a previous run.
      if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
        docker rm -f "$NAME" >/dev/null || true
      fi

      mkdir -p "$REPO/reports"

      # Foreground run. --rm so stop = clean teardown; --init for
      # proper PID 1; security-opt mirrors devcontainer.json so bwrap
      # inside the container can use --unshare-user / --cap-add=NET_ADMIN.
      exec docker run --rm \
        --name "$NAME" \
        -v "$REPO":/workspace \
        -v "$REPO/reports":/out \
        --init \
        --cap-add=NET_ADMIN \
        --security-opt=seccomp=unconfined \
        --security-opt=apparmor=unconfined \
        "$IMG"
    '';
  };
}
