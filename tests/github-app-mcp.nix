# github-app-mcp — runtime-invocation harness for the GitHub MCP credential
# wrapper. It drives the real wrapper text against a fake server, exercising
# fail-closed config/key validation, inert parsing, personal/org installation
# routing, argv construction, and removal of every token credential before exec.
# Boots nothing; runs in seconds.
#
# Run: nix build .#checks.x86_64-linux.codex-github-mcp -L
{ pkgs, deployedBin }:

let
  fakeServer = pkgs.writeShellApplication {
    name = "github-mcp-server";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      : "''${CAPTURE_DIR:?CAPTURE_DIR must be set by the harness}"
      printf '%s\n' "$@" > "$CAPTURE_DIR/argv"
      env | sort > "$CAPTURE_DIR/env"
    '';
  };
  wrapper = import ../home/github-app-mcp.nix {
    inherit pkgs;
    githubMcpServer = fakeServer;
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
      "$@" > "$name.log" 2>&1 \
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
      local home_dir="$1" app_id="$2" installation_id="$3" key_path="$4"
      local org_installations="''${5:-example=789}"
      cat > "$home_dir/.config/github-app/config" <<EOF
APP_ID=$app_id
INSTALLATION_ID=$installation_id
KEY_PATH=$key_path
TOKEN_ROOT=$home_dir/.cache/gh-tokens
ORG_INSTALLATIONS="$org_installations"
EOF
    }

    write_shell_syntax_config() {
      local home_dir="$1" key_path="$2"
      printf '%s\r\n' \
        'export APP_ID=123 # personal app id' \
        "export INSTALLATION_ID='456'   " \
        "export KEY_PATH=\"$key_path\"   " \
        "TOKEN_ROOT=$home_dir/.cache/gh-tokens   " \
        "export ORG_INSTALLATIONS='KLAFFAT=987 other=654'   " \
        > "$home_dir/.config/github-app/config"
    }

    # The deployed package must be the production derivation, while this
    # harness uses the same wrapper with only its pinned server replaced.
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
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    # Literal injection payload for the parser.
    # shellcheck disable=SC2016
    write_config "$home_dir" '$(touch should-not-exist)' 456 "$key_path"
    expect_failure bad-app-id "config key APP_ID requires shell expansion" \
      env HOME="$home_dir" "$tool"
    [ ! -e should-not-exist ] || fail "config value was executed"
    ! grep -Fq 'should-not-exist' bad-app-id.log \
      || fail "expansion error disclosed APP_ID value"

    home_dir=$(make_home bad-installation-id)
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    write_config "$home_dir" 123 not-a-number "$key_path"
    expect_failure bad-installation-id "INSTALLATION_ID in" \
      env HOME="$home_dir" "$tool"

    # Paths needing shell expansion are refused with a data-only error that
    # names the key but never echoes its value.
    home_dir=$(make_home dollar-key-path)
    # Literal shell expansion for refusal coverage.
    # shellcheck disable=SC2016
    write_config "$home_dir" 123 456 '$HOME/.config/github-app/app.pem'
    expect_failure dollar-key-path \
      "config key KEY_PATH requires shell expansion; this wrapper reads the file as data" \
      env HOME="$home_dir" "$tool"
    ! grep -Fq '.config/github-app/app.pem' dollar-key-path.log \
      || fail "expansion error disclosed dollar KEY_PATH value"

    home_dir=$(make_home tilde-key-path)
    # Literal tilde expansion for refusal coverage.
    # shellcheck disable=SC2088
    write_config "$home_dir" 123 456 '~/.config/github-app/app.pem'
    expect_failure tilde-key-path \
      "config key KEY_PATH requires shell expansion; this wrapper reads the file as data" \
      env HOME="$home_dir" "$tool"
    ! grep -Fq '.config/github-app/app.pem' tilde-key-path.log \
      || fail "expansion error disclosed tilde KEY_PATH value"

    home_dir=$(make_home backtick-app-id)
    # Literal command substitution for refusal coverage.
    # shellcheck disable=SC2016
    write_config "$home_dir" '`printf 123`' 456 \
      "$home_dir/.config/github-app/app.pem"
    expect_failure backtick-app-id "config key APP_ID requires shell expansion" \
      env HOME="$home_dir" "$tool"
    ! grep -Fq 'printf 123' backtick-app-id.log \
      || fail "expansion error disclosed backtick APP_ID value"

    # Wrong fixed path, then the correct path without read permission.
    home_dir=$(make_home wrong-key-path)
    wrong_path="$home_dir/.config/github-app/elsewhere.pem"
    : > "$wrong_path"
    write_config "$home_dir" 123 456 "$wrong_path"
    expect_failure wrong-key-path "KEY_PATH in" env HOME="$home_dir" "$tool"

    home_dir=$(make_home unreadable-key)
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    chmod 000 "$key_path"
    write_config "$home_dir" 123 456 "$key_path"
    expect_failure unreadable-key "cannot read GitHub App private key" \
      env HOME="$home_dir" "$tool"

    # Happy path without --owner: export prefixes, CRLF, quoted values, trailing
    # spaces and an unquoted trailing comment parse as shell syntax while the
    # personal installation remains selected. Caller policy args pass through,
    # unrelated assignments are ignored, and inherited credentials are absent.
    home_dir=$(make_home success)
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    write_shell_syntax_config "$home_dir" "$key_path"
    capture="$PWD/capture"
    mkdir -p "$capture"
    HOME="$home_dir" \
      CAPTURE_DIR="$capture" \
      GITHUB_PERSONAL_ACCESS_TOKEN=personal \
      GITHUB_TOKEN=github \
      GH_TOKEN=gh \
      GITHUB_APP_PRIVATE_KEY=private \
      "$tool" --toolsets context,repos --exclude-tools merge_pull_request \
      > success.log 2>&1 \
      || fail "valid config invocation failed"

    cat > expected-argv <<EOF
