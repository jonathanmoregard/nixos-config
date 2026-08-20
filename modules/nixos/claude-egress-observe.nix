# claude-egress-observe — phase 1 of 2: OBSERVE the egress of interactive
# Claude Code sessions. Log, never block.
#
# Spec: ~/.claude/tasks/nixos-config/claude-egress-phase1-spec.md
# Gate: nix build .#checks.x86_64-linux.vm-claude-egress
#
# ── What problem this solves ──────────────────────────────────────────
#
# CLAUDE.md denies WebFetch / WebSearch / curl / wget at the PERMISSION
# layer. That is cooperation, not enforcement: a subprocess that opens a
# raw socket ignores it completely. Claude Code runs as uid 1000, the
# same uid as the browser and the IDE, so `meta skuid` cannot
# discriminate — scoping has to be by cgroup.
#
# Phase 2 (a separate PR) flips this to `drop` using the allowlist the
# phase-1 data produces. It deliberately does NOT happen here: nobody
# knows yet what the six MCP servers actually dial, and a `drop` against
# a guessed allowlist reproduces the research-agent's 2026-06 incident,
# where an unlisted destination did not fail — it HUNG to the client
# timeout, burning whole research budgets on dead waits.
#
# ── F1: `socket cgroupv2` binds an INODE at parse time ────────────────
#
# nftables 1.1.6 src/datatype.c:1716 cgroupv2_type_parse() does
#
#     snprintf(path, sizeof(path), "/sys/fs/cgroup/%s", sym->identifier);
#     if (stat(path, &st) < 0) return error(...);
#     ino = st.st_ino;
#
# so the rule carries st_ino as a CONSTANT. Three consequences, all
# verified empirically in the VM harness before this module was written:
#
#   1. The path argument is RELATIVE to /sys/fs/cgroup. Passing an
#      absolute path yields "cgroupv2 path fails: No such file or
#      directory".
#   2. A ruleset naming a not-yet-existing cgroup FAILS TO LOAD. That is
#      why the table below loads with NO cgroup rule in it and the rule
#      is added at runtime by claude-egress-bind.service — boot can never
#      fail on an unlaunched slice.
#   3. A slice destroyed and recreated gets a new inode, and the rule
#      then matches NOTHING while still looking armed. This is the same
#      silent-no-op class as PR #184. claude-egress-bind.service therefore
#      re-checks the binding on a timer and repairs it.
#
# Repairing is possible because nft reverse-resolves the stored inode
# when listing: a live binding prints the cgroup path, a dead one prints
# a bare integer. Comparing the printed path against the live slice is an
# exact staleness test that needs no bookkeeping.
#
# ── The level index is 5, not 4 ───────────────────────────────────────
#
# `socket cgroupv2 level N` matches the socket's cgroup ANCESTOR at depth
# N (root = 0), so matching the slice matches every descendant — MCP
# servers are covered without naming a single binary. The naive
# arithmetic for
#
#   /user.slice/user-1000.slice/user@1000.service/claude-egress.slice
#
# gives 4, and 4 is WRONG: systemd derives a slice's parent from the
# dashes in its own name, so claude-egress.slice actually lands under an
# auto-created claude.slice at
#
#   /user.slice/user-1000.slice/user@1000.service/claude.slice/claude-egress.slice
#
# which is level 5. A level-4 rule parses fine, loads fine, and matches
# nothing — verified. Nothing here hardcodes either number: the bind unit
# DISCOVERS the cgroup with `find` and derives the level from the path it
# found, so a future rename cannot silently un-arm the control.
#
# ── Logging is lossy ──────────────────────────────────────────────────
#
# nft `log` rides kernel printk and is net_ratelimit()-ed, so a bursty
# MCP startup CAN lose lines. `log group` + a userspace collector (ulogd)
# would be lossless but adds a daemon and a config surface for no phase-1
# benefit. The accepted consequence: a lost line is a missing allowlist
# entry and therefore a phase-2 breakage, so treat `claude-egress-report`
# output as a lower bound on the destination set, never as complete.
#
# ── Blast radius ──────────────────────────────────────────────────────
#
# This module does NOT touch `networking.firewall` and does NOT set
# `networking.nftables.enable` (asserted below). It loads a standalone
# `inet claude_egress` table from its own unit, coexisting with the
# running iptables backend. Flipping the backend on a host running
# docker, libvirt/QEMU and tailscale — all of which install their own
# rules — is risk this change does not need to take.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.claudeEgressObserve;

  tableName = "claude_egress";
  chainName = "output";
  logPrefix = "claude-egress: ";
  sliceUnit = "claude-egress.slice";
  stateDir = "/run/claude-egress";
  # /var/lib, not /run: the resolution snapshot is only worth having if it
  # survives the reboot between an observation and the report that reads it.
  libDir = "/var/lib/claude-egress";

  # The chain the rule is added to. Deliberately EMPTY of cgroup matches
  # — see F1 consequence 2 in the header.
  #
  # `table` then `delete table` is the idiomatic idempotent preamble: the
  # bare `table` line creates it when absent so the delete cannot fail,
  # and the delete guarantees a restart starts from a known-clean chain
  # instead of stacking duplicates.
  baseRulesetText = ''
    table inet ${tableName}
    delete table inet ${tableName}

    table inet ${tableName} {
      chain ${chainName} {
        type filter hook output priority 0; policy accept;
      }
    }
  '';

  baseRuleset = pkgs.writeText "claude-egress-base.nft" baseRulesetText;

  # The verdict half of the runtime rule. Isolated as its own string so
  # the phase-1 assertion below can prove it observes and nothing more.
  ruleVerdict = ''ct state new counter log prefix "${logPrefix}"'';

  bindScript = pkgs.writeShellApplication {
    name = "claude-egress-bind";
    runtimeInputs = with pkgs; [ nftables coreutils findutils gnugrep ];
    text = ''
      user="''${CLAUDE_EGRESS_USER:-jonathan}"
      state_dir="${stateDir}"
      mkdir -p "$state_dir"

      uid="$(id -u "$user" 2>/dev/null || true)"
      if [ -z "$uid" ]; then
        echo "claude-egress-bind: user $user does not exist — nothing to bind"
        exit 0
      fi

      write_state() {
        # 0644 on purpose: claude-egress-report runs as the user and this
        # is the health record it reads. Nothing secret in it.
        {
          printf 'state=%s\n' "$1"
          printf 'path=%s\n'  "''${2:-}"
          printf 'level=%s\n' "''${3:-}"
          printf 'inode=%s\n' "''${4:-}"
          printf 'checked_at=%s\n' "$(date -Is)"
        } > "$state_dir/state.tmp"
        mv "$state_dir/state.tmp" "$state_dir/state"
        chmod 0644 "$state_dir/state"
      }

      user_root="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
      cg=""
      if [ -d "$user_root" ]; then
        # DISCOVER rather than compute: systemd nests a dashed slice name
        # under auto-created parents (claude-egress.slice lives inside
        # claude.slice), so the depth is not derivable from the unit name.
        cg="$(find "$user_root" -maxdepth 4 -type d -name '${sliceUnit}' -print -quit 2>/dev/null || true)"
      fi

      if [ -z "$cg" ]; then
        # An unlaunched slice is not an error — exit 0.
        #
        # The chain is emptied anyway. A rule left pointing at a dead
        # inode matches nothing while still LOOKING armed, and that
        # appearance is exactly what this unit exists to prevent. An
        # empty chain is honest.
        nft flush chain inet ${tableName} ${chainName} 2>/dev/null || true
        write_state absent
        echo "claude-egress-bind: ${sliceUnit} cgroup absent under $user_root — chain left empty"
        exit 0
      fi

      rel="''${cg#/sys/fs/cgroup/}"
      ino="$(stat -c %i "$cg")"
      # Depth below the cgroup2 root = number of path separators + 1.
      slashes="$(printf '%s' "$rel" | tr -cd '/' | wc -c)"
      level=$((slashes + 1))

      want="socket cgroupv2 level $level \"$rel\""
      current="$(nft list chain inet ${tableName} ${chainName} 2>/dev/null || true)"

      if printf '%s' "$current" | grep -qF "$want"; then
        # nft only prints the path when the stored inode still resolves to
        # a live cgroup; a stale binding prints a bare integer and lands
        # in the rebind branch below.
        write_state bound "$rel" "$level" "$ino"
        echo "claude-egress-bind: already bound to $rel (level $level, inode $ino)"
        exit 0
      fi

      # Flush and add in ONE nft transaction so the chain is never
      # observably empty between the two.
      tmp="$(mktemp)"
      # shellcheck disable=SC2064
      trap "rm -f '$tmp'" EXIT
      {
        printf 'flush chain inet %s %s\n' "${tableName}" "${chainName}"
        printf 'add rule inet %s %s socket cgroupv2 level %s "%s" %s\n' \
          "${tableName}" "${chainName}" "$level" "$rel" '${ruleVerdict}'
      } > "$tmp"
      nft -f "$tmp"

      write_state bound "$rel" "$level" "$ino"
      date -Is > "$state_dir/bound-at"
      chmod 0644 "$state_dir/bound-at"
      echo "claude-egress-bind: bound $rel (level $level, inode $ino)"
    '';
  };

  candidateArray = ''
    candidates=(
    ${lib.concatMapStrings (h: "  ${lib.escapeShellArg h}\n") cfg.candidateHosts}
    )'';

  # ── Why the resolution table has to ROLL ──────────────────────────────
  #
  # Resolving the candidate list only when the report is run is not enough.
  # api.anthropic.com and the Google/GitHub surfaces are CDN-fronted with
  # short TTLs, so an address observed on Tuesday may resolve from nothing
  # by Friday and would be filed as "unmatched" — indistinguishable from a
  # genuinely unknown destination, which is the one signal this report
  # exists to surface. Snapshotting the forward resolution on a timer, from
  # this host and this resolver, keeps a near-in-time answer available for
  # every observation window. The reporter unions the snapshot with a fresh
  # resolution so it still works before the timer has ever fired.
  #
  # The same short TTLs are why entries have to AGE OUT as well as roll.
  # An address that belonged to a candidate host in March may belong to
  # someone else entirely by June; a snapshot row with no expiry would go
  # on vouching for it, and the new occupant — a genuinely unknown
  # destination — would be filed as matched and never reach section 2.
  # Both writer and reader therefore honour resolutionTtlDays: the roll
  # drops expired rows, and the reporter ignores any that survive in a
  # file it did not write.
  resolveScript = pkgs.writeShellApplication {
    name = "claude-egress-resolve";
    runtimeInputs = with pkgs; [ coreutils gawk getent ];
    text = ''
      ${candidateArray}

      lib_dir="${libDir}"
      table="$lib_dir/resolutions.tsv"
      mkdir -p "$lib_dir"

      tmp="$(mktemp)"
      # shellcheck disable=SC2064
      trap "rm -f '$tmp'" EXIT

      # Third column: when this pair was observed to be true. Without it a
      # pair is true forever, and cloud/CDN addresses are recycled to other
      # operators — so a months-old row keeps filing a NEW occupant of that
      # address as a known destination, suppressing the unmatched signal in
      # section 2 of the report, which is the one thing that section is for.
      now="$(date +%s)"
      cutoff=$(( now - ${toString cfg.resolutionTtlDays} * 86400 ))

      for host in "''${candidates[@]}"; do
        while IFS= read -r ip; do
          [ -n "$ip" ] || continue
          printf '%s\t%s\t%s\n' "$ip" "$host" "$now"
        done < <(getent ahosts "$host" 2>/dev/null | awk '/STREAM/{print $1}' | sort -u)
      done > "$tmp"

      new_count="$(wc -l < "$tmp")"
      # `if`, not `[ -r … ] && …`: as the last command of a top-level list
      # under `set -e`, a false test is a non-zero exit status and takes
      # the whole unit down on the very first run, when the table does not
      # exist yet.
      old_count=0
      if [ -r "$table" ]; then
        old_count="$(wc -l < "$table")"
      fi

      # Newest first, aged out, de-duplicated, then capped. `sort -u` would
      # be simpler but would throw away recency, and the cap is what keeps
      # an ever-rotating CDN from growing this file without bound.
      #
      # The dedup key is the ip/name PAIR, not the whole line: with a
      # timestamp on every row, keying on $0 would make each refresh a new
      # unique row and the file would grow one copy per pass.
      #
      # A row whose third field is missing or non-numeric evaluates to 0
      # and is dropped, so a legacy two-column file ages out on the first
      # pass rather than living on as un-expirable rows.
      #
      # One awk over both files, deliberately NOT `cat … | awk | head`:
      # under `set -o pipefail`, `head` closing the pipe early SIGPIPEs its
      # upstream and the whole pipeline exits 141, which `set -e` then
      # turns into a failed unit — a bug that only appears once the table
      # exceeds the cap, i.e. months in, on the busiest host.
      touch "$table"
      awk -F'\t' -v max=${toString cfg.resolutionTableMaxEntries} -v cutoff="$cutoff" \
        '$3 + 0 >= cutoff && !seen[$1 FS $2]++ { print; if (++n >= max) exit }' \
        "$tmp" "$table" > "$table.new"
      mv "$table.new" "$table"
      chmod 0644 "$table"
      date -Is > "$lib_dir/resolved-at"
      chmod 0644 "$lib_dir/resolved-at"

      retained="$(wc -l < "$table")"
      echo "claude-egress-resolve: $new_count address/name pairs this pass, $retained retained of $((old_count + new_count)) seen (TTL ${toString cfg.resolutionTtlDays}d)"
    '';
  };

  reportScript = pkgs.writeShellApplication {
    name = "claude-egress-report";
    runtimeInputs = with pkgs; [
      coreutils gnugrep gnused gawk systemd getent findutils nftables
    ];
    text = ''
      since="''${1:--7 days}"
      state_dir="${stateDir}"
      lib_dir="${libDir}"

      ${candidateArray}

      echo "claude-egress-report — window: $since"
      echo

      # ── observed destinations ────────────────────────────────────────
      # nft log lines are printk records, so they land in the kernel
      # journal. DST/DPT are the two fields an allowlist needs.
      #
      # `_TRANSPORT=kernel`, never `-k`: journalctl(1) says -k "implies -b",
      # so `journalctl -k --since '-7 days'` silently returns only what
      # happened since the last boot, with nothing in the output admitting
      # the window was cut. On this host that was 1349 lines versus 27368
      # for the same 30-day window. A truncated window here is a phase-2
      # allowlist with holes in it, which is a hang-to-timeout later.
      observed="$(journalctl _TRANSPORT=kernel --no-pager --since "$since" 2>/dev/null \
        | grep -F ${lib.escapeShellArg logPrefix} \
        | sed -n 's/.*DST=\([0-9a-fA-F.:]*\).*DPT=\([0-9]*\).*/\1 \2/p' \
        | sort | uniq -c | sort -rn || true)"

      # ── forward-resolution join table ────────────────────────────────
      # Reverse DNS cannot produce an allowlist: api.anthropic.com is
      # CDN-fronted, PTRs on CloudFront/Fastly ranges are opaque, and
      # MagicDNS hides names entirely. So resolve a candidate list
      # FORWARD from this host, with this resolver, near in time to the
      # observation, and join on the addresses.
      declare -A names=()

      remember() {
        case " ''${names[$1]:-} " in
          *" $2 "*) ;;
          *) names[$1]="''${names[$1]:-}''${names[$1]:+ }$2" ;;
        esac
      }

      # The rolling snapshot first — it holds answers from when the
      # traffic was actually observed, which is the whole point.
      #
      # Expired rows are skipped rather than trusted. The roll normally
      # removes them, but the reader must not depend on the writer having
      # run: a resolve unit that has been failing for a month leaves a
      # table full of pairs that are all quietly out of date, and that is
      # precisely when joining against them is most wrong.
      snap_used=0
      snap_expired=0
      ttl_cutoff=$(( $(date +%s) - ${toString cfg.resolutionTtlDays} * 86400 ))
      if [ -r "$lib_dir/resolutions.tsv" ]; then
        while IFS=$'\t' read -r ip host ts; do
          [ -n "$ip" ] && [ -n "$host" ] || continue
          # Non-numeric or absent timestamp counts as expired: a pair that
          # cannot prove its age is a pair that cannot be trusted to still
          # be true, and over-reporting section 2 is the safe direction.
          case "''${ts:-}" in
            ""|*[!0-9]*) snap_expired=$((snap_expired + 1)); continue ;;
          esac
          if [ "$ts" -lt "$ttl_cutoff" ]; then
            snap_expired=$((snap_expired + 1))
            continue
          fi
          snap_used=$((snap_used + 1))
          remember "$ip" "$host"
        done < "$lib_dir/resolutions.tsv"
      fi

      # Then a live resolution, so the report is useful before the timer
      # has ever run and picks up anything that moved since.
      for host in "''${candidates[@]}"; do
        while IFS= read -r ip; do
          [ -n "$ip" ] && remember "$ip" "$host"
        done < <(getent ahosts "$host" 2>/dev/null | awk '/STREAM/{print $1}' | sort -u)
      done

      matched=""
      unmatched=""
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        count="$(printf '%s' "$line" | awk '{print $1}')"
        ip="$(printf '%s' "$line" | awk '{print $2}')"
        port="$(printf '%s' "$line" | awk '{print $3}')"
        if [ -n "''${names[$ip]:-}" ]; then
          matched="$matched$(printf '  %-6s %-39s %-5s %s' "$count" "$ip" "$port" "''${names[$ip]}")"$'\n'
        else
          unmatched="$unmatched$(printf '  %-6s %-39s %-5s' "$count" "$ip" "$port")"$'\n'
        fi
      done <<< "$observed"

      echo "== 1. matched (candidate phase-2 allowlist entries) =="
      if [ -n "$matched" ]; then
        printf '  %-6s %-39s %-5s %s\n' COUNT ADDRESS PORT NAMES
        printf '%s' "$matched"
      else
        echo "  (none)"
      fi
      echo

      echo "== 2. unmatched (needs manual attention) =="
      if [ -n "$unmatched" ]; then
        printf '  %-6s %-39s %-5s\n' COUNT ADDRESS PORT
        printf '%s' "$unmatched"
      else
        echo "  (none)"
      fi
      echo

      # ── health ───────────────────────────────────────────────────────
      # Not decoration. PR #184 went unnoticed for four hours because the
      # failure presented as silence; a control that can die quietly must
      # be able to say it is alive. Everything below is derived
      # INDEPENDENTLY of the bind unit's own claim wherever possible.
      echo "== 3. health =="
      if [ ! -r "$state_dir/state" ]; then
        echo "  UNKNOWN: no $state_dir/state — has claude-egress-bind.service ever run?"
      else
        # shellcheck disable=SC1091
        state=""; path=""; level=""; inode=""; checked_at=""
        while IFS='=' read -r k v; do
          case "$k" in
            state) state="$v" ;;
            path) path="$v" ;;
            level) level="$v" ;;
            inode) inode="$v" ;;
            checked_at) checked_at="$v" ;;
          esac
        done < "$state_dir/state"

        echo "  recorded state:  $state"
        [ -n "$path" ] && echo "  bound cgroup:    $path (level $level, inode $inode)"
        echo "  last checked:    $checked_at"
        if [ -r "$state_dir/bound-at" ]; then
          echo "  last (re)bound:  $(cat "$state_dir/bound-at")"
        else
          echo "  last (re)bound:  never"
        fi

        # Cross-check against the live filesystem rather than trusting the
        # record: a bind unit that died between ticks leaves a state file
        # that still says "bound".
        if [ -n "$path" ] && [ -d "/sys/fs/cgroup/$path" ]; then
          live_ino="$(stat -c %i "/sys/fs/cgroup/$path")"
          if [ "$live_ino" = "$inode" ]; then
            echo "  live check:      OK — recorded inode matches the live cgroup"
          else
            echo "  live check:      STALE — cgroup was recreated (live inode $live_ino != recorded $inode)"
            echo "                   the rule currently matches NOTHING; run claude-egress-bind.service"
          fi
        elif [ "$state" = absent ]; then
          echo "  live check:      slice not started — nothing is being observed"
        else
          echo "  live check:      STALE — recorded cgroup path no longer exists"
        fi

        # `systemctl is-active` prints the state AND exits non-zero for
        # every state that is not "active", so `|| echo unknown` appends
        # a second line rather than substituting one. Capture, then
        # default only when the capture is genuinely empty.
        timer_state="$(systemctl is-active claude-egress-bind.timer 2>/dev/null || true)"
        table_state="$(systemctl is-active claude-egress-table.service 2>/dev/null || true)"
        echo "  bind timer:      ''${timer_state:-unknown}"
        echo "  table unit:      ''${table_state:-unknown}"
      fi

      # The join is only as good as the snapshot behind it: an empty or
      # stale resolution table silently turns every known destination into
      # an "unmatched" one, which reads as alarming rather than as broken.
      if [ -r "$lib_dir/resolutions.tsv" ]; then
        echo "  resolution snapshot: $(wc -l < "$lib_dir/resolutions.tsv") pairs, last refreshed $(cat "$lib_dir/resolved-at" 2>/dev/null || echo never)"
        echo "                       $snap_used within the ${toString cfg.resolutionTtlDays}-day TTL, $snap_expired aged out and ignored"
      else
        echo "  resolution snapshot: MISSING — section 2 will over-report until claude-egress-resolve.service has run"
      fi

      # How much of the requested window the journal can actually answer
      # for. The gap between the two is the difference between "no
      # unknown destinations" and "no records", and a report that cannot
      # tell those apart is worse than no report. Scoped to the window so
      # it costs no more than the query above.
      #
      # `awk NR==1` without an `exit`, never `head -1`: an early-exiting
      # reader SIGPIPEs journalctl, and under writeShellApplication's
      # `set -o pipefail` that exits 141 and kills the script.
      oldest_kernel="$(journalctl _TRANSPORT=kernel --no-pager -o short-iso \
        --since "$since" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
      echo "  kernel journal:  oldest record in window ''${oldest_kernel:-(none readable)}"

      # Reading the ruleset needs CAP_NET_ADMIN; say so rather than
      # printing a blank section when run unprivileged.
      if rules="$(nft list chain inet ${tableName} ${chainName} 2>/dev/null)"; then
        echo "  live rule:"
        printf '%s\n' "$rules" | sed -n 's/^/    /p'
      else
        echo "  live rule:       (not readable as this user — re-run with sudo to see it)"
      fi
    '';
  };
