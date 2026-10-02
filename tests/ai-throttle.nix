# Not a VM lane: runtime-invocation harness for scripts/ai-throttle.py and
# scripts/host-telemetry.py. Builds fake /sys, cgroup and /proc trees plus a
# fake `systemctl` that records freeze/thaw calls, then drives the scripts'
# `--once` mode tick by tick: heat with hysteresis, battery, a recent
# dictation, an inactive unit, and the telemetry record shape. Seconds.
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
  unit() { mkdir -p $W/units/$1; echo "$2" > $W/units/$1/ActiveState; echo "$3" > $W/units/$1/FreezerState; }
  freezer() { cat $W/units/$1/FreezerState; }
  fail() { echo "FAIL: $*"; exit 1; }

  # Fake systemctl: unit state lives in $W/units/<unit>/{ActiveState,FreezerState};
  # every freeze/thaw is appended to $W/calls.
  cat > $W/bin/systemctl <<'EOF'
  #!${pkgs.bash}/bin/bash
  [ "$1" = --user ] && shift
  cmd=$1; shift
  case $cmd in
    show) u=''${@: -1}
          echo "ActiveState=$(cat $FAKE/units/$u/ActiveState 2>/dev/null || echo inactive)"
          echo "FreezerState=$(cat $FAKE/units/$u/FreezerState 2>/dev/null || echo running)" ;;
    freeze) echo "freeze $1" >> $FAKE/calls; echo frozen > $FAKE/units/$1/FreezerState ;;
    thaw) echo "thaw $1" >> $FAKE/calls; echo running > $FAKE/units/$1/FreezerState ;;
  esac
  EOF
  chmod +x $W/bin/systemctl
  export FAKE=$W PATH=$W/bin:$PATH SYSFS_ROOT=$W/sys CGROUP_ROOT=$W/cg PROC_ROOT=$W/proc
  export AI_THROTTLE_STATE=$W/state.json
  export AI_THROTTLE_UNITS="aggregator-embed.service aggregator-embed-server.service"
  export AI_THROTTLE_FOREGROUND="local-stt.service local-stt-general.service"
  export AI_THROTTLE_PAUSE_AT_C=70 AI_THROTTLE_RESUME_BELOW_C=60
  export AI_THROTTLE_FOREGROUND_HOLD_S=60 AI_THROTTLE_FOREGROUND_CPU_MS=50
  tick() { python3 ${../scripts/ai-throttle.py} --once --now "$1" > $W/last.json; }
  paused() { jq -e '.paused' $W/last.json > /dev/null; }

  unit aggregator-embed.service active running
  unit aggregator-embed-server.service active running
  temp 50; ac 1; stt_usage 1000

  tick 1000
  paused && fail "cool, on mains, nobody dictating: must run"
  [ "$(freezer aggregator-embed.service)" = running ] || fail "froze while cool"

  temp 72; tick 1010
  paused || fail "72 C >= 70 C must pause"
  [ "$(freezer aggregator-embed.service)" = frozen ] || fail "worker not frozen when hot"
  [ "$(freezer aggregator-embed-server.service)" = frozen ] || fail "server not frozen when hot"

  temp 65; tick 1020
  paused || fail "65 C is above the 60 C resume point: must stay paused (hysteresis)"
  temp 59; tick 1030
  paused && fail "59 C is below 60 C: must resume"
  [ "$(freezer aggregator-embed.service)" = running ] || fail "worker not thawed after cooling"

  ac 0; tick 1040
  paused || fail "on battery must pause"
  jq -e '.reasons == ["battery"]' $W/last.json > /dev/null || fail "battery reason missing"
  ac 1; tick 1050
  paused && fail "back on mains must resume"

  # A dictation: 200 ms of STT CPU since the last tick.
  stt_usage 201000; tick 1060
  paused || fail "foreground CPU since last tick must pause"
  tick 1100
  paused || fail "40 s after the dictation is inside the 60 s hold"
  tick 1121
  paused && fail "61 s after the dictation must resume"

  # Idle STT ticking up by a few ms is not a dictation.
  stt_usage 205000; tick 1130
  paused && fail "4 ms of foreground CPU is below the 50 ms threshold"

  # An inactive worker (between timer runs) is never frozen; the server is.
  unit aggregator-embed.service inactive running
  : > $W/calls
  temp 75; tick 1140
  grep -q 'freeze aggregator-embed.service' $W/calls && fail "froze an inactive unit"
  grep -q 'freeze aggregator-embed-server.service' $W/calls || fail "active server not frozen"
  # Already frozen: no repeated freeze calls.
  : > $W/calls; tick 1150
  [ -s $W/calls ] && fail "re-froze an already frozen unit: $(cat $W/calls)"

  # host-telemetry: two samples, the second carries deltas.
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
  [ "$(cat $W/tel/*.jsonl | wc -l)" = 2 ] || fail "expected two telemetry lines"

  echo "ai-throttle: all assertions passed"
  touch $out
''
