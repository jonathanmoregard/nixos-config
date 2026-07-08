# Shell text for the cachix post-build-hook, parameterized over binary
# locations, limits and the token path so the runtime-invocation test
# (tests/cachix-push-filter.nix) can instantiate the SAME logic with
# PATH stubs and a short timeout. cachix-push.nix instantiates it with
# production values (absolute /nix/store binary paths — the hook runs
# from nix-daemon's minimal environment where $PATH is not trustworthy).
#
# Keep ALL hook logic in this template. Anything added directly in
# cachix-push.nix escapes the runtime test.
{ cacheName          # cachix cache to push to
, pushTimeoutSeconds # wall-clock cap per `cachix push` invocation
, maxPathBytes       # skip pushing store paths larger than this
, tokenFile          # path to the cachix auth token (shell-expanded at runtime)
, cachixBin          # cachix executable
, timeoutBin         # coreutils timeout executable
, duBin              # coreutils du executable (path size measurement)
, cutBin             # coreutils cut executable
}:
''
  set -uf
  export IFS=' '
  if [ -z "''${OUT_PATHS:-}" ]; then
    exit 0
  fi
  tokenFile="${tokenFile}"
  if [ ! -r "$tokenFile" ]; then
    # Secret not yet activated (early boot, or recipient mismatch).
    exit 0
  fi

  # Push-budget filter: skip the microvm store disk image (banned by
  # name regardless of size) and any path whose apparent size exceeds
  # maxPathBytes. Oversize blobs can never finish inside the push
  # timeout on dellan's uplink, so every referencing derivation
  # re-attempts the same upload forever (2026-07-07: ~621 MiB erofs
  # re-pushed dozens of times per VM-gate run). An unmeasurable path
  # (du fails) is treated as size 0 and pushed — the filter must never
  # turn a measurement hiccup into a lost push, and rc handling below
  # tolerates a failing push anyway.
  keep=""
  # shellcheck disable=SC2086 # OUT_PATHS is intentionally word-split
  for p in $OUT_PATHS; do
    size="$(${duBin} -sb -- "$p" 2>/dev/null | ${cutBin} -f1)"
    case "$size" in
      "" | *[!0-9]*) size=0 ;;
    esac
    skip=0
    case "''${p##*/}" in
      *-microvm-store-disk.erofs) skip=1 ;;
    esac
    if [ "$size" -gt ${toString maxPathBytes} ]; then
      skip=1
    fi
    if [ "$skip" -eq 1 ]; then
      echo "cachix-push: skipping $p ($size bytes): exceeds push budget" >&2
    else
      keep="$keep$p "
    fi
  done
  OUT_PATHS="''${keep% }"
  if [ -z "$OUT_PATHS" ]; then
    exit 0
  fi

  # Capture the exit code BEFORE any `if`-test or `!`-inversion —
  # bash zeroes `$?` once a conditional has decided, so reading rc
  # from inside an `if ! cmd; then` block always sees 0 and the
  # 124/137 timeout-vs-failure discriminator below would be wrong.
  rc=0
  # shellcheck disable=SC2086 # OUT_PATHS is intentionally word-split
  CACHIX_AUTH_TOKEN="$(< "$tokenFile")" \
    ${timeoutBin} \
      --signal=KILL --kill-after=5s ${toString pushTimeoutSeconds}s \
    ${cachixBin} push ${cacheName} $OUT_PATHS \
    >&2 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = "137" ] || [ "$rc" = "124" ]; then
      echo "cachix-push-hook: timed out after ${toString pushTimeoutSeconds}s pushing $OUT_PATHS" >&2
    else
      echo "cachix-push-hook: cachix push failed with exit $rc (ignoring; build artifact is local)" >&2
    fi
  fi

  # Always succeed: the push is opportunistic.
  exit 0
''
