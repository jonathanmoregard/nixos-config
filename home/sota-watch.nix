{ pkgs, ... }:
# SOTA-watch daily runner — durable schedule replacing the 7-day Claude
# cron stopgap.
#
# The runner script lives in ~/Repos/sota-watch/runner/run-watch.sh, a
# separate userspace repo iterated on outside this flake. It is NOT
# cloned by the HM activation (deliberate — the SOTA-watch repo carries
# its own state layout and bootstrapping), so on any host without the
# checkout the wrapper here must stay green: log a "skipping" line and
# exit 0. That keeps the systemd unit from going red on VMs, fresh
# installs, or dellan before a manual `git clone` of the sota-watch
# repo.
#
# The unit is `Type = "oneshot"`; timer fires daily at 07:37 local with
# a 10-minute randomised jitter and `Persistent = true` so missed runs
# (suspend, offline) catch up on the next wake.
#
# OnFailure notification: the runner sat red for 11 days (2026-07-17 →
# 2026-07-28, expired OAuth token) and nothing surfaced it — a daily
# oneshot has no user watching its journal. Same direct notify-send
# pattern as the healthcheck user units (research-agent-microvm-
# healthcheck.nix): sota-watch already runs on the user manager, so no
# root→user flag-file hop is needed. The notify script always emits a
# journal marker first (asserted by tests/base.nix, works headless),
# then attempts the desktop notification best-effort — a missing
# notification daemon (VMs, bare TTY) must not turn the notifier
# itself red, but the fallback is logged so it's diagnosable.
let
  failureNotifyScript = pkgs.writeShellScript "sota-watch-failure-notify" ''
    set -uo pipefail

    echo "SOTA-watch runner failed — inspect: journalctl --user -u sota-watch; tail ~/.local/share/sota-watch/run.log"
    if ! ${pkgs.libnotify}/bin/notify-send -u critical "SOTA-watch FAILED" \
      "Daily research runner exited non-zero. Likely: expired Claude OAuth (run: claude /login) or research-agent MCP down. Details: journalctl --user -u sota-watch + ~/.local/share/sota-watch/run.log"; then
      echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal only"
    fi
  '';

  runnerScript = pkgs.writeShellScript "sota-watch-run" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/sota-watch"
    mkdir -p "$LOG_DIR"
    RUNLOG="$LOG_DIR/run.log"
    RUNNER="$HOME/Repos/sota-watch/runner/run-watch.sh"

    # Single-generation size-cap rotation: the runner appends a full
    # claude result JSON (tens of KB) every day forever. Roll to .1 once
    # the log passes 5 MiB so it can't grow unbounded (close-out
    # resource-growth check). One backup is plenty for post-hoc triage.
    if [ -f "$RUNLOG" ] && [ "$(${pkgs.coreutils}/bin/stat -c %s "$RUNLOG")" -gt 5242880 ]; then
      mv "$RUNLOG" "$RUNLOG.1"
    fi

    if [ ! -x "$RUNNER" ]; then
      echo "$(date -Iseconds): runner not found at $RUNNER, skipping" >> "$RUNLOG"
      exit 0
    fi

    exec "$RUNNER" >> "$RUNLOG" 2>&1
  '';
in
{
  # notify-send on the user PATH. The runner's Claude allowlist grants
  # `Bash(notify-send*)` for medium/high findings, but the binary was
  # never in the user profile — every notification attempt since the
  # first run exited 127, silently (only surfaced in the run.log JSON).
  # The OnFailure unit below is immune (absolute store path), but the
  # in-run notification path needs the binary resolvable. tests/base.nix
  # asserts this so the allowlist can't go dead again.
  home.packages = [ pkgs.libnotify ];

  systemd.user.services.sota-watch = {
    Unit = {
      Description = "SOTA-watch daily runner";
      OnFailure = [ "sota-watch-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${runnerScript}";
    };
  };

  # Activated only via OnFailure — no Install section on purpose.
  systemd.user.services.sota-watch-failure-notify = {
    Unit.Description = "Desktop notification: SOTA-watch runner failed";
    Service = {
      Type = "oneshot";
      ExecStart = "${failureNotifyScript}";
    };
  };

  systemd.user.timers.sota-watch = {
    Unit.Description = "SOTA-watch daily runner — 07:37 local";
    Timer = {
      OnCalendar = "*-*-* 07:37:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
