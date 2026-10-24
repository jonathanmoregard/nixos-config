# The two programs behind the GitHub App key broker's sockets (./default.nix).
# systemd runs one per accepted connection, as github-app, with the
# connection on stdin/stdout and the key path as $1. tests/github-app-broker.nix
# drives them directly.
#
# The request line is the caller's data: it is matched whole against a fixed
# grammar (single spaces, numeric ids, a length cap) before anything is done
# with it, never evaluated, and never echoed back except as the flag name a
# refusal names. Before the key signs for an installation, GitHub is asked
# whose it is; only `allowedOwners` are served.
{ pkgs, apiUrl, allowedOwners, githubMcpServer ? pkgs.github-mcp-server }:
let
  lib = pkgs.lib;
  owners = lib.concatMapStringsSep " " lib.toLower allowedOwners;

  # Shared by both programs. `refuse` is defined by each, since only the
  # token socket may answer on stdout.
  common = ''
    export LC_ALL=C
    key="$1"
    api_url=${lib.escapeShellArg apiUrl}
    allowed_owners=${lib.escapeShellArg owners}

    # read_request <max-bytes>: one newline-terminated line into $line. A
    # line that hits the cap, a missing newline and a silent caller are all
    # refusals; bash reads a socket byte by byte, so nothing after the
    # newline (the MCP stream) is consumed.
    read_request() {
      line=""
      IFS= read -r -t 10 -n "$1" line || refuse "no complete request line"
      [ "''${#line}" -lt "$1" ] || refuse "request line too long"
    }

    b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

    # sign_jwt <app_id>: the App JWT, valid 9 minutes, into $jwt. It reaches
    # curl through a file descriptor, never argv.
    sign_jwt() {
      local now header payload signature
      now=$(date +%s)
      header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
      payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$1" | b64url)
      signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url) \
        || refuse "could not sign the App JWT"
      [ -n "$signature" ] || refuse "could not sign the App JWT"
      jwt="$header.$payload.$signature"
    }

    # github <method> <path> [curl args...]: one App-authenticated call.
    github() {
      local method="$1" path="$2"
      shift 2
      curl -sS --fail-with-body --max-time 30 -X "$method" \
        -H @<(printf 'Authorization: Bearer %s\n' "$jwt") \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" "$api_url$path" 2>&1
    }

    # require_allowed_owner <installation_id>: refuse unless the installation
    # belongs to one of allowed_owners.
    require_allowed_owner() {
      local response login
      response=$(github GET "/app/installations/$1") \
        || refuse "GitHub does not know installation $1 of this App"
      login=$(jq -r '.account.login // empty | ascii_downcase' <<< "$response" 2>/dev/null) || login=""
      [[ "$login" =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] \
        || refuse "GitHub named no account for installation $1"
      case " $allowed_owners " in
        *" $login "*) ;;
        *) refuse "installation $1 belongs to '$login', which is not an allowed owner" ;;
      esac
    }

    id='[0-9]{1,20}'
  '';
in
{
  # One line in: `<app_id> <installation_id> [<repo_id>]`. One line out:
  # GitHub's installation-token JSON, or `refused: <reason>` /
  # `error: <GitHub's answer>`.
  mintToken = pkgs.writeShellApplication {
    name = "github-app-mint-token";
    runtimeInputs = with pkgs; [ coreutils curl jq openssl ];
    text = ''
      refuse() {
        printf 'refused: %s\n' "$1"
        echo "github-app-mint-token: refused: $1" >&2
        exit 1
      }
      ${common}

      read_request 128
      [[ "$line" =~ ^($id)\ ($id)(\ ($id))?$ ]] \
        || refuse "request must be: <app_id> <installation_id> [<repo_id>]"
      app_id="''${BASH_REMATCH[1]}"
      installation_id="''${BASH_REMATCH[2]}"
      repo_id="''${BASH_REMATCH[4]}"

      sign_jwt "$app_id"
      require_allowed_owner "$installation_id"
      body='{}'
      [ -z "$repo_id" ] || body="{\"repository_ids\":[$repo_id]}"
      if ! response=$(github POST "/app/installations/$installation_id/access_tokens" -d "$body"); then
        echo "github-app-mint-token: GitHub refused installation $installation_id: $response" >&2
        printf 'error: GitHub refused installation %s: %s\n' "$installation_id" "$response"
        exit 1
      fi
      echo "github-app-mint-token: minted for installation $installation_id''${repo_id:+ repo $repo_id}" >&2
      printf '%s\n' "$response"
    '';
  };

  # One header line in: `<app_id> <installation_id> [<flag> [<value>]]...`,
  # then the MCP stdio stream in both directions, served by
  # github-mcp-server in App mode (it refreshes its own installation tokens
  # for the session). Refusals go to the journal only: stdout is the MCP
  # stream.
  mcpSession = pkgs.writeShellApplication {
    name = "github-app-mcp-session";
    runtimeInputs = with pkgs; [ coreutils curl jq openssl ];
    text = ''
      refuse() {
        echo "github-app-mcp-session: refused: $1" >&2
        exit 1
      }
      ${common}

      read_request 4096
      [[ "$line" =~ ^($id)\ ($id)((\ [[:graph:]]+)*)$ ]] \
        || refuse "header must be: <app_id> <installation_id> [args...]"
      app_id="''${BASH_REMATCH[1]}"
      installation_id="''${BASH_REMATCH[2]}"
      args=()
      IFS=' ' read -r -a args <<< "''${BASH_REMATCH[3]}"

      # The allowlist: which tools the session offers, and nothing else. A
      # flag that could point the key-holding server at another host, write
      # files or log traffic is refused by not being here.
      i=0
      while [ "$i" -lt "''${#args[@]}" ]; do
        flag="''${args[$i]}"
        case "$flag" in
          --toolsets | --tools | --exclude-tools)
            i=$((i + 1))
            [[ "''${args[$i]:-}" =~ ^[a-z0-9][a-z0-9_,-]*$ ]] \
              || refuse "value for $flag is not allowed"
            ;;
          --read-only | --lockdown-mode) ;;
          *)
            # Name a flag-shaped argument; never echo anything else.
            [[ "$flag" =~ ^--?[a-z][a-z-]{0,40}$ ]] && refuse "argument $flag is not allowed"
            refuse "argument is not allowed"
            ;;
        esac
        i=$((i + 1))
      done

      sign_jwt "$app_id"
      require_allowed_owner "$installation_id"
      exec ${githubMcpServer}/bin/github-mcp-server stdio \
        --app-id "$app_id" \
        --app-installation-id "$installation_id" \
        --app-private-key-path "$key" \
        "''${args[@]}"
    '';
  };
}