in
{
  options.services.claudeEgressObserve = {
    enable = lib.mkEnableOption "Claude Code egress observation (phase 1: log only)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = "User whose claude-egress.slice cgroup is observed.";
    };

    resolutionTableMaxEntries = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20000;
      description = ''
        Cap on retained address/name pairs in the rolling resolution
        snapshot. Newest entries are kept; CDN address rotation would
        otherwise grow the file without bound.
      '';
    };

    resolutionTtlDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        How long an address/name pair in the rolling resolution snapshot
        is allowed to keep vouching for an address. Cloud and CDN
        addresses are recycled between operators, so a pair with no expiry
        eventually joins a genuinely unknown destination back to a name it
        no longer has — and the report files it as matched instead of
        surfacing it. Must exceed the widest window passed to
        claude-egress-report (default -7 days), or observations at the far
        end of that window come back nameless.
      '';
    };

    candidateHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Hostnames the reporter resolves FORWARD, from this host, to turn
        observed destination addresses into names. Not an allowlist — it
        is only a join table, and adding a name here grants nothing.
      '';
      default = [
        # Claude Code itself
        "api.anthropic.com"
        "console.anthropic.com"
        "statsig.anthropic.com"
        "claude.ai"
        # npm / node — the native installer self-updates
        "registry.npmjs.org"
        # git remotes used by the session and its skills
        "github.com"
        "api.github.com"
        "codeload.github.com"
        "raw.githubusercontent.com"
        "objects.githubusercontent.com"
        # MCP: research-agent
        "api.exa.ai"
        "mcp.exa.ai"
        "api.tavily.com"
        "mcp.tavily.com"
        # MCP: injection scanner used by the research-agent wrappers
        "api.lakera.ai"
        # MCP: reddit
        "www.reddit.com"
        "oauth.reddit.com"
        # MCP: gdocs-review
        "oauth2.googleapis.com"
        "www.googleapis.com"
        "docs.googleapis.com"
        "drive.googleapis.com"
        # MCP: ticktick / calendly (aggregator + chief-of-staff surfaces)
        "api.ticktick.com"
        "ticktick.com"
        "api.calendly.com"
        # nix substituters — a rebuild started from inside a session
        "cache.nixos.org"
        "jonathanmoregard.cachix.org"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Blast radius, stated as a build-time gate rather than a comment.
        # Flipping the backend on a host running docker, libvirt and
        # tailscale is not risk this change takes.
        assertion = !config.networking.nftables.enable;
        message = ''
          services.claudeEgressObserve loads a standalone `inet claude_egress`
          table alongside the running iptables backend. It must not be combined
          with networking.nftables.enable — see the module header.
        '';
      }
      {
        # Phase-1 tripwire. The whole point of shipping observation first
        # is that nobody knows yet what the MCP servers dial; a `drop`
        # here would reproduce the 2026-06 hang-to-timeout incident.
        assertion =
          !(lib.hasInfix "drop" baseRulesetText) && !(lib.hasInfix "drop" ruleVerdict);
        message = ''
          services.claudeEgressObserve is phase 1 and must LOG, never block.
          A blocking verdict belongs in the separate phase-2 change, built on
          the allowlist this phase's data produces.
        '';
      }
    ];

    # Without linger, user@<uid>.service is destroyed at logout and every
    # cgroup inode beneath it changes — F1's second half, on a schedule.
    # mkDefault so this cannot conflict with nixos-auto-deploy.nix, which
    # already lingers its notify user.
    users.users.${cfg.user}.linger = lib.mkDefault true;

    environment.systemPackages = [ reportScript ];

    systemd.services.claude-egress-table = {
      description = "Load the claude_egress nftables table (no cgroup rule)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${baseRuleset}";
        # `-` so stopping a unit whose table is already gone is not a
        # failure.
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet ${tableName}";
      };
    };

    systemd.services.claude-egress-bind = {
      description = "Bind the claude_egress log rule to ${sliceUnit}'s live cgroup";
      # wantedBy the table service mirrors research-agent-egress-init's
      # `wantedBy = [ … "nftables.service" ]`: a reload of the table must
      # pull the rule back in rather than leave the chain empty.
      wantedBy = [ "multi-user.target" "claude-egress-table.service" ];
      after = [ "claude-egress-table.service" ];
      requires = [ "claude-egress-table.service" ];
      # PartOf so restarting the table restarts this in the same
      # transaction — the chain is recreated empty by the table unit, and
      # without this the rule would simply be gone until the next timer
      # tick (up to 5 minutes of silent non-observation).
      partOf = [ "claude-egress-table.service" ];
      environment.CLAUDE_EGRESS_USER = cfg.user;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bindScript}/bin/claude-egress-bind";
      };
    };

    systemd.services.claude-egress-resolve = {
      description = "Snapshot forward DNS for the claude-egress candidate hosts";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${resolveScript}/bin/claude-egress-resolve";
        StateDirectory = "claude-egress";
        # A resolver that hangs must not wedge the unit indefinitely; a
        # missed snapshot is recoverable, a stuck one is not.
        TimeoutStartSec = "5min";
      };
    };

    systemd.timers.claude-egress-resolve = {
      description = "Refresh the claude-egress forward-resolution snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # OnCalendar rather than a monotonic pair, because Persistent=
        # only has an effect on OnCalendar= and this is a laptop that
        # suspends: without catch-up, a machine asleep over a boundary
        # skips the snapshot and the window it covers loses its names.
        # Same reasoning as claude-pull.timer in home/claude-services.nix.
        OnCalendar = "*:0/30";
        Persistent = true;
        AccuracySec = "1min";
        Unit = "claude-egress-resolve.service";
      };
    };

    systemd.timers.claude-egress-bind = {
      description = "Re-check the claude_egress cgroup binding";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # 1min after boot: the user manager and the slice need to exist
        # first, and an absent slice is a no-op anyway.
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        AccuracySec = "30s";
        Unit = "claude-egress-bind.service";
      };
    };
  };
}
