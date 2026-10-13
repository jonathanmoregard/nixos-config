# codex-github-mcp — runtime-invocation harness for the GitHub MCP credential
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
  wrapper = import ../home/codex-github-mcp.nix {
    inherit pkgs;
    githubMcpServer = fakeServer;
  };
in
pkgs.runCommand "codex-github-mcp-harness"
  {
    inherit deployedBin;
    tool = "${wrapper}/bin/codex-github-mcp-server";
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

    write_quoted_config() {
      local home_dir="$1" key_path="$2"
      cat > "$home_dir/.config/github-app/config" <<EOF
APP_ID="123"
INSTALLATION_ID='456'
KEY_PATH="$key_path"
TOKEN_ROOT=$home_dir/.cache/gh-tokens
ORG_INSTALLATIONS='KLAFFAT=987 other=654'
EOF
    }

    # The deployed package must be the production derivation, while this
    # harness uses the same wrapper with only its pinned server replaced.
    case "$deployedBin" in
      /nix/store/*/bin/codex-github-mcp-server) ;;
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
    write_config "$home_dir" '$(touch should-not-exist)' 456 "$key_path"
    expect_failure bad-app-id "APP_ID in" env HOME="$home_dir" "$tool"
    [ ! -e should-not-exist ] || fail "config value was executed"

    home_dir=$(make_home bad-installation-id)
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    write_config "$home_dir" 123 not-a-number "$key_path"
    expect_failure bad-installation-id "INSTALLATION_ID in" \
      env HOME="$home_dir" "$tool"

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

    # Happy path without --owner: quoted values parse, the personal installation
    # remains selected, caller policy args pass through, unrelated assignments
    # are ignored, and inherited credentials are absent.
    home_dir=$(make_home success)
    key_path="$home_dir/.config/github-app/app.pem"
    : > "$key_path"
    write_quoted_config "$home_dir" "$key_path"
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
    expect_failure misplaced-owner "must be the first two arguments" \
      env HOME="$home_dir" "$tool" --toolsets repos --owner klaffat

    malformed_home=$(make_home malformed-org)
    malformed_key="$malformed_home/.config/github-app/app.pem"
    : > "$malformed_key"
    write_config "$malformed_home" 123 456 "$malformed_key" \
      "klaffat=not-a-number other=654"
    expect_failure malformed-owner "must have a numeric installation id" \
      env HOME="$malformed_home" "$tool" --owner klaffat

    touch "$out"
  ''
