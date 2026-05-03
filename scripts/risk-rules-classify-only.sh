#!/usr/bin/env bash
# scripts/risk-rules-classify-only.sh — pure classifier (no toplevel build).
#
# Reads pre-staged inputs from $WORK/{pkg-delta.txt,etc-paths.diff,source-paths.txt}
# and emits the verdict bucket on stdout's last line.
#
# Used by:
#   - the test harness (risk-rules.test.sh) with stubbed inputs
#   - classify-pr.sh after it builds toplevels and writes the input files
#
# Inputs (env): WORK, REPO_ROOT
# Output: markdown summary on stdout; final line = bucket name

set -euo pipefail

: "${WORK:?WORK directory must contain pkg-delta.txt, etc-paths.diff, source-paths.txt}"
: "${REPO_ROOT:?REPO_ROOT must point to repo root}"

RULES="$REPO_ROOT/scripts/risk-rules.nix"

read_rule() {
  nix eval --raw --impure --expr \
    "let r = import \"$RULES\"; in builtins.concatStringsSep \"\n\" (r.$1.$2 or [])"
}

PKG_LINES=$(wc -l < "$WORK/pkg-delta.txt")
ETC_LINES=$(wc -l < "$WORK/etc-paths.diff")
SRC_LINES=$(wc -l < "$WORK/source-paths.txt")

if [ "$PKG_LINES" -eq 0 ] && [ "$ETC_LINES" -eq 0 ] && [ "$SRC_LINES" -eq 0 ]; then
  echo "TRIVIAL"
  exit 0
fi

PKG_CRIT=$(read_rule packages critical)
PKG_HIGH=$(read_rule packages high)
SECRET_HIGH=$(read_rule secrets high)
ETC_HIGH=$(read_rule etcPaths high)
ETC_CRIT=$(read_rule etcPaths critical)
SRC_TRIVIAL=$(read_rule sourceTree trivial)

bucket_rank() {
  case "$1" in
    CRITICAL) echo 5 ;;
    HIGH)     echo 4 ;;
    MEDIUM)   echo 3 ;;
    LOW)      echo 2 ;;
    TRIVIAL)  echo 1 ;;
    *)        echo 0 ;;
  esac
}

upgrade_to() {
  local target="$1" cur_rank new_rank
  cur_rank=$(bucket_rank "$RISK")
  new_rank=$(bucket_rank "$target")
  if [ "$new_rank" -gt "$cur_rank" ]; then RISK="$target"; fi
}

RISK=TRIVIAL

# Source 1: package names
while IFS= read -r line; do
  [ -z "$line" ] && continue
  pkg="${line%%:*}"
  pkg="${pkg// /}"
  matched=0

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "$pkg" = "$rule" ]; then upgrade_to CRITICAL; matched=1; break; fi
  done <<< "$PKG_CRIT"
  [ "$matched" = 1 ] && continue

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "$pkg" = "$rule" ]; then upgrade_to HIGH; matched=1; break; fi
  done <<< "$PKG_HIGH"
  [ "$matched" = 1 ] && continue

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "${pkg: -${#rule}}" = "$rule" ]; then upgrade_to HIGH; matched=1; break; fi
  done <<< "$SECRET_HIGH"
  [ "$matched" = 1 ] && continue

  upgrade_to MEDIUM
done < "$WORK/pkg-delta.txt"

# Source 2: etc-tree paths
while IFS= read -r line; do
  if [[ "$line" =~ ^[\<\>][[:space:]]+\.\/(.+)$ ]]; then
    p="${BASH_REMATCH[1]}"
    matched=0

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      if [[ "$p" == "$rule"* ]]; then upgrade_to CRITICAL; matched=1; break; fi
    done <<< "$ETC_CRIT"
    [ "$matched" = 1 ] && continue

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      if [[ "$p" == "$rule"* ]]; then upgrade_to HIGH; matched=1; break; fi
    done <<< "$ETC_HIGH"
    [ "$matched" = 1 ] && continue

    upgrade_to MEDIUM
  fi
done < "$WORK/etc-paths.diff"

# Source 3: source-tree paths
SRC_NONTRIVIAL=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  trivial_match=0
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [[ "$p" == "$rule"* ]]; then trivial_match=1; break; fi
  done <<< "$SRC_TRIVIAL"
  [ "$trivial_match" = 0 ] && SRC_NONTRIVIAL=1
done < "$WORK/source-paths.txt"

# Source-only-trivial AND no closure delta = TRIVIAL (fallback)
if [ "$RISK" = "TRIVIAL" ] && [ "$SRC_NONTRIVIAL" = 0 ]; then
  : # stay TRIVIAL
fi

echo "$RISK"
