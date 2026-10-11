# GitHub access as the GitHub App, never as the founder.
#
# gh-token.service (home/claude-services.nix) runs ~/.claude's mint-gh-token,
# which mints a whole-installation GitHub App token into
# ~/.cache/gh-tokens/host/token (0600) every 20 minutes. Two consumers read it:
#
#   gh                  wrapper that shadows the system gh (home.packages comes
#                       before /run/current-system/sw/bin on PATH). An explicit
#                       GH_TOKEN/GITHUB_TOKEN passes through untouched; otherwise
#                       the host token becomes GH_TOKEN for the real gh.
#   gh-app-credential   git credential helper for https://github.com.
#
# Both FAIL CLOSED: a missing, empty or stale (older than 55 min; tokens live
# 60) token file is an error naming gh-token.service. There is deliberately no
# fallback to gh's keyring credential: the keyring holds the founder's admin PAT
# until it is revoked, and an agent that can reach it can merge its own PR or
# edit a ruleset.
#
# Escape hatch for the founder's own browser-session work (e.g. `gh auth
# logout` of the old PAT): the unwrapped /run/current-system/sw/bin/gh.
#
# Import with: import ./gh-host-token.nix { inherit pkgs; }
{ pkgs }:
let
  maxAgeMinutes = 55;

  # Sets host_token, or host_token_error and returns 1. Shared verbatim by both
  # scripts so the freshness rule cannot drift between them.
  loadHostToken = ''
    load_host_token() {
      local file="''${HOME:-}/.cache/gh-tokens/host/token" mtime now age
      host_token=""
      host_token_error=""
      if [ -z "''${HOME:-}" ]; then
        host_token_error="HOME is unset, cannot locate the GitHub App host token; no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
      if [ ! -s "$file" ]; then
        host_token_error="GitHub App host token $file is missing or empty; no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
      mtime=$(stat -c %Y -- "$file")
      now=$(date +%s)
      age=$(( (now - mtime) / 60 ))
      if [ "$age" -ge ${toString maxAgeMinutes} ]; then
        host_token_error="GitHub App host token $file is stale (''${age} min old, limit ${toString maxAgeMinutes}); no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
      host_token=$(<"$file")
      if [ -z "$host_token" ]; then
        host_token_error="GitHub App host token $file is empty; no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
    }
  '';

  gh = pkgs.writeShellApplication {
    name = "gh";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # An explicit token is the caller's deliberate choice (e.g. a unit that
      # loads its own credential); gh itself prefers GH_TOKEN over GITHUB_TOKEN.
      if [ -n "''${GH_TOKEN:-}" ] || [ -n "''${GITHUB_TOKEN:-}" ]; then
        exec ${pkgs.gh}/bin/gh "$@"
      fi
      ${loadHostToken}
      if ! load_host_token; then
        echo "gh: $host_token_error" >&2
        exit 1
      fi
      export GH_TOKEN="$host_token"
      exec ${pkgs.gh}/bin/gh "$@"
    '';
  };

  credentialHelper = pkgs.writeShellApplication {
    name = "gh-app-credential";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # git credential helper protocol: `get` answers, `store`/`erase` are
      # no-ops (the token is rotated by gh-token.service, never by git).
      if [ "''${1:-}" != get ]; then
        cat >/dev/null || true
        exit 0
      fi
      protocol=""
      host=""
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && break
        case "$line" in
          protocol=*) protocol="''${line#protocol=}" ;;
          host=*) host="''${line#host=}" ;;
        esac
      done
      # Only github.com over https gets the token; anything else gets silence,
      # which lets git try its next helper or fail on its own.
      if [ "$protocol" != https ] || [ "$host" != github.com ]; then
        exit 0
      fi
      ${loadHostToken}
      if ! load_host_token; then
        echo "gh-app-credential: $host_token_error" >&2
        # quit=1 stops git from consulting any later helper or prompting:
        # fail closed instead of falling through to another credential.
        echo "quit=1"
        exit 1
      fi
      printf 'username=x-access-token\npassword=%s\n' "$host_token"
    '';
  };
in
{
  inherit gh credentialHelper;
}
