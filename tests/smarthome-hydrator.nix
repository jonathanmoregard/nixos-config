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
    : "''${NIX_WRAPPER_SUBSTITUTERS:?NIX_WRAPPER_SUBSTITUTERS must be set}"
    : "''${NIX_WRAPPER_TRUSTED_KEYS:?NIX_WRAPPER_TRUSTED_KEYS must be set}"
    : "''${NIX_WRAPPER_CACHE_URLS:?NIX_WRAPPER_CACHE_URLS must be set}"
    NIX_WRAPPER_PRECOPY_URL=''${NIX_WRAPPER_PRECOPY_URL:-}
    NIX_WRAPPER_PRECOPY_PATH=''${NIX_WRAPPER_PRECOPY_PATH:-}
    NIX_WRAPPER_BUILD_SOURCE_URL=''${NIX_WRAPPER_BUILD_SOURCE_URL:-$NIX_WRAPPER_SOURCE_URL}
    NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL=''${NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL:-}
    NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER=''${NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER:-}

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

    require_allowed_cache() {
      local candidate=$1 allowed
      for allowed in $NIX_WRAPPER_CACHE_URLS; do
        [ "$candidate" = "$allowed" ] && return 0
      done
      fail_argv "cache is not configured: $candidate" "$@"
    }

    case "''${1:-}:''${2:-}" in
      build:*)
        require_arg_once --no-link "$@"
        require_arg_once --refresh "$@"
        require_nix_option max-jobs 0 "$@"
        require_nix_option fallback false "$@"
        require_nix_option builders "" "$@"
        require_nix_option always-allow-substitutes true "$@"
        require_nix_option substituters "$NIX_WRAPPER_SUBSTITUTERS" "$@"
        require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEYS" "$@"
        record_class copy
        target="''${!#}"
        if [ -n "$NIX_WRAPPER_PRECOPY_URL" ]; then
          [ -n "$NIX_WRAPPER_PRECOPY_PATH" ] || \
            fail_argv 'precopy URL lacks path' "$@"
          ${pkgs.nix}/bin/nix copy \
            --refresh \
            --from "$NIX_WRAPPER_PRECOPY_URL" \
            --option max-jobs 0 \
            --option fallback false \
            --option builders "" \
            --option always-allow-substitutes true \
            --option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEYS" \
            "$NIX_WRAPPER_PRECOPY_PATH"
        fi
        # Disposable tests use a nonstandard StoreDir, unlike production.
        # Validate exact production argv above, then translate hydration into
        # equivalent signed cache copies against the disposable store.
        exec ${pkgs.nix}/bin/nix copy \
          --refresh \
          --from "$NIX_WRAPPER_BUILD_SOURCE_URL" \
          --option max-jobs 0 \
          --option fallback false \
          --option builders "" \
          --option always-allow-substitutes true \
          --option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEYS" \
          "$target"
        ;;
      store:copy-sigs)
        require_arg_once --refresh "$@"
        require_arg_once --recursive "$@"
        substituter=$(option_value --substituter "$@" || true)
        [ -n "$substituter" ] || fail_argv 'missing --substituter' "$@"
        require_allowed_cache "$substituter" "$@"
        require_flag_value --substituter "$substituter" "$@"
        record_class copy-sigs
        if [ -n "$NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL" ]; then
          [ -n "$NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER" ] || \
            fail_argv 'copy-sigs fail-once URL lacks marker' "$@"
          if [ "$substituter" = "$NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL" ] \
            && [ ! -e "$NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER" ]; then
            : > "$NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER"
            exit 1
          fi
          exec ${pkgs.nix}/bin/nix "$@"
        fi
        ;;
      store:verify)
        store_url=$(option_value --store "$@" || true)
        if [ -z "$store_url" ]; then
          require_arg_once --recursive "$@"
          has_arg --no-contents "$@" && fail_argv 'local verification skipped contents' "$@"
          require_flag_value --sigs-needed 1 "$@"
          require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEYS" "$@"
          grep -qxF 'CLASS:closure-snapshot-verify' "$NIX_WRAPPER_LOG" || \
            fail_argv 'local verification preceded closure snapshot verification' "$@"
          record_class local-verify
        elif [ "$store_url" = "$NIX_WRAPPER_SOURCE_URL" ]; then
          fail_argv 'direct source-store verification is forbidden' "$@"
        elif has_arg --recursive "$@"; then
          case "$store_url" in
            file://*) ;;
            *) fail_argv 'closure snapshot verification did not use file cache' "$@" ;;
          esac
          require_flag_value --store "$store_url" "$@"
          require_arg_once --recursive "$@"
          require_arg_once --no-contents "$@"
          require_flag_value --sigs-needed 1 "$@"
          require_nix_option trusted-public-keys "$NIX_WRAPPER_TRUSTED_KEYS" "$@"
          grep -qxF 'CLASS:closure-metadata' "$NIX_WRAPPER_LOG" || \
            fail_argv 'closure snapshot verification preceded metadata capture' "$@"
          record_class closure-snapshot-verify
        else
          case "$store_url" in
            file://*) ;;
            *) fail_argv 'snapshot verification did not use file cache' "$@" ;;
          esac
          require_flag_value --store "$store_url" "$@"
          require_arg_once --no-contents "$@"
          has_arg --recursive "$@" && fail_argv 'root snapshot verification was recursive' "$@"
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
          has_arg --recursive "$@" && fail_argv 'primary root metadata query was recursive' "$@"
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
        elif has_arg --json "$@"; then
          require_arg_once --json "$@"
          if has_arg --recursive "$@"; then
            require_arg_once --recursive "$@"
            grep -qxF 'CLASS:copy-sigs' "$NIX_WRAPPER_LOG" || \
              fail_argv 'closure metadata query preceded signature import' "$@"
            record_class closure-metadata
          else
            grep -qxF 'CLASS:snapshot-verify' "$NIX_WRAPPER_LOG" || \
              fail_argv 'local metadata binding preceded snapshot verification' "$@"
            record_class metadata-binding
          fi
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
    SPLIT_ROOT_CACHE="$PWD/split-root-cache"
    UPSTREAM_CACHE="$PWD/upstream-cache"
    COMBINED_CACHE="$PWD/combined-cache"
    CA_COMPLETE_CACHE="$PWD/ca-complete-cache"
    CA_ROOT_CACHE="$PWD/ca-root-cache"
    CA_INPUT="$PWD/ca-dependency-input"
    SECRET_KEY="$PWD/cache-secret-key"
    WRONG_SECRET_KEY="$PWD/cache-wrong-secret-key"
    UPSTREAM_SECRET_KEY="$PWD/upstream-cache-secret-key"
    PUBLIC_KEY_FILE="$PWD/cache-public-key"
    UPSTREAM_PUBLIC_KEY_FILE="$PWD/upstream-cache-public-key"

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

    printf 'content-addressed dependency\n' > "$CA_INPUT"
    CA_DEPENDENCY_PATH=$(${pkgs.nix}/bin/nix store add-file "$CA_INPUT")
    CA_ROOT_DRV=$(${pkgs.nix}/bin/nix-instantiate -E '
      let dependency = builtins.storePath "'"$CA_DEPENDENCY_PATH"'";
      in derivation {
        name = "smarthome-hydrator-ca-root";
        system = builtins.currentSystem;
        builder = "${pkgs.bash}/bin/bash";
        args = [ "-c" "printf %s \"$dependency\" > \"$out\"" ];
        inherit dependency;
      }
    ')
    SIGNED_CA_ROOT=$(${pkgs.nix}/bin/nix-store --query --outputs "$CA_ROOT_DRV")
    realise_with_root "$SIGNED_CA_ROOT" "$CA_ROOT_DRV" "$PWD/result-ca-root"

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
    ${pkgs.nix}/bin/nix path-info --json "$CA_DEPENDENCY_PATH" \
      | ${pkgs.jq}/bin/jq -e \
        'to_entries | all(.value.ca != null and (.value.signatures | length == 0))' \
        > /dev/null || {
      echo 'FAIL: CA dependency fixture is not unsigned content-addressed' >&2
      exit 1
    }

    ${pkgs.nix}/bin/nix key generate-secret \
      --key-name smarthome-hydrator-test-1 > "$SECRET_KEY"
    ${pkgs.nix}/bin/nix key generate-secret \
      --key-name smarthome-hydrator-test-1 > "$WRONG_SECRET_KEY"
    ${pkgs.nix}/bin/nix key generate-secret \
      --key-name smarthome-hydrator-upstream-test-1 > "$UPSTREAM_SECRET_KEY"
    ${pkgs.nix}/bin/nix key convert-secret-to-public \
      < "$SECRET_KEY" > "$PUBLIC_KEY_FILE"
    ${pkgs.nix}/bin/nix key convert-secret-to-public \
      < "$UPSTREAM_SECRET_KEY" > "$UPSTREAM_PUBLIC_KEY_FILE"
    PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")
    UPSTREAM_PUBLIC_KEY=$(cat "$UPSTREAM_PUBLIC_KEY_FILE")

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
    cp -R "$SIGNED_CACHE" "$SPLIT_ROOT_CACHE"
    dependency_cache_hash=$(basename "$UNSIGNED_DEPENDENCY_PATH")
    dependency_cache_hash=''${dependency_cache_hash%%-*}
    dependency_narinfo="$SPLIT_ROOT_CACHE/$dependency_cache_hash.narinfo"
    dependency_nar=$(sed -n 's/^URL: //p' "$dependency_narinfo")
    rm -f "$SPLIT_ROOT_CACHE/$dependency_nar" "$dependency_narinfo"
    ${pkgs.nix}/bin/nix copy --to "file://$UPSTREAM_CACHE" "$UNSIGNED_DEPENDENCY_PATH"
    ${pkgs.nix}/bin/nix store sign --store "file://$UPSTREAM_CACHE" \
      --key-file "$UPSTREAM_SECRET_KEY" "$UNSIGNED_DEPENDENCY_PATH"
    cp -R "$SPLIT_ROOT_CACHE" "$COMBINED_CACHE"
    mkdir -p "$COMBINED_CACHE/nar"
    cp -R "$UPSTREAM_CACHE/nar/." "$COMBINED_CACHE/nar/"
    cp "$UPSTREAM_CACHE/"*.narinfo "$COMBINED_CACHE/"
    ${pkgs.nix}/bin/nix copy --to "file://$CA_COMPLETE_CACHE" "$SIGNED_CA_ROOT"
    ${pkgs.nix}/bin/nix store sign --store "file://$CA_COMPLETE_CACHE" \
      --key-file "$SECRET_KEY" "$SIGNED_CA_ROOT"
    cp -R "$CA_COMPLETE_CACHE" "$CA_ROOT_CACHE"
    ca_dependency_cache_hash=$(basename "$CA_DEPENDENCY_PATH")
    ca_dependency_cache_hash=''${ca_dependency_cache_hash%%-*}
    ca_dependency_narinfo="$CA_ROOT_CACHE/$ca_dependency_cache_hash.narinfo"
    ca_dependency_nar=$(sed -n 's/^URL: //p' "$ca_dependency_narinfo")
    rm -f "$CA_ROOT_CACHE/$ca_dependency_nar" "$ca_dependency_narinfo"
    cp -R "$SIGNED_CACHE" "$MUTATION_CACHE"

    # Roots guard fixtures from automatic GC until both caches are complete.
    # Then remove every output and drv from the disposable target store so the
    # helper can only hydrate from the selected cache.
    rm -f \
      "$PWD/result-signed" \
      "$PWD/result-unsigned" \
      "$PWD/result-delayed" \
      "$PWD/result-dependency" \
      "$PWD/result-closure-root" \
      "$PWD/result-ca-root"
    ${pkgs.nix}/bin/nix-store --gc > /dev/null
    for fixture_path in \
      "$SIGNED_PATH" \
      "$UNSIGNED_PATH" \
      "$DELAYED_PATH" \
      "$UNSIGNED_DEPENDENCY_PATH" \
      "$SIGNED_CLOSURE_ROOT" \
      "$CA_DEPENDENCY_PATH" \
      "$SIGNED_CA_ROOT" \
      "$SIGNED_DRV" \
      "$UNSIGNED_DRV" \
      "$DELAYED_DRV" \
      "$DEPENDENCY_DRV" \
      "$CLOSURE_ROOT_DRV" \
      "$CA_ROOT_DRV"; do
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
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH NIX_WRAPPER_BUILD_SOURCE_URL \
        NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER
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
      cache_args=()
      source_urls=()
      trusted_keys=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --from)
            cache_args+=("$1" "$2")
            source_urls+=("$2")
            shift 2
            ;;
          --trusted-key)
            cache_args+=("$1" "$2")
            trusted_keys+=("$2")
            shift 2
            ;;
          *)
            break
            ;;
        esac
      done
      export NIX_WRAPPER_SOURCE_URL="''${source_urls[0]}"
      export NIX_WRAPPER_TRUSTED_KEY="''${trusted_keys[0]}"
      export NIX_WRAPPER_SUBSTITUTERS="$(IFS=' '; printf '%s' "''${source_urls[*]}")"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SUBSTITUTERS"
      export NIX_WRAPPER_TRUSTED_KEYS="$(IFS=' '; printf '%s' "''${trusted_keys[*]}")"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH NIX_WRAPPER_BUILD_SOURCE_URL
      NIX_STORE_DIR="$TARGET_STORE" \
      NIX_STATE_DIR="$TARGET_STATE" \
      NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 2 --attempts 1 \
          "''${cache_args[@]}" \
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
      for class in copy copy-sigs closure-metadata closure-snapshot-verify local-verify source-metadata snapshot-verify metadata-binding; do
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
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH NIX_WRAPPER_BUILD_SOURCE_URL
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
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH NIX_WRAPPER_BUILD_SOURCE_URL
      ${pkgs.nix}/bin/nix copy \
        --from "file://$SIGNED_CACHE" \
        --option require-sigs false \
        "$UNSIGNED_DEPENDENCY_PATH"
      ${pkgs.nix}/bin/nix path-info "$UNSIGNED_DEPENDENCY_PATH" > /dev/null || {
        echo 'FAIL(preexisting-wrong-key-dependency): pre-seed failed' >&2
        exit 1
      }
      # Model a preexisting dependency carrying only a same-named wrong-key
      # signature. Hydration skips present paths, so recursive verification
      # must still reject it rather than trusting the root alone.
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
      grep -qF 'release closure cache signature verification failed' \
        preexisting-wrong-key-dependency.log || {
        cat preexisting-wrong-key-dependency.log
        echo 'FAIL(preexisting-wrong-key-dependency): expected closure signature diagnostic' >&2
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

    expect_preexisting_ultimate_dependency_failure() {
      reset_target
      : > "$NIX_WRAPPER_LOG"
      local_dependency_drv=$(${pkgs.nix}/bin/nix-instantiate -E "$DEPENDENCY_EXPR")
      local_dependency_path=$(${pkgs.nix}/bin/nix-store --query --outputs "$local_dependency_drv")
      [ "$local_dependency_path" = "$UNSIGNED_DEPENDENCY_PATH" ] || {
        echo 'FAIL(preexisting-ultimate-dependency): local output path changed' >&2
        exit 1
      }
      ${pkgs.nix}/bin/nix-store --realise "$local_dependency_drv" > /dev/null
      ${pkgs.nix}/bin/nix path-info --json "$local_dependency_path" \
        | ${pkgs.jq}/bin/jq -e --arg path "$local_dependency_path" \
          '.[$path].ultimate == true and (.[$path].signatures | length == 0)' \
          > /dev/null || {
        echo 'FAIL(preexisting-ultimate-dependency): fixture is not unsigned and ultimate' >&2
        exit 1
      }

      export NIX_WRAPPER_SOURCE_URL="file://$SPLIT_ROOT_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY"
      export NIX_WRAPPER_BUILD_SOURCE_URL="file://$COMBINED_CACHE"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH
      if NIX_STORE_DIR="$TARGET_STORE" \
        NIX_STATE_DIR="$TARGET_STATE" \
        NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 2 --attempts 1 \
          --from "$NIX_WRAPPER_SOURCE_URL" \
          --trusted-key "$PUBLIC_KEY" \
          "$SIGNED_CLOSURE_ROOT" > preexisting-ultimate-dependency.log 2>&1; then
        cat preexisting-ultimate-dependency.log
        echo 'FAIL(preexisting-ultimate-dependency): expected hydration to fail' >&2
        exit 1
      fi
      grep -qF 'release closure contains a path without an allowed cache signature' \
        preexisting-ultimate-dependency.log || {
        cat preexisting-ultimate-dependency.log
        echo 'FAIL(preexisting-ultimate-dependency): expected closure signature diagnostic' >&2
        exit 1
      }
    }

    expect_delayed_dependency_signature_success() {
      reset_target
      : > "$NIX_WRAPPER_LOG"
      local_dependency_drv=$(${pkgs.nix}/bin/nix-instantiate -E "$DEPENDENCY_EXPR")
      local_dependency_path=$(${pkgs.nix}/bin/nix-store --query --outputs "$local_dependency_drv")
      [ "$local_dependency_path" = "$UNSIGNED_DEPENDENCY_PATH" ] || {
        echo 'FAIL(delayed-dependency-signature): local output path changed' >&2
        exit 1
      }
      ${pkgs.nix}/bin/nix-store --realise "$local_dependency_drv" > /dev/null
      ${pkgs.nix}/bin/nix path-info --json "$local_dependency_path" \
        | ${pkgs.jq}/bin/jq -e --arg path "$local_dependency_path" \
          '.[$path].ultimate == true and (.[$path].signatures | length == 0)' \
          > /dev/null || {
        echo 'FAIL(delayed-dependency-signature): fixture is not unsigned and ultimate' >&2
        exit 1
      }

      signature_marker="$PWD/delayed-dependency-signature.marker"
      rm -f "$signature_marker"
      export NIX_WRAPPER_SOURCE_URL="file://$SPLIT_ROOT_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL file://$UPSTREAM_CACHE"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SUBSTITUTERS"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY $UPSTREAM_PUBLIC_KEY"
      export NIX_WRAPPER_BUILD_SOURCE_URL="file://$COMBINED_CACHE"
      export NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL="file://$UPSTREAM_CACHE"
      export NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER="$signature_marker"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH
      if ! NIX_STORE_DIR="$TARGET_STORE" \
        NIX_STATE_DIR="$TARGET_STATE" \
        NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 6 --interval 1 --attempts 4 \
          --from "$NIX_WRAPPER_SOURCE_URL" \
          --trusted-key "$PUBLIC_KEY" \
          --from "file://$UPSTREAM_CACHE" \
          --trusted-key "$UPSTREAM_PUBLIC_KEY" \
          "$SIGNED_CLOSURE_ROOT" > delayed-dependency-signature.log 2>&1; then
        cat delayed-dependency-signature.log
        echo 'FAIL(delayed-dependency-signature): transient signature miss was not retried' >&2
        exit 1
      fi
      [ -e "$signature_marker" ] || {
        echo 'FAIL(delayed-dependency-signature): initial signature miss was not exercised' >&2
        exit 1
      }
      ${pkgs.nix}/bin/nix path-info --json "$local_dependency_path" \
        | ${pkgs.jq}/bin/jq -e --arg path "$local_dependency_path" \
          --arg signer "''${UPSTREAM_PUBLIC_KEY%%:*}:" \
          '.[$path].signatures | any(startswith($signer))' \
          > /dev/null || {
        echo 'FAIL(delayed-dependency-signature): retry did not import dependency signature' >&2
        exit 1
      }
      unset NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_URL NIX_WRAPPER_COPY_SIGS_FAIL_ONCE_MARKER
    }

    expect_preexisting_ca_dependency_failure() {
      reset_target
      : > "$NIX_WRAPPER_LOG"
      local_ca_path=$(${pkgs.nix}/bin/nix store add-file "$CA_INPUT")
      [ "$local_ca_path" = "$CA_DEPENDENCY_PATH" ] || {
        echo 'FAIL(preexisting-ca-dependency): local CA path changed' >&2
        exit 1
      }
      ${pkgs.nix}/bin/nix path-info --json "$local_ca_path" \
        | ${pkgs.jq}/bin/jq -e --arg path "$local_ca_path" \
          '.[$path].ca != null and (.[$path].signatures | length == 0)' \
          > /dev/null || {
        echo 'FAIL(preexisting-ca-dependency): fixture is not unsigned content-addressed' >&2
        exit 1
      }

      export NIX_WRAPPER_SOURCE_URL="file://$CA_ROOT_CACHE"
      export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
      export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SOURCE_URL"
      export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY"
      export NIX_WRAPPER_BUILD_SOURCE_URL="file://$CA_COMPLETE_CACHE"
      unset NIX_WRAPPER_PRECOPY_URL NIX_WRAPPER_PRECOPY_PATH
      if NIX_STORE_DIR="$TARGET_STORE" \
        NIX_STATE_DIR="$TARGET_STATE" \
        NIX_LOG_DIR="$TARGET_LOG" \
        bash "$script" --timeout-seconds 2 --attempts 1 \
          --from "$NIX_WRAPPER_SOURCE_URL" \
          --trusted-key "$PUBLIC_KEY" \
          "$SIGNED_CA_ROOT" > preexisting-ca-dependency.log 2>&1; then
        cat preexisting-ca-dependency.log
        echo 'FAIL(preexisting-ca-dependency): expected hydration to fail' >&2
        exit 1
      fi
      grep -qF 'release closure contains a path without an allowed cache signature' \
        preexisting-ca-dependency.log || {
        cat preexisting-ca-dependency.log
        echo 'FAIL(preexisting-ca-dependency): expected unsigned closure diagnostic' >&2
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
    reset_target
    : > "$NIX_WRAPPER_LOG"
    export NIX_WRAPPER_SOURCE_URL="file://$SPLIT_ROOT_CACHE"
    export NIX_WRAPPER_TRUSTED_KEY="$PUBLIC_KEY"
    export NIX_WRAPPER_SUBSTITUTERS="$NIX_WRAPPER_SOURCE_URL file://$UPSTREAM_CACHE"
    export NIX_WRAPPER_CACHE_URLS="$NIX_WRAPPER_SUBSTITUTERS"
    export NIX_WRAPPER_TRUSTED_KEYS="$NIX_WRAPPER_TRUSTED_KEY $UPSTREAM_PUBLIC_KEY"
    export NIX_WRAPPER_PRECOPY_URL="file://$UPSTREAM_CACHE"
    export NIX_WRAPPER_PRECOPY_PATH="$UNSIGNED_DEPENDENCY_PATH"
    export NIX_WRAPPER_BUILD_SOURCE_URL="file://$COMBINED_CACHE"
    if ! NIX_STORE_DIR="$TARGET_STORE" \
      NIX_STATE_DIR="$TARGET_STATE" \
      NIX_LOG_DIR="$TARGET_LOG" \
      bash "$script" --timeout-seconds 2 --attempts 1 \
        --from "file://$SPLIT_ROOT_CACHE" \
        --trusted-key "$PUBLIC_KEY" \
        --from "file://$UPSTREAM_CACHE" \
        --trusted-key "$UPSTREAM_PUBLIC_KEY" \
        "$SIGNED_CLOSURE_ROOT" > split-cache.log 2>&1; then
      cat split-cache.log
      echo 'FAIL(split-cache): expected root and dependency from separate signed caches to hydrate' >&2
      exit 1
    fi
    expect_failure unsigned 'signature verification failed' \
      --from "file://$UNSIGNED_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$UNSIGNED_PATH"
    expect_failure missing 'not available' \
      --from "file://$SIGNED_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$MISSING_PATH"
    expect_failure missing-dependency 'not available' \
      --from "file://$SPLIT_ROOT_CACHE" \
      --trusted-key "$PUBLIC_KEY" \
      "$SIGNED_CLOSURE_ROOT"
    expect_preexisting_wrong_key_dependency_failure
    expect_delayed_dependency_signature_success
    expect_preexisting_ultimate_dependency_failure
    expect_preexisting_ca_dependency_failure

    echo 'ok: signed, delayed-path, delayed-signature, split-cache, and source-mutated closures hydrated; unsigned, wrong-key, ultimate, CA, missing dependency, and unavailable paths refused'
    touch "$out"
  ''
