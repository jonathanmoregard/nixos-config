{ pkgs, ... }:
# ai-router — the home-manager side of the provider router.
#
# The router itself (CLI, launcher, hooks, skill, the ranking-evidence
# updater) lives in the ~/.claude repo, iterated on outside this flake:
#   ~/.claude/bin/ai-router                        launcher
#   ~/.claude/tools/ai-router/update_ranking.py    ranking-evidence updater
# Nothing here clones or vendors that repo. This module contributes the
# two things only the host config can provide: a PATH entry and a durable
# schedule with a failure path that reaches Claude.
#
# PATH: `~/.claude/bin` is where repo-managed launchers live (`ai-router`
# is the first). Interactive shells need it on PATH so `ai-router pick`
# works as typed; Codex reaches the launchers by absolute path anyway, so
# the entry is for humans and Claude sessions, not for the sync.
#
# Schedule: `ai-router-ranking` is `Type = "oneshot"`, fired daily at
# 08:17 local by a timer with 10-minute jitter and `Persistent = true` so
# a missed tick (laptop suspended, offline) catches up on the next wake.
#
# Guard path, same shape as sota-watch.nix: the updater is NOT present
# on every host that evaluates this module — a fresh install, the test
# VM, or dellan while the ~/.claude PR that ships the script is still
# unmerged. A missing script must not turn the unit red: log a
# "skipping" line, record the skip in the outcome file, exit 0.
#
# Failure must reach Claude, not only the desktop (session constraint,
# 2026-08-31). Measured instance behind that rule: aggregator-embed
# failed on every 30-minute tick for ~5 hours and produced exactly ONE
# toast (24h debounce); no Claude session learned of it because a toast
# reaches Jonathan and nobody else. Earlier, sota-watch sat red for 11
# days (2026-07-17 → 2026-07-28, expired OAuth) with no signal at all.
# So this unit has THREE channels, and the machine-readable one is the
# point:
#   1. `~/.local/state/ai-router/ranking.last-run.json` — written
#      atomically BEFORE the run (finished_at/exit_code null) and again
#      AFTER it. A Claude SessionStart hook (shipped by the ~/.claude PR,
#      not this module) reads it, so the next session sees a failed or
#      skipped run without a human relaying it. A file left with
#      `finished_at: null` means the wrapper died mid-run (killed by
#      TimeoutStartSec, OOM, reboot) — also a signal.
#   2. The journal: the OnFailure notifier's first line is unconditional
#      and names the units + log to inspect (tests/base.nix asserts it).
#   3. `notify-send -u critical`, best-effort — no notification daemon
#      (VM, bare TTY) must not turn the notifier itself red, but the
#      fallback is logged so it is diagnosable.
#
# Store paths, not the user manager's PATH: `writeShellApplication`
# prepends coreutils/libnotify, and python3 is spelled absolutely. The
# user manager's PATH is whatever the session happened to export, which
# is exactly the class of "works on my shell" drift these units exist to
# avoid.
let
  # Single-generation size-cap rotation, same fragment as sota-watch:
  # the runner appends forever otherwise. Roll to .1 past 5 MiB; one
  # backup is plenty for post-hoc triage.
  rotateFragment = logPath: ''
    if [ -f "${logPath}" ] && [ "$(stat -c %s "${logPath}")" -gt 5242880 ]; then
      mv -f -- "${logPath}" "${logPath}.1"
    fi
  '';

  rankingRunner = pkgs.writeShellApplication {
    name = "ai-router-ranking-run";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      LOG_DIR="$HOME/.local/share/ai-router"
      STATE_DIR="$HOME/.local/state/ai-router"
      NOTES_DIR="$HOME/.local/state/claude-tasks/dot-claude"
      SCRIPT="$HOME/.claude/tools/ai-router/update_ranking.py"
      RUNLOG="$LOG_DIR/ranking.log"
      OUTCOME="$STATE_DIR/ranking.last-run.json"

      # The state dir is shared with the router CLI (contract: create on
      # demand, mode 0700 — it holds quota snapshots and job transcripts).
      # NOTES_DIR is where the updater appends its pending_for_human
      # entry; creating it here means a fresh host's first run cannot
      # fail on a missing parent directory instead of on real evidence.
      mkdir -p "$LOG_DIR" "$NOTES_DIR" "$STATE_DIR"
      chmod 0700 "$STATE_DIR"

      ${rotateFragment "$RUNLOG"}

      STARTED_AT="$(date -Iseconds)"

      # Atomic outcome write: tmp file + rename, so a SessionStart hook
      # reading concurrently never sees a torn document. Arguments are
      # JSON literals (null / "2026-…" / 0 / true), never free text.
      write_outcome() {
        printf '{"unit":"ai-router-ranking","started_at":"%s","finished_at":%s,"exit_code":%s,"skipped":%s}\n' \
          "$STARTED_AT" "$1" "$2" "$3" > "$OUTCOME.tmp"
        mv -f -- "$OUTCOME.tmp" "$OUTCOME"
      }

      # BEFORE the run: an in-progress marker. If the wrapper is killed
      # this is what the hook finds, which is itself the signal.
      write_outcome null null false

      if [ ! -f "$SCRIPT" ]; then
        echo "$(date -Iseconds): updater not found at $SCRIPT, skipping" >> "$RUNLOG"
        write_outcome "\"$(date -Iseconds)\"" 0 true
        exit 0
      fi

      # `cmd || rc=$?` keeps the real exit status under `set -e`. NOT
      # `if ! cmd; then rc=$?` — bash zeroes $? after the negation (PR #67
      # incident: a hook lost timeout-vs-failure distinction that way).
      rc=0
      ${pkgs.python3}/bin/python3 "$SCRIPT" \
        --pending "$NOTES_DIR/pending_for_human.md" >> "$RUNLOG" 2>&1 || rc=$?
      write_outcome "\"$(date -Iseconds)\"" "$rc" false
      exit "$rc"
    '';
  };

  failureNotify = pkgs.writeShellApplication {
    name = "ai-router-ranking-failure-notify";
    runtimeInputs = [ pkgs.coreutils pkgs.libnotify ];
    text = ''
      RUNLOG="$HOME/.local/share/ai-router/ranking.log"
      OUTCOME="$HOME/.local/state/ai-router/ranking.last-run.json"

      # Journal marker FIRST and unconditionally — this line is the
      # testable contract (tests/base.nix greps for it) and works
      # headless. The outcome document is echoed too so triage from the
      # journal alone has the exit code and timestamps.
      echo "ai-router ranking updater failed — inspect: journalctl --user -u ai-router-ranking ; tail $RUNLOG ; outcome: $OUTCOME"
      if [ -r "$OUTCOME" ]; then
        echo "last-run outcome: $(cat "$OUTCOME")"
      fi
      if ! notify-send -u critical "ai-router ranking FAILED" \
        "ai-router-ranking.service exited non-zero. Details: journalctl --user -u ai-router-ranking ; tail $RUNLOG"; then
        echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal + $OUTCOME only"
      fi
    '';
  };
