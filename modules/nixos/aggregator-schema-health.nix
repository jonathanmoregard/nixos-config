# Aggregator schema-skew detector — the check that would have caught a
# three-day, completely silent outage of the memory index.
#
# ── The incident ──
#
# Three components share one SQLite cache and each knows only its own half of
# the contract:
#
#   * the READER — `aggregator-mcp`, launched by Claude Code out of the live
#     working tree — opens the cache read-only and refuses every call when
#     `PRAGMA user_version < SCHEMA_VERSION`. It can NEVER migrate: read-only
#     by construction.
#   * the WRITER — `pkgs.aggregator`, what aggregator-ingest.service execs and
#     what `aggregator` on $PATH resolves to — is a uv2nix build of the rev
#     pinned as the `aggregator-src` flake input. It runs `migrate()`, which
#     ENDS by stamping `PRAGMA user_version` with its OWN constant.
#   * the CACHE carries whatever the writer last stamped.
#
# On 2026-08-27 SCHEMA_VERSION went 5 -> 6 upstream. The reader picked it up
# immediately, because it runs from the tree. The pin did not move, so the
# writer stayed at 5, re-stamped `user_version = 5` every thirty minutes, and
# EXITED 0 EVERY TIME. Recall was 100% dead for three days.
#
# ── Why nothing already here caught it, and why this is a new unit ──
#
# aggregator-ingest-timer.nix has two failure channels and this incident
# defeats BOTH, which is the whole reason a third thing has to exist:
#
#   1. `OnFailure=aggregator-ingest-failure-notify.service` fires when the
#      UNIT fails. The unit did not fail. It succeeded, on time, ~every 30
#      minutes, for three days, while destroying the thing it was maintaining.
#      OnFailure cannot see a successful run and never will.
#   2. `AGGREGATOR_NOTIFY_COMMAND`, the aggregator's own in-process notifier,
#      fires on a run that exits 0 but has something to say. This run had
#      nothing to say — by its own lights it ingested 797 new observations
#      into a healthy cache at exactly the schema version it expected.
#
# Both channels report on the RUN. The failure is not in the run; it is in the
# relationship between the run's build and a different build somewhere else on
# the disk. No component holds more than two of the three version numbers, and
# every pair looks healthy from inside — the writer sees cache 5 and itself 5
# and cannot know 6 exists, because the code that would notice was compiled
# from the same stale rev.
#
# So this unit is a fourth thing that holds all three at once. It is also why
# the detector must NOT live inside the ingest run: a detector built from the
# stale pin is blind to exactly the class of skew it is meant to find.
#
# ── Why it does not, and must not, run `aggregator` ──
#
# The aggregator CLI calls `store.migrate()` on every subcommand except
# `embed`, and `migrate()` writes `PRAGMA user_version`. So `aggregator status`
# — the obvious probe, and the command the MCP's own remediation string still
# recommends — is a WRITE that re-stamps the cache at the prober's version.
# Probing with it from the schema-5 build performs the exact damage it is being
# asked to report on and destroys the evidence in the same breath.
#
# The probe therefore opens the cache read-only and reads two source files as
# text. It runs NO subprocesses at all, which also means a writer too broken or
# too wedged to execute is still measurable and cannot hang this unit.
#
# ── Where the probe comes from, and why not from this repo ──
#
# `aggregator/health/schema_probe.py` in the aggregator repo, invoked out of
# the checkout the MCP reader itself runs from. Three alternatives were
# considered and rejected:
#
#   * vendoring the predicate here as shell — then nixos-config and the
#     aggregator each own a copy of "what counts as healthy", and a detector
#     that disagrees with itself about whether the machine is sick is worse
#     than either half alone.
#   * taking it from `${aggregator-src}` — that is the WRITER's pin, the very
#     thing under suspicion. A detector shipped from the stale input goes stale
#     with it, which reintroduces the blindness this unit exists to remove.
#   * hard-coding the checkout path — the reader's location is stated by
#     ~/.claude.json, which is what Claude Code actually executes; a literal
#     here would keep reporting on a checkout the reader had stopped using.
#
# Coupling the probe to the reader's own tree is deliberate and is the correct
# direction: the probe is then exactly as current as the reader whose
# requirement it reports, and if that tree is missing the probe says so rather
# than guessing.
#
# NOTHING BELOW MAY SPELL A PATH UNDER THE HOME DIRECTORY. tests/base.nix greps
# the generated script text for `/home/`, deliberately without parsing shell
# syntax, and asserts the ingest wrapper is free of it. This script resolves
# everything at runtime from $HOME and $XDG_STATE_HOME instead — which is the
# shape that ban's own rationale endorses ("the aggregator resolves those
# itself at runtime from $HOME").
#
# ── Notification: journal always, toast debounced, stamp cleared on recovery ──
#
# Modelled on `mkFailureNotify` in the aggregator repo's own home-manager
# module (nix/aggregator.nix): journal line first and unconditionally, then a
# best-effort `notify-send`, then a 24h debounce stamp armed ONLY after
# notify-send exits 0, failing open on both halves.
#
# Two deliberate departures:
#
#   * ITS OWN STAMP FILE. That module names a shared stamp as a bug and
#     reproduces it; two detectors sharing one stamp means whichever fires
#     first silences the other for a day. This one is `schema-skew-notified`
#     and is touched by nothing else.
#   * THE STAMP IS REMOVED ON RECOVERY. mkFailureNotify has no recovery path,
#     because OnFailure only ever runs on failure. This unit runs on a timer
#     and therefore sees the healthy case too, so it can clear the stamp —
#     without which a fault fixed and re-broken inside 24h would be silently
#     suppressed the second time, and the second time is the one that proves
#     the fix did not hold.
#
# The 24h debounce is right for this fault specifically: it is
# persistent-until-a-human-acts, so an hourly toast would be nagging rather
# than informing, and a nagged operator mutes the channel.
{ config, pkgs, lib, ... }:
let
  # Absolute store path, same reasoning as the ingest timer's
  # AGGREGATOR_NOTIFY_COMMAND: a bare `notify-send` would depend on whatever
  # PATH the user manager happened to inherit.
  notifyCommand = "${pkgs.libnotify}/bin/notify-send";

  # Plain python3 — the probe is stdlib-only BY CONTRACT (a test in the
  # aggregator repo asserts it imports nothing from its own package), so it
  # needs no venv, no uv, and none of the aggregator's dependency closure.
  # Using `uv run` here would both drag in torch and WRITE to the developer's
  # checkout from an unattended unit, which is the defect the 2026-08-16
  # packaging change closed for the ingest timer.
  pythonBin = "${pkgs.python3}/bin/python3";

  healthScript = pkgs.writeShellApplication {
    name = "aggregator-schema-health";
    runtimeInputs = [ pkgs.coreutils pkgs.libnotify pkgs.python3 ];
    text = ''
      set -uo pipefail

      # Resolved at runtime, never spelled literally — see the header. The
      # probe ships in the aggregator repo; the checkout it lives in is the
      # one the MCP reader runs from, which the probe itself rediscovers from
      # ~/.claude.json. This path only has to find the probe FILE.
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/aggregator"
      stamp="$state_dir/schema-skew-notified"
      probe="''${AGGREGATOR_SCHEMA_PROBE:-$HOME/Repos/aggregator/aggregator/health/schema_probe.py}"

      notify() {
        # Journal FIRST and unconditionally: a headless boot or a session with
        # no notification daemon must still leave a diagnosable record, and
        # the journal marker is what the VM lane asserts on because it works
        # without a notification daemon.
        echo "aggregator schema health: $1"
        echo "$2"

        # Debounce. Fails OPEN on an unreadable stamp — if we cannot tell
        # whether we already spoke, speak. A missed toast is recoverable; a
        # suppressed one on a fault nobody knows about is the whole incident.
        if [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
          echo "desktop notification suppressed — already notified within 24h"
          return 0
        fi

        if ${notifyCommand} -u critical -a aggregator "$1" "$2"; then
          # Armed ONLY after a successful send, so a failed notify retries on
          # the next tick instead of being debounced into silence.
          mkdir -p "$state_dir" || true
          touch "$stamp" || true
        else
          echo "notify-send failed (no notification daemon on session bus?) — recorded in journal only"
        fi
      }

      if [ ! -f "$probe" ]; then
        # The detector's own machinery is missing. This is announced, not
        # swallowed: a check that goes quiet when it cannot run is
        # indistinguishable from one reporting good news, and exiting
        # non-zero routes it into OnFailure as a second backstop.
        notify "aggregator recall health UNVERIFIED" \
          "The schema-skew probe is missing at $probe, so whether aggregator recall works is unknown. It ships in the aggregator repo at aggregator/health/schema_probe.py."
        exit 1
      fi

      # The probe's exit code IS the verdict: 0 fine, 10 writer behind
      # (will-rot), 20 cache behind the reader (recall dead now), 30 could not
      # measure. writeShellApplication turns errexit ON by default, which
      # would abort here on every unhealthy verdict — i.e. the detector would
      # die precisely when it had something to report — so it is disabled for
      # this one call and restored immediately after. Deliberately NOT the
      # `if ! cmd; then rc=$?` shape, which bash zeroes (the PR #67 incident).
      set +e
      summary=$(${pythonBin} "$probe" --text 2>&1)
      rc=$?
      set -e

      if [ "$rc" -eq 0 ]; then
        # Healthy. Silent by design — a detector that speaks every hour is one
        # nobody reads on the hour it matters. Clear the debounce so the NEXT
        # incident is announced immediately rather than being suppressed by a
        # stamp left over from the last one.
        rm -f "$stamp" || true
        exit 0
      fi

      case "$rc" in
        20) headline="AGGREGATOR RECALL IS DEAD" ;;
        10) headline="aggregator recall will break on the next ingest tick" ;;
        30) headline="aggregator recall health UNVERIFIED" ;;
        # An exit code this script does not know. Per the rule this whole unit
        # is built on, an unrecognised verdict is announced, never assumed
        # benign — the probe grew a state and this case is how we find out.
        *)  headline="aggregator schema probe returned unrecognised status $rc" ;;
      esac

      notify "$headline" "$summary"
      exit 0
    '';
  };

  # Backstop for the detector itself dying — python missing from the closure,
  # the script unable to start at all. Same shape as the ingest timer's
  # notifier, and reachable ONLY through OnFailure (no wantedBy, so it is
  # `static` and nothing can pull it in on its own).
  healthFailureNotifyScript =
    pkgs.writeShellScript "aggregator-schema-health-failure-notify" ''
      set -uo pipefail

      echo "aggregator-schema-health FAILED to run — the recall detector is itself down; inspect: journalctl --user -u aggregator-schema-health.service -n 100"
      if ! ${notifyCommand} -u critical -a aggregator \
        "aggregator recall detector FAILED" \
        "aggregator-schema-health could not complete, so nothing is currently watching whether recall works. Inspect: journalctl --user -u aggregator-schema-health.service -n 100"; then
        echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal only"
      fi
    '';
