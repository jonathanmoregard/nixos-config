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
# Second unit — `sota-watch-refresh-roster` — refreshes the AI power-
# users roster from the source Google Sheet ahead of the research
# runner (fires at 06:47 daily so the 07:37 research pass sees the
# latest roster). Fully deterministic: HTTPS GET → CSV parse → write
# the rendered file, only if content actually changed. No AI, no MCP,
# no credentials — the sheet is publicly viewable via its CSV export
# URL. Nothing is committed: as of 2026-08-10 the sota-watch repo keeps
# its watchlist, config and research output out of git entirely (the
# repo is public and holds the tool, not the data), so the refresh
# writes to an ignored path and stops there.
# Same guard-path semantics: missing runner script → log skip + exit 0.
#
# OnFailure notification: the runner sat red for 11 days (2026-07-17 →
# 2026-07-28, expired OAuth token) and nothing surfaced it — a daily
# oneshot has no user watching its journal. Same direct notify-send
# pattern as the healthcheck user units (research-agent-microvm-
# healthcheck.nix): sota-watch already runs on the user manager, so no
# root→user flag-file hop is needed. Both services share this
# notifier — the message is generic ("SOTA-watch failed") and the
# journal line names the failing unit for triage. The notify script
# always emits a journal marker first (asserted by tests/base.nix,
# works headless), then attempts the desktop notification best-effort
# — a missing notification daemon (VMs, bare TTY) must not turn the
# notifier itself red, but the fallback is logged so it's diagnosable.
let
  failureNotifyScript = pkgs.writeShellScript "sota-watch-failure-notify" ''
    set -uo pipefail

    echo "SOTA-watch runner failed — inspect: journalctl --user -u sota-watch\\* ; tail ~/.local/share/sota-watch/run.log ~/.local/share/sota-watch/refresh-roster.log"
    if ! ${pkgs.libnotify}/bin/notify-send -u critical "SOTA-watch FAILED" \
      "A sota-watch* unit exited non-zero. Likely: expired Claude OAuth (run: claude /login), research-agent MCP down, or sheet fetch failure. Details: journalctl --user -u sota-watch\\* + ~/.local/share/sota-watch/*.log"; then
      echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal only"
    fi
  '';

  # Log-rotation helper shared by both wrappers. Single-generation
  # size-cap rotation: each runner appends output forever otherwise.
  # Roll to .1 once the log passes 5 MiB. One backup is plenty for
  # post-hoc triage. Written as a shell fragment so both wrappers embed
  # it verbatim rather than sharing a runtime file.
  rotateFragment = logPath: ''
    if [ -f "${logPath}" ] && [ "$(${pkgs.coreutils}/bin/stat -c %s "${logPath}")" -gt 5242880 ]; then
      mv "${logPath}" "${logPath}.1"
    fi
  '';

  runnerScript = pkgs.writeShellScript "sota-watch-run" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/sota-watch"
    mkdir -p "$LOG_DIR"
    RUNLOG="$LOG_DIR/run.log"
    RUNNER="$HOME/Repos/sota-watch/runner/run-watch.sh"

    ${rotateFragment "$RUNLOG"}

    if [ ! -x "$RUNNER" ]; then
      echo "$(date -Iseconds): runner not found at $RUNNER, skipping" >> "$RUNLOG"
      exit 0
    fi

    exec "$RUNNER" >> "$RUNLOG" 2>&1
  '';

  refreshRosterScript = pkgs.writeShellScript "sota-watch-refresh-roster" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/sota-watch"
    mkdir -p "$LOG_DIR"
    RUNLOG="$LOG_DIR/refresh-roster.log"
    RUNNER="$HOME/Repos/sota-watch/runner/refresh-roster.sh"

    ${rotateFragment "$RUNLOG"}

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

  systemd.user.services.sota-watch-refresh-roster = {
    Unit = {
      Description = "SOTA-watch AI power-users roster refresh from source sheet";
      OnFailure = [ "sota-watch-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${refreshRosterScript}";
    };
  };

  # Fires 50 min before sota-watch (07:37) so the research runner sees
  # the latest roster. Same 10m jitter + Persistent=true catch-up as
  # the research timer; worst-case gap is comfortably under 40 min.
  systemd.user.timers.sota-watch-refresh-roster = {
    Unit.Description = "SOTA-watch roster refresh — 06:47 local";
    Timer = {
      OnCalendar = "*-*-* 06:47:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
