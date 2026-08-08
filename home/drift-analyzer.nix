{ pkgs, ... }:
# Config-drift detection, hourly. Two units on ONE timer:
#
#   nixos-drift-analyzer      — advisory. Feeds live state + config to
#                               claude and writes a markdown report a
#                               human reads when they feel like it.
#                               Deliberately exits 0 when claude is
#                               missing; nothing depends on it.
#   crontab-drift-check       — deterministic and consequential. Diffs
#                               the LIVE user crontab against the
#                               rendered declaration and opens a PR for
#                               live-only entries. Loud on its own
#                               failure. Script + full rationale in
#                               home/crontab-drift-script.nix.
#
# Why one timer and not two: the checker is pulled in by the analyzer
# service via Wants=, with no ordering dependency, so the two run
# concurrently on the analyzer's hourly schedule. Reusing the existing
# cadence means this host has a single "when do we look for drift?"
# answer rather than two schedules that can silently diverge — and the
# failure mode of a stopped timer is one obviously-dead unit instead of
# a second one nobody remembers exists. Wants= (not Requires=/After=)
# keeps the failure semantics independent in both directions: a red
# crontab check does not fail the analyzer, and the analyzer's
# deliberate exit-0-on-missing-claude cannot mask a real crontab
# failure. tests/base.nix asserts the Wants= line so deleting it (which
# would leave the checker installed but never scheduled — silent death,
# the exact failure class this unit exists to stop) fails CI.
let
  crontabDriftScript = import ./crontab-drift-script.nix { inherit pkgs; };

  # Same shape as sota-watch's notifier (home/sota-watch.nix): journal
  # marker FIRST because it always works headless, then a best-effort
  # desktop notification. A missing notification daemon (VM, bare TTY)
  # must not turn the notifier itself red, but the fallback is logged
  # so it stays diagnosable.
  crontabDriftNotify = pkgs.writeShellScript "crontab-drift-failure-notify" ''
    set -uo pipefail

    echo "crontab-drift-check FAILED — the live-vs-declared crontab check could not do its job. Inspect: journalctl --user -u crontab-drift-check.service"
    if ! ${pkgs.libnotify}/bin/notify-send -u critical "Crontab drift check FAILED" \
      "crontab-drift-check exited non-zero: live crontab drift may be going unfiled. Likely: gh unauthenticated (gh auth login), no network, or the crontab wrapper is missing. Details: journalctl --user -u crontab-drift-check.service"; then
      echo "notify-send failed (no notification daemon on the session bus?) — failure recorded in journal only"
    fi
  '';

  analyzerScript = pkgs.writeShellScript "nixos-drift-analyzer" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/nixos-drift-analyzer"
    mkdir -p "$LOG_DIR"
    LATEST="$LOG_DIR/latest.md"
    RUNLOG="$LOG_DIR/run.log"

    log() { echo "$(date -Iseconds): $*" >> "$RUNLOG"; }

    # claude-code is in home.packages — use it directly
    CLAUDE="${pkgs.claude-code}/bin/claude"
    if [ ! -x "$CLAUDE" ]; then
      log "claude not found at $CLAUDE, skipping"
      exit 0
    fi

    log "starting drift analysis"

    # Live state: imperative installs
    IMPERATIVE=$(${pkgs.nix}/bin/nix-env --query 2>/dev/null | grep -v '^$' || true)

    # Live state: manually dropped binaries
    LOCAL_BIN=$(ls "$HOME/.local/bin" 2>/dev/null | tr '\n' ' ' || true)

    # Inline key nix config files (skip large/generated ones)
    CONFIG=""
    for f in /etc/nixos/flake.nix \
              /etc/nixos/home/jonathan.nix \
              /etc/nixos/home/jonathan-linux.nix \
              /etc/nixos/home/desktop-apps.nix \
              /etc/nixos/home/cinnamon.nix \
              /etc/nixos/modules/nixos/desktop.nix \
              /etc/nixos/hosts/vm/default.nix; do
      if [ -f "$f" ]; then
        CONFIG+="
