{ pkgs }:

# mint-gh-token <config> <token-root> <broker-socket> — refresh every GitHub
# App installation token jonathan's tools read, through the App key broker's
# token socket (modules/nixos/github-app-broker). Runs as jonathan from
# gh-token.service (home/claude-services.nix); it never sees the App key or a
# JWT.
#
#   <token-root>/<sandbox>/token        one per dir holding a numeric
#                                       `repo_id`: a token scoped to that one
#                                       repository of the personal installation
#                                       (claude-sandbox mounts the dir into its
#                                       container)
#   <token-root>/host/token             whole personal installation, when
#                                       host/scope reads `installation`
#   <token-root>/host/<owner>/token     whole installation of each
#                                       ORG_INSTALLATIONS owner (dir 0700)
#
# `host` is reserved: never treated as a sandbox dir. Each token file is
# replaced atomically, mode 0600, and only by a token the broker returned;
# on any failure the previous file is left as it was, so a broker or GitHub
# outage ages tokens into the consumers' fail-closed staleness limit rather
# than replacing them with anything else. One owner's failure does not stop
# the others; any failure fails the run. Tokens never reach the journal: the
# log line names what was minted and the App's reach (selection,
# permissions).
let
  installations = import ./github-app-installations.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "mint-gh-token";
  runtimeInputs = with pkgs; [ coreutils jq socat ];
  text = ''
    [ "$#" -eq 3 ] || { echo "usage: mint-gh-token <config> <token-root> <broker-socket>" >&2; exit 2; }
    config="$1"
    token_root="$2"
    socket="$3"

    listing=$(${installations}/bin/github-app-installations "$config") || exit 1
    read -r app_id personal_installation <<< "$listing"

    # mint <dir> <request> <log-label>: ask the broker for one token and
    # atomically replace <dir>/token with it.
    mint() {
      local dir="$1" request="$2" label="$3" response token
      if ! response=$(printf '%s\n' "$request" | socat -t 60 - "UNIX-CONNECT:$socket" 2>&1); then
        echo "mint-gh-token: cannot reach the GitHub App key broker at $socket for $dir: $response" >&2
        return 1
      fi
      token=$(jq -r '.token // empty' <<< "$response" 2>/dev/null) || token=""
      if [ -z "$token" ]; then
        echo "mint-gh-token: no token for $dir: $response" >&2
        return 1
      fi
      ( umask 077; printf '%s' "$token" > "$dir/token.new" )
      mv "$dir/token.new" "$dir/token"
      jq -c --arg minted "$label" \
        '{minted: $minted, expires_at, repository_selection, permissions}' <<< "$response" \
        | sed 's/^/mint-gh-token: /'
    }

    mint_for_sandbox() {
      local dir="$1" repo_id
      [ -f "$dir/repo_id" ] || return 0
      repo_id=$(cat "$dir/repo_id")
      if ! [[ "$repo_id" =~ ^[0-9]+$ ]]; then
        echo "mint-gh-token: $dir/repo_id is not a numeric repository id; not minted" >&2
        return 1
      fi
      mint "$dir" "$app_id $personal_installation $repo_id" "sandbox ''${dir##*/}"
    }

    mint_for_host() {
      local dir="$1" scope rc=0 org_app org_installation owner
      [ -f "$dir/scope" ] || return 0
      scope=$(tr -d '[:space:]' < "$dir/scope")
      if [ "$scope" != installation ]; then
        echo "mint-gh-token: $dir/scope is '$scope', expected 'installation'; host token not minted" >&2
        return 1
      fi
      mint "$dir" "$app_id $personal_installation" "host" || rc=1
      while read -r org_app org_installation owner; do
        [ -n "''${owner:-}" ] || continue
        if [ ! -d "$dir/$owner" ] && ! mkdir -m 0700 "$dir/$owner"; then
          echo "mint-gh-token: cannot create $dir/$owner; $owner token not minted" >&2
          rc=1
          continue
        fi
        mint "$dir/$owner" "$org_app $org_installation" "host $owner" || rc=1
      done <<< "$listing"
      return "$rc"
    }

    mkdir -p "$token_root"
    shopt -s nullglob
    exit_code=0
    for dir in "$token_root"/*/; do
      dir="''${dir%/}"
      [ "''${dir##*/}" = host ] && continue
      mint_for_sandbox "$dir" || exit_code=1
    done
    if [ -d "$token_root/host" ]; then
      mint_for_host "$token_root/host" || exit_code=1
    fi
    exit "$exit_code"
  '';
}
