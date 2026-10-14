# shellcheck shell=bash
# scripts/security-static.sh — fast, offline, free security scanners.
#
# Run as `nix run .#security-static` (packages.security-static in
# flake.nix wraps this file with pinned tool versions from flake.lock,
# so CI and a laptop run identical scanners). CI runs it in the
# `security-static` job of .github/workflows/ci.yml.
#
# Every tool here is free, never uploads code, needs no network, and
# finishes in ~1 s on this repo (measured 2026-10-04). Slow or host-level
# tools (vulnix/vulnxscan, lynis, ssh-audit, scorecard, flake-checker)
# are deliberately absent; see the PR that added this file.
#
# Baselines are narrow and live next to the code they excuse:
#   zizmor   inline `# zizmor: ignore[<audit>]` comments with a reason
#   poutine  .poutine.yml (one rule skipped, reason inline)
#   actionlint / shellcheck   severity floor (`warning` / `error`)
#
# Usage:
#   security-static              scan the current git checkout
#   security-static --self-test  mutation check: plant an unpinned
#                                action, a fake credential and a
#                                shell error in a scratch copy and
#                                require every scanner to fail on it

root=$(git rev-parse --show-toplevel)

scan() {
  local dir=$1 failed=() rc
  cd "$dir"

  echo "== zizmor (offline, min severity low)"
  zizmor --offline --min-severity low --no-progress .github/workflows || failed+=(zizmor)

  echo "== actionlint (embedded shellcheck at warning+)"
  SHELLCHECK_OPTS="-S warning" actionlint || failed+=(actionlint)

  echo "== gitleaks (full git history)"
  gitleaks git . --redact --no-banner --exit-code 1 || failed+=(gitleaks)

  echo "== shellcheck (tracked *.sh, errors only)"
  rc=0
  git ls-files -z -- '*.sh' | xargs -0 -r shellcheck -S error || rc=$?
  [ "$rc" -eq 0 ] || failed+=(shellcheck)

  echo "== poutine (CI/CD supply chain)"
  poutine analyze_local . --quiet --format pretty --fail-on-violation || failed+=(poutine)

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "security-static: FAILED: ${failed[*]}" >&2
    return 1
  fi
  echo "security-static: all scanners clean"
}

# git in the scratch repo: no user hooks (a local gitleaks pre-commit hook
# would refuse the planted probe), throwaway identity.
pgit() {
  git -C "$scratch" -c core.hooksPath=/dev/null \
    -c user.name=probe -c user.email=probe@invalid "$@"
}

scratch=""
self_test() {
  local probe_ok=1
  # Global, not local: the EXIT trap runs after this function returns.
  scratch=$(mktemp -d)
  trap 'rm -rf -- "$scratch"' EXIT

  # Copy of the tracked working-tree files (so uncommitted edits are tested
  # too) as a fresh one-commit repo; gitleaks scans history.
  (cd "$root" && git ls-files -z | tar --null -T - -c) | tar -x -C "$scratch"
  pgit init -q
  pgit add -A
  pgit commit -q -m base

  echo "## self-test: clean copy must pass"
  if ! (scan "$scratch"); then
    echo "self-test: clean copy failed; fix that first" >&2
    return 1
  fi

  # Probe 1: unpinned third-party action plus PR-title injection under
  # pull_request_target -> zizmor and poutine.
  cat >"$scratch/.github/workflows/probe.yml" <<'EOF'
name: probe
on: pull_request_target
permissions: {}
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: someone/some-action@main
      - run: echo "${{ github.event.pull_request.title }}"
EOF
  # Probe 2: credential-shaped string, assembled at runtime so this
  # script itself never contains one.
  printf 'aws_access_key_id = %s%s\n' "AKIA" "QYLPMN5HHHFPZAM2" >"$scratch/probe-credentials.txt"
  # Probe 3: shell error (unterminated quote) -> shellcheck -S error.
  printf '#!/usr/bin/env bash\necho "unterminated\n' >"$scratch/probe.sh"
  pgit add -A
  pgit commit -q -m probes

  echo "## self-test: probed copy must fail in every scanner"
  local out
  out=$( (scan "$scratch") 2>&1 ) && probe_ok=0
  for tool in zizmor gitleaks shellcheck poutine; do
    if ! grep -q "FAILED:.*\b$tool\b" <<<"$out"; then
      echo "self-test: $tool did not catch its probe" >&2
      probe_ok=0
    fi
  done
  if [ "$probe_ok" -ne 1 ]; then
    printf '%s\n' "$out" | tail -40 >&2
    return 1
  fi
  echo "self-test: every scanner caught its probe"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") scan "$root" ;;
  *) echo "usage: security-static [--self-test]" >&2; exit 2 ;;
esac
