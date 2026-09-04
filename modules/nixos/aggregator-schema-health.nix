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
# ── How the WRITER is named, and why it is NOT looked up on PATH ──
#
# Measured on dellan 2026-08-31 09:50, this unit had NEVER been able to pass,
# on any run, on any machine state:
#
#   aggregator schema health: aggregator recall health UNVERIFIED
#   the aggregator WRITER's schema version could not be determined (looked at
#   no `aggregator` on PATH).
#
# A systemd unit starts from a near-empty environment. This unit's PATH is the
# NixOS default for user units — coreutils, findutils, gnugrep, gnused,
# systemd — and no `aggregator` has ever been on it. The probe falls back to a
# PATH search when it is not told which writer to look at, that search found
# nothing every single time, and the whole check therefore reported UNVERIFIED
# by construction. A detector that is structurally incapable of a healthy
# verdict is worse than no detector: it occupies the slot.
#
# So the writer is NAMED, as `${pkgs.aggregator}/bin/aggregator`, via the
# probe's own AGGREGATOR_WRITER_BIN override. Three candidates were weighed:
#
#   * `/etc/profiles/per-user/jonathan/bin/aggregator` hard-coded — spells a
#     username, so it is wrong for any other user and wrong on a fresh machine
#     until that user's profile has been populated at least once. It is also a
#     DIFFERENT FACT from the one that matters: the profile entry is what a
#     human types, not what stamps the cache.
#   * putting the profile directory on PATH — keeps the ambient dependency and
#     makes it worse, because it turns a deterministic answer into a search. With
#     two aggregators reachable the search order silently decides which one gets
#     called "the writer", and a detector that reports a WRONG number is strictly
#     worse than one that reports a missing one.
#   * naming the derivation — chosen. `aggregator-ingest-timer.nix` execs
#     `lib.getExe pkgs.aggregator`; this is the same expression, so the probe
#     measures the writer that actually stamps the cache BY CONSTRUCTION rather
#     than by coincidence. Being in this unit's own closure, it cannot be missing
#     while the unit exists — the same argument the ingest timer makes when it
#     drops its checkout guard — which holds on a fresh machine and across every
#     rebuild, with no activation ordering to get right.
#
# THIS IS NOT the "take it from ${aggregator-src}" alternative rejected above,
# though it looks identical at a glance. That rejection is about where the
# PROBE — the predicate, the thing that decides — comes from; a predicate
# shipped from the writer's pin goes stale with the writer and is blind to
# exactly this class of skew. What is taken from the pin here is the SUBJECT
# being measured, and the subject must be the pin: measuring anything else
# measures a writer that is not the one stamping the cache.
#
# ── Exit semantics: UNVERIFIED is a FAILURE, not a success ──
#
# The same 2026-08-31 run recorded `ExecMainStatus=0`, `Result=success`. Every
# probe verdict — writer behind, cache dead, could-not-measure — fell through
# to one `exit 0`. So `OnFailure=` never fired, systemd recorded three days of
# green, and paired with the 24h toast debounce a permanently broken detector
# was completely silent. That is the identical shape of the incident this unit
# was built to catch, reproduced inside the catcher.
#
# The probe's exit code is now the UNIT's exit code, passed through verbatim:
# 0 fine, 10 writer behind, 20 recall dead, 30 could not measure. Only a
# VERIFIED-healthy run exits 0, which is the "unknown schema => warn, never
# 'fine'" rule this system already follows, expressed where systemd can see it.
# Passing the code through rather than collapsing to `exit 1` also carries the
# verdict to the OnFailure unit in $MONITOR_EXIT_STATUS and to an operator in
# `systemctl show -p ExecMainStatus`, with no journal parsing — and it keeps 1
# and 2 free to mean "the detector itself is broken", which is the convention
# schema_probe.py's own exit-code table states.
#
# ── ...without becoming an hourly OnFailure siren ──
#
# The opposite failure is real: an hourly `notify-send -u critical` from
# OnFailure is a channel an operator mutes, and a muted channel is the silence
# we started from. Two things are deliberately NOT the same kind of signal:
#
#   * the unit's FAILED STATE is a level. It costs nothing to be permanent, it
#     is exactly the durable machine-readable signal that was missing, and it
#     is not debounced.
#   * the TOAST is an edge, and it is what would spam. Before this change the
#     OnFailure notifier had no debounce at all, so simply exiting non-zero
#     would have made things worse, not better.
#
# So the notifier now suppresses on two grounds. First, it is verdict-aware:
# the health script stamps its own $INVOCATION_ID whenever it announces, and
# the notifier compares that against $MONITOR_INVOCATION_ID (systemd sets it
# for OnFailure= units; verified on dellan — the two ids match exactly). If the
# check already spoke about this very run, the notifier journals one line and
# does NOT re-toast the same fault; its reason to exist is the case where the
# check was killed, timed out, or died before saying anything. Second, that
# remaining case carries its own 24h stamp, so even a detector that is down for
# a week toasts once a day. Both fail OPEN — an absent or unreadable marker
# toasts — because an undelivered warning is recoverable and a suppressed one
# is the whole incident.
#
# Net per standing fault: one toast per 24h, unchanged; plus a unit that stays
# `failed` and a journal line every tick, which are the channels that were
# missing. And the toast is not the only reader — a Claude session learns the
# same verdict from the SessionStart hook that runs this same probe, so a
# background failure reaches the agent that can fix it without a human relaying
# it.
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

  # The WRITER under test: the exact derivation aggregator-ingest.service
  # execs (`lib.getExe pkgs.aggregator` in aggregator-ingest-timer.nix), not
  # whatever a PATH search happens to turn up. See the header section on how
  # the writer is named for why this is a store path and not a profile entry.
  writerBin = lib.getExe pkgs.aggregator;

  healthScript = pkgs.writeShellApplication {
    name = "aggregator-schema-health";
    # findutils is NOT optional and was NOT here: the debounce below calls
    # `find`, which lives in findutils, never in coreutils. It resolved only
    # because the NixOS default user-unit PATH happens to carry findutils and
    # writeShellApplication appends that PATH rather than replacing it — i.e.
    # by luck, through the same ambient channel that left the writer
    # unresolvable. Named explicitly so it cannot go the same way.
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.libnotify pkgs.python3 ];
    text = ''
      set -uo pipefail

      # Resolved at runtime, never spelled literally — see the header. The
      # probe ships in the aggregator repo; the checkout it lives in is the
      # one the MCP reader runs from, which the probe itself rediscovers from
      # ~/.claude.json. This path only has to find the probe FILE.
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/aggregator"
      stamp="$state_dir/schema-skew-notified"
      # The OnFailure notifier's own 24h stamp, cleared here on recovery —
      # see clear_stamps().
      down_stamp="$state_dir/detector-down-notified"
      # Written whenever this script ANNOUNCES, so the OnFailure notifier can
      # tell "the check spoke and then failed on its verdict" from "the check
      # died without saying anything" — the only case its toast is for.
      spoke_marker="$state_dir/last-announced-invocation"
      probe="''${AGGREGATOR_SCHEMA_PROBE:-$HOME/Repos/aggregator/aggregator/health/schema_probe.py}"

      notify() {
        # Journal FIRST and unconditionally: a headless boot or a session with
        # no notification daemon must still leave a diagnosable record, and
        # the journal marker is what the VM lane asserts on because it works
        # without a notification daemon.
        echo "aggregator schema health: $1"
        echo "$2"

        # Recorded here, NOT after the toast: "announced" means the journal
        # has it, which is the channel that cannot fail. A verdict whose toast
        # was debounced away has still been announced, and the OnFailure
        # notifier must not toast about it a second time.
        mkdir -p "$state_dir" || true
        printf '%s\n' "''${INVOCATION_ID:-none}" > "$spoke_marker" || true

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
        #
        # Exit 30, the probe's own UNKNOWN code, and not the ad-hoc 1 this
        # used to be: "the probe file is absent" IS could-not-measure, so it
        # should be indistinguishable from every other could-not-measure to
        # anything reading the exit status. It also leaves 1 and 2 meaning
        # "the detector itself crashed", which is the distinction
        # schema_probe.py's exit-code table is built around.
        notify "aggregator recall health UNVERIFIED" \
          "The schema-skew probe is missing at $probe, so whether aggregator recall works is unknown. It ships in the aggregator repo at aggregator/health/schema_probe.py."
        exit 30
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
        # Healthy — and VERIFIED healthy, which after this change is the only
        # thing that exits 0. Silent by design: a detector that speaks every
        # hour is one nobody reads on the hour it matters. Clear both debounce
        # stamps so the NEXT incident is announced immediately rather than
        # being suppressed by one left over from the last. The detector-down
        # stamp is cleared from HERE because its own notifier never sees a
        # healthy run — OnFailure only ever fires on failure — which is the
        # gap mkFailureNotify has upstream and this unit can close.
        rm -f "$stamp" "$down_stamp" "$spoke_marker" || true
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

      # THE VERDICT IS THE EXIT STATUS. This was `exit 0`, which is how a
      # detector that had never once been able to pass still recorded
      # Result=success on every run for a day and never fired OnFailure. An
      # UNVERIFIED or unhealthy result must be distinguishable to systemd from
      # a verified-healthy one, and this is where that happens.
      exit "$rc"
    '';
  };

  # Backstop for the detector itself dying — python missing from the closure,
  # the script killed, the run reaped by TimeoutStartSec, the script unable to
  # start at all. Reachable ONLY through OnFailure (no wantedBy, so it is
  # `static` and nothing can pull it in on its own).
  #
  # Now that an unhealthy VERDICT also fails the unit, this script runs in two
  # situations that want opposite treatment, and telling them apart is its main
  # job. See the header's OnFailure-siren section.
  healthFailureNotifyScript =
    pkgs.writeShellScript "aggregator-schema-health-failure-notify" ''
      set -uo pipefail

      echo "aggregator-schema-health FAILED (result=''${MONITOR_SERVICE_RESULT:-unknown} status=''${MONITOR_EXIT_STATUS:-unknown}) — inspect: journalctl --user -u aggregator-schema-health.service -n 100"

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/aggregator"
      spoke_marker="$state_dir/last-announced-invocation"
      down_stamp="$state_dir/detector-down-notified"

      # (1) Did the check already speak about THIS run? It stamps its own
      # $INVOCATION_ID whenever it announces, and systemd hands us the
      # triggering unit's invocation id in $MONITOR_INVOCATION_ID (verified on
      # dellan: the two ids are byte-identical). Matching ids mean the verdict
      # is already in the journal and already toasted under its own 24h
      # debounce, so a second critical toast about the same fault would be pure
      # nag — and nag is what gets a channel muted.
      #
      # Exact rather than heuristic on purpose. Branching on the exit status
      # instead would misread the one case that matters most: a script that
      # dies under `set -e` BEFORE announcing also exits non-zero with
      # result=exit-code, and suppressing the toast there would silence the
      # detector-is-down report entirely.
      #
      # Fails OPEN in every direction — unset id, unreadable marker, no match —
      # because an extra toast is recoverable and a swallowed one is the
      # incident.
      spoke=""
      if [ -n "''${MONITOR_INVOCATION_ID:-}" ] && [ -r "$spoke_marker" ]; then
        spoke="$(cat "$spoke_marker" 2>/dev/null)" || spoke=""
      fi
      if [ -n "$spoke" ] && [ "$spoke" = "''${MONITOR_INVOCATION_ID:-}" ]; then
        echo "the check announced its own verdict for this run (invocation $spoke) — already in the journal above and toasted under its own 24h debounce; not raising a second notification"
        exit 0
      fi

      # (2) The check died without saying anything. This IS the case worth a
      # toast, and it gets its own 24h debounce so a detector that is down for
      # a week reports once a day rather than every hour. Cleared by the health
      # script on the next verified-healthy run, which is the recovery path
      # OnFailure notifiers structurally cannot have.
      if [ -n "$(${pkgs.findutils}/bin/find "$down_stamp" -mmin -1440 2>/dev/null)" ]; then
        echo "desktop notification suppressed — already notified within 24h (stamp: $down_stamp). Failure is in the journal above."
        exit 0
      fi

      if ${notifyCommand} -u critical -a aggregator \
        "aggregator recall detector FAILED" \
        "aggregator-schema-health could not complete, so nothing is currently watching whether recall works. Inspect: journalctl --user -u aggregator-schema-health.service -n 100"; then
        ${pkgs.coreutils}/bin/mkdir -p "$state_dir" 2>/dev/null
        ${pkgs.coreutils}/bin/touch "$down_stamp" 2>/dev/null
      else
        # Not arming the debounce on an undelivered popup: a toast nobody saw
        # must not buy a day of silence, so the next failing tick tries again.
        echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal only. NOT arming the 24h debounce."
      fi
    '';
in
{
  systemd.user.services.aggregator-schema-health = {
    description = "Aggregator: cache/reader/writer schema-skew check";
    unitConfig.OnFailure = "aggregator-schema-health-failure-notify.service";
    environment = {
      # Names the writer instead of leaving the probe to search a PATH that
      # has never contained it — the defect measured 2026-08-31 that made a
      # healthy verdict unreachable on every run. Set on the UNIT rather than
      # exported inside the script so `systemctl --user show -p Environment`
      # is the single place an operator (and tests/base.nix) reads which
      # writer is under test. See the header for why this derivation and not
      # a profile path.
      AGGREGATOR_WRITER_BIN = writerBin;
    };
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
