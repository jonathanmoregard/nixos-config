# egress-refresh: runtime-invocation harness for the research-agent
# guest's egress-refresh script (the exact text systemd will execute,
# evaluated out of the flake — not a copy that can drift).
#
# Simulates the 2026-08-24 incident class: egress-init resolves the
# allowlist FQDNs exactly once at guest boot and never again. Hosts
# behind rotating IPs (api.tavily.com is AWS ELB-backed) drift out of
# the nftables set; because the output chain is policy=drop, every
# subsequent call is silently blackholed and hangs to its client
# timeout. The VM had been up 11.5 days when this was found, and every
# Tavily call in three consecutive research runs timed out at 30s while
# Cloudflare-anycast Exa (stable IPs) kept working.
#
# The refresh unit closes that gap. Its two load-bearing contracts:
#
#   1. ATOMIC REPLACE on full success — flush + adds in ONE `nft -f`
#      transaction, so the live set is never observably empty.
#   2. LEAVE THE LIVE SET ALONE on any partial resolution failure. A
#      DNS blip must never shrink a working allowlist. This is the
#      property that makes a 10-minute timer safe to run unattended:
#      the worst case is a stale set (today's status quo), never a
#      dead one.
#
# The unit must also never exit non-zero — it runs on a timer, and a
# failed unit is noise that trains the operator to ignore the journal.
#
# Run: nix build .#checks.x86_64-linux.egress-refresh -L
{ pkgs, script }:

