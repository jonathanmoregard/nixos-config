#!/usr/bin/env bash
# scripts/classify-pr.sh — derivation-graph blast-radius classifier.
#
# Runs in the trusted gate.yml workflow (pull_request_target) with the
# script loaded from the BASE checkout, never from the PR branch.
#
# Inputs (env):
#   BASE_SHA  - SHA of base branch tip when the workflow fired
#   HEAD_SHA  - SHA of the PR head
#
# We compare HEAD against the merge-base (`git merge-base BASE HEAD`),
# NOT against BASE_SHA directly. Reason: when a PR is branched from an
# older main and main advances before classification runs, BASE_SHA is
# the *current* main tip and `BASE_SHA..HEAD_SHA` includes the inverse
# of every intermediate merge — the classifier then sees the PR as
# "reverting" everything that landed in between. Merge-base is the
# actual fork point, so the diff reflects only what THIS PR introduces.
#
# Caveat: this misses post-merge regressions caused by interaction
# between the PR's diff and intermediate merges. Acceptable for the
# linear-history solo-dev workflow; revisit if multi-author parallel
# branches become common.
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

# Compare against the actual fork point, not the current base tip.
# Falls back to BASE_SHA if merge-base lookup fails (shouldn't happen
# in normal PR flow, but be defensive — fail-closed by treating BASE
# as the comparison point preserves prior behavior).
MERGE_BASE=$(git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null || echo "$BASE_SHA")
if [ "$MERGE_BASE" != "$BASE_SHA" ]; then
  echo "note: comparing against merge-base $MERGE_BASE (PR branched from older main than current $BASE_SHA)" >&2
fi

# --- Build both system.build.toplevel derivations ----------------------

# Fast path: skip both toplevel builds when every file in the diff is
# proven NOT to feed `system.build.toplevel`.
#
# Using a denylist (not an allowlist) is the safer shape:
#  - An earlier draft listed Nix-bearing dirs (`^home/`, `^modules/`,
#    `^hosts/`, ...). It MISSED `dotfiles/`, `assets/`, `wallpapers/`
#    which are referenced from home-manager modules via
#    `home.file.<x>.source = ../<dir>/...` — content changes in those
#    dirs DO change the closure, but the diff would have shown
#    "no Nix files" and the PR would have been mis-classified TRIVIAL.
#  - With a denylist, new top-level dirs default to slow-path. Adding
#    a docs-only dir requires an explicit denylist entry; forgetting
#    that entry just makes the path slower, never less safe.
#
# Denylist: paths that cannot, by their own definition, feed any Nix
# derivation. `.github/` is NOT in this list — workflow changes need
# classification (risk-rules.nix flags them HIGH) even though they
# don't change the dellan closure.
SAFE_NON_CLOSURE_RE='(^|/)docs/|^proposals/|^README(\..*)?$|^CLAUDE\.md$|^pending_for_human\.md$|^\.gitignore$|^\.gitattributes$|^LICENSE([.\-].*)?$|^\.editorconfig$'

UNSAFE_PATHS=$(git diff --name-only "$MERGE_BASE" "$HEAD_SHA" \
  | grep -Ev "$SAFE_NON_CLOSURE_RE" \
  || true)

if [ -z "$UNSAFE_PATHS" ]; then
  echo "## Risk: TRIVIAL"
  echo
  echo "Fast-path: every file in the diff matches the doc/non-closure denylist."
  echo "Skipped the two toplevel builds + closure diff."
  echo "risk=TRIVIAL" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# Run base + head toplevel builds in parallel. Cachix substitutes both
# closures from the binary cache when available (every main-branch build
# pushes there); concurrent runs overlap cachix downloads on cold misses.

build_toplevel_to() {
  local sha="$1" outfile="$2"
  nix build --no-link --print-out-paths \
    "git+file://$REPO_ROOT?rev=$sha#nixosConfigurations.dellan.config.system.build.toplevel" \
    > "$outfile" 2>"$outfile.err"
}

