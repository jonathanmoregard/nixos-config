# smarthome-activator: transactional profile-switch harness. The profile
# adapter preserves nix-env generation/symlink semantics inside a build chroot,
# where the daemon database is intentionally unavailable.
#
# Run: nix build --no-link .#checks.x86_64-linux.smarthome-activator -L
{ pkgs, script }:

let
  mkPackage = name: pkgs.runCommand name { } ''
    mkdir -p "$out/bin"
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > "$out/bin/house-automationd"
    chmod 0555 "$out/bin/house-automationd"
  '';

  v1 = mkPackage "smarthome-activator-v1";
  v2 = mkPackage "smarthome-activator-v2";
  v3 = mkPackage "smarthome-activator-v3";

  systemctlStub = pkgs.writeShellScript "smarthome-activator-systemctl" ''
    set -euo pipefail
    printf 'systemctl' >> "$ACTIVATOR_TEST_LOG"
    printf ' %q' "$@" >> "$ACTIVATOR_TEST_LOG"
    printf '\n' >> "$ACTIVATOR_TEST_LOG"
    current=$(readlink -f "$ACTIVATOR_TEST_PROFILE" || true)
    if [ "''${1:-}" = reset-failed ] && \
       [ -n "''${ACTIVATOR_TEST_START_LIMIT_SENTINEL:-}" ]; then
      rm -f "$ACTIVATOR_TEST_START_LIMIT_SENTINEL"
      exit 0
    fi
    if [ "''${1:-}" = restart ] && \
       [ "''${ACTIVATOR_TEST_START_LIMIT_PATH:-}" = "$current" ]; then
      touch "$ACTIVATOR_TEST_START_LIMIT_SENTINEL"
      exit 0
    fi
    if [ "''${1:-}" = restart ] && \
       [ -n "''${ACTIVATOR_TEST_START_LIMIT_SENTINEL:-}" ] && \
       [ -e "$ACTIVATOR_TEST_START_LIMIT_SENTINEL" ]; then
      exit 1
    fi
    if [ "''${ACTIVATOR_TEST_SIGNAL_PATH:-}" = "$current" ] && \
       [ ! -e "$ACTIVATOR_TEST_SIGNAL_SENTINEL" ]; then
      touch "$ACTIVATOR_TEST_SIGNAL_SENTINEL"
      kill -TERM "$PPID"
    fi
    if [ "''${ACTIVATOR_TEST_ROLLBACK_SIGNAL_PATH:-}" = "$current" ]; then
      kill -TERM "$PPID"
    fi
    if [ "''${ACTIVATOR_TEST_RESTART_FAILURE_PATH:-}" = "$current" ]; then
      exit 1
    fi
  '';

  curlStub = pkgs.writeShellScript "smarthome-activator-curl" ''
    set -euo pipefail
    printf 'curl' >> "$ACTIVATOR_TEST_LOG"
    printf ' %q' "$@" >> "$ACTIVATOR_TEST_LOG"
    printf '\n' >> "$ACTIVATOR_TEST_LOG"
    current=$(readlink -f "$ACTIVATOR_TEST_PROFILE" || true)
    [ "''${ACTIVATOR_TEST_UNHEALTHY_PATH:-}" != "$current" ]
  '';

  sleepStub = pkgs.writeShellScript "smarthome-activator-sleep" ''
    exit 0
  '';

  mvStub = pkgs.writeShellScript "smarthome-activator-mv" ''
    set -euo pipefail
    destination=
    for arg in "$@"; do
      destination=$arg
    done
    if [ "''${ACTIVATOR_TEST_FAIL_SUCCESS_MARKER:-0}" = 1 ]; then
      case "$destination" in
        */last-success) exit 1 ;;
      esac
    fi
    ${pkgs.coreutils}/bin/mv "$@"
    if [ "''${ACTIVATOR_TEST_SIGNAL_AFTER_SUCCESS_MARKER:-0}" = 1 ]; then
      case "$destination" in
        */last-success) kill -TERM "$PPID" ;;
      esac
    fi
  '';

  nixEnvStub = pkgs.writeShellScript "smarthome-activator-nix-env" ''
    set -euo pipefail
    printf 'nix-env' >> "$ACTIVATOR_TEST_LOG"
    printf ' %q' "$@" >> "$ACTIVATOR_TEST_LOG"
    printf '\n' >> "$ACTIVATOR_TEST_LOG"
    [ "$#" -ge 3 ] && [ "$1" = --profile ] || exit 64
    profile=$2
    operation=$3
    shift 3
    case "$operation" in
      --set)
        [ "$#" -eq 1 ] || exit 64
        package_path=$1
        generation=1
        if [ -s "$ACTIVATOR_TEST_GENERATIONS" ]; then
          last_generation=$(${pkgs.coreutils}/bin/tail -n 1 "$ACTIVATOR_TEST_GENERATIONS")
          generation=$((last_generation + 1))
        fi
        generation_link="$profile-$generation-link"
        ln -s "$package_path" "$generation_link"
        temporary_link="$profile.tmp.$$"
        ln -s "$generation_link" "$temporary_link"
        mv -Tf "$temporary_link" "$profile"
        printf '%s\n' "$generation" >> "$ACTIVATOR_TEST_GENERATIONS"
        ;;
      --list-generations)
        [ "$#" -eq 0 ] || exit 64
        current_link=$(readlink "$profile" 2>/dev/null || true)
        while IFS= read -r generation; do
          [ -n "$generation" ] || continue
          suffix=
          [ "$current_link" = "$profile-$generation-link" ] && suffix=' (current)'
          printf '%s 2026-09-21 00:00:00%s\n' "$generation" "$suffix"
        done < "$ACTIVATOR_TEST_GENERATIONS"
        ;;
      --switch-generation)
        [ "$#" -eq 1 ] || exit 64
        requested_generation=$1
        found=0
        while IFS= read -r generation; do
          [ "$generation" = "$requested_generation" ] && found=1
        done < "$ACTIVATOR_TEST_GENERATIONS"
        [ "$found" -eq 1 ] || exit 1
        generation_link="$profile-$requested_generation-link"
        temporary_link="$profile.tmp.$$"
        ln -s "$generation_link" "$temporary_link"
        mv -Tf "$temporary_link" "$profile"
        ;;
      --delete-generations)
        [ "$#" -gt 0 ] || exit 64
        temporary_generations="$ACTIVATOR_TEST_GENERATIONS.tmp"
        : > "$temporary_generations"
        while IFS= read -r generation; do
          delete=0
          for requested in "$@"; do
            [ "$generation" = "$requested" ] && delete=1
          done
          if [ "$delete" -eq 1 ]; then
            rm -f "$profile-$generation-link"
          else
            printf '%s\n' "$generation" >> "$temporary_generations"
          fi
        done < "$ACTIVATOR_TEST_GENERATIONS"
        mv -f "$temporary_generations" "$ACTIVATOR_TEST_GENERATIONS"
        ;;
      *) exit 64 ;;
    esac
  '';
