# github-app-mint — scenario harness for mint-gh-token (home/github-app-mint.nix),
# the jonathan-side token refresher behind gh-token.service. A fake App key
# broker on a unix socket answers `<app_id> <installation_id> [<repo_id>]`
# with tok-<installation>[-<repo>] (installations listed in ./fail answer like
# a GitHub refusal), so nothing here touches a key, the network or a real
# token cache. vm-base drives the real broker end to end.
# Boots nothing; runs in seconds.
#
# Run: nix build .#checks.x86_64-linux.github-app-mint -L
{ pkgs }:

let
  mint = import ../home/github-app-mint.nix { inherit pkgs; };

  fakeBroker = pkgs.writeShellApplication {
    name = "fake-github-app-broker";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      state="$1"
      read -r app_id installation_id repo_id
      echo "$app_id $installation_id ''${repo_id:-}" >> "$state/requests"
      if grep -qx "$installation_id" "$state/fail" 2>/dev/null; then
        echo 'error: GitHub refused installation'
        exit 1
      fi
      selection=all
      [ -z "''${repo_id:-}" ] || selection=selected
      printf '{"token":"tok-%s%s","expires_at":"2099-01-01T00:00:00Z","repository_selection":"%s","permissions":{}}\n' \
        "$installation_id" "''${repo_id:+-$repo_id}" "$selection"
    '';
  };
