#!/usr/bin/env bash
# scripts/classify-pr.sh — derivation-graph blast-radius classifier.
#
# Runs in the trusted gate.yml workflow (pull_request_target) with the
# script loaded from the BASE checkout, never from the PR branch.
#
# Inputs (env):
#   BASE_SHA  - SHA of the merge base on origin/main
#   HEAD_SHA  - SHA of the PR head
#
# Outputs:
#   stdout: a markdown summary of per-source contributions
#   $GITHUB_OUTPUT: risk=<TRIVIAL|LOW|MEDIUM|HIGH|CRITICAL>
#
# Highest matched bucket wins. If signals exist but no rule matches,
# default = MEDIUM (fail-closed). If all three sources are empty
# (truly no-op PR), result = TRIVIAL.

set -euo pipefail

: "${BASE_SHA:?BASE_SHA must be set}"
: "${HEAD_SHA:?HEAD_SHA must be set}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
RULES="$REPO_ROOT/scripts/risk-rules.nix"
WORK="${WORK:-/tmp/classify-pr-$$}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# --- Build both system.build.toplevel derivations ----------------------

build_toplevel() {
  local sha="$1" out
  out=$(nix build --no-link --print-out-paths \
    "git+file://$REPO_ROOT?rev=$sha#nixosConfigurations.dellan.config.system.build.toplevel" \
    2>/dev/null) || return 1
  echo "$out"
}

BASE_TOPLEVEL=$(build_toplevel "$BASE_SHA")
HEAD_TOPLEVEL=$(build_toplevel "$HEAD_SHA")

# --- Source 1: package-set delta ---------------------------------------

nix store diff-closures "$BASE_TOPLEVEL" "$HEAD_TOPLEVEL" \
  > "$WORK/pkg-delta.txt" 2>/dev/null || true

# --- Source 2: etc-tree path delta -------------------------------------

base_etc=$(nix-store -q --references "$BASE_TOPLEVEL" \
  | grep -E -- '-etc(-[^/]+)?$' | head -1 || true)
head_etc=$(nix-store -q --references "$HEAD_TOPLEVEL" \
  | grep -E -- '-etc(-[^/]+)?$' | head -1 || true)

if [ -n "$base_etc" ] && [ -n "$head_etc" ]; then
  diff <(cd "$base_etc/etc" 2>/dev/null && find . -type f -o -type l | sort) \
       <(cd "$head_etc/etc" 2>/dev/null && find . -type f -o -type l | sort) \
       > "$WORK/etc-paths.diff" 2>/dev/null || true
else
  : > "$WORK/etc-paths.diff"
fi

# --- Source 3: source-tree delta ---------------------------------------

git diff --name-only "$BASE_SHA" "$HEAD_SHA" > "$WORK/source-paths.txt" || {
  : > "$WORK/source-paths.txt"
}

# --- Source 1b: derivation churn ---------------------------------------
# Same package name+version present in both closures but with different
# store hash = derivation differs (patches, build env vars, kernel config
# flip without version bump). Cheap signal that closes the 3 nix-diff
# blind spots without nix-diff's parse cost.
nix-store -qR "$BASE_TOPLEVEL" | sort > "$WORK/base-paths.txt"
nix-store -qR "$HEAD_TOPLEVEL" | sort > "$WORK/head-paths.txt"

# Strip /nix/store/<32-char-hash>- prefix to get name-version key.
# Find name-version values present in both, then check if their hashes differ.
extract_nv() { sed -E 's,^/nix/store/[a-z0-9]{32}-,,' "$1" | sort -u; }
extract_nv "$WORK/base-paths.txt" > "$WORK/base-nv.txt"
extract_nv "$WORK/head-paths.txt" > "$WORK/head-nv.txt"
comm -12 "$WORK/base-nv.txt" "$WORK/head-nv.txt" > "$WORK/shared-nv.txt"

: > "$WORK/churn.txt"
while IFS= read -r nv; do
  [ -z "$nv" ] && continue
  base_hash=$(grep -E "/[a-z0-9]{32}-${nv//./\\.}$" "$WORK/base-paths.txt" \
    | head -1 | sed -E 's,^/nix/store/([a-z0-9]{32})-.*,\1,')
  head_hash=$(grep -E "/[a-z0-9]{32}-${nv//./\\.}$" "$WORK/head-paths.txt" \
    | head -1 | sed -E 's,^/nix/store/([a-z0-9]{32})-.*,\1,')
  if [ -n "$base_hash" ] && [ -n "$head_hash" ] && [ "$base_hash" != "$head_hash" ]; then
    # Strip trailing version (last -<digit-or-dot> chunk) to extract package name.
    pkg_name=$(echo "$nv" | sed -E 's/-[0-9][0-9a-z.+-]*$//')
    echo "$pkg_name" >> "$WORK/churn.txt"
  fi
done < "$WORK/shared-nv.txt"
sort -u "$WORK/churn.txt" -o "$WORK/churn.txt"

# --- No-op short-circuit ----------------------------------------------

PKG_LINES=$(wc -l < "$WORK/pkg-delta.txt")
ETC_LINES=$(wc -l < "$WORK/etc-paths.diff")
SRC_LINES=$(wc -l < "$WORK/source-paths.txt")
CHURN_LINES=$(wc -l < "$WORK/churn.txt")