=== ''${f#/etc/nixos/} ===
$(cat "$f")
"
      fi
    done

    PROMPT="You are a NixOS config drift analyzer running on a live NixOS VM (Linux Mint 22.2 / Cinnamon mirror).
Your goal: find things that will be LOST on the next nixos-rebuild and draft the exact Nix code to capture them.

## Live system state

nix-env imperative installs (lost on rebuild):
''${IMPERATIVE:-none}

~/.local/bin (manually placed, may need home.packages):
''${LOCAL_BIN:-empty}

## Current NixOS config
$CONFIG

## Instructions

1. Compare live state to what is declared in the config.
2. Also flag static patterns that commonly cause drift:
   - ~/.ssh/config, ~/.gnupg/, ~/.config/* paths not managed by home.file or programs.*
   - Service state dirs not persisted (/var/lib/*, ~/.local/share/*)
   - PATH entries or env vars set imperatively that belong in home.sessionVariables
   - TODOs / manual-step comments that could be automated
   - Incomplete autostart, dconf, or MIME declarations
3. For each gap, write the exact Nix snippet to fix it (file + attribute path).
4. Be conservative — only flag things you are confident about from what is visible here.
5. Output a markdown report with:
   - ## Drift Report $(date +%Y-%m-%d)
   - One bullet per finding: problem, then nix code block with the fix
   - If nothing to report: '## No drift detected $(date +%Y-%m-%d)'"

    "$CLAUDE" --print "$PROMPT" > "$LATEST" 2>> "$RUNLOG"
    log "done — report at $LATEST"
  '';
in
{
  home.packages = [ pkgs.claude-code ];

  systemd.user.services.nixos-drift-analyzer = {
    Unit = {
      Description = "NixOS config drift analyzer";
      # Pull the deterministic crontab check onto this timer. No After=
      # — they are independent jobs sharing a cadence, not a pipeline.
      Wants = [ "crontab-drift-check.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${analyzerScript}";
    };
  };

  systemd.user.timers.nixos-drift-analyzer = {
    Unit.Description = "NixOS drift analyzer — hourly";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.crontab-drift-check = {
    Unit = {
      Description = "Live-vs-declared user crontab drift check (PR-gated writer)";
      OnFailure = [ "crontab-drift-check-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      # tests/crontab-drift.nix asserts this ExecStart is byte-identical
      # to the derivation under test — keep both importing the same file.
      ExecStart = "${crontabDriftScript}/bin/crontab-drift-check";
      Nice = 10;
      # DELIBERATELY UNSANDBOXED — do not "harden" this unit.
      #
      # /run/wrappers/bin/crontab is a setuid wrapper, and reading the
      # live crontab needs that elevation. Any sandboxing option that
      # brings no_new_privs with it makes `crontab -l` fail, and the
      # checker then cannot see the live crontab at all — the exact
      # blindness this unit exists to prevent, wearing a security hat.
      #
      # Both probed on dellan, same failure:
      #   systemd-run --user -p NoNewPrivileges=yes \
      #     /run/wrappers/bin/crontab -l
      #   systemd-run --user -p PrivateTmp=yes \
      #     /run/wrappers/bin/crontab -l
      #   → cannot chdir(/var/cron), bailing out.
      #     /var/cron: Permission denied
      #
      # PrivateTmp is the non-obvious one: on a USER unit systemd
      # implements it with an unprivileged user namespace, and entering
      # one sets no_new_privs unconditionally. worktree-sweep sets
      # PrivateTmp=yes safely because it never touches a setuid binary;
      # this unit cannot. Caught by the vm-base lane (2026-08-08) after
      # PrivateTmp was added here on exactly that false analogy.
      #
      # tests/base.nix asserts both options stay absent AND that a real
      # run logs its live-entry count, so a future sandboxing option
      # nobody thought of still fails CI behaviourally.
    };
  };

  # Activated only via OnFailure — no Install section on purpose.
  systemd.user.services.crontab-drift-check-failure-notify = {
    Unit.Description = "Desktop notification: crontab drift check failed";
    Service = {
      Type = "oneshot";
      ExecStart = "${crontabDriftNotify}";
    };
  };
}