stdio
--app-id
123
--app-installation-id
456
--app-private-key-path
$key_path
--toolsets
context,repos
--exclude-tools
merge_pull_request
EOF
    cmp expected-argv "$capture/argv" \
      || fail "server argv did not match the wrapper contract"
    if grep -Eq '^(GITHUB_PERSONAL_ACCESS_TOKEN|GITHUB_TOKEN|GH_TOKEN|GITHUB_APP_PRIVATE_KEY)=' "$capture/env"; then
      fail "an inherited GitHub credential reached the server"
    fi

    # Explicit owner: case-insensitive lookup selects the org installation,
    # consumes --owner and forwards only the remaining policy arguments.
    org_capture="$PWD/org-capture"
    mkdir -p "$org_capture"
    HOME="$home_dir" CAPTURE_DIR="$org_capture" \
      "$tool" --owner KlAfFaT --toolsets repos > org-success.log 2>&1 \
      || fail "org installation invocation failed"
    cat > expected-org-argv <<EOF
stdio
--app-id
123
--app-installation-id
987
--app-private-key-path
$key_path
--toolsets
repos
EOF
    cmp expected-org-argv "$org_capture/argv" \
      || fail "org installation argv did not match the wrapper contract"
    ! grep -Fxq -- --owner "$org_capture/argv" \
      || fail "--owner was forwarded to the server"

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
    unset_org_key="$unset_org_home/.config/github-app/app.pem"
    : > "$unset_org_key"
    write_config "$unset_org_home" 123 456 "$unset_org_key"
    grep -v '^ORG_INSTALLATIONS=' \
      "$unset_org_home/.config/github-app/config" \
      > "$unset_org_home/.config/github-app/config.tmp"
    mv "$unset_org_home/.config/github-app/config.tmp" \
      "$unset_org_home/.config/github-app/config"
    expect_failure unset-org "is not listed in ORG_INSTALLATIONS" \
      env HOME="$unset_org_home" "$tool" --owner klaffat

    duplicate_home=$(make_home duplicate-org)
    duplicate_key="$duplicate_home/.config/github-app/app.pem"
    : > "$duplicate_key"
    write_config "$duplicate_home" 123 456 "$duplicate_key" \
      "klaffat=987 KLAFFAT=988"
    expect_failure duplicate-owner "contains duplicate entries" \
      env HOME="$duplicate_home" "$tool" --owner klaffat

    malformed_home=$(make_home malformed-org)
    malformed_key="$malformed_home/.config/github-app/app.pem"
    : > "$malformed_key"
    write_config "$malformed_home" 123 456 "$malformed_key" \
      "klaffat=not-a-number other=654"
    expect_failure malformed-owner "must have a numeric installation id" \
      env HOME="$malformed_home" "$tool" --owner klaffat

    touch "$out"
  ''
