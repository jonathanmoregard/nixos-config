{ config, lib, pkgs, ... }:
# Zero-downtime machinery for the research-agent egress-broker switchover
# (research-agent docs/egress-broker.md §12): the drained VM roll, the
# research-slot files it locks, the deploy-era marker the MCP server
# reads, and the G3 gate script.
#
# Why a roll at all: microvm.nix restarts a declarative VM whenever its
# guest toplevel changes (restartIfChanged, default true), i.e. in the
# middle of whatever research call is running. Both VMs now set
# restartIfChanged = false, so a switch only re-links
# /var/lib/microvms/<vm>/current; this unit then restarts the VM at an
# idle moment:
#
#   1. need:    current != booted (a guest change is pending), or, for the
#               scraper, its GET /health says `stale` (the scraper compares
#               the code it loaded with the code on its share; root never
#               hashes or runs checkout content);
#   2. drain:   flock every research slot, keeping each one won while it
#               waits for the next (research() callers poll their slot for
#               up to 1800 s, so held slots delay calls, never fail them);
#               the scraper additionally waits for its /health to report
#               0 open sessions and 0 un-pulled artifacts, for at most
#               scraperQuietSeconds; past that it releases every slot,
#               exits 0 and arms research-vm-roll-retry-scraper.timer
#               (calls must never wait past their 1800 s slot budget);
#   3. mark:    /run/research-agent/rolling — the watchdogs skip their
#               probe while it exists AND this unit is running;
#   4. restart: systemctl restart microvm@<vm> (its own graceful ExecStop);
#   5. ready:   research VM: sshd answers for `agent`; scraper: /health ok;
#   6. release: marker and slots.
# A guest that never comes back keeps the marker and the slots (queued
# calls wait instead of dialling a dead VM) and notifies; the roll keeps
# polling and releases as soon as it answers.
let
  cfg = config.researchAgent;
  checkout = "/home/jonathan/Repos/research-agent";
  lockDir = "/home/jonathan/.cache/research-agent";
  vms = [ "research-agent" "scraper" ];

  rollScript = pkgs.writeShellApplication {
    name = "research-vm-roll";
    runtimeInputs = with pkgs; [
      coreutils findutils util-linux systemd curl jq openssh
    ];
    text = ''
      inst=''${1:?instance}
      case "$inst" in
        research-agent|scraper) ;;
        *) echo "research-vm-roll: unknown instance $inst" >&2; exit 2 ;;
      esac

      STATE=/var/lib/microvms/$inst
      LOCK_DIR=${lockDir}
      SLOTS=${toString cfg.slots}
      MARKER=/run/research-agent/rolling
      OWN=/run/research-vm-roll/$inst/marked
      STAMP=/var/lib/research-vm-roll/$inst.fingerprint
      NOTIFY=/run/microvm-healthcheck-notify/roll-$inst
      QUIET=${toString cfg.roll.scraperQuietSeconds}
      READY_TIMEOUT=${toString cfg.roll.readyTimeoutSeconds}
      PENDING_NOTIFY_S=86400
      RESEARCH_VM_KEY=${config.age.secrets.research-agent-host-key.path}
      HOST_PUB=/var/lib/research-agent/vm-ssh/ssh_host_ed25519_key.pub

      log() { echo "research-vm-roll@$inst: $*"; }
      notify() {
        log "NOTIFY: $*"
        date +%s > "$NOTIFY" 2>/dev/null || true
      }

      # ---- marker: /run/research-agent is jonathan's dir, so never write
      # through a name there (a planted symlink would aim root's write).
      # mktemp is O_EXCL, rename replaces a symlink rather than following
      # it, unlink never follows.
      mark() {
        local tmp
        if tmp=$(mktemp /run/research-agent/.rolling.XXXXXX) && mv -fT "$tmp" "$MARKER"; then
          : > "$OWN"
        else
          rm -f "''${tmp:-}"
          log "could not set $MARKER; the watchdog may count probes during the restart"
        fi
      }
      unmark() {
        if [ -e "$OWN" ]; then rm -f "$MARKER" "$OWN"; fi
      }

      # ---- slots
      FDS=()
      release_all() {
        local fd
        for fd in "''${FDS[@]}"; do exec {fd}<&-; done
        FDS=()
      }
      cleanup() { unmark; release_all; }
      trap cleanup EXIT
      trap 'exit 143' TERM INT

      config_error() {
        notify "$1"
        exit 1
      }

      acquire_all() {
        local i f fd real owner started notified=0
        started=$(date +%s)
        for ((i = 0; i < SLOTS; i++)); do
          f=$LOCK_DIR/agent.lock.$i
          # Never create a slot file: whoever creates it owns it, and the
          # MCP's O_RDWR open of a root-owned 0600 file fails EACCES —
          # every research call would fail. systemd-tmpfiles creates them
          # owned by jonathan; a missing one is a configuration error.
          if [ -L "$f" ] || [ ! -f "$f" ]; then
            config_error "slot file $f is missing or not a regular file (systemd-tmpfiles creates it, owned by jonathan); not creating it as root"
          fi
          # O_RDONLY, no O_CREAT: flock needs no write access.
          exec {fd}<"$f" || config_error "cannot open slot file $f"
          FDS+=("$fd")
          # Check what was actually opened, not the name: a swapped-in
          # symlink would have been followed by the open.
          real=$(readlink "/proc/$$/fd/$fd")
          owner=$(stat -L -c %U "/proc/$$/fd/$fd")
          if [ "$real" != "$f" ] || [ "$owner" != jonathan ]; then
            config_error "slot file $f resolves to $real owned by $owner; expected jonathan's own file"
          fi
          if ! flock -n -x "$fd"; then
            log "waiting for slot $i (a run holds it; keeping slots 0..$((i - 1)))"
            while ! flock -x -w 60 "$fd"; do
              log "still waiting for slot $i"
              if [ "$notified" = 0 ] && [ $(( $(date +%s) - started )) -ge "$PENDING_NOTIFY_S" ]; then
                notify "roll pending for over 24 h: slot $i never became free"
                notified=1
              fi
            done
          fi
          log "holding slot $i"
        done
      }

      # ---- state probes
      vm_state() { systemctl show -P ActiveState "microvm@$inst.service"; }
      link() { readlink "$STATE/$1" 2>/dev/null || echo none; }
      # Only for today's scraper, whose /health has no `stale`: has
      # anything under scraper/ changed since this unit last restarted it?
      # Metadata only (name, size, mtime, inode) — root reads no checkout
      # content — and compared only with its own earlier output, so there
      # is no second implementation to drift from.
      fingerprint() {
        (cd ${checkout} && find scraper -type f ! -name '*.pyc' ! -path '*/__pycache__/*' \
           -printf '%p %s %T@ %i\n' 2>/dev/null | LC_ALL=C sort | sha256sum | cut -d' ' -f1) || echo none
      }
      health() { curl -fsS -m 5 http://127.0.0.1:8123/health 2>/dev/null; }

      REASON=""
      need() {
        local st h
        st=$(vm_state)
        if [ "$st" != active ]; then
          log "not needed: microvm@$inst is $st (it boots current when started)"
          return 1
        fi
        if [ "$(link current)" != "$(link booted)" ]; then
          REASON="current $(link current) != booted $(link booted)"
          return 0
        fi
        if [ "$inst" != scraper ]; then
          log "not needed: booted == current"
          return 1
        fi
        if ! h=$(health); then
          log "not needed as far as can be told: scraper /health unreachable"
          return 1
        fi
        case "$(jq -r 'if (.stale | type) == "boolean" then .stale else "legacy" end' <<<"$h" 2>/dev/null || echo bad)" in
          true)
            REASON="scraper reports stale code"
            return 0 ;;
          false)
            log "not needed: scraper reports it runs the code on disk"
            return 1 ;;
          legacy)
            # Today's scraper: no `stale`. Roll if scraper/ changed since
            # this unit last restarted it (or it never has).
            if [ "$(fingerprint)" != "$(cat "$STAMP" 2>/dev/null || echo none)" ]; then
              REASON="legacy scraper (no stale field); scraper/ changed since its last drained restart"
              return 0
            fi
            log "not needed: legacy scraper, scraper/ unchanged since its last drained restart"
            return 1 ;;
          *)
            log "not needed as far as can be told: unparseable /health"
            return 1 ;;
        esac
      }

      # Scraper: idle by its own account. 0 = idle (or legacy, after the
      # cap), 1 = not idle within the cap.
      scraper_idle() {
        local start now verdict
        start=$(date +%s)
        while :; do
          verdict=bad
          if h=$(health); then
            verdict=$(jq -r '
              if (.open_sessions | type) == "number" and (.pending_artifacts | type) == "number" then
                (if .open_sessions == 0 and .pending_artifacts == 0 then "idle" else "busy \(.open_sessions) \(.pending_artifacts)" end)
              elif has("open_sessions") or has("pending_artifacts") then "bad"
              else "legacy" end' <<<"$h" 2>/dev/null || echo bad)
          fi
          now=$(date +%s)
          case "$verdict" in
            idle)
              log "scraper idle: 0 open sessions, 0 pending artifacts"
              return 0 ;;
            legacy)
              # Today's scraper reports no counters, so its idleness cannot
              # be observed. Every slot is held (no run, so no session can
              # open); restart after holding them for the cap.
              if [ $((now - start)) -ge "$QUIET" ]; then
                log "legacy scraper (no idle counters): every slot held for ''${QUIET}s, treating as idle"
                return 0
              fi ;;
          esac
          if [ $((now - start)) -ge "$QUIET" ]; then
            log "scraper not idle after ''${QUIET}s ($verdict); releasing every slot and deferring the roll"
            return 1
          fi
          sleep 2
        done
      }

      ready() {
        local h
        if [ "$inst" = research-agent ]; then
          ssh-keyscan -t ed25519 -p 2223 -T 10 127.0.0.1 2>/dev/null | grep -q ' ssh-ed25519 ' || return 1
          local kh=/run/research-vm-roll/$inst/known_hosts
          if [ -r "$HOST_PUB" ]; then
            printf '[127.0.0.1]:2223 %s\n' "$(cut -d' ' -f1,2 "$HOST_PUB")" > "$kh"
          else
            ssh-keyscan -t ed25519 -p 2223 -T 10 127.0.0.1 2>/dev/null > "$kh" || return 1
          fi
          ssh -F /dev/null -i "$RESEARCH_VM_KEY" -p 2223 \
            -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh" \
            agent@127.0.0.1 true </dev/null >/dev/null 2>&1
        else
          h=$(health) || return 1
          jq -e '.status == "ok"' <<<"$h" >/dev/null 2>&1 || return 1
          # A fresh boot loaded whatever the checkout held at that moment;
          # stale right after it means the code changed again during the
          # restart. Readiness is "serving", not "current": holding every
          # slot over a stale flag would turn it into an outage. The loop
          # below rolls again.
          if jq -e '.stale == true' <<<"$h" >/dev/null 2>&1; then
            log "scraper is up but already reports stale code (changed during the restart)"
          fi
          return 0
        fi
      }

      roll() {
        local deadline notified=0
        mark
        log "all $SLOTS slots held; restarting microvm@$inst ($REASON)"
        CUR_AT_RESTART=$(link current)
        FP_AT_RESTART=""
        if [ "$inst" = scraper ]; then FP_AT_RESTART=$(fingerprint); fi
        timeout "$READY_TIMEOUT" systemctl restart "microvm@$inst.service" \
          || log "restart job did not finish cleanly; waiting for readiness anyway"
        if [ "$inst" = scraper ]; then
          printf '%s\n' "$FP_AT_RESTART" > "$STAMP.tmp" && mv -f "$STAMP.tmp" "$STAMP"
        fi
        deadline=$(( $(date +%s) + READY_TIMEOUT ))
        until ready; do
          if [ "$notified" = 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
            notify "microvm@$inst not ready ''${READY_TIMEOUT}s after a drained restart; holding every slot and the marker until it is"
            notified=1
          fi
          sleep 5
        done
        log "ready"
        unmark
        release_all
        log "released"
      }

      # A roll is deferrable, a research call is not: callers wait up to
      # 1800 s for a slot, exactly the scraper's artifact TTL, so holding
      # every slot until a crashed run's artifacts expire would turn queued
      # calls into "research backend busy" errors. The idle wait is
      # therefore capped at scraperQuietSeconds; past it every slot is
      # released and the roll ends, to be retried by the retry timer (or
      # the next path trigger). Pending for over 24 h across such retries
      # notifies once.
      PENDING_SINCE=/var/lib/research-vm-roll/$inst.pending-since
      PENDING_NOTIFIED=/var/lib/research-vm-roll/$inst.pending-notified
      defer() {
        release_all
        local since
        [ -s "$PENDING_SINCE" ] || date +%s > "$PENDING_SINCE"
        since=$(cat "$PENDING_SINCE" 2>/dev/null || date +%s)
        if [ ! -e "$PENDING_NOTIFIED" ] && [ $(( $(date +%s) - since )) -ge "$PENDING_NOTIFY_S" ]; then
          notify "roll of microvm@$inst pending for over 24 h: the scraper has not been idle for ''${QUIET}s at any attempt"
          : > "$PENDING_NOTIFIED"
        fi
        systemctl restart "research-vm-roll-retry-$inst.timer" \
          || log "could not arm research-vm-roll-retry-$inst.timer; the next path trigger retries"
        log "deferred; every slot released; retrying in ''${QUIET}s"
        exit 0
      }

      rolls=0
      while need; do
        rolls=$((rolls + 1))
        log "roll needed: $REASON"
        acquire_all
        if [ "$inst" = scraper ] && ! scraper_idle; then defer; fi
        roll
        # Re-check only for a change that landed during this roll (its
        # trigger was swallowed while this unit ran).
        if [ "$(link current)" = "$CUR_AT_RESTART" ] \
          && { [ "$inst" != scraper ] || [ "$(fingerprint)" = "$FP_AT_RESTART" ]; }; then
          break
        fi
        if [ "$rolls" -ge 3 ]; then
          log "changed again during 3 consecutive rolls; leaving it to the next trigger"
          break
        fi
      done
      rm -f "$PENDING_SINCE" "$PENDING_NOTIFIED"
    '';
  };

  # Backstop for a roll killed outright (SIGKILL skips the EXIT trap).
  unmarkScript = pkgs.writeShellScript "research-vm-roll-unmark" ''
    if [ -e "/run/research-vm-roll/$1/marked" ]; then
      ${pkgs.coreutils}/bin/rm -f /run/research-agent/rolling "/run/research-vm-roll/$1/marked"
    fi
  '';

  # G3 (§12.6): may the contract step (nixos-B) merge? Only when no MCP
  # process able to take the legacy path is alive, and none took it lately.
  protocheck = pkgs.writers.writePython3Bin "research-mcp-protocheck"
    { flakeIgnore = [ "E501" ]; } ''
    """research-mcp-protocheck: gate G3 of the egress-broker switchover.

    Passes (exit 0) only when
      1. every live research-agent MCP python process of this user has a
         protocol marker $XDG_RUNTIME_DIR/research-agent-mcp/<pid> holding
         exactly its own kernel start tick (written by the dual-mode
         server.py; a pre-pull process writes none; a missing, unreadable,
         malformed or mismatching marker fails),
      2. server.log (with its rotations) reaches back over the whole window
         and holds no `mode=legacy` dial inside it.
    Run as jonathan.
    """
    import argparse
    import os
    import re
    import sys
    import time

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window-hours", type=float, default=24.0)
    args = ap.parse_args()

    uid = os.getuid()
    rundir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{uid}"
    markers = os.path.join(rundir, "research-agent-mcp")
    log = os.environ.get("RESEARCH_AGENT_LOG") or os.path.expanduser(
        "~/.cache/research-agent/server.log")
    failures = []
    passed = []


    def is_mcp(argv):
        if not argv or not os.path.basename(argv[0]).startswith(b"python"):
            return False
        if any(a.endswith(b"research-agent-mcp-bootstrap.py") for a in argv):
            return True
        return any(a == b"-m" and b == b"mcp_server.server" for a, b in zip(argv, argv[1:]))


    def start_ticks(pid):
        # Field 22 of /proc/<pid>/stat (clock ticks since boot); comm may
        # hold spaces and parens, so split after the last ')'. Same parse
        # as research-agent mcp_server/mcp_marker.py, which writes it.
        with open(f"/proc/{pid}/stat", encoding="ascii", errors="replace") as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])


    for pid in sorted((p for p in os.listdir("/proc") if p.isdigit()), key=int):
        try:
            if os.stat(f"/proc/{pid}").st_uid != uid:
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
            if not is_mcp([a for a in argv if a]):
                continue
            ticks = start_ticks(pid)
        except (FileNotFoundError, ProcessLookupError):
            continue  # gone: not live
        except (OSError, IndexError, ValueError) as e:
            # A process of this user we cannot read is not proven new.
            failures.append(f"pid {pid}: unreadable ({type(e).__name__}); cannot prove it is not legacy-capable")
            continue
        # Live only on an exact start-time match (fail closed): the
        # marker holds the start tick its writer read for itself, so a
        # reused PID or a rewritten marker cannot pass, whatever its mtime
        # or the wall clock says.
        marker = os.path.join(markers, pid)
        try:
            with open(marker, encoding="ascii") as f:
                recorded = int(f.read().strip())
        except FileNotFoundError:
            failures.append(f"pid {pid}: no protocol marker {marker} (pre-pull server.py, legacy-capable)")
            continue
        except (OSError, ValueError, UnicodeDecodeError) as e:
            failures.append(f"pid {pid}: marker {marker} unreadable or malformed ({type(e).__name__})")
            continue
        if recorded != ticks:
            failures.append(f"pid {pid}: marker {marker} records start tick {recorded}, process started at {ticks} (reused PID or stale marker)")
            continue
        passed.append(pid)

    cutoff = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - args.window_hours * 3600))
    stamp = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d{3} ")
    legacy = re.compile(r"(^|\s)mode=legacy(\s|$)")
    oldest = None
    hits = []
    for path in [log] + [f"{log}.{i}" for i in range(1, 10)]:
        try:
            f = open(path, encoding="utf-8", errors="replace")
        except FileNotFoundError:
            continue
        with f:
            for line in f:
                m = stamp.match(line)
                if not m:
                    continue
                ts = m.group(1)
                if oldest is None or ts < oldest:
                    oldest = ts
                if ts >= cutoff and legacy.search(line):
                    hits.append(f"{path}: {line.rstrip()}")
    if oldest is None or oldest > cutoff:
        failures.append(f"{log}: covers {'nothing' if oldest is None else 'only since ' + oldest}, not the whole {args.window_hours:g} h window (since {cutoff})")
    for h in hits:
        failures.append(f"mode=legacy dial inside the window: {h}")

    for p in passed:
        print(f"ok   pid {p}: protocol marker present")
    for msg in failures:
        print(f"FAIL {msg}")
    print("G3 PASS" if not failures else "G3 FAIL")
    sys.exit(1 if failures else 0)
  '';