in
pkgs.runCommand "github-app-mint-harness"
  {
    nativeBuildInputs = with pkgs; [ bash coreutils findutils gnugrep socat ];
  } ''
    set -uo pipefail
    failures=0
    expect() { # expect <name> <command...>
      local name="$1"; shift
      if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
    }
    content() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
    mode() { [ "$(stat -c %a "$1" 2>/dev/null)" = "$2" ]; }
    logged() { grep -qF -- "$1" <<< "$output"; }
    no_token_in_output() { ! grep -q 'tok-' <<< "$output"; }

    state="$PWD/broker"
    mkdir -p "$state"
    socket="$PWD/broker.sock"
    socat UNIX-LISTEN:"$socket",fork EXEC:"${fakeBroker}/bin/fake-github-app-broker $state" &
    broker_pid=$!
    for _ in $(seq 50); do [ -S "$socket" ] && break; sleep 0.1; done

    # run <name> <org-installations or empty>: fresh token root with
    # host/scope, then one mint run. Sets $tr, $rc, $output (stdout+stderr).
    run() {
      tr="$PWD/$1/tokens"
      mkdir -p "$tr/host"
      printf installation > "$tr/host/scope"
      printf '%s\n' APP_ID=1 INSTALLATION_ID=100 "ORG_INSTALLATIONS=\"$2\"" > "$PWD/$1/config"
      : > "$state/requests"
    }
    mint_now() {
      # stdenv runs this under `set -e`: capture the status, don't die on it.
      rc=0
      output=$(${mint}/bin/mint-gh-token "$PWD/$1/config" "$tr" "$socket" 2>&1) || rc=$?
    }

    # 1. No ORG_INSTALLATIONS: personal only.
    run personal ""; mint_now personal
    expect "personal-only rc=0" [ "$rc" = 0 ]
    expect "personal-only host/token" content "$tr/host/token" tok-100
    expect "personal-only host/token 0600" mode "$tr/host/token" 600
    expect "personal-only no owner dirs" [ -z "$(find "$tr/host" -mindepth 1 -type d)" ]
    expect "personal-only log line" logged '{"minted":"host","expires_at"'
    expect "personal-only one request" [ "$(wc -l < "$state/requests")" = 1 ]
    expect "personal-only token never logged" no_token_in_output

    # 2. Two org installations, one with an upper-case owner.
    run orgs "KlaFFat=200 other-org=300"; mint_now orgs
    expect "orgs rc=0" [ "$rc" = 0 ]
    expect "orgs personal token" content "$tr/host/token" tok-100
    expect "orgs klaffat token" content "$tr/host/klaffat/token" tok-200
    expect "orgs other-org token" content "$tr/host/other-org/token" tok-300
    expect "orgs owner dir 0700" mode "$tr/host/klaffat" 700
    expect "orgs owner token 0600" mode "$tr/host/klaffat/token" 600
    expect "orgs whole-installation requests" [ "$(grep -c '^1 [0-9]* $' "$state/requests")" = 3 ]
    expect "orgs log line per owner" logged '{"minted":"host klaffat"'
    expect "orgs log line other-org" logged '{"minted":"host other-org"'
    expect "orgs token never logged" no_token_in_output

    # 3. host/<owner> is never a sandbox dir, even with a repo_id planted in
    #    it; real sandbox dirs next to host get repo-scoped tokens.
    run sandbox "klaffat=200"
    mkdir -p "$tr/proj" "$tr/host/klaffat"
    printf 5 > "$tr/proj/repo_id"
    printf 999 > "$tr/host/klaffat/repo_id"
    mint_now sandbox
    expect "sandbox rc=0" [ "$rc" = 0 ]
    expect "sandbox repo-scoped token" content "$tr/proj/token" tok-100-5
    expect "sandbox repo-scoped request" grep -qx '1 100 5' "$state/requests"
    expect "host/<owner> repo_id ignored" bash -c "! grep -q 999 '$state/requests'"
    expect "host/<owner> still gets org token" content "$tr/host/klaffat/token" tok-200

    # 4. A malformed config entry fails the run before anything is minted.
    run malformed "bare klaffat=200"; mint_now malformed
    expect "malformed rc=1" [ "$rc" = 1 ]
    expect "malformed names entry" logged "entry for owner 'bare' is malformed"
    expect "malformed mints nothing" [ ! -s "$state/requests" ]

    # 5. An org installation failing does not stop the personal token or
    #    another org; the run still fails.
    run org-fail "klaffat=200 other-org=300"
    echo 200 > "$state/fail"; mint_now org-fail; rm "$state/fail"
    expect "org-fail rc=1" [ "$rc" = 1 ]
    expect "org-fail personal still minted" content "$tr/host/token" tok-100
    expect "org-fail other org still minted" content "$tr/host/other-org/token" tok-300
    expect "org-fail no token file" [ ! -e "$tr/host/klaffat/token" ]
    expect "org-fail refusal logged" logged "no token for $tr/host/klaffat: error: GitHub refused"

    # 6. A sandbox repo_id that is not a numeric id is reported and never
    #    sent; the others still mint.
    run bad-repo ""
    mkdir -p "$tr/bad" "$tr/good"
    printf '5]}' > "$tr/bad/repo_id"
    printf 7 > "$tr/good/repo_id"
    mint_now bad-repo
    expect "bad-repo rc=1" [ "$rc" = 1 ]
    expect "bad-repo reported" logged "$tr/bad/repo_id is not a numeric repository id"
    expect "bad-repo never requested" bash -c "! grep -qF ']' '$state/requests'"
    expect "bad-repo good sandbox minted" content "$tr/good/token" tok-100-7

    # 7. The token file cannot be written: the run fails, logs no
    #    "minted" line, and the previous token stays.
    run nowrite ""; mint_now nowrite
    printf old > "$tr/host/token"
    chmod 0500 "$tr/host"
    mint_now nowrite
    chmod 0700 "$tr/host"
    expect "nowrite rc=1" [ "$rc" = 1 ]
    expect "nowrite reported" logged "cannot write $tr/host/token.new; previous token kept"
    expect "nowrite no minted line" bash -c "! grep -qF '\"minted\"' <<< \"\$1\"" _ "$output"
    expect "nowrite keeps previous token" content "$tr/host/token" old

    # 8. The rename fails (a directory squats on the token path): the run
    #    fails, the new token is not left behind, and nothing lands inside
    #    the directory.
    run norename ""
    mkdir -p "$tr/host/token/x"
    mint_now norename
    expect "norename rc=1" [ "$rc" = 1 ]
    expect "norename reported" logged "cannot replace $tr/host/token; previous token kept"
    expect "norename no minted line" bash -c "! grep -qF '\"minted\"' <<< \"\$1\"" _ "$output"
    expect "norename token.new removed" [ ! -e "$tr/host/token.new" ]
    expect "norename nothing moved into the directory" [ ! -e "$tr/host/token/token.new" ]

    # 9. Broker unreachable: the run fails naming the socket, and the
    #    previous token stays exactly as it was.
    run down ""; mint_now down
    kill "$broker_pid"; wait "$broker_pid" 2>/dev/null || true; rm -f "$socket"
    mint_now down
    expect "down rc=1" [ "$rc" = 1 ]
    expect "down names socket" logged "cannot reach the GitHub App key broker at $socket"
    expect "down keeps previous token" content "$tr/host/token" tok-100

    [ "$failures" = 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
    touch "$out"
  ''
