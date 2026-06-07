#!/usr/bin/env bash
# check-eval-warnings.sh — run `nix flake check` and FAIL on eval-time
# lib.warn / lib.warnIf output.
#
# Why: eval warnings are decorative — they scroll past in CI logs and
# local builds without failing anything. microvm.nix warned "QEMU hangs
# if memory is exactly 2GB" on every eval of this repo for weeks
# (lib/runners/qemu.nix:156 in the pinned input) while the 2048-MiB
# DSDT-corruption outage (PR #117) happened anyway. A warning nobody
# sees is not a warning; this script turns them into failures.
#
# Known-acceptable warnings go in scripts/eval-warnings-allowlist.txt
# (one extended-regex per line, # comments allowed), each with a
# comment justifying why it is acceptable.
#
# Run locally: ./scripts/check-eval-warnings.sh
set -uo pipefail

cd "$(dirname "$0")/.."
ALLOWLIST=scripts/eval-warnings-allowlist.txt
STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

# Plain redirection (not a tee process-substitution) so the file is
# complete before we grep it; replay stderr afterwards so the CI log
# still shows everything nix said.
nix flake check --no-build --all-systems 2>"$STDERR_FILE"
rc=$?
cat "$STDERR_FILE" >&2
# A hard eval error outranks warning policing.
[ "$rc" -ne 0 ] && exit "$rc"

# lib.warn/warnIf surface as "evaluation warning: ..." on current nix
# (2.24+/Determinate) and as "trace: warning: ..." on older releases —
# match both. Nix CLI's own notices ("warning: Git tree ... is dirty")
# carry neither prefix and are deliberately not policed.
warnings=$(grep -E '^(evaluation warning:|trace: warning:)' "$STDERR_FILE" | sort -u || true)
if [ -z "$warnings" ]; then
  echo "eval-warnings: none"
  exit 0
fi

# Drop allowlisted patterns (extended regex, one per line).
if [ -s "$ALLOWLIST" ]; then
  patterns=$(grep -Ev '^[[:space:]]*(#|$)' "$ALLOWLIST" || true)
  if [ -n "$patterns" ]; then
    warnings=$(printf '%s\n' "$warnings" \
      | grep -Evf <(printf '%s\n' "$patterns") || true)
  fi
fi
if [ -z "$warnings" ]; then
  echo "eval-warnings: allowlisted only"
  exit 0
fi

{
  echo
  echo "eval-warnings: FAIL — unallowlisted eval-time warnings:"
  printf '%s\n' "$warnings"
  echo
  echo "Fix the warning at its source, or add a justified pattern to $ALLOWLIST."
} >&2
exit 1
