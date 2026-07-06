#!/usr/bin/env bash
# Fail loudly when a doc/skill/comment references `nix run .#<attr>`
# whose attribute no longer resolves against the current flake.
#
# Motivated by the agenix-rekey migration: the migration commit's own
# message documented `nix run .#agenix -- edit ...`, which never worked
# (the configure call writes outputs at `.#agenix-rekey.<system>.<cmd>`,
# not at `.#agenix`). The same stale reference also lived in the
# `nixos-agenix-secret` skill prose — three drift hits stemming from
# one rename, none caught by eval/build because they only appear in
# documentation strings.
#
# Strategy: pure-shell grep for the literal `nix run .#<attr>` form,
# then `nix eval --apply 'x: null'` each unique attribute. Eval is
# sub-second per attribute after the first one warms the cache; no
# realization happens, so the cost stays inside the eval budget the
# `flake check` job already pays.
#
# Usage:
#   scripts/check-docs-commands.sh [extra-root ...]
#
# Default search roots are this repo's docs / modules / hosts / skills /
# the top-level CLAUDE.md. Extra roots passed as positional arguments
# (e.g. a sibling .claude checkout) are appended; the CI workflow uses
# this to validate ~/.claude references on every nixos-config PR.
#
# Exit codes:
#   0 — every reference resolved (or none found)
#   1 — at least one reference is stale (printed to stderr with file:line)
set -euo pipefail

# proposals/ is deliberately EXCLUDED: proposals are point-in-time
# archival records that legitimately quote dead or placeholder syntax
# (e.g. the cross-repo-skill-staleness proposal documents the broken
# `nix run .#agenix` form and the `.#agenix-DEAD` negative-test string
# as cautionary examples). Living docs must stay fresh; archives must
# not be forced to rewrite history. First tripped on PR #131.
ROOTS=(
  CLAUDE.md
  docs
  home
  hosts
  modules
  scripts
)
# Append any extra search roots from the caller (e.g. a sibling .claude
# checkout). Skip those that don't exist so the script also runs cleanly
# on machines without the optional paths.
for arg in "$@"; do
  if [ -e "$arg" ]; then
    ROOTS+=("$arg")
  else
    echo "check-docs-commands: skipping non-existent root: $arg" >&2
  fi
done

# Capture: file:line:`nix run .#<attr>` so a failure points to the
# exact source location, not just the orphan attribute. Exclude this
# script from the search — its own header documents stale examples
# (`.#agenix`, `.#foo.bar`) as cautionary tales, not as live references.
#
# Regex: a valid attribute path is one or more dot-separated segments
# of `[a-zA-Z0-9_-]+`. Trailing dots are deliberately NOT matched so
# placeholder syntax in docs (`.#agenix-rekey.x86_64-linux.<cmd>`) is
# captured as `agenix-rekey.x86_64-linux` — without the orphan dot
# that's not a real attribute terminator.
mapfile -t HITS < <(
  grep -rEHno \
    --exclude="$(basename "$0")" \
    'nix run \.#[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)*' "${ROOTS[@]}" 2>/dev/null \
    || true
)

if [ "${#HITS[@]}" -eq 0 ]; then
  echo "check-docs-commands: no 'nix run .#' references found in ${ROOTS[*]}"
  exit 0
fi

# Build the unique attribute set (sorted) for eval, but keep the
# file:line provenance for the failure path. Initialise both arrays
# explicitly: `set -u` will trip on `${#ATTR_FAIL[@]}` if no key was
# ever assigned (i.e. every reference resolved cleanly).
declare -A ATTR_OK=()
declare -A ATTR_FAIL=()
ATTRS=()
for hit in "${HITS[@]}"; do
  # hit looks like: path/to/file.md:42:nix run .#foo.bar
  attr="${hit##*nix run .#}"
  ATTRS+=("$attr")
done

# Dedupe.
mapfile -t UNIQUE < <(printf '%s\n' "${ATTRS[@]}" | sort -u)

echo "check-docs-commands: validating ${#UNIQUE[@]} unique attribute(s) across ${#HITS[@]} reference site(s)..."

# Probe the same attribute-path chain `nix run` walks. The bare
# `nix eval .#X` only resolves attributes at the flake root; `nix run`
# additionally tries `apps.<system>.<attr>` → `packages.<system>.<attr>`
# → `legacyPackages.<system>.<attr>`. Without this fallback the linter
# false-positives on legitimate `.#feature-vm` style references.
SYSTEM="${NIX_SYSTEM:-x86_64-linux}"
PROBE_PREFIXES=(
  "apps.${SYSTEM}."
  "packages.${SYSTEM}."
  "legacyPackages.${SYSTEM}."
  ""
)

for attr in "${UNIQUE[@]}"; do
  found=0
  for prefix in "${PROBE_PREFIXES[@]}"; do
    if nix eval ".#${prefix}${attr}" --apply 'x: null' >/dev/null 2>&1; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 1 ]; then
    ATTR_OK["$attr"]=1
    echo "  ok    $attr"
  else
    ATTR_FAIL["$attr"]=1
    echo "  STALE $attr" >&2
  fi
done

if [ "${#ATTR_FAIL[@]}" -eq 0 ]; then
  echo "check-docs-commands: all references resolve."
  exit 0
fi

# Failure path: print every site that referenced a stale attribute,
# so a reader knows exactly which lines to fix.
echo >&2
echo "check-docs-commands: ${#ATTR_FAIL[@]} stale reference(s) found:" >&2
for hit in "${HITS[@]}"; do
  attr="${hit##*nix run .#}"
  if [ -n "${ATTR_FAIL[$attr]:-}" ]; then
    echo "  $hit" >&2
  fi
done
echo >&2
echo "Fix the reference (rename to the current attribute) or restore the" >&2
echo "attribute. Background: proposals/2026-06-25-cross-repo-skill-staleness.md" >&2
exit 1
