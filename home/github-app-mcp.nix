{ pkgs, relay ? null }:

# github-app-mcp-server — the GitHub MCP server, authenticated as the GitHub
# App, for jonathan's MCP clients. It never touches the App key: it resolves
# the installation from ~/.config/github-app/config
# (home/github-app-installations.nix) and relays stdio to the App key
# broker's MCP socket (modules/nixos/github-app-broker), where
# github-mcp-server runs as the key's owner and refreshes its own tokens.
#
# Contract: `github-app-mcp-server [--owner <login>] <server args...>`. An
# optional leading `--owner <login>` selects that owner's App installation
# and is consumed here; there is no fallback to the personal installation.
# The remaining args reach the server unchanged and each must be one word;
# the broker admits only tool-policy flags. MCP toolsets and tool exclusions
# are policy and live only in ai-client-config, never here.
let
  sockets = import ../modules/nixos/github-app-broker/sockets.nix;
  installations = import ./github-app-installations.nix { inherit pkgs; };

  # github-app-mcp-relay <header>: send the header line, then splice stdio
  # to the broker's MCP socket until either side closes.
  defaultRelay = pkgs.writeShellApplication {
    name = "github-app-mcp-relay";
    runtimeInputs = [ pkgs.coreutils pkgs.socat ];
    text = ''
      exec socat STDIO UNIX-CONNECT:${sockets.mcp} < <(printf '%s\n' "$1"; exec cat)
    '';
  };
  relayBin = if relay == null then defaultRelay else relay;
in
pkgs.writeShellApplication {
  name = "github-app-mcp-server";
  text = ''
    die() {
      echo "github-app-mcp-server: $*" >&2
      exit 1
    }

    [ -n "''${HOME:-}" ] || die "HOME is unset; cannot locate GitHub App config"

    requested_owner=""
    if [[ "''${1:-}" == --owner=* ]]; then
      die "--owner must use the form --owner <login>"
    fi
    if [ "''${1:-}" = --owner ]; then
      [ "$#" -ge 2 ] && [ -n "$2" ] \
        || die "--owner requires a non-empty <login>"
      requested_owner="''${2,,}"
      [[ "$requested_owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "invalid --owner login '$2'; expected ^[a-z0-9][a-z0-9-]*$"
      shift 2
    fi
    for arg in "$@"; do
      case "$arg" in
        --owner | --owner=*)
          die "--owner <login> must be the first two arguments"
          ;;
      esac
      if [[ "$arg" =~ [[:space:]] ]]; then
        die "argument '$arg' contains whitespace; the broker takes one word per argument"
      fi
    done

    listing=$(${installations}/bin/github-app-installations "$HOME/.config/github-app/config") \
      || exit 1
    selected=""
    while read -r app_id installation_id owner; do
      if [ "''${owner:-}" = "$requested_owner" ]; then
        selected="$app_id $installation_id"
        break
      fi
    done <<< "$listing"
    [ -n "$selected" ] \
      || die "owner '$requested_owner' is not listed in ORG_INSTALLATIONS; refusing personal installation fallback"

    exec ${relayBin}/bin/github-app-mcp-relay "$selected''${*:+ $*}"
  '';
}