pkgs.runCommand "egress-refresh-harness"
  {
    inherit script;
    passAsFile = [ "script" ];
    nativeBuildInputs = with pkgs; [ bash gawk coreutils ];
  } ''
    mkdir -p bin
    export PATH="$PWD/bin:$PATH"

    # nft stub. Logs the sub-command and dumps the `-f` transaction body
    # so we can assert on atomicity.
    #
    # Crucially it also MODELS REAL NFT'S DUPLICATE REJECTION: `add
    # element` on an already-present element is an error, and inside a
    # single transaction that aborts the whole batch. A stub that always
    # returns 0 hid a real bug here on 2026-08-24 (two EUIPO domains
    # share 169.50.35.246, so every refresh would have failed) — the
    # bug was only caught by running the generated script against live
    # DNS. Never let this stub be more forgiving than nftables.
    #
    # Honours NFT_FAIL=1 to simulate a mid-reload set that doesn't exist.
    cat > bin/nft <<'STUB'
    #!/bin/sh
    echo "nft $*" >> "$STATE/nft.log"
    if [ "$1" = "-f" ] && [ -f "$2" ]; then
      echo "--- transaction ---" >> "$STATE/nft.log"
      cat "$2" >> "$STATE/nft.log"
      dup=$(grep '^add element' "$2" | sort | uniq -d)
      if [ -n "$dup" ]; then
        echo "$dup" >> "$STATE/dups"
        echo "Error: Could not process rule: File exists" >&2
        exit 1
      fi
    fi
    [ -n "''${NFT_FAIL:-}" ] && exit 1
    exit 0
    STUB

    # getent stub. Each domain resolves to two domain-UNIQUE addresses
    # plus one address SHARED by every domain — mirroring the real
    # allowlist, where euipo.europa.eu and api.euipo.europa.eu land on
    # the same IP. The shared address is what forces global (not
    # per-domain) de-duplication.
    #
    # $FAIL_DOMAIN fails like a real NXDOMAIN/servfail. Output mimics
    # `getent ahostsv4`: STREAM + DGRAM + RAW lines, so the /STREAM/
    # filter and sort -u de-dup are exercised for real.
    cat > bin/getent <<'STUB'
    #!/bin/sh
    if [ -n "''${FAIL_DOMAIN:-}" ] && [ "$2" = "$FAIL_DOMAIN" ]; then exit 2; fi
    n=$(cat "$STATE/n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE/n"
    printf '192.0.2.%s      STREAM %s\n' "$((n * 2))" "$2"
    printf '192.0.2.%s      DGRAM\n' "$((n * 2))"
    printf '192.0.2.%s      STREAM %s\n' "$((n * 2 + 1))" "$2"
    printf '192.0.2.%s      RAW\n' "$((n * 2 + 1))"
    printf '198.51.100.7      STREAM %s\n' "$2"
    printf '198.51.100.7      RAW\n'
    STUB

    chmod +x bin/*

    # ---------- case 1: every domain resolves -> atomic replace ----------
    export STATE="$PWD/s1"; mkdir -p "$STATE"
    bash "$scriptPath" > out1.log 2>&1 || {
      cat out1.log; echo "FAIL(1): refresh exited non-zero on the happy path"; exit 1; }

    calls=$(grep -c '^nft ' "$STATE/nft.log" || true)
    [ "$calls" -eq 1 ] || {
      cat "$STATE/nft.log"
      echo "FAIL(1): expected exactly ONE nft invocation (atomic -f), got $calls."
      echo "Incremental adds leave the set observably partial mid-refresh."; exit 1; }

    grep -q '^nft -f ' "$STATE/nft.log" || {
      cat "$STATE/nft.log"; echo "FAIL(1): refresh did not apply via 'nft -f' (not atomic)"; exit 1; }

    grep -q 'flush set inet filter research_allowed' "$STATE/nft.log" || {
      cat "$STATE/nft.log"; echo "FAIL(1): transaction has no flush — stale IPs would accumulate forever"; exit 1; }

    adds=$(grep -c 'add element inet filter research_allowed' "$STATE/nft.log" || true)
    [ "$adds" -ge 20 ] || {
      cat "$STATE/nft.log"; echo "FAIL(1): expected >=20 adds (2 IPs x ~11 domains), got $adds"; exit 1; }

    grep -q '192.0.2.2 ' "$STATE/nft.log" && grep -q '192.0.2.3 ' "$STATE/nft.log" || {
      cat "$STATE/nft.log"
      echo "FAIL(1): multi-IP response not fully inserted (STREAM filter broken)"; exit 1; }

    # Global de-dup. The shared address must appear EXACTLY once even
    # though every domain resolved to it. See the nft stub's comment:
    # a duplicate aborts the whole transaction in real nftables, so
    # this assertion is the difference between a refresh that works and
    # one that fails on every single tick.
    [ ! -f "$STATE/dups" ] || {
      echo "=== duplicate elements in transaction ==="; cat "$STATE/dups"
      echo "FAIL(1): transaction contains duplicate 'add element' lines."
      echo "Real nft rejects the whole batch — the set would never refresh."; exit 1; }

    shared=$(grep -c 'add element inet filter research_allowed { 198.51.100.7 }' "$STATE/nft.log" || true)
    [ "$shared" -eq 1 ] || {
      cat "$STATE/nft.log"
      echo "FAIL(1): shared address emitted $shared times, expected exactly 1 (global de-dup)"; exit 1; }

    # flush MUST precede the adds inside the transaction, or the
    # transaction wipes exactly what it just inserted.
    tflush=$(grep -n 'flush set inet filter research_allowed' "$STATE/nft.log" | head -1 | cut -d: -f1)
    tadd=$(grep -n 'add element inet filter research_allowed' "$STATE/nft.log" | head -1 | cut -d: -f1)
    [ "$tflush" -lt "$tadd" ] || {
      cat "$STATE/nft.log"; echo "FAIL(1): flush does not precede adds — set ends up empty"; exit 1; }

    # ---------- case 2: one domain fails -> live set untouched ----------
    export STATE="$PWD/s2"; mkdir -p "$STATE"
    FAIL_DOMAIN=api.tavily.com bash "$scriptPath" > out2.log 2>&1 || {
      cat out2.log; echo "FAIL(2): refresh exited non-zero on partial resolution"; exit 1; }

    if [ -s "$STATE/nft.log" ]; then
      cat "$STATE/nft.log"
      echo "FAIL(2): refresh mutated the live set despite an unresolved domain."
      echo "A DNS blip must never shrink a working allowlist — that converts"
      echo "a stale-set bug into a total-egress-outage bug."
      exit 1
    fi

    grep -qi 'untouched\|unresolved' out2.log || {
      cat out2.log; echo "FAIL(2): partial failure was not logged"; exit 1; }

    # ---------- case 3: nft itself fails -> still exit 0 ----------
    export STATE="$PWD/s3"; mkdir -p "$STATE"
    NFT_FAIL=1 bash "$scriptPath" > out3.log 2>&1 || {
      cat out3.log
      echo "FAIL(3): refresh exited non-zero when nft failed."
      echo "The set does not exist during an nftables reload; a timer unit"
      echo "must absorb that, not latch into failed state."; exit 1; }

    grep -qi 'warn' out3.log || {
      cat out3.log; echo "FAIL(3): nft failure was swallowed without a WARN"; exit 1; }

    echo "ok: atomic replace ($adds adds, flush-before-add), no-op on partial DNS, exit 0 on nft failure"
    touch $out
  ''
