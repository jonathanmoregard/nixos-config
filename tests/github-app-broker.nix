# github-app-broker — request-handling harness for the two programs behind
# the GitHub App key broker's sockets (modules/nixos/github-app-broker/
# programs.nix). Each connection's bytes arrive on stdin exactly as systemd
# hands them over (Accept=yes), so the harness pipes requests in directly.
# A fake GitHub API on loopback (tests/lib/fake-github-api.py) verifies
# every JWT against the fixture key and knows three installations: 456
# (jonathanmoregard), 789 (klaffat) and 999 (stranger, not allowed).
#
# Covers the strict request grammar (anything else refused before GitHub is
# asked), the configured App id, the owner restriction, the permission cap
# sent with every token request, forced MCP lockdown and the MCP flag
# allowlist, against a fake
# github-mcp-server that records its argv and stdin. Socket permissions, the
# key's file mode and the real MCP server are vm-base's.
# Boots nothing; runs in seconds.
#
# Run: nix build .#checks.x86_64-linux.github-app-broker -L
{ pkgs }:

let
  fixture = import ./lib/github-app-key-fixture.nix { inherit pkgs; };
  port = 8788;

  fakeServer = pkgs.writeShellApplication {
    name = "github-mcp-server";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      printf '%s\n' "$@" > "$CAPTURE_DIR/argv"
      cat > "$CAPTURE_DIR/stdin"
    '';
  };

  programs = import ../modules/nixos/github-app-broker/programs.nix {
    inherit pkgs;
    apiUrl = "http://127.0.0.1:${toString port}";
    appId = 1;
    allowedOwners = [ "JonathanMoregard" "klaffat" ];
    tokenPermissions = { contents = "write"; metadata = "read"; };
    githubMcpServer = fakeServer;
  };