in
{
  # Repo-managed launchers. Rendered into hm-session-vars.sh, which the
  # HM zsh module sources from .zshenv, so login and interactive shells
  # both see it (tests/base.nix asserts on a login shell's $PATH).
  home.sessionPath = [ "$HOME/.claude/bin" ];

  systemd.user.services.ai-router-ranking = {
    Unit = {
      Description = "ai-router ranking-evidence updater";
      OnFailure = [ "ai-router-ranking-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${rankingRunner}/bin/ai-router-ranking-run";
      # The updater runs out of the ~/.claude git checkout; bytecode
      # caches there would dirty a tree that is meant to stay clean.
      Environment = "PYTHONDONTWRITEBYTECODE=1";
      # Background maintenance — never compete with an interactive session.
      Nice = 10;
      IOSchedulingClass = "idle";
      # The updater bounds each source fetch itself (--timeout-s); this
      # is the backstop for a hang anywhere else (app-server RPC, DNS).
      # A kill here leaves finished_at null in the outcome file — see the
      # header — and fires OnFailure like any other non-zero exit.
      TimeoutStartSec = "15min";
    };
  };

  # Activated only via OnFailure — no Install section on purpose.
  systemd.user.services.ai-router-ranking-failure-notify = {
    Unit.Description = "Notification: ai-router ranking updater failed";
    Service = {
      Type = "oneshot";
      ExecStart = "${failureNotify}/bin/ai-router-ranking-failure-notify";
    };
  };

  systemd.user.timers.ai-router-ranking = {
    Unit.Description = "ai-router ranking-evidence updater — 08:17 local";
    Timer = {
      OnCalendar = "*-*-* 08:17:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