if [ "$PKG_LINES" -eq 0 ] && [ "$ETC_LINES" -eq 0 ] \
   && [ "$SRC_LINES" -eq 0 ] && [ "$CHURN_LINES" -eq 0 ]; then
  RISK=TRIVIAL
  echo "## Classifier: TRIVIAL (no-op — all three diffs empty)"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "risk=$RISK" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

# --- Rule matching -----------------------------------------------------

read_rule() {
  # Args: source path (key1) sub-key
  # Reads rules/$1/$2 list from Nix file as newline-separated values.
  nix eval --raw --impure --expr \
    "let r = import \"$RULES\"; in builtins.concatStringsSep \"\n\" (r.$1.$2 or [])"
}

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
  local target="$1"
  local cur_rank new_rank
  cur_rank=$(bucket_rank "$RISK")
  new_rank=$(bucket_rank "$target")
  if [ "$new_rank" -gt "$cur_rank" ]; then RISK="$target"; fi
}

RISK=TRIVIAL
SOURCE1_HITS=()
SOURCE2_HITS=()
SOURCE3_HITS=()

# Source 1: package names — EXACT match on token left of colon
while IFS= read -r line; do
  [ -z "$line" ] && continue
  pkg="${line%%:*}"
  pkg="${pkg// /}"  # trim spaces
  matched=0

  # critical?
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "$pkg" = "$rule" ]; then
      SOURCE1_HITS+=("$pkg → CRITICAL")
      upgrade_to CRITICAL; matched=1; break
    fi
  done <<< "$PKG_CRIT"
  [ "$matched" = 1 ] && continue

  # high?
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "$pkg" = "$rule" ]; then
      SOURCE1_HITS+=("$pkg → HIGH")
      upgrade_to HIGH; matched=1; break
    fi
  done <<< "$PKG_HIGH"
  [ "$matched" = 1 ] && continue

  # secret rotation? (suffix .age)
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [ "${pkg: -${#rule}}" = "$rule" ]; then
      SOURCE1_HITS+=("$pkg → HIGH (secret)")
      upgrade_to HIGH; matched=1; break
    fi
  done <<< "$SECRET_HIGH"
  [ "$matched" = 1 ] && continue

  # default for any closure delta line: MEDIUM
  SOURCE1_HITS+=("$pkg → MEDIUM (default)")
  upgrade_to MEDIUM
done < "$WORK/pkg-delta.txt"

# Source 2: etc-tree paths — PREFIX match (path relative to etc/)
while IFS= read -r line; do
  # parse `> ./<path>` and `< ./<path>` from `diff` output
  if [[ "$line" =~ ^[\<\>][[:space:]]+\.\/(.+)$ ]]; then
    p="${BASH_REMATCH[1]}"
    matched=0

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      if [[ "$p" == "$rule"* ]]; then
        SOURCE2_HITS+=("$p → CRITICAL")
        upgrade_to CRITICAL; matched=1; break
      fi
    done <<< "$ETC_CRIT"
    [ "$matched" = 1 ] && continue

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      if [[ "$p" == "$rule"* ]]; then
        SOURCE2_HITS+=("$p → HIGH")
        upgrade_to HIGH; matched=1; break
      fi
    done <<< "$ETC_HIGH"
    [ "$matched" = 1 ] && continue

    SOURCE2_HITS+=("$p → MEDIUM (default)")
    upgrade_to MEDIUM
  fi
done < "$WORK/etc-paths.diff"

# Source 3: source-tree paths — PREFIX
SRC_NONTRIVIAL=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  trivial_match=0
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [[ "$p" == "$rule"* ]]; then
      SOURCE3_HITS+=("$p → trivial")
      trivial_match=1; break
    fi
  done <<< "$SRC_TRIVIAL"
  if [ "$trivial_match" = 0 ]; then
    SRC_NONTRIVIAL=1
  fi
done < "$WORK/source-paths.txt"

# If only TRIVIAL paths changed AND no closure delta → TRIVIAL
if [ "$RISK" = "TRIVIAL" ] && [ "$SRC_NONTRIVIAL" = 0 ]; then
  : # stay TRIVIAL
fi

# --- Emit summary ------------------------------------------------------

{
  echo "## Classifier verdict: **$RISK**"
  echo ""
  echo "| Source | Matched | Contribution |"
  echo "|--------|---------|--------------|"
  if [ "${#SOURCE1_HITS[@]}" -gt 0 ]; then
    for h in "${SOURCE1_HITS[@]}"; do echo "| diff-closures | $h | |"; done
  else
    echo "| diff-closures | (none) | — |"
  fi
  if [ "${#SOURCE2_HITS[@]}" -gt 0 ]; then
    for h in "${SOURCE2_HITS[@]}"; do echo "| etc-tree paths | $h | |"; done
  else
    echo "| etc-tree paths | (none) | — |"
  fi
  if [ "${#SOURCE3_HITS[@]}" -gt 0 ]; then
    for h in "${SOURCE3_HITS[@]}"; do echo "| source-tree (git) | $h | |"; done
  else
    echo "| source-tree (git) | (none) | — |"
  fi
  echo "| **Final** | | **$RISK** |"
  echo ""
  echo "_Multi-source matches show in each row that hit; final = max, not sum._"
}

# --- Emit GitHub output ------------------------------------------------

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "risk=$RISK" >> "$GITHUB_OUTPUT"
fi