in
{
  options.researchAgent = {
    slots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Concurrent research VM slots: the MCP wrapper's RESEARCH_SLOTS, the
        slot files systemd-tmpfiles creates, and how many the drained roll
        locks. One value so the three never disagree.
      '';
    };
    legacyPaths = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Transition switch of the egress-broker switchover (research-agent
        docs/egress-broker.md §12.1), not a feature flag. true (expand):
        the research VM keeps its keyed API hosts, the scraper's :8123 and
        the scraper-token share next to the broker, and the era file says
        `legacy-ok`, so MCP processes running old code keep working.
        false (contract): broker only, era `broker-only`.
      '';
    };
    roll = {
      scraperQuietSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          Safety cap, not the criterion: how long the scraper roll holds
          every slot waiting for /health to report 0 open_sessions and 0
          pending_artifacts before it gives every slot back and defers
          (exit 0; research-vm-roll-retry-scraper.timer retries after as
          long again). Must stay well under the MCP's 1800 s slot wait.
          Also how long it holds them before
          restarting a scraper that reports no counters (today's code).
        '';
      };
      readyTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = ''
          After a drained restart, how long until a VM that is still not
          ready raises a notification. The roll keeps holding the slots
          and keeps waiting either way.
        '';
      };
    };
  };

  config = {
    # Read first by the dual-mode MCP server (§12.4): `legacy-ok` admits
    # the legacy protocol, `broker-only` refuses it whatever the broker's
    # state. A deploy-state fact, root-owned, never a liveness probe.
    # A copied regular file, not the default /etc/static symlink: the
    # server opens it O_NOFOLLOW, and a symlink reads as `era-unreadable`,
    # failing every dial closed.
    environment.etc."research-agent/egress-era" = {
      text = if cfg.legacyPaths then "legacy-ok" else "broker-only";
      mode = "0444";
    };

    environment.systemPackages = [ protocheck ];

    # The slot files, owned by jonathan (see acquire_all above). `d` on the
    # two dirs keeps the chain jonathan's on a fresh host instead of
    # letting tmpfiles create a missing parent as root; the modes are what
    # the live host already has.
    systemd.tmpfiles.rules = [
      "d /home/jonathan/.cache 0755 jonathan users -"
      "d ${lockDir} 0700 jonathan users -"
    ] ++ map (i: "f ${lockDir}/agent.lock.${toString i} 0600 jonathan users -")
      (lib.range 0 (cfg.slots - 1));

    microvm.vms = lib.genAttrs vms (_: { restartIfChanged = false; });

    systemd.services = {
      "research-vm-roll@" = {
        description = "Drained restart of microVM %i";
        # Re-check after every re-link, whoever made it.
        after = [ "install-microvm-%i.service" ];
        # A running roll holds every slot and may be mid-restart: a switch
        # must not kill it.
        restartIfChanged = false;
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          # exec, not oneshot: the instances are wanted by microvms.target,
          # and a switch's start of that target must not wait for an idle
          # window.
          Type = "exec";
          User = "root";
          ExecStart = "${rollScript}/bin/research-vm-roll %i";
          ExecStopPost = "${unmarkScript} %i";
          StateDirectory = "research-vm-roll";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "research-vm-roll/%i";
          RuntimeDirectoryMode = "0700";
        };
      };
    } // lib.genAttrs (map (vm: "research-vm-roll@${vm}") vms) (_: {
      overrideStrategy = "asDropin";
      # Every switch starts microvms.target, which re-runs install-microvm
      # (the re-link of `current`) and then this. Needed at the switch that
      # introduces the path units below: they may start watching after
      # that switch's re-link already happened.
      wantedBy = [ "microvms.target" ];
    });

    systemd.paths = lib.genAttrs (map (vm: "research-vm-roll-${vm}") vms) (name:
      let vm = lib.removePrefix "research-vm-roll-" name; in {
        wantedBy = [ "paths.target" ];
        pathConfig = {
          Unit = "research-vm-roll@${vm}.service";
          # The switch re-links `current`; for the scraper also its code,
          # which only a restart of scraper-http loads (virtiofs carries no
          # host inotify into the guest). Watch the state DIRECTORY, not
          # `current`: on a symlink, PathChanged triggers only for events
          # on the followed target (systemd src/core/path.c, primary_wd),
          # and a re-link replaces the link without touching any target.
          # The directory also changes on every VM start (`booted`,
          # sockets); those runs end at "not needed".
          PathChanged = [ "/var/lib/microvms/${vm}" ]
            ++ lib.optional (vm == "scraper") "${checkout}/scraper";
        };
      });

    # Retry for a deferred scraper roll (not idle within the cap). Not
    # wanted by anything: only the roll arms it (`systemctl restart`
    # re-arms OnActiveSec), so an idle host runs no periodic checks.
    systemd.timers.research-vm-roll-retry-scraper = {
      description = "Retry a deferred drained roll of microVM scraper";
      timerConfig = {
        OnActiveSec = "${toString cfg.roll.scraperQuietSeconds}s";
        AccuracySec = "1s";
        Unit = "research-vm-roll@scraper.service";
      };
    };

    # Notifications: root writes a timestamp, the user session shows it
    # (same channel as the watchdogs' give-up notice).
    systemd.user.paths = lib.genAttrs (map (vm: "research-vm-roll-notify-${vm}") vms) (name:
      let vm = lib.removePrefix "research-vm-roll-notify-" name; in {
        wantedBy = [ "default.target" ];
        pathConfig.PathChanged = "/run/microvm-healthcheck-notify/roll-${vm}";
      });
    systemd.user.services = lib.genAttrs (map (vm: "research-vm-roll-notify-${vm}") vms) (name:
      let vm = lib.removePrefix "research-vm-roll-notify-" name; in {
        description = "Desktop notification: drained roll of microVM ${vm} is stuck";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "research-vm-roll-notify-${vm}" ''
            ${pkgs.libnotify}/bin/notify-send -u critical "${vm} VM roll stuck" \
              "Research calls are queued behind a drained restart of ${vm}. Inspect: journalctl -u research-vm-roll@${vm}.service"
          '';
        };
      });
  };
}
