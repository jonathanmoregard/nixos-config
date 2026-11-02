# github-app-mcp — runtime-invocation harness for the GitHub MCP wrapper. It
# drives the real wrapper text against a fake relay that records the header
# the wrapper would send to the App key broker's MCP socket
# (modules/nixos/github-app-broker), exercising fail-closed config parsing,
# inert parsing, personal/org installation routing and header construction.
# The broker side (key, allowlist, server) is exercised by vm-base.
# Boots nothing; runs in seconds.
#
# Run: nix build .#checks.x86_64-linux.github-app-mcp -L
{ pkgs, deployedBin }:

let
  fakeRelay = pkgs.writeShellApplication {
    name = "github-app-mcp-relay";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      : "''${CAPTURE_DIR:?CAPTURE_DIR must be set by the harness}"
      [ "$#" -eq 1 ] || { echo "relay takes exactly one header argument, got $#" >&2; exit 2; }
      printf '%s\n' "$1" > "$CAPTURE_DIR/header"
      cat > "$CAPTURE_DIR/stdin"
    '';
  };
  wrapper = import ../home/github-app-mcp.nix {
    inherit pkgs;
    relay = fakeRelay;
  };
in
pkgs.runCommand "github-app-mcp-harness"
  {
    inherit deployedBin;
    tool = "${wrapper}/bin/github-app-mcp-server";
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep ];
  } ''
    set -euo pipefail

    fail() {
      echo "FAIL: $*" >&2
      for log in ./*.log; do
        [ -f "$log" ] || continue
        echo "=== $log ===" >&2
        cat "$log" >&2
      done
      exit 1
    }

    expect_failure() {
      local name="$1" expected="$2"
      shift 2
      "$@" > "$name.log" 2>&1 < /dev/null \
        && fail "$name unexpectedly succeeded"
      grep -Fq -- "$expected" "$name.log" \
        || fail "$name did not report: $expected"
    }

    make_home() {
      local name="$1"
      test_home="$PWD/$name/home"
      mkdir -p "$test_home/.config/github-app"
      printf '%s\n' "$test_home"
    }

    write_config() {
      local home_dir="$1" app_id="$2" installation_id="$3"
      local org_installations="''${4:-example=789}"
      cat > "$home_dir/.config/github-app/config" <<EOF
APP_ID=$app_id
INSTALLATION_ID=$installation_id
KEY_PATH=$home_dir/.config/github-app/app.pem
TOKEN_ROOT=$home_dir/.cache/gh-tokens
ORG_INSTALLATIONS="$org_installations"
EOF
    }

    write_shell_syntax_config() {
      local home_dir="$1"
      printf '%s\r\n' \
        'export APP_ID=123 # personal app id' \
        "export INSTALLATION_ID='456'   " \
        "export KEY_PATH=\"\$HOME/.config/github-app/app.pem\"   " \
        "TOKEN_ROOT=$home_dir/.cache/gh-tokens   " \
        "export ORG_INSTALLATIONS='KLAFFAT=987 other=654'   " \
        > "$home_dir/.config/github-app/config"
    }

    # The deployed package must be the production derivation, while this
    # harness uses the same wrapper with only its pinned relay replaced.
    case "$deployedBin" in
      /nix/store/*/bin/github-app-mcp-server) ;;
      *) fail "deployed wrapper has unexpected path: $deployedBin" ;;
    esac

    # Missing config.
    home_dir=$(make_home missing-config)
    rm -f "$home_dir/.config/github-app/config"
    expect_failure missing-config "cannot read config" \
      env HOME="$home_dir" "$tool"

    # Non-numeric IDs. The command-shaped APP_ID also proves the parser never
    # sources or evaluates config values.
    home_dir=$(make_home bad-app-id)
    # Literal injection payload for the parser.
    # shellcheck disable=SC2016
    write_config "$home_dir" '$(touch should-not-exist)' 456
    expect_failure bad-app-id "config key APP_ID requires shell expansion" \
      env HOME="$home_dir" "$tool"
    [ ! -e should-not-exist ] || fail "config value was executed"
    ! grep -Fq 'should-not-exist' bad-app-id.log \
      || fail "expansion error disclosed APP_ID value"

    home_dir=$(make_home bad-installation-id)
    write_config "$home_dir" 123 not-a-number
    expect_failure bad-installation-id "INSTALLATION_ID in" \
      env HOME="$home_dir" "$tool"

    home_dir=$(make_home backtick-app-id)
    # Literal command substitution for refusal coverage.
    # shellcheck disable=SC2016
    write_config "$home_dir" '`printf 123`' 456
    expect_failure backtick-app-id "config key APP_ID requires shell expansion" \
      env HOME="$home_dir" "$tool"
    ! grep -Fq 'printf 123' backtick-app-id.log \
      || fail "expansion error disclosed backtick APP_ID value"

    # Happy path without --owner: export prefixes, CRLF, quoted values, trailing
    # spaces and an unquoted trailing comment parse as shell syntax while the
    # personal installation remains selected. KEY_PATH and TOKEN_ROOT are
    # inert, even with a `$` in them: the key is the broker's, not the
    # wrapper's. Caller policy args become the rest of the header, and the
    # caller's stdin is the relay's stdin.
    home_dir=$(make_home success)
    write_shell_syntax_config "$home_dir"
    capture="$PWD/capture"
    mkdir -p "$capture"
    printf 'mcp-bytes\n' | HOME="$home_dir" CAPTURE_DIR="$capture" \
      "$tool" --toolsets context,repos --exclude-tools merge_pull_request \
      > success.log 2>&1 \
      || fail "valid config invocation failed"
    echo "123 456 --toolsets context,repos --exclude-tools merge_pull_request" \
      > expected-header
    cmp expected-header "$capture/header" \
      || fail "relay header did not match the wrapper contract: $(cat "$capture/header")"
    [ "$(cat "$capture/stdin")" = mcp-bytes ] \
      || fail "caller stdin did not reach the relay"

    # Explicit owner: case-insensitive lookup selects the org installation,
    # consumes --owner and forwards only the remaining policy arguments.
    org_capture="$PWD/org-capture"
    mkdir -p "$org_capture"
    HOME="$home_dir" CAPTURE_DIR="$org_capture" \
      "$tool" --owner KlAfFaT --toolsets repos > org-success.log 2>&1 < /dev/null \
      || fail "org installation invocation failed"
    echo "123 987 --toolsets repos" > expected-org-header
    cmp expected-org-header "$org_capture/header" \
      || fail "org installation header did not match: $(cat "$org_capture/header")"

    # An argument the header cannot carry as one word is refused, not split.
    expect_failure spaced-arg "contains whitespace" \
      env HOME="$home_dir" CAPTURE_DIR="$capture" "$tool" --toolsets 'repos issues'

    # An explicit owner never falls back to the personal installation.
    expect_failure unknown-owner "is not listed in ORG_INSTALLATIONS" \
      env HOME="$home_dir" "$tool" --owner unknown
    expect_failure invalid-owner "invalid --owner login" \
      env HOME="$home_dir" "$tool" --owner 'bad/owner'
    expect_failure missing-owner-value "--owner requires a non-empty <login>" \
      env HOME="$home_dir" "$tool" --owner
    expect_failure equals-owner "must use the form --owner <login>" \
      env HOME="$home_dir" "$tool" --owner=klaffat
    expect_failure misplaced-owner "must be the first two arguments" \
      env HOME="$home_dir" "$tool" --toolsets repos --owner klaffat

    unset_org_home=$(make_home unset-org)
    write_config "$unset_org_home" 123 456
    grep -v '^ORG_INSTALLATIONS=' \
      "$unset_org_home/.config/github-app/config" \
      > "$unset_org_home/.config/github-app/config.tmp"
    mv "$unset_org_home/.config/github-app/config.tmp" \
      "$unset_org_home/.config/github-app/config"
    expect_failure unset-org "is not listed in ORG_INSTALLATIONS" \
      env HOME="$unset_org_home" "$tool" --owner klaffat

    duplicate_home=$(make_home duplicate-org)
    write_config "$duplicate_home" 123 456 "klaffat=987 KLAFFAT=988"
    expect_failure duplicate-owner "contains duplicate entries" \
      env HOME="$duplicate_home" "$tool" --owner klaffat

    malformed_home=$(make_home malformed-org)
    write_config "$malformed_home" 123 456 "klaffat=not-a-number other=654"
    expect_failure malformed-owner "must have a numeric installation id" \
      env HOME="$malformed_home" "$tool" --owner klaffat

    touch "$out"
  ''
