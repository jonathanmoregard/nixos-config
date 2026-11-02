# Not a VM lane: runtime-invocation harness for scripts/host-telemetry.py.
# Builds fake /sys, cgroup and /proc trees, drives the script's `--once` mode
# twice and checks the sensor fields, the memory fields, the per-unit CPU delta
# between the samples, and that one JSON line is appended per sample. Seconds.
{ pkgs }:
pkgs.runCommand "ai-throttle-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.jq pkgs.coreutils ];
} ''
  set -euo pipefail
  W=$PWD/w
  UNIT=$W/cg/user.slice/user@1.service/app.slice/aggregator-ingest.service
  mkdir -p $W/sys/class/hwmon/hwmon0 $W/sys/class/power_supply/AC0 \
           $W/sys/class/drm/card1/device $W/proc $UNIT
  echo k10temp > $W/sys/class/hwmon/hwmon0/name
  echo 75000 > $W/sys/class/hwmon/hwmon0/temp1_input
  echo Mains > $W/sys/class/power_supply/AC0/type
  echo 1 > $W/sys/class/power_supply/AC0/online
  echo 37 > $W/sys/class/drm/card1/device/gpu_busy_percent
  printf '1.5 1.0 0.5 1/1 1\n' > $W/proc/loadavg
  printf 'MemAvailable: 8388608 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n' > $W/proc/meminfo
  fail() { echo "FAIL: $*"; exit 1; }
  export SYSFS_ROOT=$W/sys CGROUP_ROOT=$W/cg PROC_ROOT=$W/proc
  export HOST_TELEMETRY_DIR=$W/tel

  printf 'usage_usec 1000000\n' > $UNIT/cpu.stat
  python3 ${../scripts/host-telemetry.py} --once > /dev/null
  printf 'usage_usec 4000000\n' > $UNIT/cpu.stat
  python3 ${../scripts/host-telemetry.py} --once > $W/tel.json
  jq -e '.tctl_c == 75 and .ac == true and .gpu_busy == 37 and .load1 == 1.5' $W/tel.json > /dev/null \
    || fail "telemetry sensors wrong: $(cat $W/tel.json)"
  jq -e '.mem_avail_gb == 8 and .swap_used_gb == 1' $W/tel.json > /dev/null || fail "telemetry memory wrong"
  jq -e '.cpu_top[0] == ["aggregator-ingest.service", 3000]' $W/tel.json > /dev/null \
    || fail "telemetry cpu_top should credit 3000 ms to the ingest unit: $(jq -c .cpu_top $W/tel.json)"
  [ "$(cat $W/tel/*.jsonl | wc -l)" = 2 ] || fail "expected two telemetry lines"

  echo "host-telemetry: all assertions passed"
  touch $out
''
