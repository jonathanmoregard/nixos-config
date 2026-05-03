# modules/nixos/ci-state.nix
#
# /var/lib/ci-state — owned by root:actions-runner mode 0775. Stores:
#
#   - ai-approved-merges.jsonl    circuit-breaker history
#   - label-events.jsonl          audit trail of label-add events
#   - snapshots/                  hourly snapshots of ai-approved-merges.jsonl
#                                 (for tamper detection — see D.4)
#
# Declared as a separate module so ownership/permissions are reproducible
# and independent of the runner unit's own state.
{ config, lib, pkgs, ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/ci-state 0775 root actions-runner - -"
    "d /var/lib/ci-state/snapshots 0755 root root - -"
    # Append-only log files. Touched into existence with sane modes;
    # workflows append via runner identity.
    "f /var/lib/ci-state/ai-approved-merges.jsonl 0664 root actions-runner - -"
    "f /var/lib/ci-state/label-events.jsonl       0664 root actions-runner - -"
  ];

  # Hourly snapshot timer. Tamper detection: classifier hashes live file
  # against the latest snapshot's tail; mismatch → engages circuit-breaker
  # on suspicion (logic in classify-pr.sh / label-gate.yml, not here).
  systemd.services.ci-state-snapshot = {
    description = "Snapshot /var/lib/ci-state/ai-approved-merges.jsonl";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "ci-state-snapshot" ''
        set -e
        src=/var/lib/ci-state/ai-approved-merges.jsonl
        dest=/var/lib/ci-state/snapshots/$(date -u +%Y%m%dT%H%M%SZ).jsonl
        cp -a "$src" "$dest"
        # Prune snapshots older than 30 days
        find /var/lib/ci-state/snapshots -type f -mtime +30 -delete
      '';
    };
  };

  systemd.timers.ci-state-snapshot = {
    description = "Hourly CI-state snapshot";
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };
}
