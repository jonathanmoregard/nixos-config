# GitHub access as the GitHub App. The "never as the founder" guarantee is
# complete only once the founder's PAT is revoked and gh is logged out of the
# keyring: until then the unwrapped /run/current-system/sw/bin/gh and an
# explicit GH_TOKEN can still reach GitHub as the founder.
#
# gh-token.service (home/claude-services.nix) runs ~/.claude's mint-gh-token,
# which mints whole-installation GitHub App tokens every 20 minutes:
#
#   ~/.cache/gh-tokens/host/token           personal installation (0600)
#   ~/.cache/gh-tokens/host/<owner>/token   one per ORG_INSTALLATIONS entry in
#                                           ~/.config/github-app/config
#                                           (dir 0700, file 0600, lowercase)
#
# One App installation covers one owner, so the token is picked per owner:
#
#   gh                  wrapper that shadows the system gh (home.packages comes
#                       before /run/current-system/sw/bin on PATH). An explicit
#                       GH_TOKEN/GITHUB_TOKEN passes through untouched.
#                       Otherwise the owner comes from, first match wins:
#                       -R/--repo [HOST/]OWNER/NAME (or `gh repo <sub>
#                       OWNER/NAME`), else GH_REPO, else the cwd repo's
#                       remote.origin.url. That owner's token becomes GH_TOKEN
#                       if host/<owner>/token exists, else the personal one.
#   gh-app-credential   git credential helper for https://github.com. With
#                       credential.useHttpPath git sends path=OWNER/NAME.git;
#                       the first segment picks the owner the same way.
#
# Both FAIL CLOSED on whichever file was picked: a missing, empty or stale
# (older than 55 min; tokens live 60) token file is an error naming
# gh-token.service. A stale org token never falls back to the personal one,
# and there is deliberately no fallback to gh's keyring credential: the keyring
# holds the founder's admin PAT until it is revoked, and an agent that can
# reach it can merge its own PR or edit a ruleset. Only an ABSENT org token
# file falls back to personal (no org installation configured yet).
#
# Escape hatch for the founder's own browser-session work (e.g. `gh auth
# logout` of the old PAT): the unwrapped /run/current-system/sw/bin/gh.
#
# Import with: import ./gh-host-token.nix { inherit pkgs; }
{ pkgs }:
let
  maxAgeMinutes = 55;

  # Shared verbatim by both scripts so neither the owner rules nor the
  # freshness rule can drift between them.
  #
  # normalize_owner <login>: lowercased GitHub owner, or rc 1 when it is not a
  # plausible login (keeps `..`, slashes and empties out of the token path).
  #
  # owner_from_repo_spec <spec>: owner of OWNER/NAME, HOST/OWNER/NAME or an
  # https/ssh/scp remote URL, `.git` stripped; rc 1 for another host or
  # anything without OWNER/NAME.
  #
  # token_file_for_owner <owner|"">: host/<owner>/token when that file exists,
  # else the personal host/token.
  #
  # load_token <file>: sets host_token, or host_token_error and returns 1.
  tokenLib = ''
    token_root="''${HOME:-}/.cache/gh-tokens/host"

    normalize_owner() {
      local owner="''${1,,}"
      [[ "$owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
      printf '%s\n' "$owner"
    }

    owner_from_repo_spec() {
      local spec="''${1%/}" rest host path
      spec="''${spec%.git}"
      case "$spec" in
        *://*)
          rest="''${spec#*://}"
          host="''${rest%%/*}"
          host="''${host##*@}"
          host="''${host%%:*}"
          [ "$rest" != "''${rest#*/}" ] || return 1
          path="''${rest#*/}"
          ;;
        *@*:*)
          rest="''${spec#*@}"
          host="''${rest%%:*}"
          path="''${rest#*:}"
          ;;
        */*/*)
          host="''${spec%%/*}"
          path="''${spec#*/}"
          ;;
        */*)
          host=github.com
          path="$spec"
          ;;
        *) return 1 ;;
      esac
      [ "''${host,,}" = github.com ] || return 1
      case "$path" in
        ?*/?*) ;;
        *) return 1 ;;
      esac
      case "''${path#*/}" in
        */*) return 1 ;;
      esac
      normalize_owner "''${path%%/*}"
    }

    token_file_for_owner() {
      if [ -n "''${1:-}" ] && [ -e "$token_root/$1/token" ]; then
        printf '%s\n' "$token_root/$1/token"
      else
        printf '%s\n' "$token_root/token"
      fi
    }

    load_token() {
      local file="$1" mtime now age
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
      # Callers run this under `if !`, which switches errexit off inside the
      # function, so every step checks its own result: a failed stat or date
      # must refuse, never slip through as an empty number.
      mtime=$(stat -c %Y -- "$file" 2>/dev/null) || mtime=""
      now=$(date +%s 2>/dev/null) || now=""
      if ! [[ "$mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then
        host_token_error="cannot determine the age of GitHub App host token $file (stat or date failed); no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
      if [ $(( now - mtime )) -lt -60 ]; then
        host_token_error="GitHub App host token $file is dated in the future ($(( (mtime - now) / 60 )) min ahead of the clock); no fallback to a personal token. Fix: systemctl --user start gh-token.service"
        return 1
      fi
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
      ${tokenLib}

      # Which repo will gh act on? The first source that is PRESENT decides,
      # even when it names no org with a token (then: personal): an explicit
      # -R elsewhere makes the cwd's origin irrelevant.
      spec=""
      have_spec=""
      args=("$@")
      for ((i = 0; i < ''${#args[@]}; i++)); do
        case "''${args[i]}" in
          --) break ;;
          -R | --repo) spec="''${args[i + 1]:-}"; have_spec=1; i=$((i + 1)) ;;
          --repo=*) spec="''${args[i]#--repo=}"; have_spec=1 ;;
          -R?*) spec="''${args[i]#-R}"; have_spec=1 ;;
        esac
      done
      # `gh repo view|clone|... OWNER/NAME`: the first positional that parses.
      if [ -z "$have_spec" ] && [ "''${1:-}" = repo ]; then
        for arg in "''${@:3}"; do
          [ "$arg" = -- ] && break
          case "$arg" in -*) continue ;; esac
          if owner_from_repo_spec "$arg" >/dev/null; then
            spec="$arg"
            have_spec=1
            break
          fi
        done
      fi
      if [ -z "$have_spec" ] && [ -n "''${GH_REPO:-}" ]; then
        spec="$GH_REPO"
        have_spec=1
      fi
      if [ -z "$have_spec" ]; then
        spec=$(${pkgs.git}/bin/git config --get remote.origin.url 2>/dev/null) || spec=""
      fi
      owner=$(owner_from_repo_spec "$spec") || owner=""

      token_file=$(token_file_for_owner "$owner")
      if ! load_token "$token_file"; then
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
      path=""
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && break
        case "$line" in
          protocol=*) protocol="''${line#protocol=}" ;;
          host=*) host="''${line#host=}" ;;
          path=*) path="''${line#path=}" ;;
        esac
      done
      # Only github.com over https gets the token; anything else gets silence,
      # which lets git try its next helper or fail on its own.
      if [ "$protocol" != https ] || [ "$host" != github.com ]; then
        exit 0
      fi
      ${tokenLib}
      # path= (credential.useHttpPath) is OWNER/NAME.git; its first segment
      # picks the owner. No path, or one without OWNER/: the personal token.
      owner=""
      case "$path" in
        ?*/*) owner=$(normalize_owner "''${path%%/*}") || owner="" ;;
      esac
      if ! load_token "$(token_file_for_owner "$owner")"; then
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