in
pkgs.runCommand "smarthome-activator-harness"
  {
    inherit script;
    nativeBuildInputs = with pkgs; [ bash coreutils ];
  } ''
    set -euo pipefail
    export HOME="$PWD/home"
    export NIX_CONFIG="sandbox = false
    experimental-features = nix-command
    substituters =
    fallback = false"

    STATE_DIR="$PWD/state"
    PROFILE="$PWD/profiles/smarthome"
    STUB_DIR="$PWD/stubs"
    TEST_LOG="$PWD/activator.log"
    SIGNAL_SENTINEL="$PWD/signal-sent"
    START_LIMIT_SENTINEL="$PWD/start-limit-exhausted"
    mkdir -p "$HOME" "$STATE_DIR" "$(dirname "$PROFILE")" "$STUB_DIR"
    ln -s ${systemctlStub} "$STUB_DIR/systemctl"
    ln -s ${curlStub} "$STUB_DIR/curl"
    ln -s ${sleepStub} "$STUB_DIR/sleep"
    ln -s ${mvStub} "$STUB_DIR/mv"
    ln -s ${nixEnvStub} "$STUB_DIR/nix-env"
    export PATH="$STUB_DIR:$PATH"

    export ACTIVATOR_TEST_PROFILE="$PROFILE"
    export ACTIVATOR_TEST_LOG="$TEST_LOG"
    export ACTIVATOR_TEST_SIGNAL_SENTINEL="$SIGNAL_SENTINEL"
    export ACTIVATOR_TEST_GENERATIONS="$PWD/generations"
    export ACTIVATOR_TEST_UNHEALTHY_PATH=${v2}
    : > "$TEST_LOG"
    : > "$ACTIVATOR_TEST_GENERATIONS"

    REV1=1111111111111111111111111111111111111111
    REV2=2222222222222222222222222222222222222222
    REV3=3333333333333333333333333333333333333333
    SERVICE=house-automationd.service
    HEALTH=http://127.0.0.1:9876/healthz

    activate() {
      bash "$script" "$@" "$STATE_DIR" "$PROFILE" "$SERVICE" "$HEALTH"
    }

    assert_profile() {
      expected=$1
      actual=$(readlink -f "$PROFILE")
      [ "$actual" = "$expected" ] || {
        echo "FAIL(profile): expected $expected, got $actual" >&2
        exit 1
      }
    }

    assert_success_marker() {
      revision=$1
      path=$2
      previous=$3
      diff -u \
        <(printf 'rev=%s\npath=%s\nprevious_path=%s\n' "$revision" "$path" "$previous") \
        "$STATE_DIR/last-success"
    }

    expect_failure() {
      label=$1
      shift
      if "$@" > "$label.log" 2>&1; then
        cat "$label.log"
        echo "FAIL($label): expected activation failure" >&2
        exit 1
      fi
    }

    # Argument-pair validation must fail before profile mutation.
    expect_failure service-health-mismatch \
      bash "$script" ${v1} "$REV1" "$STATE_DIR" "$PROFILE" - "$HEALTH"
    [ ! -e "$PROFILE" ] || {
      echo 'FAIL(validation): mismatched service/health mutated profile' >&2
      exit 1
    }

    activate ${v1} "$REV1"
    assert_profile ${v1}
    assert_success_marker "$REV1" ${v1} none

    # Candidate starts but never becomes healthy: restore v1 and leave the
    # successful release marker untouched.
    generations_before_unhealthy=$(cat "$ACTIVATOR_TEST_GENERATIONS")
    expect_failure unhealthy activate ${v2} "$REV2"
    assert_profile ${v1}
    assert_success_marker "$REV1" ${v1} none
    grep -qxF "rev=$REV2" "$STATE_DIR/last-failure"
    grep -qxF "path=${v2}" "$STATE_DIR/last-failure"
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure"
    if ! diff -u \
      <(printf '%s\n' "$generations_before_unhealthy") \
      "$ACTIVATOR_TEST_GENERATIONS"; then
      nix-env --profile "$PROFILE" --list-generations >&2
      echo 'FAIL(failed-generations): failed activation changed generation set' >&2
      exit 1
    fi

    # A crashing candidate can exhaust systemd's start limit while health is
    # polled. Rollback must clear that limit before restarting the stable unit.
    export ACTIVATOR_TEST_START_LIMIT_PATH=${v2}
    export ACTIVATOR_TEST_START_LIMIT_SENTINEL="$START_LIMIT_SENTINEL"
    expect_failure start-limit activate ${v2} "$REV2"
    unset ACTIVATOR_TEST_START_LIMIT_PATH ACTIVATOR_TEST_START_LIMIT_SENTINEL
    assert_profile ${v1}
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure" || {
      cat "$STATE_DIR/last-failure" >&2
      echo 'FAIL(start-limit): stable service restart was rate-limited' >&2
      exit 1
    }
    [ ! -e "$START_LIMIT_SENTINEL" ] || {
      echo 'FAIL(start-limit): rollback left service start limit exhausted' >&2
      exit 1
    }

    # Restart failure follows the same rollback path.
    export ACTIVATOR_TEST_RESTART_FAILURE_PATH=${v3}
    expect_failure restart-failure activate ${v3} "$REV3"
    unset ACTIVATOR_TEST_RESTART_FAILURE_PATH
    assert_profile ${v1}
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure"

    activate ${v3} "$REV3"
    assert_profile ${v3}
    assert_success_marker "$REV3" ${v3} ${v1}

    activate ${v1} "$REV1"
    assert_profile ${v1}
    assert_success_marker "$REV1" ${v1} ${v3}
    generation_count=$(nix-env --profile "$PROFILE" --list-generations | \
      awk '$1 ~ /^[0-9]+$/ { count += 1 } END { print count + 0 }')
    [ "$generation_count" -eq 2 ] || {
      nix-env --profile "$PROFILE" --list-generations >&2
      echo "FAIL(generations): expected 2, got $generation_count" >&2
      exit 1
    }
    grep -qF "nix-env --profile $PROFILE --delete-generations" "$TEST_LOG" || {
      cat "$TEST_LOG"
      echo 'FAIL(generations): activator did not request explicit generation deletion' >&2
      exit 1
    }

    # Atomic success-marker failure must also restore current package.
    generations_before_marker_failure=$(cat "$ACTIVATOR_TEST_GENERATIONS")
    export ACTIVATOR_TEST_FAIL_SUCCESS_MARKER=1
    expect_failure marker-failure activate ${v3} "$REV3"
    unset ACTIVATOR_TEST_FAIL_SUCCESS_MARKER
    assert_profile ${v1}
    assert_success_marker "$REV1" ${v1} ${v3}
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure"
    while IFS= read -r generation; do
      [ -n "$generation" ] || continue
      grep -qxF "$generation" "$ACTIVATOR_TEST_GENERATIONS" || {
        echo "FAIL(marker-failure): preexisting generation $generation was deleted" >&2
        exit 1
      }
    done <<< "$generations_before_marker_failure"

    # Once rollback begins, another TERM must be deferred/ignored until the
    # old profile is healthy and last-failure records the completed rollback.
    export ACTIVATOR_TEST_ROLLBACK_SIGNAL_PATH=${v1}
    expect_failure rollback-signal activate ${v2} "$REV2"
    unset ACTIVATOR_TEST_ROLLBACK_SIGNAL_PATH
    assert_profile ${v1}
    grep -qxF "rev=$REV2" "$STATE_DIR/last-failure"
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure"

    # Interrupt after profile mutation. One-shot systemctl stub signals the
    # activator, then permits rollback restart and old-health verification.
    rm -f "$SIGNAL_SENTINEL"
    export ACTIVATOR_TEST_SIGNAL_PATH=${v3}
    expect_failure signal activate ${v3} "$REV3"
    unset ACTIVATOR_TEST_SIGNAL_PATH
    [ -e "$SIGNAL_SENTINEL" ] || {
      echo 'FAIL(signal): injection edge was not reached' >&2
      exit 1
    }
    assert_profile ${v1}
    grep -qxF 'rollback=complete' "$STATE_DIR/last-failure"

    # Marker rename is the commit point. A signal delivered after the rename
    # must preserve the committed candidate and successful exit.
    export ACTIVATOR_TEST_SIGNAL_AFTER_SUCCESS_MARKER=1
    activate ${v3} "$REV3"
    unset ACTIVATOR_TEST_SIGNAL_AFTER_SUCCESS_MARKER
    assert_profile ${v3}
    assert_success_marker "$REV3" ${v3} ${v1}

    echo 'ok: profile activation, rollback, commit-point signals, and generation pruning'
    touch "$out"
  ''