build_toplevel_to "$MERGE_BASE" "$WORK/base.path" &
base_pid=$!
build_toplevel_to "$HEAD_SHA" "$WORK/head.path" &
head_pid=$!

base_rc=0; head_rc=0
wait "$base_pid" || base_rc=$?
wait "$head_pid" || head_rc=$?
if [ "$base_rc" -ne 0 ] || [ "$head_rc" -ne 0 ]; then
  echo "classify-pr: toplevel build failed (base rc=$base_rc head rc=$head_rc)" >&2
  [ -s "$WORK/base.path.err" ] && cat "$WORK/base.path.err" >&2 || true
  [ -s "$WORK/head.path.err" ] && cat "$WORK/head.path.err" >&2 || true
  exit 1
fi

BASE_TOPLEVEL=$(cat "$WORK/base.path")
HEAD_TOPLEVEL=$(cat "$WORK/head.path")

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

git diff --name-only "$MERGE_BASE" "$HEAD_SHA" > "$WORK/source-paths.txt" || {
  : > "$WORK/source-paths.txt"
}

# --- Source 1b: derivation churn ---------------------------------------
# Same package name+version present in both closures but with different
# store hash = derivation differs (patches, build env vars, kernel config
# flip without version bump). Cheap signal that closes the 3 nix-diff
# blind spots without nix-diff's parse cost.
nix-store -qR "$BASE_TOPLEVEL" | sort > "$WORK/base-paths.txt"
nix-store -qR "$HEAD_TOPLEVEL" | sort > "$WORK/head-paths.txt"

# Build a (nv, hash) table from each closure via awk — pure string ops,
# no regex over user-controlled package names. Avoids escaping pitfalls
# with `+`, `[`, etc. in nixpkgs version strings.
extract_nv_hash() {
  # Input: /nix/store/<32-char-hash>-<nv>
  # Output: <nv>\t<hash> (one per line)
  awk -F/ '
    {
      bn = $NF
      hash = substr(bn, 1, 32)
      nv   = substr(bn, 34)        # skip 32-char hash + "-"
      if (length(hash) == 32 && nv != "") print nv "\t" hash
    }
  ' "$1" | sort -u
}
extract_nv_hash "$WORK/base-paths.txt" > "$WORK/base-nv-hash.txt"
extract_nv_hash "$WORK/head-paths.txt" > "$WORK/head-nv-hash.txt"

# Join on nv. awk does the dedup + churn detection in one pass.
: > "$WORK/churn.txt"
awk -F'\t' '
  NR == FNR { base[$1] = $2; next }
  { if (($1 in base) && base[$1] != $2) print $1 }
' "$WORK/base-nv-hash.txt" "$WORK/head-nv-hash.txt" \
  | while IFS= read -r nv; do
      # Strip trailing version (last -<digit><digit-letter-dot-+-chars>* chunk).
      pkg_name=$(echo "$nv" | sed -E 's/-[0-9][0-9a-z.+-]*$//')
      echo "$pkg_name"
    done | sort -u > "$WORK/churn.txt"

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
SRC_HIGH=$(read_rule sourceTree high)

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
# Order: high (upgrade) → trivial (annotate-only) → fall-through to closure-based scoring.
while IFS= read -r p; do
  [ -z "$p" ] && continue
  matched=0

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [[ "$p" == "$rule"* ]]; then
      SOURCE3_HITS+=("$p → HIGH")
      upgrade_to HIGH; matched=1; break
    fi
  done <<< "$SRC_HIGH"
  [ "$matched" = 1 ] && continue

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    if [[ "$p" == "$rule"* ]]; then
      SOURCE3_HITS+=("$p → trivial")
      matched=1; break
    fi
  done <<< "$SRC_TRIVIAL"
  [ "$matched" = 1 ] && continue

  # Path doesn't match any source-tree rule. No upgrade — closure/etc
  # signals (Sources 1/2/1b) still drive the verdict if they fire.
done < "$WORK/source-paths.txt"

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
