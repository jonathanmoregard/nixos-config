{ pkgs }:

# github-app-installations <config> — the GitHub App installations jonathan's
# config names, one per line: `<app_id> <installation_id>` for the personal
# installation first, then `<app_id> <installation_id> <owner>` for each
# ORG_INSTALLATIONS entry (owner lowercased). The single reader of
# ~/.config/github-app/config for the App key broker's clients
# (home/github-app-mint.nix, home/github-app-mcp.nix).
#
# The file is shell-assignment syntax but is read strictly as data: values are
# never evaluated, a value needing expansion is refused without being echoed,
# and keys other than APP_ID, INSTALLATION_ID and ORG_INSTALLATIONS (KEY_PATH,
# TOKEN_ROOT, ...) are inert. Any invalid entry fails the whole listing, so a
# client never acts on a half-read config.
pkgs.writeShellApplication {
  name = "github-app-installations";
  text = ''
    die() {
      echo "github-app-installations: $*" >&2
      exit 1
    }

    [ "$#" -eq 1 ] || die "usage: github-app-installations <config>"
    config="$1"
    [ -r "$config" ] || die "cannot read config: $config"

    app_id=""
    installation_id=""
    org_installations=""
    seen_app_id=""
    seen_installation_id=""
    seen_org_installations=""

    while IFS= read -r line || [ -n "$line" ]; do
      line="''${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        die "malformed config line in $config"
      fi

      key="''${BASH_REMATCH[2]}"
      value="''${BASH_REMATCH[3]}"

      # Trailing horizontal whitespace is shell syntax, not part of the value.
      while [[ "$value" == *[[:space:]] ]]; do
        value="''${value%?}"
      done

      # In an unquoted shell word, whitespace starts an optional trailing
      # comment. A # without preceding whitespace remains data.
      case "$value" in
        \"* | \'*) ;;
        *)
          if [[ "$value" =~ ^(.*)[[:space:]]+\#.*$ ]]; then
            value="''${BASH_REMATCH[1]}"
            while [[ "$value" == *[[:space:]] ]]; do
              value="''${value%?}"
            done
          fi
          ;;
      esac

      # Strip one matching quote pair only. This is syntax recognition, not
      # evaluation: the contents stay byte-for-byte data.
      case "$value" in
        \"*\") value="''${value:1:''${#value}-2}" ;;
        \'*\') value="''${value:1:''${#value}-2}" ;;
      esac

      case "$key" in
        APP_ID | INSTALLATION_ID | ORG_INSTALLATIONS)
          case "$value" in
            *'$'* | *'`'*)
              die "config key $key requires shell expansion; this reader takes the file as data"
              ;;
          esac
          ;;
      esac

      case "$key" in
        APP_ID)
          [ -z "$seen_app_id" ] || die "duplicate APP_ID in $config"
          app_id="$value"
          seen_app_id=1
          ;;
        INSTALLATION_ID)
          [ -z "$seen_installation_id" ] || die "duplicate INSTALLATION_ID in $config"
          installation_id="$value"
          seen_installation_id=1
          ;;
        ORG_INSTALLATIONS)
          [ -z "$seen_org_installations" ] \
            || die "duplicate ORG_INSTALLATIONS in $config"
          org_installations="$value"
          seen_org_installations=1
          ;;
      esac
    done < "$config"

    [[ "$app_id" =~ ^[0-9]+$ ]] \
      || die "APP_ID in $config must be numeric"
    [[ "$installation_id" =~ ^[0-9]+$ ]] \
      || die "INSTALLATION_ID in $config must be numeric"

    lines=("$app_id $installation_id")
    declare -A seen_owners=()
    org_pairs=()
    read -r -a org_pairs <<< "$org_installations"
    for pair in "''${org_pairs[@]}"; do
      owner="''${pair%%=*}"
      owner="''${owner,,}"
      [[ "$pair" == *=* ]] \
        || die "ORG_INSTALLATIONS entry for owner '$owner' is malformed; expected owner=numeric-id"
      [[ "$owner" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
        || die "ORG_INSTALLATIONS entry for owner '$owner' has an invalid login"
      [[ "''${pair#*=}" =~ ^[0-9]+$ ]] \
        || die "ORG_INSTALLATIONS entry for owner '$owner' must have a numeric installation id"
      [ -z "''${seen_owners[$owner]:-}" ] \
        || die "ORG_INSTALLATIONS contains duplicate entries for owner '$owner'"
      seen_owners[$owner]=1
      lines+=("$app_id ''${pair#*=} $owner")
    done
    printf '%s\n' "''${lines[@]}"
  '';
}
