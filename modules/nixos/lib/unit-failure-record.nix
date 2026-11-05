# The failure record that reaches a Claude session, in one place.
#
# WHY THIS FILE EXISTS
#
# A failing system unit's `OnFailure=` notifier reaches the journal and a
# desktop toast, neither of which a Claude session can read (2026-08-31
# constraint: failure notifications must reach Claude). The agreed channel is a
# durable JSON record under /var/lib/unit-failures/<name>.json, which
# ~/.claude/hooks/unit-failure-health.py reads at SessionStart and announces.
#
# That hook is generic over units — any unit writing this shape is covered
# without touching the hook. The WRITER was not: nix-gc and security-batch had
# grown two independent copies of the same mktemp/jq/chmod/mv sequence, and a
# third unit (claude-runtime-links) needed the same thing. Three copies of a
# wire format read by one consumer is how the shape drifts: a field renamed in
# one copy fails silently, because the hook's own contract treats a record it
# cannot parse as "the unit is probably failing" and says so either way.
#
# So the shape lives here and the call sites supply only what differs.
#
# WHAT IS DELIBERATELY NOT HERE
#
# The journal line each notifier prints first, and its "recorded <path>"
# confirmation. Both are per-unit prose, both are asserted verbatim by the
# lanes (tests/nix-gc.nix:78, tests/security-batch.nix:77), and folding them in
# would mean inventing one wording for three different failures.
#
# USAGE
#
#   let ufr = import ./lib/unit-failure-record.nix { inherit pkgs; };
#   in pkgs.writeShellApplication {
#     name = "foo-failure-notify";
#     runtimeInputs = ufr.runtimeInputs;
#     text = ''
#       ${ufr.writerFunction}
#       result="''${MONITOR_SERVICE_RESULT:-unknown}"
#       status="''${MONITOR_EXIT_STATUS:-unknown}"
#       echo "foo FAILED (result=$result status=$status): ..."
#       write_unit_failure_record ${ufr.recordPath "foo"} foo.service \
#         "$result" "$status" "the summary" "the inspect command"
#       echo "foo-failure-notify: recorded ${ufr.recordPath "foo"}"
#     '';
#   }
#
# `summary` and `inspect` are passed as arguments rather than baked in because
# security-batch computes both at runtime from the failed run's own output. The
# hook caps them at 300 and 120 characters respectively; it is the caller's job
# to stay inside that, since only the caller knows what is worth keeping.
{ pkgs }:

let
  failuresDir = "/var/lib/unit-failures";
in
{
  inherit failuresDir;

  # Everything the writer function shells out to. A call site adds its own.
  runtimeInputs = [ pkgs.jq pkgs.coreutils ];

  # Where a given record lives. Named through a function so no call site
  # spells the directory itself, which is what let the two copies drift apart
  # in the first place.
  recordPath = name: "${failuresDir}/${name}.json";

  # Shell function, inlined by the call site.
  #
  # Atomic by mktemp-then-rename inside the SAME directory, so the hook never
  # reads a half-written record — it skips dot-prefixed files precisely because
  # they are this function's in-flight temporaries.
  #
  # The directory is created and its mode asserted on every run rather than by
  # tmpfiles: a notifier that cannot write its record is a failure nobody would
  # ever see, so it must not depend on an earlier unit having run. 0755 keeps
  # it readable by the hook, which runs as the user, and writable only by root
  # (tests/nix-gc.nix asserts both).
  writerFunction = ''
    write_unit_failure_record() {
      local record="$1" unit="$2" result="$3" status="$4" summary="$5" inspect="$6"
      local tmp

      mkdir -p -- ${failuresDir}
      chmod 0755 -- ${failuresDir}
      tmp=$(mktemp "${failuresDir}/.$(basename "$record" .json).XXXXXX")
      jq -n \
        --arg unit "$unit" \
        --arg result "$result" \
        --arg status "$status" \
        --arg invocation "''${MONITOR_INVOCATION_ID:-}" \
        --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg summary "$summary" \
        --arg inspect "$inspect" \
        '{unit: $unit, result: $result, exit_status: $status, invocation_id: $invocation, failed_at: $failed_at, summary: $summary, inspect: $inspect}' \
        > "$tmp"
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" "$record"
    }
  '';

  # The other half of the contract, and the half that is easy to forget: a
  # record is deleted by the next SUCCESSFUL run, so silence means healthy
  # rather than unreported. Dropped into an ExecStopPost, which runs on success
  # and failure alike — hence the SERVICE_RESULT test.
  clearOnSuccess = name: ''
    if [ "''${SERVICE_RESULT:-}" = success ]; then
      ${pkgs.coreutils}/bin/rm -f -- ${failuresDir}/${name}.json
    fi
  '';
}
