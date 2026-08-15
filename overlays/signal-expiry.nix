# Signal Desktop ships a hard build expiry: the client refuses to open its
# provisioning/auth websocket once `buildExpiration` passes, failing with
# "build expired, not connecting provisioning socket" and presenting to the
# user as "failed to connect to server". Network is fine; the client is
# simply refusing.
#
# Observed 2026-08-08: nixpkgs was pinned at 2026-05-15, shipping
# signal-desktop 8.8.0, whose 90-day window had closed. Signal was
# unusable on dellan until nixpkgs was bumped (8.21.0).
#
# Unlike Beeper (overlays/beeper.nix), we do NOT repackage Signal here.
# Beeper is an AppImage — version + hash is the whole build. signal-desktop
# is a real nixpkgs electron build whose expression changes across releases,
# so pinning our own version would mean maintaining that build. Instead we
# keep Signal from nixpkgs and treat *nixpkgs staleness* as the thing to
# automate: measure Signal's remaining runway, and bump nixpkgs when it
# runs short.
#
# `buildExpiration` is embedded as epoch-milliseconds in Signal's
# config/production.json inside app.asar, and is exactly
# `buildCreation + 90 days`. Reading it from the built package is the only
# fully local way to know the real deadline — the version string alone
# doesn't tell you when it was cut.
#
# Consumed by .github/workflows/update-signal.yml.
final: prev:
{
  # Usage:
  #   check-signal-expiry [flake-ref]     measure <flake-ref>'s locked
  #                                       signal-desktop (default: `.`)
  #   check-signal-expiry --asar <path>   measure a specific app.asar
  #
  # The `--asar` form exists because "which Signal build am I actually
  # running?" is a real question independent of the flake: the installed
  # client under /nix/store, or a `nix run` of some other revision, may
  # differ from what the flake currently locks. It is also what
  # tests/signal-expiry.nix drives, so the harness exercises these exact
  # deployed bytes rather than a reimplementation.
  #
  # Emits `key=value` lines on stdout for CI to parse, plus a human line
  # on stderr. Exit 0 whenever the measurement succeeded — including when
  # the build is ALREADY EXPIRED (days_left goes negative). "Expired" is
  # the condition this tool exists to report, not a tool failure. Exit 1
  # only when the expiry genuinely could not be read.
  #
  # writeShellScriptBin (not writeShellApplication), matching
  # overlays/beeper.nix: grep/sed/date/nix come from the caller's PATH
  # rather than the closure, so this stays buildable on a GitHub runner
  # even when the nixpkgs revision has drifted ahead of the binary cache.
  signal-expiry-check = prev.writeShellScriptBin "check-signal-expiry" ''
    set -euo pipefail

    if [[ "''${1:-}" = "--asar" ]]; then
      if [[ -z "''${2:-}" ]]; then
        echo "check-signal-expiry: --asar requires a path" >&2
        exit 1
      fi
      asar="$2"
      version="unknown"
    else
      flake_ref="''${1:-.}"

      # Build (usually just substitute) signal-desktop from the flake's own
      # locked nixpkgs, so this measures what the config would actually
      # deploy — not whatever nixpkgs the caller happens to have.
      store_path="$(nix build --no-link --print-out-paths \
        "$flake_ref#nixosConfigurations.dellan.pkgs.signal-desktop")"

      version="$(nix eval --raw \
        "$flake_ref#nixosConfigurations.dellan.pkgs.signal-desktop.version")"

      asar="$store_path/share/signal-desktop/app.asar"
    fi

    if [[ ! -f "$asar" ]]; then
      echo "check-signal-expiry: no app.asar at $asar" >&2
      exit 1
    fi

    # config/production.json lives inside the asar blob. Several
    # `buildExpiration` occurrences exist in the bundle (the source default
    # is 0); the real deadline is the largest, so take the max rather than
    # the first match and avoid reporting a bogus 1970 expiry.
    #
    # `|| true`: a no-match grep exits 1, and under `set -o pipefail` that
    # would abort the script right here — exiting 1 with nothing on stderr,
    # so CI would see a bare failure and no reason. Swallow it and let the
    # emptiness check below report properly.
    expiry_ms="$(grep --text --only-matching --extended-regexp \
      '"buildExpiration":[0-9]+' "$asar" \
      | grep --only-matching --extended-regexp '[0-9]+' \
      | sort --numeric-sort | tail -1 || true)"

    if [[ -z "$expiry_ms" || "$expiry_ms" = "0" ]]; then
      echo "check-signal-expiry: could not read buildExpiration from $asar" >&2
      exit 1
    fi

    expiry_s=$(( expiry_ms / 1000 ))
    now_s="$(date +%s)"

    # FLOOR division, not bash's truncate-toward-zero. A build that
    # expired three hours ago has `secs_left = -10800`, and `/ 86400`
    # would report `0 days left` — which reads as "expires today" for a
    # client that is already refusing to connect. Round away from zero
    # on the negative side so "expired" is always strictly negative.
    secs_left=$(( expiry_s - now_s ))
    days_left=$(( secs_left / 86400 ))
    if (( secs_left < 0 && secs_left % 86400 != 0 )); then
      days_left=$(( days_left - 1 ))
    fi

    echo "check-signal-expiry: signal-desktop $version expires $(date -u -d "@$expiry_s" '+%Y-%m-%d %H:%M UTC') — $days_left days left" >&2

    echo "version=$version"
    echo "expiry_epoch=$expiry_s"
    echo "days_left=$days_left"
  '';
}
