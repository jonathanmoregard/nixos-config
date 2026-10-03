{ pkgs, ... }:
# session-reflect backfill — the Friday drain of quota-dropped reflections.
#
# The drain itself lives in the ~/.claude repo
# (skills/session-reflect/backfill.sh); this module only provides the
# schedule and the failure path, same split as home/ai-router.nix.
#
# Policy (Jonathan, 2026-10-02): on Fridays, before the weekly reset, if the
# weekly and monthly budgets are still ample, work through the backlog of
# SessionEnd reflections a spend cap dropped. The script owns every gate
# (Friday, weekly reset ahead, weekly > 20% left, monthly spend below the
# week-of-month threshold) and re-checks them per item; the timer only
# offers it a chance every hour on Fridays. A tick on a closed gate costs one
# quota read and exits 0.
#
# Guard path: the script is absent on a fresh host, in the test VM, and on
# dellan until the ~/.claude PR merges — log "skipping", exit 0.
#
# Failure reaches Claude (2026-08-31 constraint): the script writes
# ~/.claude/reflections/backfill/last-run.json and the ~/.claude SessionStart
# hook `reflect-backfill-health.py` speaks on a crash, a fail-closed gate or a
# hung run. This unit adds the journal line and a best-effort toast.
#
# PATH: the drain shells out to `claude` (~/.local/bin) and `ai-router`
# (~/.claude/bin) and hands PATH on to the reflection workers it spawns via
# `systemd-run --user`, so both user dirs go in front of the store tools.
let
  runner = pkgs.writeShellApplication {
    name = "session-reflect-backfill-run";
    runtimeInputs = with pkgs; [
      bash coreutils findutils gnugrep gawk jq util-linux python3 systemd
    ];
    text = ''
      LOG_DIR="$HOME/.local/share/session-reflect"
      SCRIPT="$HOME/.claude/skills/session-reflect/backfill.sh"
      RUNLOG="$LOG_DIR/backfill.log"
      mkdir -p "$LOG_DIR"
      if [ -f "$RUNLOG" ] && [ "$(stat -c %s "$RUNLOG")" -gt 5242880 ]; then
        mv -f -- "$RUNLOG" "$RUNLOG.1"
      fi
      export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"

      if [ ! -f "$SCRIPT" ]; then
        echo "$(date -Iseconds): drain not found at $SCRIPT, skipping" >> "$RUNLOG"
        exit 0
      fi
      # `cmd || rc=$?` keeps the real status under set -e (PR #67 lesson).
      rc=0
      echo "$(date -Iseconds): drain start" >> "$RUNLOG"
      bash "$SCRIPT" >> "$RUNLOG" 2>&1 || rc=$?
      echo "$(date -Iseconds): drain exit $rc" >> "$RUNLOG"
      exit "$rc"
    '';
  };

  failureNotify = pkgs.writeShellApplication {
    name = "session-reflect-backfill-failure-notify";
    runtimeInputs = [ pkgs.coreutils pkgs.libnotify ];
    text = ''
      RUNLOG="$HOME/.local/share/session-reflect/backfill.log"
      RECORD="$HOME/.claude/reflections/backfill/last-run.json"
      echo "session-reflect backfill drain failed — inspect: journalctl --user -u session-reflect-backfill ; tail $RUNLOG ; record: $RECORD"
      if [ -r "$RECORD" ]; then
        echo "last-run record: $(cat "$RECORD")"
      fi
      if ! notify-send -u critical "Reflection backfill FAILED" \
        "session-reflect-backfill.service exited non-zero. journalctl --user -u session-reflect-backfill"; then
        echo "notify-send failed (no notification daemon?) — failure recorded in journal + $RECORD only"
      fi
    '';
  };
in
{
  systemd.user.services.session-reflect-backfill = {
    Unit = {
      Description = "Drain quota-dropped session reflections (Fridays, budget-gated)";
      OnFailure = [ "session-reflect-backfill-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${runner}/bin/session-reflect-backfill-run";
      # Background maintenance: the script also paces itself on load and
      # memory; these keep its own processes behind interactive work.
      Nice = 19;
      IOSchedulingClass = "idle";
      # Backstop for a hang. The script records a crash itself; a kill here
      # leaves last-run.json at `started`, which the health hook reports.
      TimeoutStartSec = "3h";
    };
  };

  # Activated only via OnFailure — no Install section on purpose.
  systemd.user.services.session-reflect-backfill-failure-notify = {
    Unit.Description = "Notification: session-reflect backfill drain failed";
    Service = {
      Type = "oneshot";
      ExecStart = "${failureNotify}/bin/session-reflect-backfill-failure-notify";
    };
  };

  systemd.user.timers.session-reflect-backfill = {
    Unit.Description = "session-reflect backfill drain — hourly on Fridays";
    Timer = {
      OnCalendar = "Fri *-*-* *:07:00";
      RandomizedDelaySec = "5m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
