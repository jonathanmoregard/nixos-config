# egress-init-retry: runtime-invocation harness for the research-agent
# guest's egress-init script (the exact text systemd will execute,
# evaluated out of the flake — not a copy that can drift).
#
# Simulates the 2026-07-07 incident class: host offline at guest boot.
# The getent stub fails the first OFFLINE_CALLS invocations (DNS dead),
# then "the network comes back" and every lookup resolves. The script
# MUST survive the offline window (no exit 1 — that cascades into a
# failed sshd via Requires= and a give-up-latched watchdog) and finish
# with a fully populated allowlist once resolution works.
#
# sleep is stubbed to a no-op recorder so the retry/backoff path runs
# in milliseconds; the recorded sleeps prove the script waited instead
# of dying.
#
# Run: nix build .#checks.x86_64-linux.egress-init-retry -L
{ pkgs, script }:

pkgs.runCommand "egress-init-retry-harness"
  {
    inherit script;
    passAsFile = [ "script" ];
    nativeBuildInputs = with pkgs; [ bash gawk coreutils ];
  } ''
    mkdir -p bin state
    export STATE="$PWD/state"

    # getent stub, three phases mimicking a link coming back up:
    #   calls 1..12    — hard offline: every lookup fails (rc 2)
    #   calls 13..24   — partial: only even-length domains resolve
    #                    (locks the insert-incrementally contract)
    #   calls 25+      — fully online
    # Output mimics real `getent ahostsv4`: STREAM + DGRAM + RAW lines
    # per IP, two IPs per domain — exercises the /STREAM/ filter and
    # the sort -u de-dup for real.
    cat > bin/getent <<'STUB'
    #!/bin/sh
    n=$(cat "$STATE/getent-calls" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE/getent-calls"
    [ "$n" -le 12 ] && exit 2
    if [ "$n" -le 24 ] && [ $(( ''${#2} % 2 )) -eq 1 ]; then exit 2; fi
    printf '192.0.2.10      STREAM %s\n192.0.2.10      DGRAM\n192.0.2.10      RAW\n192.0.2.11      STREAM %s\n' "$2" "$2"
    STUB

    # nft stub: record every invocation for post-run assertions.
    cat > bin/nft <<'STUB'
    #!/bin/sh
    echo "$@" >> "$STATE/nft.log"
    exit 0
    STUB

    # sleep stub: record requested duration, return instantly.
    cat > bin/sleep <<'STUB'
    #!/bin/sh
    echo "$1" >> "$STATE/sleeps"
    exit 0
    STUB

    chmod +x bin/*
    export PATH="$PWD/bin:$PATH"

    if ! bash "$scriptPath" > out.log 2>&1; then
      echo "=== script output ==="
      cat out.log
      echo "FAIL: egress-init exited non-zero under a transient offline window."
      echo "Offline at boot must mean 'wait for network', never a dead sshd."
      exit 1
    fi

    grep -q "firewall active" out.log || {
      cat out.log
      echo "FAIL: script exited 0 but never reached 'firewall active'"; exit 1; }

    added=$(grep -c "add element inet filter research_allowed" "$STATE/nft.log" || true)
    [ "$added" -ge 20 ] || {
      cat "$STATE/nft.log"
      echo "FAIL: expected >=20 inserts (2 IPs x ~11 domains), got $added"; exit 1; }

    grep -q "192.0.2.10" "$STATE/nft.log" && grep -q "192.0.2.11" "$STATE/nft.log" || {
      echo "FAIL: multi-IP responses not both inserted (STREAM filter / de-dup broken)"; exit 1; }

    waits=$(wc -l < "$STATE/sleeps")
    [ "$waits" -ge 2 ] || {
      echo "FAIL: expected >=2 retry waits (offline + partial phases), got $waits"; exit 1; }

    # Incremental contract: some domains must be inserted WHILE others
    # are still unresolved (partial-connectivity phase) — i.e. an
    # 'allow' line precedes the final 'unresolved' retry line.
    first_allow=$(grep -n "\[egress-init\] allow" out.log | head -1 | cut -d: -f1)
    last_retry=$(grep -n "unresolved (attempt" out.log | tail -1 | cut -d: -f1)
    [ -n "$first_allow" ] && [ -n "$last_retry" ] && [ "$first_allow" -lt "$last_retry" ] || {
      cat out.log
      echo "FAIL: inserts were not incremental across the partial phase"; exit 1; }

    echo "ok: survived offline window ($waits waits), $added inserts, incremental across partial phase"
    touch $out
  ''
