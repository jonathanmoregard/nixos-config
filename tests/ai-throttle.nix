# Not a VM lane: runtime-invocation harness for scripts/ai-throttle.py and
# scripts/host-telemetry.py. Builds fake /sys, cgroup and /proc trees plus a
# fake `systemctl` that records the SIGSTOP/SIGCONT it is asked to send and a
# fake `xprintidle`, then drives the scripts' `--once` mode tick by tick: the
# duty-cycle governor (duty follows the temperature error, clamps, and runs
# each period as pause-then-run), the idle setpoint, the hard-stop band with
# hysteresis, battery, a recent dictation (by CPU use and by the router's
# record-start hint), an inactive unit, and the telemetry record shape. Seconds.
{ pkgs }:
pkgs.runCommand "ai-throttle-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.jq pkgs.coreutils pkgs.bash ];
} ''
  set -euo pipefail
  W=$PWD/w
  mkdir -p $W/sys/class/hwmon/hwmon0 $W/sys/class/power_supply/AC0 \
           $W/sys/class/drm/card1/device $W/bin $W/units $W/proc/1 \
           $W/cg/user.slice/user@1.service/app.slice/local-stt-general.service \
           $W/cg/user.slice/user@1.service/app.slice/aggregator-embed.service
  echo k10temp > $W/sys/class/hwmon/hwmon0/name
  echo Mains > $W/sys/class/power_supply/AC0/type
  echo 37 > $W/sys/class/drm/card1/device/gpu_busy_percent
  printf '1.5 1.0 0.5 1/1 1\n' > $W/proc/loadavg
  printf 'MemAvailable: 8388608 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' > $W/proc/meminfo
  STT=$W/cg/user.slice/user@1.service/app.slice/local-stt-general.service
  EMB=$W/cg/user.slice/user@1.service/app.slice/aggregator-embed.service

  temp() { echo "$(( $1 * 1000 ))" > $W/sys/class/hwmon/hwmon0/temp1_input; }
  ac() { echo "$1" > $W/sys/class/power_supply/AC0/online; }
  stt_usage() { printf 'usage_usec %s\n' "$1" > $STT/cpu.stat; }
  idle_ms() { printf '%s' "$1" > $W/idle_ms; }
  # unit NAME ACTIVESTATE PROCSTATE PID: one process per unit, its state letter
  # in the fake /proc/<pid>/stat (S running, T stopped).
  unit() {
    mkdir -p $W/units/$1 $W/cg/units/$1 $W/proc/$4
    echo "$2" > $W/units/$1/ActiveState
    echo "$4" > $W/cg/units/$1/cgroup.procs
    echo "$4 (fake) $3 1 1" > $W/proc/$4/stat
  }
  freezer() { pid=$(cat $W/cg/units/$1/cgroup.procs); awk '{print $3}' $W/proc/$pid/stat; }
  fail() { echo "FAIL: $*"; exit 1; }

  # Fake systemctl: ActiveState lives in $W/units/<unit>/ActiveState, the
  # unit's cgroup in $W/cg/units/<unit>; every kill is appended to $W/calls
  # and flips the fake process state like the real signal would.
  cat > $W/bin/systemctl <<'EOF'
  #!${pkgs.bash}/bin/bash
  [ "$1" = --user ] && shift
  cmd=$1; shift
  case $cmd in
    show) u=''${@: -1}
          echo "ActiveState=$(cat $FAKE/units/$u/ActiveState 2>/dev/null || echo inactive)"
          [ -d $FAKE/cg/units/$u ] && echo "ControlGroup=/units/$u" ;;
    kill) sig=''${1#--signal=}; u=$2
          echo "$sig $u" >> $FAKE/calls
          new=S; [ "$sig" = SIGSTOP ] && new=T
          for pid in $(cat $FAKE/cg/units/$u/cgroup.procs); do
            echo "$pid (fake) $new 1 1" > $FAKE/proc/$pid/stat
          done ;;
  esac
  EOF
  chmod +x $W/bin/systemctl
  # Fake xprintidle: prints $W/idle_ms; fails like a session without a display
  # when that file is empty.
  cat > $W/bin/xprintidle <<'EOF'
  #!${pkgs.bash}/bin/bash
  v=$(cat $FAKE/idle_ms 2>/dev/null)
  [ -n "$v" ] || exit 1
  echo "$v"
  EOF
  chmod +x $W/bin/xprintidle
  export FAKE=$W PATH=$W/bin:$PATH SYSFS_ROOT=$W/sys CGROUP_ROOT=$W/cg PROC_ROOT=$W/proc
  export AI_THROTTLE_STATE=$W/state.json
  export AI_THROTTLE_FOREGROUND_HINT=$W/foreground-hint
  export AI_THROTTLE_UNITS="aggregator-embed.service aggregator-embed-server.service"
  export AI_THROTTLE_FOREGROUND="local-stt.service local-stt-general.service"
  export AI_THROTTLE_QUIET_AT_C=65 AI_THROTTLE_IDLE_QUIET_AT_C=75 AI_THROTTLE_IDLE_AFTER_S=900
  export AI_THROTTLE_PAUSE_AT_C=70 AI_THROTTLE_RESUME_BELOW_C=60
  export AI_THROTTLE_PERIOD_S=0.02 AI_THROTTLE_GAIN=0.02 AI_THROTTLE_DUTY_MIN=0.1
  export AI_THROTTLE_FOREGROUND_HOLD_S=60 AI_THROTTLE_FOREGROUND_CPU_MS_PER_S=5
  tick() { python3 ${../scripts/ai-throttle.py} --once --now "$1" > $W/last.json; }
  paused() { jq -e '.paused' $W/last.json > /dev/null; }
  duty() { jq -r '.duty' $W/last.json; }
  state() { cat $W/last.json; }

  unit aggregator-embed.service active S 101
  unit aggregator-embed-server.service active S 102
  temp 50; ac 1; stt_usage 1000; idle_ms 0

  # Governor. Cool: full duty against the quiet setpoint, and full duty sends
  # no signal at all.
  : > $W/calls
  tick 1000
  paused && fail "cool, on mains, nobody dictating: must not be hard-paused"
  jq -e '.duty == 1 and .setpoint_c == 65' $W/last.json > /dev/null \
    || fail "cool machine must run at full duty against the quiet setpoint: $(state)"
  [ -s $W/calls ] && fail "full duty must send no signals: $(cat $W/calls)"
  [ "$(freezer aggregator-embed.service)" = S ] || fail "paused while cool"

  # 3 C over the 65 C setpoint: duty falls by gain x error = 0.02 x 3 per step.
  temp 68; tick 1010
  jq -e '.duty == 0.94' $W/last.json > /dev/null || fail "68 C against 65 C must cut duty to 0.94, got $(duty)"
  # A governed period pauses first and runs last, so a tick ends with the
  # units running and the signals land in that order.
  : > $W/calls; tick 1020
  jq -e '.duty == 0.88' $W/last.json > /dev/null || fail "duty must keep falling while over the setpoint, got $(duty)"
  [ "$(sed -n 1p $W/calls)" = "SIGSTOP aggregator-embed.service" ] || fail "a governed period must start by stopping: $(cat $W/calls)"
  [ "$(tail -n 1 $W/calls)" = "SIGCONT aggregator-embed-server.service" ] || fail "a governed period must end by resuming: $(cat $W/calls)"
  [ "$(freezer aggregator-embed.service)" = S ] || fail "worker must be running when a governed tick ends"
  # Clamps at the floor; the floor is still governed, never a hard pause.
  for t in $(seq 1030 10 1200); do tick $t; done
  jq -e '.duty == 0.1' $W/last.json > /dev/null || fail "duty must clamp at the 0.1 floor, got $(duty)"
  paused && fail "the floor is governed, not hard-paused: $(state)"
  # Under the setpoint: duty climbs back and clamps at 1.
  temp 60; tick 1210
  jq -e '.duty == 0.2' $W/last.json > /dev/null || fail "5 C under the setpoint must raise duty by 0.1, got $(duty)"
  for t in $(seq 1220 10 1300); do tick $t; done
  jq -e '.duty == 1' $W/last.json > /dev/null || fail "duty must clamp at 1, got $(duty)"

  # Idle: nobody at the desk for 15 min -> the idle setpoint governs.
  temp 68; tick 1310
  jq -e '.duty == 0.94 and .idle == false' $W/last.json > /dev/null || fail "present: the quiet setpoint governs: $(state)"
  idle_ms 900000; tick 1320
  jq -e '.idle == true and .setpoint_c == 75 and .duty == 1' $W/last.json > /dev/null \
    || fail "idle 15 min: 68 C is under the 75 C idle setpoint, duty must climb: $(state)"
  idle_ms 899999; tick 1330
  jq -e '.idle == false and .setpoint_c == 65' $W/last.json > /dev/null || fail "14:59 idle is not idle: $(state)"
  # No answer from xprintidle (no display): never idle.
  idle_ms ""; tick 1340
  jq -e '.idle == false and .setpoint_c == 65' $W/last.json > /dev/null || fail "no xprintidle answer must mean present: $(state)"
  idle_ms 0
  temp 50; for t in $(seq 1350 10 1400); do tick $t; done
  jq -e '.duty == 1' $W/last.json > /dev/null || fail "cool again must return to full duty, got $(duty)"

  # Hard-stop band, with hysteresis; the governor is frozen while it holds.
  temp 72; tick 1410
  paused || fail "72 C >= 70 C must pause"
  jq -e '.reasons == ["hot:72.0"] and .duty == 1' $W/last.json > /dev/null || fail "hard pause must carry its reason and freeze duty: $(state)"
  [ "$(freezer aggregator-embed.service)" = T ] || fail "worker not stopped when hot"
  [ "$(freezer aggregator-embed-server.service)" = T ] || fail "server not stopped when hot"
  temp 65; tick 1420
  paused || fail "65 C is above the 60 C resume point: must stay paused (hysteresis)"
  temp 59; tick 1430
  paused && fail "59 C is below 60 C: must resume"
  [ "$(freezer aggregator-embed.service)" = S ] || fail "worker not resumed after cooling"

  ac 0; tick 1440
  paused || fail "on battery must pause"
  jq -e '.reasons == ["battery"]' $W/last.json > /dev/null || fail "battery reason missing"
  ac 1; tick 1450
  paused && fail "back on mains must resume"

  # A dictation: 200 ms of STT CPU in the 10 s since the last tick (20 ms/s).
  stt_usage 201000; tick 1460
  paused || fail "foreground CPU since last tick must pause"
  tick 1500
  paused || fail "40 s after the dictation is inside the 60 s hold"
  tick 1521
  paused && fail "61 s after the dictation must resume"

  # The threshold is a rate, not a count per tick: 14 ms over a 2 s tick is
  # 7 ms/s, over the 5 ms/s threshold, although it is under the 50 ms a 10 s
  # tick used to need.
  stt_usage 215000; tick 1523
  paused || fail "7 ms/s of foreground CPU over a 2 s tick must pause"
  tick 1584
  paused && fail "61 s after light foreground use must resume"

  # Idle STT ticking up by a few ms is not a dictation: 4 ms over 9 s.
  stt_usage 219000; tick 1593
  paused && fail "0.4 ms/s of foreground CPU is below the 5 ms/s threshold"

  # A record-start hint: the local-stt router touches this file when Voquill
  # pings /v1/prepare and at the start of every transcription, before any
  # STT CPU time shows in cpu.stat. A hint older than the hold is history; a
  # fresh one pauses the units on this very tick, as foreground.
  touch -d @1500 $W/foreground-hint; tick 1594
  paused && fail "a hint older than the 60 s hold must not pause: $(state)"
  touch -d @1595 $W/foreground-hint; tick 1596
  paused || fail "a fresh foreground hint must pause within one tick: $(state)"
  jq -e '.reasons == ["foreground"]' $W/last.json > /dev/null || fail "a hint must pause as foreground: $(state)"
  [ "$(freezer aggregator-embed.service)" = T ] || fail "worker not stopped on a fresh hint"
  rm $W/foreground-hint
  # The hold from that hint outlives the next cases; hand them running
  # processes again so they can see their own stop signals.
  unit aggregator-embed.service active S 101
  unit aggregator-embed-server.service active S 102

  # An inactive worker (between timer runs) is never signalled; the server is.
  unit aggregator-embed.service inactive S 101
  : > $W/calls
  temp 75; tick 1600
  grep -q 'SIGSTOP aggregator-embed.service' $W/calls && fail "signalled an inactive unit"
  grep -q 'SIGSTOP aggregator-embed-server.service' $W/calls || fail "active server not stopped"
  # Already stopped: no repeated signals.
  : > $W/calls; tick 1610
  [ -s $W/calls ] && fail "re-signalled an already stopped unit: $(cat $W/calls)"
  # A unit restarted while paused (new process, running) is stopped again.
  unit aggregator-embed.service active S 103; tick 1620
  [ "$(freezer aggregator-embed.service)" = T ] || fail "a new worker run started while paused was not stopped"

  # A hint dated well into the future is a clock step, not a dictation: it
  # must not count (clamped to now it would re-arm every tick until the clock
  # caught up, and the pause would outlast the hold). Inside the tolerance it
  # is just an ordinary fresh hint. The heat pause stays; only the reason moves.
  touch -d @1800 $W/foreground-hint; tick 1700
  jq -e '.reasons | index("foreground") == null' $W/last.json > /dev/null || fail "a hint from the far future must be ignored: $(state)"
  touch -d @1701 $W/foreground-hint; tick 1700
  jq -e '.reasons | index("foreground") != null' $W/last.json > /dev/null || fail "a hint 1 s ahead (clock skew) must still count: $(state)"
  rm $W/foreground-hint

  # host-telemetry: two samples, the second carries deltas and the governor's state.
  export HOST_TELEMETRY_DIR=$W/tel
  printf 'usage_usec 1000000\n' > $EMB/cpu.stat
  python3 ${../scripts/host-telemetry.py} --once > /dev/null
  printf 'usage_usec 4000000\n' > $EMB/cpu.stat
  python3 ${../scripts/host-telemetry.py} --once > $W/tel.json
  jq -e '.tctl_c == 75 and .ac == true and .gpu_busy == 37 and .load1 == 1.5' $W/tel.json > /dev/null \
    || fail "telemetry sensors wrong: $(cat $W/tel.json)"
  jq -e '.mem_avail_gb == 8 and .swap_used_gb == 1' $W/tel.json > /dev/null || fail "telemetry memory wrong"
  jq -e '.cpu_top[0] == ["aggregator-embed.service", 3000]' $W/tel.json > /dev/null \
    || fail "telemetry cpu_top should credit 3000 ms to the embed worker: $(jq -c .cpu_top $W/tel.json)"
  jq -e '.throttle.paused == true and .throttle.reasons[0] == "hot:75.0"' $W/tel.json > /dev/null \
    || fail "telemetry should carry the throttle state: $(jq -c .throttle $W/tel.json)"
  jq -e '.throttle.duty == 1 and .throttle.setpoint_c == 65 and .throttle.idle == false' $W/tel.json > /dev/null \
    || fail "telemetry should carry the governor's duty, setpoint and idle flag: $(jq -c .throttle $W/tel.json)"
  [ "$(cat $W/tel/*.jsonl | wc -l)" = 2 ] || fail "expected two telemetry lines"

  # Daemon mode: the loop logs the governed duty, cycles the units every
  # period, and SIGTERM leaves them running.
  unit aggregator-embed.service active S 101
  unit aggregator-embed-server.service active S 102
  temp 68; ac 1; idle_ms 0; rm -f $W/state.json; : > $W/calls
  AI_THROTTLE_CONTROL_S=0.05 python3 ${../scripts/ai-throttle.py} > $W/daemon.log 2>&1 &
  daemon=$!
  sleep 1
  kill -TERM $daemon
  wait $daemon || fail "daemon must exit 0 on SIGTERM: $(cat $W/daemon.log)"
  grep -q '^duty 0\.' $W/daemon.log || fail "daemon must log a governed duty: $(cat $W/daemon.log)"
  grep -q 'SIGSTOP aggregator-embed.service' $W/calls || fail "daemon never cycled the units"
  [ "$(freezer aggregator-embed.service)" = S ] || fail "SIGTERM must leave the worker running"
  [ "$(freezer aggregator-embed-server.service)" = S ] || fail "SIGTERM must leave the server running"

  # A --once run interrupted in its pause phase leaves the units running too.
  # SIGTERM, not SIGINT: a background job of a non-interactive shell ignores
  # SIGINT, so an INT here would never reach the script.
  unit aggregator-embed.service active S 101
  unit aggregator-embed-server.service active S 102
  temp 68; rm -f $W/state.json; printf '{"duty": 0.1}' > $W/state.json
  AI_THROTTLE_PERIOD_S=3 python3 ${../scripts/ai-throttle.py} --once --now 2000 > $W/once.json 2> $W/once.err &
  once=$!
  sleep 0.5
  kill -TERM $once
  wait $once && once_rc=0 || once_rc=$?
  [ "$(freezer aggregator-embed.service)" = S ] || fail "an interrupted --once left the worker stopped"
  [ "$(freezer aggregator-embed-server.service)" = S ] || fail "an interrupted --once left the server stopped"
  [ "$once_rc" = 0 ] || fail "an interrupted --once must exit 0: $(cat $W/once.err)"

  # The window the governor averages starts when it gets the units back:
  # temperatures sampled during a hard pause (units stopped, 72 C here) do
  # not cut the duty once the pause ends at 59 C. Control steps fall at
  # 0, 2 and 4 s; the pause lasts until 3.5 s, so the 2-4 s window would be
  # three quarters pause-time samples if they counted.
  unit aggregator-embed.service active S 101
  unit aggregator-embed-server.service active S 102
  temp 72; rm -f $W/state.json
  AI_THROTTLE_CONTROL_S=2 python3 ${../scripts/ai-throttle.py} > $W/daemon2.log 2>&1 &
  daemon=$!
  sleep 3.5
  temp 59
  sleep 1.5
  kill -TERM $daemon
  wait $daemon || fail "daemon must exit 0 on SIGTERM: $(cat $W/daemon2.log)"
  grep -q '^paused: hot:72.0' $W/daemon2.log || fail "the daemon never hard-paused at 72 C: $(cat $W/daemon2.log)"
  grep -q '^duty 0\.' $W/daemon2.log && fail "temperatures from the hard pause cut the duty: $(cat $W/daemon2.log)"
  grep -q 'mean 59.0 C' $W/daemon2.log || fail "no control step ran after the hard pause ended: $(cat $W/daemon2.log)"

  echo "ai-throttle: all assertions passed"
  touch $out
''
