# smarthome-hydrator: cache-only signature-verification harness for the
# home-server release hydrator. The fixtures use real Nix stores, signatures,
# and file binary caches; only the signing identity is disposable.
#
# Run: nix build --no-link .#checks.x86_64-linux.smarthome-hydrator -L
{ pkgs, script }:

let
  nixWrapper = pkgs.writeShellScript "smarthome-hydrator-nix-wrapper" ''
    set -euo pipefail
    : "''${NIX_WRAPPER_LOG:?NIX_WRAPPER_LOG must be set}"
    : "''${NIX_WRAPPER_SOURCE_URL:?NIX_WRAPPER_SOURCE_URL must be set}"
    : "''${NIX_WRAPPER_TRUSTED_KEY:?NIX_WRAPPER_TRUSTED_KEY must be set}"

    {
      printf 'nix'
      printf ' %q' "$@"
      printf '\n'
    } >> "$NIX_WRAPPER_LOG"

    has_arg() {
      local wanted=$1
      shift
      for arg in "$@"; do
        [ "$arg" = "$wanted" ] && return 0
      done
      return 1
    }

    option_value() {
      local wanted=$1 previous=
      shift
      for arg in "$@"; do
        if [ "$previous" = "$wanted" ]; then
          printf '%s\n' "$arg"
          return 0
        fi
        previous=$arg
      done
      return 1
    }

    fail_argv() {
      printf 'FAIL(nix-wrapper): %s: nix' "$1" >&2
      shift
      printf ' %q' "$@" >&2
      printf '\n' >&2
      exit 86
    }

    require_arg() {
      local required=$1
      shift
      has_arg "$required" "$@" || fail_argv "missing $required" "$@"
    }

    require_arg_once() {
      local required=$1 count=0
      shift
      for arg in "$@"; do
        if [ "$arg" = "$required" ]; then
          count=$((count + 1))
        fi
      done
      [ "$count" -eq 1 ] || fail_argv "expected $required exactly once" "$@"
    }

    require_flag_value() {
      local wanted=$1 expected=$2 previous= count=0
      shift 2
      for arg in "$@"; do
        if [ "$previous" = "$wanted" ]; then
          [ "$arg" = "$expected" ] || \
            fail_argv "$wanted did not use exact expected value" "$@"
          count=$((count + 1))
        fi
        previous=$arg
      done
      [ "$count" -eq 1 ] || \
        fail_argv "expected $wanted with exact value exactly once" "$@"
    }

    require_nix_option() {
      local wanted=$1 expected=$2 before_previous= previous= count=0
      shift 2
      for arg in "$@"; do
        if [ "$before_previous" = --option ] && [ "$previous" = "$wanted" ]; then
          [ "$arg" = "$expected" ] || \
            fail_argv "Nix option $wanted did not use exact expected value" "$@"
          count=$((count + 1))
        fi
        before_previous=$previous
        previous=$arg
      done
      [ "$count" -eq 1 ] || \
        fail_argv "expected Nix option $wanted exactly once" "$@"
    }

    record_class() {
      printf 'CLASS:%s\n' "$1" >> "$NIX_WRAPPER_LOG"
    }

    case "''${1:-}:''${2:-}" in
      copy:*)
        require_arg_once --refresh "$@"
        require_flag_value --from "$NIX_WRAPPER_SOURCE_URL" "$@"
        require_nix_option max-jobs 0 "$@"
        require_nix_option fallback false "$@"
        require_nix_option builders "" "$@"
        require_nix_option always-allow-substitutes true "$@"
        require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEY" "$@"
        record_class copy
        ;;
      store:copy-sigs)
        require_arg_once --refresh "$@"
        require_arg_once --recursive "$@"
        require_flag_value --substituter "$NIX_WRAPPER_SOURCE_URL" "$@"
        record_class copy-sigs
        ;;
      store:verify)
        store_url=$(option_value --store "$@" || true)
        if [ -z "$store_url" ]; then
          require_arg_once --recursive "$@"
          has_arg --no-contents "$@" && fail_argv 'local verification skipped contents' "$@"
          require_flag_value --sigs-needed 1 "$@"
          require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEY" "$@"
          record_class local-verify
        elif [ "$store_url" = "$NIX_WRAPPER_SOURCE_URL" ]; then
          fail_argv 'direct source-store verification is forbidden' "$@"
        else
          case "$store_url" in
            file://*) ;;
            *) fail_argv 'snapshot verification did not use file cache' "$@" ;;
          esac
          require_flag_value --store "$store_url" "$@"
          require_arg_once --no-contents "$@"
          require_arg_once --recursive "$@"
          require_flag_value --sigs-needed 1 "$@"
          require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEY" "$@"
          grep -qxF 'CLASS:source-metadata' "$NIX_WRAPPER_LOG" || \
            fail_argv 'snapshot verification preceded metadata capture' "$@"
          record_class snapshot-verify
        fi
        ;;
      path-info:*)
        store_url=$(option_value --store "$@" || true)
        if [ -n "$store_url" ]; then
          [ "$store_url" = "$NIX_WRAPPER_SOURCE_URL" ] || \
            fail_argv 'metadata query used unexpected remote store' "$@"
          require_flag_value --store "$NIX_WRAPPER_SOURCE_URL" "$@"
          require_arg_once --refresh "$@"
          require_arg_once --json "$@"
          require_arg_once --recursive "$@"
          if grep -qxF 'CLASS:source-metadata' "$NIX_WRAPPER_LOG"; then
            fail_argv 'source metadata fetched more than once' "$@"
          fi
          record_class source-metadata
          status=0
          ${pkgs.nix}/bin/nix "$@" || status=$?
          if [ "$status" -eq 0 ] && [ -n "''${NIX_WRAPPER_MUTATE_SOURCE_DIR:-}" ]; then
            rm -f "''${NIX_WRAPPER_MUTATE_SOURCE_DIR}"/*.narinfo
          fi
          exit "$status"
        elif has_arg --json "$@" && has_arg --recursive "$@"; then
          require_arg_once --json "$@"
          require_arg_once --recursive "$@"
          grep -qxF 'CLASS:snapshot-verify' "$NIX_WRAPPER_LOG" || \
            fail_argv 'local metadata binding preceded snapshot verification' "$@"
          record_class metadata-binding
        else
          fail_argv 'unrecognized path-info command' "$@"
        fi
        ;;
      *)
        fail_argv 'unrecognized nix command' "$@"
        ;;
    esac

    exec ${pkgs.nix}/bin/nix "$@"
  '';

  nixStoreWrapper = pkgs.writeShellScript "smarthome-hydrator-nix-store-wrapper" ''
    printf 'FAIL(nix-wrapper): nix-store is forbidden: nix-store' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    exit 87
  '';
in
pkgs.runCommand "smarthome-hydrator-harness"
  {
    inherit script;
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep jq nix ];
  } ''
    export HOME="$PWD/home"

    TARGET_STORE="$PWD/target-store"
    TARGET_STATE="$PWD/target-state"
    TARGET_LOG="$PWD/target-log"
    SIGNED_CACHE="$PWD/signed-cache"
    UNSIGNED_CACHE="$PWD/unsigned-cache"
    DELAYED_CACHE="$PWD/delayed-cache"
    DELAYED_STAGING_CACHE="$PWD/delayed-staging-cache"
    MUTATION_CACHE="$PWD/mutation-cache"
    SECRET_KEY="$PWD/cache-secret-key"
    WRONG_SECRET_KEY="$PWD/cache-wrong-secret-key"
    PUBLIC_KEY_FILE="$PWD/cache-public-key"

    export NIX_STORE_DIR="$TARGET_STORE"
    export NIX_STATE_DIR="$TARGET_STATE"
    export NIX_LOG_DIR="$TARGET_LOG"
    export NIX_CONFIG="sandbox = false
    experimental-features = nix-command
    substituters =
    fallback = false"
    mkdir -p "$HOME" "$NIX_STORE_DIR" "$NIX_STATE_DIR" "$NIX_LOG_DIR"

    realise_with_root() {
      expected_path=$1
      drv_path=$2
      root_path=$3
      ${pkgs.nix}/bin/nix-store --realise --add-root "$root_path" "$drv_path" > /dev/null
      realised_path=$(readlink -f "$root_path")
      [ "$realised_path" = "$expected_path" ] || {
        echo "FAIL(fixture-realise): expected $expected_path, got $realised_path" >&2
        exit 1
      }
    }

    # Instantiate every fixture in the disposable store. Referencing outer
    # derivations here would give nested Nix paths from the build chroot's
    # unrelated store/database and make the test exercise fixture lookup, not
    # hydration.
    SIGNED_DRV=$(${pkgs.nix}/bin/nix-instantiate -E '
      derivation {
        name = "smarthome-hydrator-signed-leaf";
        system = builtins.currentSystem;
        builder = "${pkgs.bash}/bin/bash";
        args = [ "-c" "printf signed > \"$out\"" ];
      }
    ')
    SIGNED_PATH=$(${pkgs.nix}/bin/nix-store --query --outputs "$SIGNED_DRV")
    realise_with_root "$SIGNED_PATH" "$SIGNED_DRV" "$PWD/result-signed"

    UNSIGNED_DRV=$(${pkgs.nix}/bin/nix-instantiate -E '
      derivation {
        name = "smarthome-hydrator-unsigned-leaf";
        system = builtins.currentSystem;
        builder = "${pkgs.bash}/bin/bash";
        args = [ "-c" "printf unsigned > \"$out\"" ];
      }
    ')
    UNSIGNED_PATH=$(${pkgs.nix}/bin/nix-store --query --outputs "$UNSIGNED_DRV")
    realise_with_root "$UNSIGNED_PATH" "$UNSIGNED_DRV" "$PWD/result-unsigned"

    DELAYED_DRV=$(${pkgs.nix}/bin/nix-instantiate -E '
      derivation {
        name = "smarthome-hydrator-delayed-leaf";
        system = builtins.currentSystem;
        builder = "${pkgs.bash}/bin/bash";
        args = [ "-c" "printf delayed > \"$out\"" ];
      }
    ')
    DELAYED_PATH=$(${pkgs.nix}/bin/nix-store --query --outputs "$DELAYED_DRV")
    realise_with_root "$DELAYED_PATH" "$DELAYED_DRV" "$PWD/result-delayed"

    DEPENDENCY_EXPR='derivation {
      name = "smarthome-hydrator-wrong-key-dependency";
      system = builtins.currentSystem;
      builder = "${pkgs.bash}/bin/bash";
      args = [ "-c" "printf dependency > \"$out\"" ];
    }'
    DEPENDENCY_DRV=$(${pkgs.nix}/bin/nix-instantiate -E "$DEPENDENCY_EXPR")
    UNSIGNED_DEPENDENCY_PATH=$(${pkgs.nix}/bin/nix-store --query --outputs "$DEPENDENCY_DRV")
    realise_with_root "$UNSIGNED_DEPENDENCY_PATH" "$DEPENDENCY_DRV" "$PWD/result-dependency"

    CLOSURE_ROOT_DRV=$(${pkgs.nix}/bin/nix-instantiate -E '
      let dependency = '"$DEPENDENCY_EXPR"';
      in derivation {
        name = "smarthome-hydrator-closure-root";
        system = builtins.currentSystem;
        builder = "${pkgs.bash}/bin/bash";
        args = [ "-c" "printf %s \"$dependency\" > \"$out\"" ];
        inherit dependency;
      }
    ')
    SIGNED_CLOSURE_ROOT=$(${pkgs.nix}/bin/nix-store --query --outputs "$CLOSURE_ROOT_DRV")
    realise_with_root "$SIGNED_CLOSURE_ROOT" "$CLOSURE_ROOT_DRV" "$PWD/result-closure-root"

    # Every signature-sensitive fixture must remain ordinary input-addressed.
    # Content-addressed fixtures could pass verification without a signature.
    ${pkgs.nix}/bin/nix path-info --json \
      "$SIGNED_PATH" \
      "$UNSIGNED_PATH" \
      "$DELAYED_PATH" \
      "$UNSIGNED_DEPENDENCY_PATH" \
      "$SIGNED_CLOSURE_ROOT" \
      | ${pkgs.jq}/bin/jq -e 'to_entries | all(.value.ca == null)' > /dev/null || {
        echo 'FAIL: signature fixture is content-addressed' >&2
        exit 1
      }

    ${pkgs.nix}/bin/nix key generate-secret \
      --key-name smarthome-hydrator-test-1 > "$SECRET_KEY"
    ${pkgs.nix}/bin/nix key generate-secret \
      --key-name smarthome-hydrator-test-1 > "$WRONG_SECRET_KEY"
    ${pkgs.nix}/bin/nix key convert-secret-to-public \
      < "$SECRET_KEY" > "$PUBLIC_KEY_FILE"
    PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")

    ${pkgs.nix}/bin/nix copy --to "file://$SIGNED_CACHE" "$SIGNED_PATH"
    ${pkgs.nix}/bin/nix store sign --store "file://$SIGNED_CACHE" \
      --key-file "$SECRET_KEY" "$SIGNED_PATH"
    ${pkgs.nix}/bin/nix copy --to "file://$UNSIGNED_CACHE" "$UNSIGNED_PATH"
    ${pkgs.nix}/bin/nix copy --to "file://$DELAYED_STAGING_CACHE" "$DELAYED_PATH"
    ${pkgs.nix}/bin/nix store sign --store "file://$DELAYED_STAGING_CACHE" \
      --key-file "$SECRET_KEY" "$DELAYED_PATH"
    mkdir -p "$DELAYED_CACHE"
    cp "$DELAYED_STAGING_CACHE/nix-cache-info" "$DELAYED_CACHE/nix-cache-info"
    ${pkgs.nix}/bin/nix copy --to "file://$SIGNED_CACHE" "$SIGNED_CLOSURE_ROOT"
    ${pkgs.nix}/bin/nix store sign --store "file://$SIGNED_CACHE" \
      --key-file "$SECRET_KEY" "$SIGNED_CLOSURE_ROOT"
    ${pkgs.nix}/bin/nix store sign --store "file://$SIGNED_CACHE" \
      --key-file "$WRONG_SECRET_KEY" "$UNSIGNED_DEPENDENCY_PATH"
    cp -R "$SIGNED_CACHE" "$MUTATION_CACHE"

    # Roots guard fixtures from automatic GC until both caches are complete.
    # Then remove every output and drv from the disposable target store so the
    # helper can only hydrate from the selected cache.
    rm -f \
      "$PWD/result-signed" \
      "$PWD/result-unsigned" \
      "$PWD/result-delayed" \
      "$PWD/result-dependency" \
      "$PWD/result-closure-root"
    ${pkgs.nix}/bin/nix-store --gc > /dev/null
    for fixture_path in \
      "$SIGNED_PATH" \
      "$UNSIGNED_PATH" \
      "$DELAYED_PATH" \
      "$UNSIGNED_DEPENDENCY_PATH" \
      "$SIGNED_CLOSURE_ROOT" \
      "$SIGNED_DRV" \
      "$UNSIGNED_DRV" \
      "$DELAYED_DRV" \
      "$DEPENDENCY_DRV" \
      "$CLOSURE_ROOT_DRV"; do
      if ${pkgs.nix}/bin/nix-store --check-validity "$fixture_path" 2> /dev/null; then
        echo "FAIL(fixture-gc): path remained valid: $fixture_path" >&2
        exit 1
      fi
    done

    NIX_WRAPPER_DIR="$PWD/nix-wrapper-bin"
    export NIX_WRAPPER_LOG="$PWD/nix-wrapper.log"
    mkdir -p "$NIX_WRAPPER_DIR"
    ln -s ${nixWrapper} "$NIX_WRAPPER_DIR/nix"
    ln -s ${nixStoreWrapper} "$NIX_WRAPPER_DIR/nix-store"
    export PATH="$NIX_WRAPPER_DIR:$PATH"
    : > "$NIX_WRAPPER_LOG"

    assert_wrapper_rejects_unknown_commands() {
      export NIX_WRAPPER_SOURCE_URL="file://$SIGNED_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      if nix --version > unknown-nix.log 2>&1; then
        echo 'FAIL(nix-wrapper): unknown nix command reached real binary' >&2
        exit 1
      fi
      grep -qF 'unrecognized nix command' unknown-nix.log || {
        cat unknown-nix.log
        echo 'FAIL(nix-wrapper): missing unknown-command diagnostic' >&2
        exit 1
      }
      if nix-store --version > unknown-nix-store.log 2>&1; then
        echo 'FAIL(nix-wrapper): nix-store reached real binary' >&2
        exit 1
      fi
      grep -qF 'nix-store is forbidden' unknown-nix-store.log || {
        cat unknown-nix-store.log
        echo 'FAIL(nix-wrapper): missing nix-store diagnostic' >&2
        exit 1
      }
      : > "$NIX_WRAPPER_LOG"
    }

    assert_wrapper_rejects_unknown_commands

    MISSING_PATH="$TARGET_STORE/00000000000000000000000000000000-missing"

    reset_target() {
      rm -rf "$TARGET_STORE" "$TARGET_STATE" "$TARGET_LOG"
      mkdir -p "$TARGET_STORE" "$TARGET_STATE" "$TARGET_LOG"
    }

    invoke() {
      reset_target
      : > "$NIX_WRAPPER_LOG"
      export NIX_WRAPPER_SOURCE_URL=
      export NIX_WRAPPER_TRUSTED_KEY=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --from)
            NIX_WRAPPER_SOURCE_URL=$2
            shift 2
            ;;
          --trusted-key)
            NIX_WRAPPER_TRUSTED_KEY=$2
            shift 2
            ;;
          *)
            break
            ;;
        esac
      done
      NIX_STORE_DIR="$TARGET_STORE" \
      NIX_STATE_DIR="$TARGET_STATE" \
      NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 2 --attempts 1 \
          --from "$NIX_WRAPPER_SOURCE_URL" \
          --trusted-key "$NIX_WRAPPER_TRUSTED_KEY" \
          "$@"
    }

    assert_wrapper_class_once() {
      class=$1
      count=$(grep -cFx "CLASS:$class" "$NIX_WRAPPER_LOG" || true)
      [ "$count" -eq 1 ] || {
        cat "$NIX_WRAPPER_LOG"
        echo "FAIL(nix-wrapper): expected class $class exactly once, got $count" >&2
        exit 1
      }
    }

    assert_success_classes() {
      for class in copy copy-sigs local-verify source-metadata snapshot-verify metadata-binding; do
        assert_wrapper_class_once "$class"
      done
    }

    expect_success() {
      label="$1"
      shift
      if ! invoke "$@" > "$label.log" 2>&1; then
        cat "$label.log"
        echo "FAIL($label): expected hydration to succeed" >&2
        exit 1
      fi
    }

    expect_failure() {
      label="$1"
      expected="$2"
      shift 2
      if invoke "$@" > "$label.log" 2>&1; then
        cat "$label.log"
        echo "FAIL($label): expected hydration to fail" >&2
        exit 1
      fi
      grep -qF "$expected" "$label.log" || {
        cat "$label.log"
        echo "FAIL($label): expected log to contain: $expected" >&2
        exit 1
      }
    }

    expect_delayed_publication_success() {
      local helper_status publisher_pid
      reset_target
      : > "$NIX_WRAPPER_LOG"
      export NIX_WRAPPER_SOURCE_URL="file://$DELAYED_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      : > delayed-publication.log
      (
        published=0
        for _ in $(seq 1 100); do
          # Helper prints captured copy diagnostics only after first copy
          # attempt has failed. Publish through cache adapter after that edge.
          if [ -s delayed-publication.log ]; then
            cp delayed-publication.log delayed-initial-miss.log
            mkdir -p "$DELAYED_CACHE/nar"
            cp -R "$DELAYED_STAGING_CACHE/nar/." "$DELAYED_CACHE/nar/"
            # Publish narinfo last so readers never see metadata before NAR.
            cp "$DELAYED_STAGING_CACHE/"*.narinfo "$DELAYED_CACHE/"
            published=1
            break
          fi
          sleep 0.05
        done
        [ "$published" -eq 1 ] || {
          echo 'FAIL(delayed-publication): first miss was not observed' >&2
          exit 1
        }
      ) &
      publisher_pid=$!

      helper_status=0
      NIX_STORE_DIR="$TARGET_STORE" \
      NIX_STATE_DIR="$TARGET_STATE" \
      NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 6 --interval 1 --attempts 4 \
          --from "file://$DELAYED_CACHE" \
          --trusted-key "$PUBLIC_KEY" \
          "$DELAYED_PATH" > delayed-publication.log 2>&1 || helper_status=$?

      if ! wait "$publisher_pid"; then
        cat delayed-publication.log
        echo 'FAIL(delayed-publication): publisher failed' >&2
        exit 1
      fi
      [ -s delayed-initial-miss.log ] || {
        echo 'FAIL(delayed-publication): missing initial failure evidence' >&2
        exit 1
      }
      if [ "$helper_status" -ne 0 ]; then
        cat delayed-publication.log
        echo 'FAIL(delayed-publication): refreshed retry did not hydrate path' >&2
        exit 1
      fi
    }

    expect_source_mutation_after_capture_success() {
      export NIX_WRAPPER_MUTATE_SOURCE_DIR="$MUTATION_CACHE"
      if ! invoke \
        --from "file://$MUTATION_CACHE" \
        --trusted-key "$PUBLIC_KEY" \
        "$SIGNED_PATH" > source-mutation.log 2>&1; then
        cat source-mutation.log
        echo 'FAIL(source-mutation): snapshot did not survive source mutation' >&2
        exit 1
      fi
      unset NIX_WRAPPER_MUTATE_SOURCE_DIR
      if find "$MUTATION_CACHE" -maxdepth 1 -name '*.narinfo' -print -quit | grep -q .; then
        echo 'FAIL(source-mutation): source narinfo was not deleted after capture' >&2
        exit 1
      fi
      assert_success_classes
    }

    expect_preexisting_wrong_key_dependency_failure() {
      reset_target
      : > "$NIX_WRAPPER_LOG"
      export NIX_WRAPPER_SOURCE_URL="file://$SIGNED_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      ${pkgs.nix}/bin/nix copy \
        --from "file://$SIGNED_CACHE" \
        --option require-sigs false \
        "$UNSIGNED_DEPENDENCY_PATH"
      ${pkgs.nix}/bin/nix path-info "$UNSIGNED_DEPENDENCY_PATH" > /dev/null || {
        echo 'FAIL(preexisting-wrong-key-dependency): pre-seed failed' >&2
        exit 1
      }
      # Model a locally trusted preexisting path while leaving cache metadata
      # signed only by the same-named wrong key. Local verification must pass;
      # source-cache exact-key verification must still reject the closure.
      ${pkgs.nix}/bin/nix store sign \
        --key-file "$SECRET_KEY" \
        "$UNSIGNED_DEPENDENCY_PATH"
      if NIX_STORE_DIR="$TARGET_STORE" \
        NIX_STATE_DIR="$TARGET_STATE" \
        NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 2 --attempts 1 \
          --from "file://$SIGNED_CACHE" \
          --trusted-key "$PUBLIC_KEY" \
          "$SIGNED_CLOSURE_ROOT" > preexisting-wrong-key-dependency.log 2>&1; then
        cat preexisting-wrong-key-dependency.log
        echo 'FAIL(preexisting-wrong-key-dependency): expected hydration to fail' >&2
        exit 1
      fi
      grep -qF 'release cache signature verification failed' \
        preexisting-wrong-key-dependency.log || {
        cat preexisting-wrong-key-dependency.log
        echo 'FAIL(preexisting-wrong-key-dependency): expected cache signature diagnostic' >&2
        exit 1
      }
      grep -qF 'is untrusted' preexisting-wrong-key-dependency.log || {
        cat preexisting-wrong-key-dependency.log
        echo 'FAIL(preexisting-wrong-key-dependency): source verification diagnostic was swallowed' >&2
        exit 1
      }
      ${pkgs.nix}/bin/nix path-info "$SIGNED_CLOSURE_ROOT" > /dev/null || {
        cat preexisting-wrong-key-dependency.log
        echo 'FAIL(preexisting-wrong-key-dependency): root was not copied before trust rejection' >&2
        exit 1
      }
    }

    expect_success signed \
      --from "file://$SIGNED_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$SIGNED_PATH"
    assert_success_classes
    expect_source_mutation_after_capture_success
    expect_delayed_publication_success
    expect_failure unsigned 'signature verification failed' \
      --from "file://$UNSIGNED_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$UNSIGNED_PATH"
    expect_failure missing 'not available' \
      --from "file://$SIGNED_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$MISSING_PATH"
    expect_preexisting_wrong_key_dependency_failure

    echo 'ok: signed, delayed, and source-mutated closures hydrated; unsigned, wrong-key dependency, and unavailable paths refused'
    touch "$out"
  ''