in
{
  systemd.user.services.aggregator-schema-health = {
    description = "Aggregator: cache/reader/writer schema-skew check";
    unitConfig.OnFailure = "aggregator-schema-health-failure-notify.service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${healthScript}/bin/aggregator-schema-health";
      # Type=oneshot disables TimeoutStartSec by DEFAULT, so without this a
      # wedged check holds the unit "activating" forever and every later tick
      # silently no-ops — a detector that has stopped detecting while looking
      # scheduled. The probe answers in ~0.2s against a 1.5 GB cache; 2
      # minutes is a runaway bound, not an expected cost.
      TimeoutStartSec = "2min";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Activated only via OnFailure — no wantedBy on purpose.
  systemd.user.services.aggregator-schema-health-failure-notify = {
    description = "Desktop notification: aggregator recall detector failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${healthFailureNotifyScript}";
    };
  };

  systemd.user.timers.aggregator-schema-health = {
    description = "Aggregator: schema-skew check timer (hourly)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Hourly. The skew itself only changes on a deploy or a `git pull`, so
      # this is not a poll of something fast-moving — it is a bound on how
      # long a broken index can sit unnoticed. Paired with the 24h notify
      # debounce, the operator hears about a standing fault once a day while
      # a NEW fault is caught within the hour.
      OnCalendar = "hourly";
      # A laptop that was asleep at the tick still gets checked on wake, and a
      # rebuild that lands mid-hour is caught without waiting for the boundary.
      Persistent = true;
      # Fire shortly after boot so a freshly-deployed host is checked promptly
      # — a deploy is precisely when the writer's pin can change underneath
      # the reader.
      OnBootSec = "10min";
      # Jitter, so this does not land on the same second as every other user
      # timer on this host.
      RandomizedDelaySec = "5min";
    };
  };
}