in
pkgs.runCommand "github-app-broker-harness"
  {
    nativeBuildInputs = with pkgs; [ bash coreutils curl gnugrep python3 ];
  } ''
    set -uo pipefail
    failures=0
    expect() { # expect <name> <command...>
      local name="$1"; shift
      if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
    }
    key=${fixture}/app.pem
    log="$PWD/github-requests"
    : > "$log"
    python3 ${./lib/fake-github-api.py} ${fixture}/app.pub.pem ${toString port} \
      ${pkgs.openssl}/bin/openssl "$log" 456=jonathanmoregard 789=klaffat 999=stranger \
      458=jonathanmoregard:contents=read,metadata=read 459=jonathanmoregard:issues=write &
    for _ in $(seq 100); do
      curl -s -o /dev/null http://127.0.0.1:${toString port}/ && break
      sleep 0.1
    done

    # mint <request bytes>: one token-socket connection. Sets $out_text,
    # $rc and $asked (the GitHub requests it caused).
    mint() {
      : > "$log"; : > "$log.bodies"
      rc=0
      out_text=$(printf '%b' "$1" | ${programs.mintToken}/bin/github-app-mint-token "$key" 2>/dev/null) || rc=$?
      asked=$(cat "$log")
      sent=$(cat "$log.bodies")
    }
    token_is() { [ "$rc" = 0 ] && [ "$(${pkgs.jq}/bin/jq -r .token <<< "$out_text")" = "$1" ]; }
    refused() { [ "$rc" != 0 ] && [[ "$out_text" == refused:* ]] && [[ "$out_text" != *ghs_* ]]; }

    # Well-formed requests: the whole installation, or one repository of it.
    mint '1 456\n'
    expect "personal installation token" token_is ghs_vm_456
    expect "owner looked up before minting" grep -qx 'GET /app/installations/456' <<< "$asked"
    expect "token capped to tokenPermissions" \
      [ "$sent" = '{"permissions": {"contents": "write", "metadata": "read"}}' ]
    mint '1 456 42\n'
    expect "repo-scoped token" token_is ghs_vm_456_42
    expect "repo-scoped token capped too" \
      [ "$sent" = '{"permissions": {"contents": "write", "metadata": "read"}, "repository_ids": [42]}' ]
    mint '1 789\n'
    expect "org installation token" token_is ghs_vm_789

    # GitHub refuses a token request naming more than the installation
    # holds, so the cap is intersected first: an installation with less
    # (458: contents read only) still mints, at its own lower levels.
    mint '1 458\n'
    expect "reduced installation still mints" token_is ghs_vm_458
    expect "reduced installation asks only for what it holds" \
      [ "$sent" = '{"permissions": {"contents": "read", "metadata": "read"}}' ]
    # One holding none of the capped permissions is refused, not asked.
    mint '1 459\n'
    expect "installation outside the cap refused" refused
    expect "installation outside the cap never minted" bash -c "! grep -q access_tokens <<< \"$asked\""

    # An installation of the App on an owner not configured is refused, and
    # GitHub is never asked for its token.
    mint '1 999\n'
    expect "unlisted owner refused" refused
    expect "unlisted owner names the account" grep -q "stranger" <<< "$out_text"
    expect "unlisted owner never minted" bash -c "! grep -q access_tokens <<< \"$asked\""
    mint '1 31337\n'
    expect "unknown installation refused" refused

    # Only the configured App is signed for: another id is refused before
    # GitHub hears of it.
    mint '2 456\n'
    expect "other app id refused" refused
    expect "other app id names itself" grep -q "app id 2 is not the configured App" <<< "$out_text"
    expect "other app id never reached GitHub" [ -z "$asked" ]

    # Anything but `<app_id> <installation_id> [<repo_id>]` in single
    # spaces is refused before GitHub hears of it.
    for bad in \
      '123 abc\n' '123 456 42 extra\n' '123 ../456\n' '\n' '123\n' \
      '123  456\n' ' 123 456\n' '123 456 \n' '123\t456\n' '123 456\r\n' \
      '1 456 42],"permissions":{"administration":"write"}\n' \
      '1 456 $(touch pwned)\n' '1 123456789012345678901\n' \
      '1 456'
    do
      mint "$bad"
      expect "malformed request refused: $bad" refused
      expect "malformed request never reached GitHub: $bad" [ -z "$asked" ]
    done
    [ ! -e pwned ] || { echo "FAIL request field was evaluated"; failures=$((failures + 1)); }

    # An endless line is cut off at the length limit, not read into memory
    # or waited out: the refusal comes long before the read timeout.
    : > "$log"
    rc=0
    out_text=$(tr '\0' 1 < /dev/zero 2>/dev/null \
      | timeout 5 ${programs.mintToken}/bin/github-app-mint-token "$key" 2>/dev/null) || rc=$?
    expect "overlong request refused" refused
    expect "overlong request never reached GitHub" [ ! -s "$log" ]

    # mcp <header> [args...]: one MCP-socket connection with `mcp-bytes`
    # after the header. Sets $rc and $err.
    capture="$PWD/capture"
    mcp() {
      rm -rf "$capture"; mkdir -p "$capture"; : > "$log"
      rc=0
      err=$(printf '%b\nmcp-bytes\n' "$1" \
        | CAPTURE_DIR="$capture" ${programs.mcpSession}/bin/github-app-mcp-session "$key" 2>&1 >/dev/null) || rc=$?
    }
    started() { [ "$rc" = 0 ] && [ -e "$capture/argv" ]; }
    mcp_refused() { [ "$rc" != 0 ] && [ ! -e "$capture/argv" ]; }

    mcp '1 789 --toolsets context,repos --exclude-tools merge_pull_request --read-only --lockdown-mode'
    expect "mcp session starts" started
    printf '%s\n' stdio --app-id 1 --app-installation-id 789 --app-private-key-path "$key" \
      --toolsets context,repos --exclude-tools merge_pull_request --read-only --lockdown-mode \
      > expected-argv
    expect "mcp server argv" cmp -s expected-argv "$capture/argv"
    expect "mcp stream follows the header" [ "$(cat "$capture/stdin" 2>/dev/null)" = mcp-bytes ]
    expect "mcp owner looked up" grep -qx 'GET /app/installations/789' "$log"

    mcp '1 999 --toolsets repos'
    expect "mcp unlisted owner refused" mcp_refused
    mcp '2 456 --toolsets repos'
    expect "mcp other app id refused" mcp_refused
    expect "mcp other app id never reached GitHub" [ ! -s "$log" ]

    # Lockdown is forced: a client that leaves it out gets it anyway, once.
    mcp '1 789 --toolsets repos --read-only'
    expect "mcp without lockdown starts" started
    printf '%s\n' stdio --app-id 1 --app-installation-id 789 --app-private-key-path "$key" \
      --toolsets repos --read-only --lockdown-mode > expected-argv
    expect "mcp lockdown forced" cmp -s expected-argv "$capture/argv"
    mcp '1 789'
    expect "mcp with no args starts" started
    printf '%s\n' stdio --app-id 1 --app-installation-id 789 --app-private-key-path "$key" \
      --lockdown-mode > expected-argv
    expect "mcp lockdown forced with no args" cmp -s expected-argv "$capture/argv"

    # Only tool-policy flags cross; everything else is refused, whatever
    # its spelling.
    for bad in \
      '1 456 --gh-host https://evil.example' '1 456 --log-file /tmp/x' \
      '1 456 --toolsets' '1 456 --toolsets --gh-host' '1 456 --read-only=false' \
      '1 456 --toolsets=repos' '1 456 --enable-command-logging' \
      '1 456 --export-translations' '1 456 -h' '1 456 stdio' \
      '1 456 --toolsets Repos' '1 456 --tools a;b' 'x 456 --read-only' \
      '1 456  --read-only' '1 456 --read-only '
    do
      mcp "$bad"
      expect "mcp refused: $bad" mcp_refused
    done
    mcp '1 456 --gh-host https://evil.example'
    expect "mcp refusal names the flag" grep -q 'refused: argument --gh-host is not allowed' <<< "$err"

    [ "$failures" = 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
    touch "$out"
  ''
